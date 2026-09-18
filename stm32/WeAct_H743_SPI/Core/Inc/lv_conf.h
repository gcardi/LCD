/* LVGL v9 configuration for the STM32H743 / FPGA RGB565 display port. */
#ifndef LV_CONF_H
#define LV_CONF_H

/* Keep LVGL self-contained and bounded; the 32 KiB pool is separate from
 * FreeRTOS heap_4 and is allocated statically by LVGL. */
#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (32U * 1024U)
#define LV_USE_STDLIB_STRING LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_BUILTIN

/* The GuiTask is LVGL's sole rendering context.  The display flush-complete
 * flag is deliberately safe to set asynchronously from DisplayTask. */
#define LV_USE_OS LV_OS_NONE

#define LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_RGB565
#define LV_DEF_REFR_PERIOD 20
#define LV_DRAW_BUF_ALIGN 32
#define LV_DRAW_BUF_STRIDE_ALIGN 1
#define LV_DRAW_SW_DRAW_UNIT_CNT 1

#define LV_USE_LOG 0
#define LV_USE_THEME_DEFAULT 1
#define LV_THEME_DEFAULT_DARK 1
#define LV_USE_FLEX 1

/* The demo uses only compact built-in text; all image decoders and optional
 * desktop/vector backends retain LVGL's disabled defaults. */
#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_DEFAULT LV_FONT_DEFAULT_MONTSERRAT_14

#endif /* LV_CONF_H */
