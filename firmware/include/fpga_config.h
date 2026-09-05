#ifndef LEPTON_FPGA_CONFIG_H
#define LEPTON_FPGA_CONFIG_H

#include <stddef.h>
#include <stdint.h>

int fpga_program_image(const uint8_t *data, size_t length);
uint32_t fpga_config_pin_state(void);

#endif
