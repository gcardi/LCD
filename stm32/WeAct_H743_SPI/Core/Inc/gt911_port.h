#ifndef GT911_PORT_H
#define GT911_PORT_H

#include <stdint.h>

extern volatile uint32_t g_gt911_state;
extern volatile uint32_t g_gt911_read_count;
extern volatile uint32_t g_gt911_i2c_error_count;
extern volatile uint32_t g_gt911_touch_count;
extern volatile uint32_t g_gt911_raw_x;
extern volatile uint32_t g_gt911_raw_y;
extern volatile uint32_t g_gt911_sensor_width;
extern volatile uint32_t g_gt911_sensor_height;

int GT911_Port_Init(void);

#endif /* GT911_PORT_H */
