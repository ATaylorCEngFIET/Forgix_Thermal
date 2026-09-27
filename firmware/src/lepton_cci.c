#include "lepton_cci.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#include "board_config.h"
#include "hardware/gpio.h"
#include "hardware/i2c.h"
#include "pico/stdlib.h"

enum {
    CCI_REG_STATUS = 0x0002,
    CCI_REG_COMMAND = 0x0004,
    CCI_REG_DATA_LENGTH = 0x0006,
    CCI_REG_DATA_0 = 0x0008,
};

enum {
    CCI_STATUS_BUSY = 1u << 0,
    CCI_STATUS_BOOTED = 1u << 2,
    CCI_OEM_PROTECTION = 0x4000,
    CCI_I2C_TIMEOUT_US = 20000,
};

enum {
    CMD_AGC_ENABLE_GET = 0x0100,
    CMD_AGC_ENABLE_SET = 0x0101,
    CMD_SYS_TELEMETRY_GET = 0x0218,
    CMD_SYS_TELEMETRY_SET = 0x0219,
    CMD_SYS_FFC_RUN = 0x0242,
    CMD_SYS_FFC_STATUS_GET = 0x0244,
    CMD_OEM_VIDEO_ENABLE_GET = CCI_OEM_PROTECTION | 0x0800 | 0x24,
    CMD_OEM_VIDEO_ENABLE_SET = CCI_OEM_PROTECTION | 0x0800 | 0x25,
    CMD_OEM_VIDEO_FORMAT_GET = CCI_OEM_PROTECTION | 0x0800 | 0x28,
    CMD_OEM_VIDEO_FORMAT_SET = CCI_OEM_PROTECTION | 0x0800 | 0x29,
    CMD_OEM_VIDEO_CHANNEL_GET = CCI_OEM_PROTECTION | 0x0800 | 0x30,
    CMD_OEM_VIDEO_CHANNEL_SET = CCI_OEM_PROTECTION | 0x0800 | 0x31,
    CMD_OEM_REBOOT = CCI_OEM_PROTECTION | 0x0800 | 0x42,
    CMD_OEM_STATUS_GET = CCI_OEM_PROTECTION | 0x0800 | 0x48,
    CMD_OEM_FRAME_MEAN_GET = CCI_OEM_PROTECTION | 0x0800 | 0x4c,
    CMD_OEM_GPIO_MODE_GET = CCI_OEM_PROTECTION | 0x0800 | 0x54,
    CMD_OEM_GPIO_MODE_SET = CCI_OEM_PROTECTION | 0x0800 | 0x55,
    CMD_OEM_VSYNC_PHASE_SET = CCI_OEM_PROTECTION | 0x0800 | 0x59,
    CMD_RAD_ENABLE_SET = CCI_OEM_PROTECTION | 0x0e00 | 0x11,
    CMD_RAD_TLINEAR_SET = CCI_OEM_PROTECTION | 0x0e00 | 0xc1,
    CMD_RAD_RESOLUTION_SET = CCI_OEM_PROTECTION | 0x0e00 | 0xc5,
};

static int g_last_camera_error;

static int write_register(uint16_t address, uint16_t value) {
    uint8_t data[4] = {
        (uint8_t)(address >> 8u), (uint8_t)address,
        (uint8_t)(value >> 8u), (uint8_t)value,
    };
    int written = i2c_write_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                                     data, sizeof(data), false, CCI_I2C_TIMEOUT_US);
    return written == (int)sizeof(data) ? 0 : -1;
}

static int read_register(uint16_t address, uint16_t *value) {
    uint8_t request[2] = {(uint8_t)(address >> 8u), (uint8_t)address};
    uint8_t response[2] = {0};
    if (i2c_write_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                           request, sizeof(request), true, CCI_I2C_TIMEOUT_US) != (int)sizeof(request)) {
        return -1;
    }
    if (i2c_read_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                          response, sizeof(response), false, CCI_I2C_TIMEOUT_US) != (int)sizeof(response)) {
        return -2;
    }
    *value = ((uint16_t)response[0] << 8u) | response[1];
    return 0;
}

static int write_words(uint16_t address, const uint16_t *words, size_t count) {
    if (count > 16u) {
        return -1;
    }
    uint8_t data[2u + 32u];
    data[0] = (uint8_t)(address >> 8u);
    data[1] = (uint8_t)address;
    for (size_t index = 0; index < count; ++index) {
        data[2u + 2u * index] = (uint8_t)(words[index] >> 8u);
        data[3u + 2u * index] = (uint8_t)words[index];
    }
    size_t length = 2u + count * 2u;
    int written = i2c_write_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                                     data, length, false, CCI_I2C_TIMEOUT_US);
    return written == (int)length ? 0 : -2;
}

static int read_words(uint16_t address, uint16_t *words, size_t count) {
    if (count > 16u) {
        return -1;
    }
    uint8_t request[2] = {(uint8_t)(address >> 8u), (uint8_t)address};
    uint8_t data[32];
    if (i2c_write_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                           request, sizeof(request), true, CCI_I2C_TIMEOUT_US) != (int)sizeof(request)) {
        return -2;
    }
    int length = (int)(count * 2u);
    if (i2c_read_timeout_us(LEPTON_I2C_INSTANCE, LEPTON_I2C_ADDRESS,
                          data, (size_t)length, false, CCI_I2C_TIMEOUT_US) != length) {
        return -3;
    }
    for (size_t index = 0; index < count; ++index) {
        words[index] = ((uint16_t)data[2u * index] << 8u) | data[2u * index + 1u];
    }
    return 0;
}

static int wait_idle(uint32_t timeout_ms, bool require_boot) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    while (!time_reached(deadline)) {
        uint16_t status = 0;
        if (read_register(CCI_REG_STATUS, &status) == 0) {
            bool booted = (status & CCI_STATUS_BOOTED) != 0u;
            bool busy = (status & CCI_STATUS_BUSY) != 0u;
            if ((!require_boot || booted) && !busy) {
                g_last_camera_error = (int8_t)(status >> 8u);
                return g_last_camera_error == 0 ? 0 : -2;
            }
        }
        sleep_ms(5);
    }
    return -1;
}

static int run_command(uint16_t command) {
    if (wait_idle(1000, true) != 0) {
        return -1;
    }
    if (write_register(CCI_REG_DATA_LENGTH, 0) != 0 ||
        write_register(CCI_REG_COMMAND, command) != 0) {
        return -2;
    }
    return wait_idle(5000, true);
}

static int start_command(uint16_t command) {
    if (wait_idle(1000, true) != 0) {
        return -1;
    }
    if (write_register(CCI_REG_DATA_LENGTH, 0) != 0 ||
        write_register(CCI_REG_COMMAND, command) != 0) {
        return -2;
    }
    return 0;
}

static int set_enum(uint16_t command, uint16_t value) {
    const uint16_t words[2] = {value, 0};
    if (wait_idle(1000, true) != 0) {
        return -1;
    }
    if (write_words(CCI_REG_DATA_0, words, 2) != 0 ||
        write_register(CCI_REG_DATA_LENGTH, 2) != 0 ||
        write_register(CCI_REG_COMMAND, command) != 0) {
        return -2;
    }
    return wait_idle(2000, true);
}

static int get_enum(uint16_t command, uint16_t *value) {
    uint16_t words[2] = {0};
    if (wait_idle(1000, true) != 0 ||
        write_register(CCI_REG_DATA_LENGTH, 2) != 0 ||
        write_register(CCI_REG_COMMAND, command) != 0 ||
        wait_idle(2000, true) != 0 ||
        read_words(CCI_REG_DATA_0, words, 2) != 0) {
        return -1;
    }
    *value = words[0];
    return 0;
}

static int get_u16(uint16_t command, uint16_t *value) {
    uint16_t word = 0;
    if (wait_idle(1000, true) != 0 ||
        write_register(CCI_REG_DATA_LENGTH, 1) != 0 ||
        write_register(CCI_REG_COMMAND, command) != 0 ||
        wait_idle(2000, true) != 0 ||
        read_words(CCI_REG_DATA_0, &word, 1) != 0) {
        return -1;
    }
    *value = word;
    return 0;
}

static int ensure_enum(uint16_t get_command, uint16_t set_command,
                       uint16_t expected) {
    uint16_t value = 0;
    if (get_enum(get_command, &value) != 0) {
        return -1;
    }
    if (value == expected) {
        return 0;
    }
    if (set_enum(set_command, expected) != 0) {
        return -2;
    }
    if (get_enum(get_command, &value) != 0 || value != expected) {
        return -3;
    }
    return 0;
}

void lepton_cci_init(void) {
    i2c_init(LEPTON_I2C_INSTANCE, LEPTON_I2C_BAUD_HZ);
    gpio_set_function(LEPTON_PIN_SDA, GPIO_FUNC_I2C);
    gpio_set_function(LEPTON_PIN_SCL, GPIO_FUNC_I2C);
    // Diagnostic build: use the RP2354's weak internal 3.3 V pull-ups.
    gpio_pull_up(LEPTON_PIN_SDA);
    gpio_pull_up(LEPTON_PIN_SCL);
    g_last_camera_error = 0;
}

int lepton_cci_configure(void) {
    if (wait_idle(2000, true) != 0) {
        return -1;
    }

    uint16_t ffc_status = 0;
    absolute_time_t deadline = make_timeout_time_ms(5000);
    do {
        if (get_enum(CMD_SYS_FFC_STATUS_GET, &ffc_status) == 0 && ffc_status == 0u) {
            break;
        }
        sleep_ms(25);
    } while (!time_reached(deadline));
    if (ffc_status != 0u) {
        return -2;
    }

    if (ensure_enum(CMD_SYS_TELEMETRY_GET, CMD_SYS_TELEMETRY_SET, 0) != 0) {
        return -3;
    }
    // Match the known-good Lepton 3.5 reference configuration. Avoid
    // rewriting an already-active video interface: query each field first
    // and only issue the corresponding SET command when it differs.
    if (ensure_enum(CMD_AGC_ENABLE_GET, CMD_AGC_ENABLE_SET, 1) != 0) {
        return -4;
    }
    if (ensure_enum(CMD_OEM_VIDEO_ENABLE_GET,
                    CMD_OEM_VIDEO_ENABLE_SET, 1) != 0) {
        return -5;
    }
    // RAW14 is enum value 7 in the FLIR Software IDD.
    if (ensure_enum(CMD_OEM_VIDEO_FORMAT_GET,
                    CMD_OEM_VIDEO_FORMAT_SET, 7) != 0) {
        return -6;
    }
    if (ensure_enum(CMD_OEM_VIDEO_CHANNEL_GET,
                    CMD_OEM_VIDEO_CHANNEL_SET, 1) != 0) {
        return -7;
    }
    if (ensure_enum(CMD_OEM_GPIO_MODE_GET,
                    CMD_OEM_GPIO_MODE_SET, 5) != 0 ||
        set_enum(CMD_OEM_VSYNC_PHASE_SET, 0) != 0) {
        return -8;
    }

    uint16_t oem_status = 0xffffu;
    uint16_t frame_mean = 0xffffu;
    int status_result = get_enum(CMD_OEM_STATUS_GET, &oem_status);
    int mean_result = get_u16(CMD_OEM_FRAME_MEAN_GET, &frame_mean);
    printf("LEPTON_CCI oem_result=%d oem=%u mean_result=%d mean=%u\n",
           status_result, oem_status, mean_result, frame_mean);
    stdio_flush();

    // Restart the VoSPI producer after applying the complete format/channel
    // configuration. A Lepton can remain CCI-responsive and generate frames
    // internally while its video interface emits discard packets only.
    if (set_enum(CMD_OEM_VIDEO_ENABLE_SET, 0) != 0) {
        return -15;
    }
    sleep_ms(20);
    if (set_enum(CMD_OEM_VIDEO_ENABLE_SET, 1) != 0) {
        return -16;
    }
    uint16_t video_enable = 0;
    if (get_enum(CMD_OEM_VIDEO_ENABLE_GET, &video_enable) != 0 ||
        video_enable != 1u) {
        return -17;
    }
    sleep_ms(200);
    return 0;
}

int lepton_cci_run_ffc(void) {
    return run_command(CMD_SYS_FFC_RUN);
}

int lepton_cci_reboot(void) {
    // The camera deliberately disappears from CCI immediately after accepting
    // this command, so do not wait for the usual command-complete response.
    return start_command(CMD_OEM_REBOOT);
}

int lepton_cci_last_camera_error(void) {
    return g_last_camera_error;
}
