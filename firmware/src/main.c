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
#include "usb_stream.h"
#include "video_receiver.h"

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
            if (length == 3u && command[0] == 'F' && command[1] == 'F' &&
                command[2] == 'C') {
                (void)lepton_cci_run_ffc();
            }
            length = 0;
        } else if (length + 1u < sizeof(command)) {
            command[length++] = character;
        } else {
            length = 0;
        }
    }
}

int main(void) {
    stdio_usb_init();
    lepton_cci_init();

    // Configure the FPGA immediately so it controls VoSPI CS and SCK throughout
    // Lepton startup. The FPGA holds both signals idle for seven seconds,
    // leaving time for camera boot, CCI setup, and receiver initialization.
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


    // The shuttered Lepton 3.5 performs an automatic FFC during boot.  FLIR's
    // Software IDD requires a five-second delay before the first CCI access.
    for (uint32_t elapsed_ms = 0; elapsed_ms < LEPTON_STARTUP_DELAY_MS;
         elapsed_ms += 1000u) {
        sleep_ms(1000);
        if (stdio_usb_connected()) {
            printf("LEPTON_BOOT camera_wait_ms=%lu\n",
                   (unsigned long)(LEPTON_STARTUP_DELAY_MS - elapsed_ms - 1000u));
            stdio_flush();
        }
    }

    int camera_result;
    while ((camera_result = lepton_cci_configure()) != 0) {
        printf("LEPTON_ERROR cci=%d camera=%d sda=%u scl=%u\n",
               camera_result, lepton_cci_last_camera_error(),
               gpio_get(LEPTON_PIN_SDA), gpio_get(LEPTON_PIN_SCL));
        stdio_flush();
        sleep_ms(1000);
    }
    printf("LEPTON_BOOT camera=ok\n");
    stdio_flush();

    video_receiver_init();
    uint32_t next_status_ms = to_ms_since_boot(get_absolute_time()) + 1000u;

    for (;;) {
        video_receiver_poll();
        service_host_commands();

        struct thermal_frame frame;
        if (stdio_usb_connected() && video_receiver_take_frame(&frame)) {
            usb_stream_send_frame(&frame);
            video_receiver_release_frame();
        }

        uint32_t now_ms = to_ms_since_boot(get_absolute_time());
        if (stdio_usb_connected() && (int32_t)(now_ms - next_status_ms) >= 0) {
            printf("LEPTON_STATUS pins=0x%lx rx=%lu transport=%lu hdr=%lu "
                   "seg=%lu,%lu,%lu,%lu fpgaerr=%u code=%u raw=0x%03x exp=%u got=%u\n",
                   (unsigned long)fpga_config_pin_state(),
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
