#include "fpga_config.h"

#include "board_config.h"
#include "hardware/gpio.h"
#include "hardware/spi.h"
#include "pico/stdlib.h"

static void configure_output(uint pin, bool value) {
    gpio_init(pin);
    gpio_put(pin, value);
    gpio_set_dir(pin, GPIO_OUT);
}

int fpga_program_image(const uint8_t *data, size_t length) {
    if (data == NULL || length == 0u) {
        return -1;
    }

    configure_output(FPGA_PIN_OSC_EN, true);
    sleep_ms(FPGA_OSC_STARTUP_MS);
    configure_output(FPGA_PIN_CS_N, true);
    configure_output(FPGA_PIN_CRESET_N, true);
    gpio_init(FPGA_PIN_CDONE);
    gpio_set_dir(FPGA_PIN_CDONE, GPIO_IN);
    gpio_init(FPGA_PIN_STATUS);
    gpio_set_dir(FPGA_PIN_STATUS, GPIO_IN);

    spi_init(FPGA_SPI_INSTANCE, FPGA_SPI_BAUD_HZ);
    spi_set_format(FPGA_SPI_INSTANCE, 8, SPI_CPOL_1, SPI_CPHA_1, SPI_MSB_FIRST);
    gpio_set_function(FPGA_PIN_MOSI, GPIO_FUNC_SPI);
    gpio_set_function(FPGA_PIN_SCK, GPIO_FUNC_SPI);

    gpio_put(FPGA_PIN_CS_N, false);
    gpio_put(FPGA_PIN_CRESET_N, false);
    sleep_ms(FPGA_RESET_LOW_MS);
    gpio_put(FPGA_PIN_CRESET_N, true);
    sleep_ms(FPGA_RESET_RELEASE_MS);

    if (spi_write_blocking(FPGA_SPI_INSTANCE, data, length) != (int)length) {
        gpio_put(FPGA_PIN_CS_N, true);
        return -2;
    }

    static const uint8_t trailing_clocks[FPGA_EXTRA_CLOCK_BYTES] = {0};
    if (spi_write_blocking(FPGA_SPI_INSTANCE, trailing_clocks,
                           sizeof(trailing_clocks)) != (int)sizeof(trailing_clocks)) {
        gpio_put(FPGA_PIN_CS_N, true);
        return -3;
    }

    absolute_time_t deadline = make_timeout_time_ms(FPGA_DONE_TIMEOUT_MS);
    while (!gpio_get(FPGA_PIN_CDONE)) {
        if (time_reached(deadline)) {
            gpio_put(FPGA_PIN_CS_N, true);
            return -4;
        }
        tight_loop_contents();
    }

    gpio_put(FPGA_PIN_CS_N, true);
    spi_deinit(FPGA_SPI_INSTANCE);
    return 0;
}

uint32_t fpga_config_pin_state(void) {
    uint32_t state = 0;
    if (gpio_get(FPGA_PIN_CDONE)) {
        state |= 1u;
    }
    if (gpio_get(FPGA_PIN_STATUS)) {
        state |= 2u;
    }
    return state;
}
