#include "lvgl_port.h"
#include "display_task.h"
#include "lcd_spi.h"
#include "lvgl.h"

#define LVGL_WIDTH 480u
#define LVGL_HEIGHT 272u
#define LVGL_BUFFER_LINES 20u
#define LVGL_BUFFER_BYTES (LVGL_WIDTH * LVGL_BUFFER_LINES * 2u)

#if LV_COLOR_FORMAT_DEFAULT != LV_COLOR_FORMAT_RGB565
#error "The FPGA LVGL port requires native RGB565 draw buffers"
#endif

typedef struct {
    lv_display_t *display;
    const uint16_t *pixels;
    uint16_t x, y, width, height;
} LvglFlushRequest;

/* These buffers are CPU-rendered, then copied row by row to the private SPI
 * DMA staging buffer.  They therefore belong in roomy D2 SRAM, not DTCM. */
static uint8_t draw_buffer_1[LVGL_BUFFER_BYTES]
    __attribute__((section(".lvgl_draw"), aligned(32)));
static uint8_t draw_buffer_2[LVGL_BUFFER_BYTES]
    __attribute__((section(".lvgl_draw"), aligned(32)));
static LvglFlushRequest flush_request;
static volatile uint32_t flush_pending;

volatile uint32_t g_lvgl_port_state;
volatile uint32_t g_lvgl_flush_count;
volatile uint32_t g_lvgl_flush_failed;
volatile uint32_t g_lvgl_flush_pixels;

static void flush_execute(void *context)
{
    LvglFlushRequest *request=(LvglFlushRequest *)context;
    int ok=request==&flush_request &&
           LCD_WriteRectStream(request->x,request->y,request->width,
                               request->height,request->pixels);
    if(ok) {
        g_lvgl_flush_count++;
        g_lvgl_flush_pixels+=(uint32_t)request->width*request->height;
    } else {
        g_lvgl_flush_failed++;
    }
    /* LVGL may reuse the draw buffer only after the FPGA fence in
     * LCD_WriteRectStream has completed. */
    flush_pending=0;
    lv_display_flush_ready(request->display);
}

static void flush_callback(lv_display_t *display,const lv_area_t *area,
                           uint8_t *pixel_map)
{
    if(flush_pending || pixel_map==NULL || area==NULL || area->x1<0 || area->y1<0 ||
       area->x2<area->x1 ||
       area->y2<area->y1 ||
       area->x1>=LVGL_WIDTH || area->y1>=LVGL_HEIGHT ||
       area->x2>=LVGL_WIDTH || area->y2>=LVGL_HEIGHT) {
        g_lvgl_flush_failed++;
        lv_display_flush_ready(display);
        return;
    }
    flush_request=(LvglFlushRequest){
        .display=display,.pixels=(const uint16_t *)pixel_map,
        .x=(uint16_t)area->x1,.y=(uint16_t)area->y1,
        .width=(uint16_t)(area->x2-area->x1+1),
        .height=(uint16_t)(area->y2-area->y1+1)
    };
    flush_pending=1;
    if(DisplayTask_Post(flush_execute,&flush_request,osWaitForever)!=osOK) {
        flush_pending=0;
        g_lvgl_flush_failed++;
        lv_display_flush_ready(display);
    }
}

int LVGL_Port_Init(void)
{
    g_lvgl_port_state=1;
    lv_init();
    lv_display_t *display=lv_display_create(LVGL_WIDTH,LVGL_HEIGHT);
    if(display==NULL) {g_lvgl_port_state=3;return 0;}
    lv_display_set_color_format(display,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display,draw_buffer_1,draw_buffer_2,
                           sizeof(draw_buffer_1),LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display,flush_callback);
    g_lvgl_port_state=2;
    return 1;
}

void LVGL_Port_Service(uint32_t elapsed_ms)
{
    lv_tick_inc(elapsed_ms);
    (void)lv_timer_handler();
}
