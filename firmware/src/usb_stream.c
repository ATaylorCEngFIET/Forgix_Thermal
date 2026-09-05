#include "usb_stream.h"

#include <stddef.h>
#include <stdint.h>

#include "board_config.h"
#include "crc32.h"
#include "pico/stdio.h"

enum {
    USB_HEADER_SIZE = 32,
    USB_PROTOCOL_VERSION = 1,
    USB_FRAME_TYPE_IMAGE = 1,
    USB_FLAG_TLINEAR_0_01K = 1u << 0,
};

static uint32_t g_usb_sequence;

static void write_u16_le(uint8_t *data, uint16_t value) {
    data[0] = (uint8_t)value;
    data[1] = (uint8_t)(value >> 8u);
}

static void write_u32_le(uint8_t *data, uint32_t value) {
    data[0] = (uint8_t)value;
    data[1] = (uint8_t)(value >> 8u);
    data[2] = (uint8_t)(value >> 16u);
    data[3] = (uint8_t)(value >> 24u);
}

static void send_bytes(const uint8_t *data, size_t length) {
    while (length != 0u) {
        int chunk = length > 1024u ? 1024 : (int)length;
        stdio_put_string((const char *)data, chunk, false, false);
        data += chunk;
        length -= (size_t)chunk;
    }
}

void usb_stream_send_frame(const struct thermal_frame *frame) {
    if (frame == NULL || frame->pixels_le16 == NULL) {
        return;
    }

    uint8_t header[USB_HEADER_SIZE] = {0};
    header[0] = 'L';
    header[1] = 'P';
    header[2] = 'T';
    header[3] = 'F';
    header[4] = USB_PROTOCOL_VERSION;
    header[5] = USB_FRAME_TYPE_IMAGE;
    write_u16_le(header + 6, USB_FLAG_TLINEAR_0_01K);
    write_u32_le(header + 8, g_usb_sequence++);
    write_u32_le(header + 12, frame->timestamp_ms);
    write_u16_le(header + 16, LEPTON_WIDTH);
    write_u16_le(header + 18, LEPTON_HEIGHT);
    write_u32_le(header + 20, LEPTON_FRAME_BYTES);
    write_u32_le(header + 24,
                 crc32_update(0, frame->pixels_le16, LEPTON_FRAME_BYTES));
    write_u16_le(header + 28, frame->fpga_frame_counter);
    write_u16_le(header + 30, frame->fpga_error_count);

    send_bytes(header, sizeof(header));
    send_bytes(frame->pixels_le16, LEPTON_FRAME_BYTES);
    stdio_flush();
}
