#ifndef LEPTON_VIDEO_RECEIVER_H
#define LEPTON_VIDEO_RECEIVER_H

#include <stdbool.h>
#include <stdint.h>

#include "board_config.h"

struct thermal_frame {
    const uint8_t *pixels_le16;
    uint16_t fpga_frame_counter;
    uint16_t fpga_error_count;
    uint32_t timestamp_ms;
    uint32_t dropped_frames;
};

void video_receiver_init(void);
void video_receiver_quiesce(void);
void video_receiver_restart(void);
void video_receiver_poll(void);
bool video_receiver_take_frame(struct thermal_frame *frame);
void video_receiver_release_frame(void);
uint32_t video_receiver_transport_errors(void);
uint32_t video_receiver_bytes_received(void);
uint32_t video_receiver_valid_headers(void);
uint32_t video_receiver_segments_received(uint8_t segment);
uint16_t video_receiver_fpga_errors(void);
uint8_t video_receiver_last_fpga_error_code(void);
uint16_t video_receiver_last_fpga_error_value(void);
uint8_t video_receiver_last_fpga_error_expected(void);
uint8_t video_receiver_last_fpga_error_actual(void);

#endif
