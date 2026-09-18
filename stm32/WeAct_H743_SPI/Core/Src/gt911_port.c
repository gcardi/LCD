#include "gt911_port.h"
#include "i2c.h"
#include "lvgl.h"

#define GT911_I2C_ADDRESS 0x5Du
#define GT911_PRODUCT_ID 0x8140u
#define GT911_RESOLUTION 0x8146u
#define GT911_STATUS 0x814Eu
#define GT911_POINT_1 0x8150u
#define GT911_MAX_POINTS 5u
#define GT911_DISPLAY_WIDTH 480u
#define GT911_DISPLAY_HEIGHT 272u

volatile uint32_t g_gt911_state;
volatile uint32_t g_gt911_read_count;
volatile uint32_t g_gt911_i2c_error_count;
volatile uint32_t g_gt911_touch_count;
volatile uint32_t g_gt911_raw_x;
volatile uint32_t g_gt911_raw_y;
volatile uint32_t g_gt911_sensor_width;
volatile uint32_t g_gt911_sensor_height;

static lv_indev_state_t pointer_state=LV_INDEV_STATE_RELEASED;
static lv_point_t pointer_point;

static int gt911_read(uint16_t reg,uint8_t *buffer,uint16_t size)
{
    if(HAL_I2C_Mem_Read(&hi2c1,GT911_I2C_ADDRESS<<1,reg,I2C_MEMADD_SIZE_16BIT,
                        buffer,size,20)!=HAL_OK) {
        g_gt911_i2c_error_count++;
        return 0;
    }
    return 1;
}

static int gt911_ack_frame(void)
{
    uint8_t clear=0;
    if(HAL_I2C_Mem_Write(&hi2c1,GT911_I2C_ADDRESS<<1,GT911_STATUS,
                         I2C_MEMADD_SIZE_16BIT,&clear,sizeof(clear),20)!=HAL_OK) {
        g_gt911_i2c_error_count++;
        return 0;
    }
    return 1;
}

static int16_t scale_coordinate(uint16_t value,uint32_t source,uint16_t target)
{
    if(source<2) return 0;
    if(value>=source) value=(uint16_t)(source-1u);
    return (int16_t)(((uint32_t)value*(target-1u))/(source-1u));
}

static void gt911_read_callback(lv_indev_t *indev,lv_indev_data_t *data)
{
    (void)indev;
    uint8_t status;
    data->state=pointer_state;
    data->point=pointer_point;
    if(!gt911_read(GT911_STATUS,&status,sizeof(status))) return;
    g_gt911_read_count++;
    if(!(status&0x80u)) return;

    uint8_t count=status&0x0Fu;
    if(count==0 || count>GT911_MAX_POINTS) {
        pointer_state=LV_INDEV_STATE_RELEASED;
        g_gt911_touch_count=0;
        (void)gt911_ack_frame();
    } else {
        /* GT911 stores each contact in eight bytes: id, x low/high, y
         * low/high, size low/high, reserved.  LVGL's pointer device uses the
         * first contact; the remaining points stay available to a future
         * multi-touch gesture adapter. */
        uint8_t point[8];
        if(gt911_read(GT911_POINT_1,point,sizeof(point))) {
            uint16_t x=(uint16_t)point[1]|((uint16_t)point[2]<<8);
            uint16_t y=(uint16_t)point[3]|((uint16_t)point[4]<<8);
            g_gt911_raw_x=x;
            g_gt911_raw_y=y;
            g_gt911_touch_count=count;
            pointer_point.x=scale_coordinate(x,g_gt911_sensor_width,GT911_DISPLAY_WIDTH);
            pointer_point.y=scale_coordinate(y,g_gt911_sensor_height,GT911_DISPLAY_HEIGHT);
            pointer_state=LV_INDEV_STATE_PRESSED;
            (void)gt911_ack_frame();
        }
    }
    data->state=pointer_state;
    data->point=pointer_point;
}

int GT911_Port_Init(void)
{
    uint8_t identity[4],resolution[4];
    g_gt911_state=1;
    if(!gt911_read(GT911_PRODUCT_ID,identity,sizeof(identity)) ||
       identity[0]!='9' || identity[1]!='1' || identity[2]!='1' ||
       !gt911_read(GT911_RESOLUTION,resolution,sizeof(resolution))) {
        g_gt911_state=3;
        return 0;
    }
    g_gt911_sensor_width=(uint16_t)resolution[0]|((uint16_t)resolution[1]<<8);
    g_gt911_sensor_height=(uint16_t)resolution[2]|((uint16_t)resolution[3]<<8);
    if(g_gt911_sensor_width<2 || g_gt911_sensor_height<2) {
        g_gt911_state=3;
        return 0;
    }
    lv_indev_t *indev=lv_indev_create();
    if(indev==NULL) {
        g_gt911_state=3;
        return 0;
    }
    lv_indev_set_type(indev,LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev,gt911_read_callback);
    lv_timer_set_period(lv_indev_get_read_timer(indev),10);
    g_gt911_state=2;
    return 1;
}
