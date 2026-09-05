#ifndef LEPTON_CRC32_H
#define LEPTON_CRC32_H

#include <stddef.h>
#include <stdint.h>

uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t len);

#endif
