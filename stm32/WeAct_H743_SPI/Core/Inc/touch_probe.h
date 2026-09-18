#ifndef TOUCH_PROBE_H
#define TOUCH_PROBE_H

#include <stdint.h>

/* State: 0 not run, 1 scanning, 2 complete.  Addresses are 7-bit I2C values;
 * bit n of g_touch_probe_addresses[n / 32] means address n acknowledged. */
extern volatile uint32_t g_touch_probe_state;
extern volatile uint32_t g_touch_probe_found;
extern volatile uint32_t g_touch_probe_addresses[4];
extern volatile uint32_t g_touch_probe_bus_error;
/* Four ASCII bytes read from Goodix's read-only Product ID register 0x8140,
 * packed most-significant byte first; zero means not read/invalid. */
extern volatile uint32_t g_touch_probe_product_id;

void Touch_Probe_Run(void);

#endif /* TOUCH_PROBE_H */
