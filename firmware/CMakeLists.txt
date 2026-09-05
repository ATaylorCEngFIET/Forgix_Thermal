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
set(FPGA_IMAGE "${CMAKE_CURRENT_LIST_DIR}/../fpga/outflow/forgix_lepton.bin"
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

add_executable(forgix_lepton_bridge
  src/crc32.c
  src/fpga_config.c
  src/lepton_cci.c
  src/main.c
  src/usb_stream.c
  src/video_receiver.c
  "${GENERATED_IMAGE_C}"
)

target_include_directories(forgix_lepton_bridge PRIVATE include)
target_compile_options(forgix_lepton_bridge PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Werror>
)
target_compile_definitions(forgix_lepton_bridge PRIVATE
  PICO_STDIO_USB_CONNECTION_WITHOUT_DTR=1
)
target_link_libraries(forgix_lepton_bridge
  pico_stdlib
  hardware_dma
  hardware_i2c
  hardware_spi
  hardware_uart
)

pico_enable_stdio_usb(forgix_lepton_bridge 1)
pico_enable_stdio_uart(forgix_lepton_bridge 0)
pico_add_extra_outputs(forgix_lepton_bridge)
