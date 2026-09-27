#include "thermal_display.h"

#include <stddef.h>

#include "board_config.h"
#include "hardware/dma.h"
#include "hardware/uart.h"

enum {
    DISPLAY_HEADER_BYTES = 8,
    DISPLAY_PIXEL_BYTES = DISPLAY_FRAME_BYTES,
    DISPLAY_TRANSFER_BYTES = DISPLAY_HEADER_BYTES + DISPLAY_PIXEL_BYTES,
};

static uint8_t g_tx_buffer[DISPLAY_TRANSFER_BYTES];
static int g_tx_dma_channel;
static uint32_t g_frames_sent;

static uint16_t read_u16_le(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8u);
}

static uint16_t thermal_palette(uint8_t level) {
    uint8_t red;
    uint8_t green;
    uint8_t blue;

    if (level < 64u) {
        red = 0u;
        green = 0u;
        blue = (uint8_t)(level << 2u);
    } else if (level < 128u) {
        red = (uint8_t)((level - 64u) << 2u);
        green = 0u;
        blue = 255u;
    } else if (level < 192u) {
        red = 255u;
        green = (uint8_t)((level - 128u) << 2u);
        blue = (uint8_t)(255u - ((level - 128u) << 2u));
    } else {
        red = 255u;
        green = 255u;
        blue = (uint8_t)((level - 192u) << 2u);
    }

    return (uint16_t)(((uint16_t)(red & 0xf8u) << 8u) |
                      ((uint16_t)(green & 0xfcu) << 3u) |
                      ((uint16_t)blue >> 3u));
}

static void write_rgb565(size_t pixel_index, uint16_t color) {
    size_t offset = DISPLAY_HEADER_BYTES + pixel_index * 2u;
    g_tx_buffer[offset] = (uint8_t)(color >> 8u);
    g_tx_buffer[offset + 1u] = (uint8_t)color;
}

static void start_transfer(void) {
    static const uint8_t header[DISPLAY_HEADER_BYTES] = {
        'L', 'C', 'D', '0', 0x01u, 0xa5u, 0x5au, 0xc3u,
    };
    for (size_t index = 0; index < DISPLAY_HEADER_BYTES; ++index) {
        g_tx_buffer[index] = header[index];
    }

    dma_channel_set_read_addr(g_tx_dma_channel, g_tx_buffer, false);
    dma_channel_set_trans_count(g_tx_dma_channel, DISPLAY_TRANSFER_BYTES, true);
    ++g_frames_sent;
}

void thermal_display_init(void) {
    g_frames_sent = 0;
    g_tx_dma_channel = dma_claim_unused_channel(true);
    dma_channel_config config = dma_channel_get_default_config(g_tx_dma_channel);
    channel_config_set_transfer_data_size(&config, DMA_SIZE_8);
    channel_config_set_read_increment(&config, true);
    channel_config_set_write_increment(&config, false);
    channel_config_set_dreq(&config, DREQ_UART0_TX);
    dma_channel_configure(g_tx_dma_channel, &config,
                          &uart_get_hw(FPGA_UART_INSTANCE)->dr,
                          g_tx_buffer, 0u, false);
}

void thermal_display_abort(void) {
    dma_channel_abort(g_tx_dma_channel);
}

bool thermal_display_busy(void) {
    return dma_channel_is_busy(g_tx_dma_channel);
}

bool thermal_display_submit_frame(const struct thermal_frame *frame) {
    if (frame == NULL || frame->pixels_le16 == NULL || thermal_display_busy()) {
        return false;
    }

    uint16_t minimum = UINT16_MAX;
    uint16_t maximum = 0u;
    for (size_t index = 0; index < LEPTON_WIDTH * LEPTON_HEIGHT; ++index) {
        uint16_t value = read_u16_le(frame->pixels_le16 + index * 2u);
        if (value != 0u && value != UINT16_MAX) {
            if (value < minimum) {
                minimum = value;
            }
            if (value > maximum) {
                maximum = value;
            }
        }
    }
    if (minimum == UINT16_MAX) {
        minimum = 0u;
        maximum = 1u;
    } else if (maximum <= minimum + 15u) {
        maximum = (uint16_t)(minimum + 15u);
    }

    uint32_t range = (uint32_t)maximum - minimum;
    for (uint32_t y = 0; y < DISPLAY_HEIGHT; ++y) {
        uint32_t source_y = (y * LEPTON_HEIGHT) / DISPLAY_HEIGHT;
        for (uint32_t x = 0; x < DISPLAY_WIDTH; ++x) {
            uint32_t source_x = (x * LEPTON_WIDTH) / DISPLAY_WIDTH;
            size_t source_index = (size_t)source_y * LEPTON_WIDTH + source_x;
            uint16_t value = read_u16_le(frame->pixels_le16 + source_index * 2u);
            uint8_t level;
            if (value <= minimum) {
                level = 0u;
            } else if (value >= maximum) {
                level = 255u;
            } else {
                level = (uint8_t)(((uint32_t)(value - minimum) * 255u) / range);
            }
            write_rgb565((size_t)y * DISPLAY_WIDTH + x,
                         thermal_palette(level));
        }
    }

    start_transfer();
    return true;
}

bool thermal_display_submit_test_pattern(uint32_t phase) {
    static const uint16_t bars[8] = {
        0xffffu, 0xffe0u, 0x07ffu, 0x07e0u,
        0xf81fu, 0xf800u, 0x001fu, 0x0000u,
    };
    if (thermal_display_busy()) {
        return false;
    }

    uint32_t marker = phase % DISPLAY_WIDTH;
    for (uint32_t y = 0; y < DISPLAY_HEIGHT; ++y) {
        for (uint32_t x = 0; x < DISPLAY_WIDTH; ++x) {
            uint16_t color;
            if (y < (DISPLAY_HEIGHT * 2u) / 3u) {
                color = bars[(x * 8u) / DISPLAY_WIDTH];
            } else {
                uint8_t level = (uint8_t)((x * 255u) / (DISPLAY_WIDTH - 1u));
                color = thermal_palette(level);
            }
            if (x == marker || y == 0u || y == DISPLAY_HEIGHT - 1u) {
                color = 0xffffu;
            }
            write_rgb565((size_t)y * DISPLAY_WIDTH + x, color);
        }
    }

    start_transfer();
    return true;
}

uint32_t thermal_display_frames_sent(void) {
    return g_frames_sent;
}
