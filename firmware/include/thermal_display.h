#ifndef THERMAL_DISPLAY_H
#define THERMAL_DISPLAY_H

#include <stdbool.h>
#include <stdint.h>

#include "video_receiver.h"

void thermal_display_init(void);
void thermal_display_abort(void);
bool thermal_display_busy(void);
bool thermal_display_submit_frame(const struct thermal_frame *frame);
bool thermal_display_submit_test_pattern(uint32_t phase);
uint32_t thermal_display_frames_sent(void);

#endif
