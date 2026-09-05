#ifndef LEPTON_USB_STREAM_H
#define LEPTON_USB_STREAM_H

#include "video_receiver.h"

void usb_stream_send_frame(const struct thermal_frame *frame);

#endif
