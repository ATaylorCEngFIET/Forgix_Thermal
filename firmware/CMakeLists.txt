cmake_minimum_required(VERSION 3.13)

if(NOT DEFINED PICO_SDK_PATH AND DEFINED ENV{PICO_SDK_PATH})
  set(PICO_SDK_PATH "$ENV{PICO_SDK_PATH}")
endif()
if(NOT PICO_SDK_PATH)
  message(FATAL_ERROR "Set PICO_SDK_PATH to the Pico SDK source directory")
endif()

include("${PICO_SDK_PATH}/external/pico_sdk_import.cmake")

project(forgix_lepton_bridge C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
pico_sdk_init()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(DISPLAY_VARIANT "waveshare_1in8" CACHE STRING "LCD build variant")
set_property(CACHE DISPLAY_VARIANT PROPERTY STRINGS waveshare_1in8 adafruit_round_1in28)

if(DISPLAY_VARIANT STREQUAL "waveshare_1in8")
  set(FIRMWARE_TARGET "forgix_lepton_waveshare_1in8")
  set(DEFAULT_FPGA_IMAGE "${CMAKE_CURRENT_LIST_DIR}/../fpga/outflow/forgix_lepton.bin")
elseif(DISPLAY_VARIANT STREQUAL "adafruit_round_1in28")
  set(FIRMWARE_TARGET "forgix_lepton_adafruit_round_1in28")
  set(DEFAULT_FPGA_IMAGE "${CMAKE_CURRENT_LIST_DIR}/../fpga/outflow/forgix_lepton_round.bin")
else()
  message(FATAL_ERROR "Unknown DISPLAY_VARIANT: ${DISPLAY_VARIANT}")
endif()

set(FPGA_IMAGE "${DEFAULT_FPGA_IMAGE}"
    CACHE FILEPATH "Built Forgix Lepton passive-SPI image")
set(GENERATED_IMAGE_C "${CMAKE_CURRENT_BINARY_DIR}/generated/fpga_image.c")

add_custom_command(
  OUTPUT "${GENERATED_IMAGE_C}"
  COMMAND "${Python3_EXECUTABLE}"
          "${CMAKE_CURRENT_LIST_DIR}/scripts/bin_to_c.py"
          "${FPGA_IMAGE}" "${GENERATED_IMAGE_C}"
  DEPENDS "${FPGA_IMAGE}" "${CMAKE_CURRENT_LIST_DIR}/scripts/bin_to_c.py"
  COMMENT "Embedding Forgix Lepton FPGA image"
  VERBATIM
)

add_executable(${FIRMWARE_TARGET}
  src/crc32.c
  src/fpga_config.c
  src/lepton_cci.c
  src/main.c
  src/thermal_display.c
  src/usb_stream.c
  src/video_receiver.c
  "${GENERATED_IMAGE_C}"
)

target_include_directories(${FIRMWARE_TARGET} PRIVATE include)
target_compile_options(${FIRMWARE_TARGET} PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Werror>
)
target_link_libraries(${FIRMWARE_TARGET}
  pico_stdlib
  hardware_dma
  hardware_i2c
  hardware_spi
  hardware_uart
)

if(DISPLAY_VARIANT STREQUAL "adafruit_round_1in28")
  target_compile_definitions(${FIRMWARE_TARGET} PRIVATE DISPLAY_GC9A01A_ROUND=1)
endif()

pico_enable_stdio_usb(${FIRMWARE_TARGET} 1)
pico_enable_stdio_uart(${FIRMWARE_TARGET} 0)
pico_add_extra_outputs(${FIRMWARE_TARGET})
