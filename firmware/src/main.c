#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "board_config.h"
#include "fpga_config.h"
#include "fpga_image.h"
#include "lepton_cci.h"
#include "hardware/gpio.h"
#include "pico/stdio_usb.h"
#include "pico/stdlib.h"
#include "thermal_display.h"
#include "usb_stream.h"
#include "video_receiver.h"

static bool g_camera_configured;
static bool g_usb_stream_enabled;

static int recover_capture_link(void) {
    // GPIO2/GPIO3 are shared by passive FPGA configuration and the runtime
    // UART. Stop both DMA directions before taking the pads back for SPI.
    thermal_display_abort();
    video_receiver_quiesce();
    int result = fpga_program_image(g_forgix_lepton_fpga_image,
                                    g_forgix_lepton_fpga_image_size);
    // Restore UART0 and its circular RX DMA even when configuration failed so
    // status and a later watchdog retry remain possible.
    video_receiver_restart();
    return result;
}

static void service_host_commands(void) {
    static char command[16];
    static size_t length;
    for (;;) {
        int value = getchar_timeout_us(0);
        if (value == PICO_ERROR_TIMEOUT) {
            return;
        }
        char character = (char)value;
        if (character == '\r' || character == '\n') {
            command[length] = '\0';
            if (g_camera_configured && length == 3u && command[0] == 'F' &&
                command[1] == 'F' && command[2] == 'C') {
                (void)lepton_cci_run_ffc();
            } else if (length == 9u &&
                       command[0] == 'S' && command[1] == 'T' &&
                       command[2] == 'R' && command[3] == 'E' &&
                       command[4] == 'A' && command[5] == 'M' &&
                       command[6] == ' ' && command[7] == 'O' &&
                       command[8] == 'N') {
                g_usb_stream_enabled = true;
            } else if (length == 10u &&
                       command[0] == 'S' && command[1] == 'T' &&
                       command[2] == 'R' && command[3] == 'E' &&
                       command[4] == 'A' && command[5] == 'M' &&
                       command[6] == ' ' && command[7] == 'O' &&
                       command[8] == 'F' && command[9] == 'F') {
                g_usb_stream_enabled = false;
            }
            length = 0;
        } else if (length + 1u < sizeof(command)) {
            command[length++] = character;
        } else {
            length = 0;
        }
    }
}

static void report_camera_result(int result, const char *prefix) {
    printf("%s result=%d camera=%d sda=%u scl=%u\n", prefix, result,
           lepton_cci_last_camera_error(), gpio_get(LEPTON_PIN_SDA),
           gpio_get(LEPTON_PIN_SCL));
    stdio_flush();
}

int main(void) {
    stdio_usb_init();
    lepton_cci_init();

    // Configure the FPGA immediately so it controls VoSPI CS and SCK throughout
    // Lepton startup. The FPGA also initializes the ST7735S display.
    int fpga_result = fpga_program_image(g_forgix_lepton_fpga_image,
                                         g_forgix_lepton_fpga_image_size);
    if (fpga_result != 0) {
        for (;;) {
            printf("LEPTON_ERROR fpga=%d pins=0x%lx\n",
                   fpga_result, (unsigned long)fpga_config_pin_state());
            stdio_flush();
            sleep_ms(1000);
        }
    }
    printf("LEPTON_BOOT fpga=ok pins=0x%lx\n",
           (unsigned long)fpga_config_pin_state());
    stdio_flush();

    // The internal runtime UART is full duplex: FPGA-to-RP captured video is
    // received on GPIO3 while a TX DMA on GPIO2 sends LCD RGB565 frames.
    video_receiver_init();
    thermal_display_init();

    // The shuttered Lepton 3.5 performs an automatic FFC during boot. Keep the
    // receiver serviced and display a test pattern during the five-second wait.
    uint32_t now_ms = to_ms_since_boot(get_absolute_time());
    uint32_t camera_start_ms = now_ms + LEPTON_STARTUP_DELAY_MS;
    uint32_t next_pattern_ms = now_ms + 1000u;
    while ((int32_t)(to_ms_since_boot(get_absolute_time()) - camera_start_ms) < 0) {
        video_receiver_poll();
        now_ms = to_ms_since_boot(get_absolute_time());
        if ((int32_t)(now_ms - next_pattern_ms) >= 0) {
            (void)thermal_display_submit_test_pattern(now_ms / 20u);
            next_pattern_ms = now_ms + 1000u;
        }
        service_host_commands();
        tight_loop_contents();
    }

    int camera_result = lepton_cci_configure();
    g_camera_configured = camera_result == 0;
    if (g_camera_configured) {
        printf("LEPTON_BOOT camera=ok\n");
        stdio_flush();
    } else {
        report_camera_result(camera_result, "LEPTON_ERROR no_camera test_pattern=on");
    }

    now_ms = to_ms_since_boot(get_absolute_time());
    uint32_t next_status_ms = now_ms + 1000u;
    uint32_t next_camera_retry_ms = now_ms + LEPTON_RETRY_INTERVAL_MS;
    // Start the silence timer after configuration rather than at power-up.
    // This gives the FPGA's SPI-only synchronizer time to find segment one.
    uint32_t last_live_frame_ms = now_ms;
    uint32_t next_stream_recovery_ms = now_ms + LEPTON_STREAM_STALL_MS;
    uint32_t recovery_count = 0u;
    next_pattern_ms = now_ms;

    for (;;) {
        video_receiver_poll();
        service_host_commands();
        if (!stdio_usb_connected()) {
            // Drop a stale enable after a viewer disconnects so reconnecting
            // USB for power alone cannot fill CDC buffers and block capture.
            g_usb_stream_enabled = false;
        }

        struct thermal_frame frame;
        if (video_receiver_take_frame(&frame)) {
            (void)thermal_display_submit_frame(&frame);
            recovery_count = 0u;
            last_live_frame_ms = to_ms_since_boot(get_absolute_time());
            next_stream_recovery_ms =
                last_live_frame_ms + LEPTON_STREAM_STALL_MS;
            if (g_usb_stream_enabled && stdio_usb_connected()) {
                usb_stream_send_frame(&frame);
            }
            video_receiver_release_frame();
        }

        now_ms = to_ms_since_boot(get_absolute_time());
        if (now_ms - last_live_frame_ms >= 1000u &&
            (int32_t)(now_ms - next_pattern_ms) >= 0) {
            (void)thermal_display_submit_test_pattern(now_ms / 20u);
            next_pattern_ms = now_ms + 1000u;
        }

        if (g_camera_configured &&
            (int32_t)(now_ms - next_stream_recovery_ms) >= 0) {
            // Reload the capture link without rebooting the camera. A periodic
            // FFC can interrupt VoSPI while CCI and the imager remain healthy;
            // rebooting the Lepton during that transition can leave a breakout
            // powered but silent until its supply is cycled.
            // A camera can remain alive on CCI while VoSPI emits only discard
            // packets. Reboot it while the freshly loaded FPGA holds /CS high,
            // then restore and verify the video setup before acquisition.
            int reboot_result = lepton_cci_reboot();
            int link_result = recover_capture_link();
            sleep_ms(LEPTON_REBOOT_DELAY_MS);
            camera_result = lepton_cci_configure();
            g_camera_configured = camera_result == 0;
            ++recovery_count;
            now_ms = to_ms_since_boot(get_absolute_time());
            last_live_frame_ms = now_ms;
            next_stream_recovery_ms =
                now_ms + LEPTON_LINK_RECOVERY_GRACE_MS;
            if (stdio_usb_connected()) {
                printf("LEPTON_RECOVERY count=%lu reboot=%d camera=%d link=%d pins=0x%lx\n",
                       (unsigned long)recovery_count, reboot_result,
                       camera_result, link_result,
                       (unsigned long)fpga_config_pin_state());
                stdio_flush();
            }
        }

        if (!g_camera_configured &&
            (int32_t)(now_ms - next_camera_retry_ms) >= 0) {
            camera_result = lepton_cci_configure();
            g_camera_configured = camera_result == 0;
            now_ms = to_ms_since_boot(get_absolute_time());
            next_camera_retry_ms = now_ms + LEPTON_RETRY_INTERVAL_MS;
            if (g_camera_configured) {
                last_live_frame_ms = now_ms;
                next_stream_recovery_ms = now_ms + LEPTON_STREAM_STALL_MS;
            }
            if (stdio_usb_connected()) {
                report_camera_result(camera_result, "LEPTON_CAMERA_RETRY");
            }
        }

        if (stdio_usb_connected() && (int32_t)(now_ms - next_status_ms) >= 0) {
            printf("LEPTON_STATUS pins=0x%lx camera=%u lcd=%lu rx=%lu transport=%lu hdr=%lu "
                   "seg=%lu,%lu,%lu,%lu fpgaerr=%u code=%u raw=0x%03x exp=%u got=%u\n",
                   (unsigned long)fpga_config_pin_state(),
                   g_camera_configured ? 1u : 0u,
                   (unsigned long)thermal_display_frames_sent(),
                   (unsigned long)video_receiver_bytes_received(),
                   (unsigned long)video_receiver_transport_errors(),
                   (unsigned long)video_receiver_valid_headers(),
                   (unsigned long)video_receiver_segments_received(1u),
                   (unsigned long)video_receiver_segments_received(2u),
                   (unsigned long)video_receiver_segments_received(3u),
                   (unsigned long)video_receiver_segments_received(4u),
                   video_receiver_fpga_errors(),
                   video_receiver_last_fpga_error_code(),
                   video_receiver_last_fpga_error_value(),
                   video_receiver_last_fpga_error_expected(),
                   video_receiver_last_fpga_error_actual());
            stdio_flush();
            next_status_ms = now_ms + 1000u;
        }
        tight_loop_contents();
    }
}
