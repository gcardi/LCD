#include "lvgl_demo.h"
#include "lvgl.h"

volatile uint32_t g_lvgl_demo_state;
static lv_obj_t *value_label;
static lv_obj_t *progress_bar;
static uint32_t progress_value;

static void progress_timer(lv_timer_t *timer)
{
    (void)timer;
    progress_value=(progress_value+1u)%101u;
    lv_bar_set_value(progress_bar,(int32_t)progress_value,LV_ANIM_OFF);
    lv_label_set_text_fmt(value_label,"Flush demo: %lu%%",
                          (unsigned long)progress_value);
}

void LVGL_Demo_Create(void)
{
    lv_obj_t *screen=lv_screen_active();
    lv_obj_set_style_bg_color(screen,lv_color_hex(0x102030),0);
    lv_obj_set_style_bg_opa(screen,LV_OPA_COVER,0);

    lv_obj_t *title=lv_label_create(screen);
    lv_label_set_text(title,"Tang Nano + LVGL 9");
    lv_obj_set_style_text_font(title,&lv_font_montserrat_20,0);
    lv_obj_set_style_text_color(title,lv_color_hex(0x5EEAD4),0);
    lv_obj_align(title,LV_ALIGN_TOP_MID,0,22);

    lv_obj_t *description=lv_label_create(screen);
    lv_label_set_text(description,"RGB565 partial flush | COPY + PRESENT");
    lv_obj_set_style_text_color(description,lv_color_hex(0xCBD5E1),0);
    lv_obj_align(description,LV_ALIGN_TOP_MID,0,58);

    progress_bar=lv_bar_create(screen);
    lv_obj_set_size(progress_bar,320,24);
    lv_obj_align(progress_bar,LV_ALIGN_CENTER,0,12);
    lv_bar_set_range(progress_bar,0,100);
    lv_bar_set_value(progress_bar,0,LV_ANIM_OFF);
    lv_obj_set_style_bg_color(progress_bar,lv_color_hex(0x334155),LV_PART_MAIN);
    lv_obj_set_style_bg_color(progress_bar,lv_color_hex(0x38BDF8),LV_PART_INDICATOR);

    value_label=lv_label_create(screen);
    lv_label_set_text(value_label,"Flush demo: 0%");
    lv_obj_set_style_text_color(value_label,lv_color_hex(0xF8FAFC),0);
    lv_obj_align(value_label,LV_ALIGN_CENTER,0,52);

    lv_obj_t *footer=lv_label_create(screen);
    lv_label_set_text(footer,"Double buffer | anti-tearing presentation");
    lv_obj_set_style_text_color(footer,lv_color_hex(0x94A3B8),0);
    lv_obj_align(footer,LV_ALIGN_BOTTOM_MID,0,-24);

    lv_timer_create(progress_timer,100,NULL);
    g_lvgl_demo_state=2;
}
