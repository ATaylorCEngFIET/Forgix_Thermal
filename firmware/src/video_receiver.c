#include "video_receiver.h"

#include <stddef.h>
#include <string.h>

#include "board_config.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"
#include "pico/stdlib.h"

enum parser_state {
    PARSER_SEARCH_MAGIC,
    PARSER_HEADER,
    PARSER_PAYLOAD,
};

static uint8_t g_dma_ring[FPGA_UART_RX_RING_SIZE]
    __attribute__((aligned(FPGA_UART_RX_RING_SIZE)));
static uint32_t g_dma_read_index;
static int g_dma_channel;

static uint8_t g_frame_buffers[2][LEPTON_FRAME_BYTES];
static unsigned g_assembly_index;
static unsigned g_ready_index;
static bool g_ready;
static bool g_assembling;
static bool g_accept_segment;
static uint8_t g_expected_segment;
static uint8_t g_segment;
static uint16_t g_assembly_frame;
static uint16_t g_fpga_errors;
static uint16_t g_ready_frame;
static uint16_t g_ready_fpga_errors;
static uint32_t g_ready_dropped_frames;
static uint32_t g_ready_timestamp_ms;
static uint32_t g_dropped_frames;
static uint32_t g_transport_errors;
static uint32_t g_received_bytes;
static uint32_t g_valid_headers;
static uint32_t g_segment_counts[5];
static uint16_t g_last_fpga_error_detail;

static enum parser_state g_parser_state;
static uint32_t g_magic_window;
static uint8_t g_header[16];
static size_t g_header_index;
static size_t g_payload_index;
static size_t g_payload_length;
static uint8_t g_packed_pixels[3];

static void configure_uart_dma(void) {
    uart_init(FPGA_UART_INSTANCE, FPGA_UART_BAUD_HZ);
    uart_set_format(FPGA_UART_INSTANCE, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(FPGA_UART_INSTANCE, true);
    // Forgix reuses RP2354 GPIO2/GPIO3 after passive-SPI configuration.
    // On these pads UART function 2 is CTS/RTS; function 11 (UART_AUX) is
    // the UART0 TX/RX mapping needed by the FPGA runtime link.
    gpio_set_function(FPGA_UART_PIN_TX, GPIO_FUNC_UART_AUX);
    gpio_set_function(FPGA_UART_PIN_RX, GPIO_FUNC_UART_AUX);

    g_dma_read_index = 0;
    dma_channel_config config = dma_channel_get_default_config(g_dma_channel);
    channel_config_set_transfer_data_size(&config, DMA_SIZE_8);
    channel_config_set_read_increment(&config, false);
    channel_config_set_write_increment(&config, true);
    channel_config_set_dreq(&config, DREQ_UART0_RX);
    channel_config_set_ring(&config, true, FPGA_UART_RX_RING_BITS);
    dma_channel_configure(g_dma_channel, &config,
                          g_dma_ring, &uart_get_hw(FPGA_UART_INSTANCE)->dr,
                          0xffffffffu, true);
}

static uint16_t read_u16_le(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8u);
}

static uint8_t header_checksum(const uint8_t *header) {
    uint8_t checksum = 0;
    for (size_t index = 0; index < 15u; ++index) {
        checksum ^= header[index];
    }
    return checksum;
}

static void reset_parser(void) {
    g_parser_state = PARSER_SEARCH_MAGIC;
    g_magic_window = 0;
    g_header_index = 0;
    g_payload_index = 0;
    g_payload_length = 0;
    g_accept_segment = false;
}

static void begin_segment(void) {
    g_segment = g_header[5];
    uint16_t frame = read_u16_le(g_header + 8);
    g_fpga_errors = read_u16_le(g_header + 12);
    g_payload_length = read_u16_le(g_header + 10);
    g_payload_index = 0;
    g_accept_segment = false;
    ++g_valid_headers;
    if (g_segment <= 4u) {
        ++g_segment_counts[g_segment];
    }

    if (g_segment == 0u) {
        g_last_fpga_error_detail = frame;
        g_assembling = false;
        g_expected_segment = 1;
        reset_parser();
        return;
    }

    if (g_header[6] != 4u || g_payload_length != FPGA_STREAM_SEGMENT_BYTES ||
        g_segment > 4u) {
        ++g_transport_errors;
        reset_parser();
        return;
    }

    if (g_segment == 1u) {
        g_assembly_frame = frame;
        g_expected_segment = 1;
        g_assembling = true;
        g_accept_segment = true;
    } else if (g_assembling && frame == g_assembly_frame &&
               g_segment == g_expected_segment) {
        g_accept_segment = true;
    } else {
        ++g_transport_errors;
        g_assembling = false;
    }
    g_parser_state = PARSER_PAYLOAD;
}

static void finish_segment(void) {
    if (g_accept_segment) {
        if (g_segment == 4u) {
            if (g_ready) {
                ++g_dropped_frames;
            } else {
                g_ready_index = g_assembly_index;
                g_ready_frame = g_assembly_frame;
                g_ready_fpga_errors = g_fpga_errors;
                g_ready_dropped_frames = g_dropped_frames;
                g_ready_timestamp_ms = to_ms_since_boot(get_absolute_time());
                g_ready = true;
                g_assembly_index ^= 1u;
            }
            g_assembling = false;
            g_expected_segment = 1;
        } else {
            g_expected_segment = g_segment + 1u;
        }
    }
    reset_parser();
}

static void consume_byte(uint8_t byte) {
    switch (g_parser_state) {
    case PARSER_SEARCH_MAGIC:
        g_magic_window = (g_magic_window << 8u) | byte;
        if (g_magic_window == 0x4c50544eu) { // "LPTN"
            g_header[0] = 'L';
            g_header[1] = 'P';
            g_header[2] = 'T';
            g_header[3] = 'N';
            g_header_index = 4;
            g_parser_state = PARSER_HEADER;
        }
        break;

    case PARSER_HEADER:
        g_header[g_header_index++] = byte;
        if (g_header_index == sizeof(g_header)) {
            if (g_header[4] != 1u || g_header[7] != sizeof(g_header) ||
                g_header[14] != 0xb5u || header_checksum(g_header) != g_header[15]) {
                ++g_transport_errors;
                reset_parser();
            } else {
                begin_segment();
            }
        }
        break;

    case PARSER_PAYLOAD:
        if (g_accept_segment && g_payload_index < FPGA_STREAM_SEGMENT_BYTES) {
            size_t segment_offset = ((size_t)g_segment - 1u) * LEPTON_SEGMENT_BYTES;
            size_t packed_offset = g_payload_index % 3u;
            g_packed_pixels[packed_offset] = byte;
            if (packed_offset == 2u) {
                size_t output_offset = segment_offset + (g_payload_index / 3u) * 4u;
                uint16_t pixel_a = (uint16_t)(((uint16_t)g_packed_pixels[0] << 4u) |
                                              (g_packed_pixels[1] >> 4u)) << 2u;
                uint16_t pixel_b = (uint16_t)(((uint16_t)(g_packed_pixels[1] & 0x0fu) << 8u) |
                                              g_packed_pixels[2]) << 2u;
                g_frame_buffers[g_assembly_index][output_offset] = (uint8_t)pixel_a;
                g_frame_buffers[g_assembly_index][output_offset + 1u] = (uint8_t)(pixel_a >> 8u);
                g_frame_buffers[g_assembly_index][output_offset + 2u] = (uint8_t)pixel_b;
                g_frame_buffers[g_assembly_index][output_offset + 3u] = (uint8_t)(pixel_b >> 8u);
            }
        }
        ++g_payload_index;
        if (g_payload_index == g_payload_length) {
            finish_segment();
        }
        break;
    }
}

void video_receiver_init(void) {
    memset(g_frame_buffers, 0, sizeof(g_frame_buffers));
    g_dma_read_index = 0;
    g_assembly_index = 0;
    g_ready_index = 0;
    g_ready = false;
    g_assembling = false;
    g_expected_segment = 1;
    g_dropped_frames = 0;
    g_transport_errors = 0;
    g_received_bytes = 0;
    g_valid_headers = 0;
    memset(g_segment_counts, 0, sizeof(g_segment_counts));
    g_last_fpga_error_detail = 0;
    reset_parser();

    g_dma_channel = dma_claim_unused_channel(true);
    configure_uart_dma();
}

void video_receiver_quiesce(void) {
    dma_channel_abort(g_dma_channel);
    uart_deinit(FPGA_UART_INSTANCE);
    g_ready = false;
    g_assembling = false;
    g_expected_segment = 1u;
    reset_parser();
}

void video_receiver_restart(void) {
    g_ready = false;
    g_assembling = false;
    g_expected_segment = 1u;
    reset_parser();
    configure_uart_dma();
}

void video_receiver_poll(void) {
    uintptr_t base = (uintptr_t)g_dma_ring;
    uintptr_t write_address = dma_hw->ch[g_dma_channel].write_addr;
    uint32_t write_index = (uint32_t)((write_address - base) &
                                      (FPGA_UART_RX_RING_SIZE - 1u));
    while (g_dma_read_index != write_index) {
        consume_byte(g_dma_ring[g_dma_read_index]);
        ++g_received_bytes;
        g_dma_read_index = (g_dma_read_index + 1u) &
                           (FPGA_UART_RX_RING_SIZE - 1u);
        write_address = dma_hw->ch[g_dma_channel].write_addr;
        write_index = (uint32_t)((write_address - base) &
                                 (FPGA_UART_RX_RING_SIZE - 1u));
    }
}

bool video_receiver_take_frame(struct thermal_frame *frame) {
    if (!g_ready || frame == NULL) {
        return false;
    }
    frame->pixels_le16 = g_frame_buffers[g_ready_index];
    frame->fpga_frame_counter = g_ready_frame;
    frame->fpga_error_count = g_ready_fpga_errors;
    frame->timestamp_ms = g_ready_timestamp_ms;
    frame->dropped_frames = g_ready_dropped_frames;
    return true;
}

void video_receiver_release_frame(void) {
    g_ready = false;
}

uint32_t video_receiver_transport_errors(void) {
    return g_transport_errors;
}

uint32_t video_receiver_bytes_received(void) {
    return g_received_bytes;
}

uint32_t video_receiver_valid_headers(void) {
    return g_valid_headers;
}

uint32_t video_receiver_segments_received(uint8_t segment) {
    return segment <= 4u ? g_segment_counts[segment] : 0u;
}

uint16_t video_receiver_fpga_errors(void) {
    return g_fpga_errors;
}

uint8_t video_receiver_last_fpga_error_code(void) {
    return (uint8_t)(g_last_fpga_error_detail >> 12u);
}

uint16_t video_receiver_last_fpga_error_value(void) {
    return g_last_fpga_error_detail & 0x0fffu;
}

uint8_t video_receiver_last_fpga_error_expected(void) {
    return (uint8_t)((g_last_fpga_error_detail >> 6u) & 0x3fu);
}

uint8_t video_receiver_last_fpga_error_actual(void) {
    return (uint8_t)(g_last_fpga_error_detail & 0x3fu);
}
