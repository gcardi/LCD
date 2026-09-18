#include "touch_probe.h"
#include "i2c.h"

volatile uint32_t g_touch_probe_state;
volatile uint32_t g_touch_probe_found;
volatile uint32_t g_touch_probe_addresses[4];
volatile uint32_t g_touch_probe_bus_error;
volatile uint32_t g_touch_probe_product_id;

void Touch_Probe_Run(void)
{
    g_touch_probe_state=1;
    g_touch_probe_found=0;
    g_touch_probe_bus_error=0;
    g_touch_probe_product_id=0;
    for(unsigned i=0;i<4;i++) g_touch_probe_addresses[i]=0;

    for(uint16_t address=0x08;address<=0x77;address++) {
        HAL_StatusTypeDef result=HAL_I2C_IsDeviceReady(&hi2c1,address<<1,2,10);
        if(result==HAL_OK) {
            g_touch_probe_addresses[address>>5]|=1u<<(address&31);
            g_touch_probe_found++;
        } else if(result==HAL_TIMEOUT || result==HAL_BUSY) {
            /* NACK is expected for empty addresses; timeout/busy indicates an
             * electrical or pull-up issue worth exposing over SWD. */
            g_touch_probe_bus_error=HAL_I2C_GetError(&hi2c1);
        }
    }
    /* 0x5D is a common Goodix address.  Product ID is read-only and verifies
     * the controller family before a GT911-specific LVGL driver is added. */
    if(g_touch_probe_addresses[0x5Du>>5]&(1u<<(0x5Du&31))) {
        uint8_t id[4]={0};
        if(HAL_I2C_Mem_Read(&hi2c1,0x5Du<<1,0x8140,I2C_MEMADD_SIZE_16BIT,
                            id,sizeof(id),20)==HAL_OK) {
            g_touch_probe_product_id=((uint32_t)id[0]<<24)|
                                     ((uint32_t)id[1]<<16)|
                                     ((uint32_t)id[2]<<8)|id[3];
        } else {
            g_touch_probe_bus_error=HAL_I2C_GetError(&hi2c1);
        }
    }
    g_touch_probe_state=2;
}
