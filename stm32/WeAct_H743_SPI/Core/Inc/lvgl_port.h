#ifndef LVGL_PORT_H
#define LVGL_PORT_H

#include <stdint.h>

extern volatile uint32_t g_lvgl_port_state;
extern volatile uint32_t g_lvgl_flush_count;
extern volatile uint32_t g_lvgl_flush_failed;
extern volatile uint32_t g_lvgl_flush_pixels;

int LVGL_Port_Init(void);
void LVGL_Port_Service(uint32_t elapsed_ms);

#endif /* LVGL_PORT_H */
