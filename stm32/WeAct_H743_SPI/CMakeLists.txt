cmake_minimum_required(VERSION 3.22)

#
# This file is generated only once,
# and is not re-generated if converter is called multiple times.
#
# User is free to modify the file as much as necessary
#

# Setup compiler settings
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)


# Define the build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug")
endif()

# Set the project name
set(CMAKE_PROJECT_NAME WeAct_H743_SPI)

# Enable compile command to ease indexing with e.g. clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)

# Core project settings
project(${CMAKE_PROJECT_NAME})
message("Build type: " ${CMAKE_BUILD_TYPE})

# LVGL is deliberately vendored as a Git submodule.  Do not let a missing or
# uninitialised checkout turn into a later, unhelpful "lvgl.h not found" error.
set(LVGL_SUBMODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/lvgl")
if(NOT EXISTS "${LVGL_SUBMODULE_DIR}/CMakeLists.txt" OR
   NOT EXISTS "${LVGL_SUBMODULE_DIR}/lvgl.h")
    message(FATAL_ERROR
        "LVGL submodule is missing or not initialised.\n"
        "Expected files below: ${LVGL_SUBMODULE_DIR}\n\n"
        "From the repository root, run:\n"
        "  git submodule update --init --recursive\n\n"
        "If LVGL has not yet been registered as a submodule, run:\n"
        "  git submodule add --branch v9.6.0 https://github.com/lvgl/lvgl.git third_party/lvgl\n\n"
        "For a new clone, use:\n"
        "  git clone --recurse-submodules <repository-url>")
endif()

# Enable CMake support for ASM and C languages
enable_language(C ASM)

# Create an executable object type
add_executable(${CMAKE_PROJECT_NAME})

# Build only the LVGL core configured by Core/Inc/lv_conf.h.  The application
# owns the UI and display port; upstream examples and demos are not firmware
# dependencies.
set(LV_BUILD_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/Core/Inc/lv_conf.h" CACHE PATH
    "LVGL configuration header" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "Do not build upstream LVGL demos" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "Do not build upstream LVGL examples" FORCE)
set(CONFIG_LV_USE_THORVG OFF CACHE BOOL "No vector backend on the MCU" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "No vector backend on the MCU" FORCE)
set(LV_FETCH_DEPENDENCIES OFF CACHE BOOL "Never download LVGL dependencies while building" FORCE)
add_subdirectory("${LVGL_SUBMODULE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/lvgl")

# LVGL's upstream CMake glob intentionally compiles every optional backend
# even when its #if body is empty.  On this Cortex-M target no upstream driver,
# test, desktop/3D/vector backend, optional decoder or optional filesystem is
# enabled.  Excluding their source files keeps the first firmware build short
# and does not change the configured LVGL API.
get_target_property(LVGL_FIRMWARE_SOURCES lvgl SOURCES)
foreach(LVGL_DISABLED_SOURCE_REGEX
    "/src/(3d|debugging|drivers|libs|others)/"
    "/src/draw/(convert|dma2d|espressif|eve|nanovg|nema_gfx|nxp|opengles|renesas|sifli|vg_lite)/"
    "/src/font/(binfont_loader|font_manager|freetype|imgfont|tiny_ttf)/"
    "/src/fs/lv_fs_(arduino|fatfs|frogfs|littlefs|posix|stdio|win32)\\."
    "/src/image/(lv_bin_decoder|lv_bmp|lv_libjpeg_turbo|lv_libpng|lv_libwebp|lv_lodepng|lv_tjpgd)/")
    list(FILTER LVGL_FIRMWARE_SOURCES EXCLUDE REGEX "${LVGL_DISABLED_SOURCE_REGEX}")
endforeach()
# Generic format conversion is part of LVGL's draw-buffer core; it lives below
# src/draw/convert but does not select any hardware conversion backend.
list(APPEND LVGL_FIRMWARE_SOURCES
    "${LVGL_SUBMODULE_DIR}/src/draw/convert/lv_draw_buf_convert.c")
set_property(TARGET lvgl PROPERTY SOURCES "${LVGL_FIRMWARE_SOURCES}")

# Add STM32CubeMX generated sources
add_subdirectory(cmake/stm32cubemx)

# Link directories setup
target_link_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined library search paths
)

# Add sources to executable
target_sources(${CMAKE_PROJECT_NAME} PRIVATE
    Core/Src/lcd_spi.c
    Core/Src/lcd_text.c
    Core/Src/lcd_font_12x24.c
    Core/Src/spi_selftest.c
    Core/Src/display_task.c
    Core/Src/lvgl_port.c
    Core/Src/lvgl_demo.c
    Core/Src/touch_probe.c
    Core/Src/gt911_port.c
    # Add user sources here
)

target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
    "-T${CMAKE_CURRENT_SOURCE_DIR}/cmake/spi_dma.ld"
)

# Add include paths
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined include paths
)

# Add project symbols (macros)
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined symbols
)

# Remove wrong libob.a library dependency when using cpp files
list(REMOVE_ITEM CMAKE_C_IMPLICIT_LINK_LIBRARIES ob)

# Add linked libraries
target_link_libraries(${CMAKE_PROJECT_NAME}
    stm32cubemx
    lvgl

    # Add user defined libraries
)
