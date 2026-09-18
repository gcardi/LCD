#include "lvgl_port.h"
#include "display_task.h"
#include "lcd_spi.h"
#include "main.h"
#include "lvgl.h"

#define LVGL_WIDTH 480u
#define LVGL_HEIGHT 272u
#define LVGL_BUFFER_LINES 20u
#define LVGL_BUFFER_BYTES (LVGL_WIDTH * LVGL_BUFFER_LINES * 2u)
#define LVGL_CONTROL_COMPLETE_FLAG (1u << 0)

#if LV_COLOR_FORMAT_DEFAULT != LV_COLOR_FORMAT_RGB565
#error "The FPGA LVGL port requires native RGB565 draw buffers"
#endif

typedef struct {
    lv_display_t *display;
    const uint16_t *pixels;
    uint16_t x, y, width, height;
    uint8_t last;
    uint32_t frame_start_tick;
} LvglFlushRequest;

typedef struct {
    osThreadId_t waiter;
    int result;
} LvglControlRequest;

/* These buffers are CPU-rendered, then copied row by row to the private SPI
 * DMA staging buffer.  They therefore belong in roomy D2 SRAM, not DTCM. */
static uint8_t draw_buffer_1[LVGL_BUFFER_BYTES]
    __attribute__((section(".lvgl_draw"), aligned(32)));
static uint8_t draw_buffer_2[LVGL_BUFFER_BYTES]
    __attribute__((section(".lvgl_draw"), aligned(32)));
static LvglFlushRequest flush_request;
static LvglControlRequest control_request;
static volatile uint32_t flush_pending;
static volatile uint32_t frame_active;
static uint32_t frame_start_tick;

volatile uint32_t g_lvgl_port_state;
volatile uint32_t g_lvgl_flush_count;
volatile uint32_t g_lvgl_flush_failed;
volatile uint32_t g_lvgl_flush_pixels;
volatile uint32_t g_lvgl_present_count;
volatile uint32_t g_lvgl_present_failed;
volatile uint32_t g_lvgl_frame_count;
volatile uint32_t g_lvgl_frame_ms;

/* Establish a known, identical front/back pair.  All LCD calls run on
 * DisplayTask, preserving its exclusive SPI/FPGA ownership. */
static void enable_double_buffer_execute(void *context)
{
    LvglControlRequest *request=(LvglControlRequest *)context;
    LcdBufferStatus status;
    int ok=request==&control_request && LCD_EnableDoubleBuffer() &&
           LCD_Clear(0x0000) && LCD_Present(1000) &&
           LCD_GetBufferStatus(&status) &&
           LCD_CopyRect(status.front,status.draw,0,0,LVGL_WIDTH,LVGL_HEIGHT,0,0);
    request->result=ok;
    (void)osThreadFlagsSet(request->waiter,LVGL_CONTROL_COMPLETE_FLAG);
}

static int enable_double_buffer(void)
{
    control_request=(LvglControlRequest){.waiter=osThreadGetId(),.result=0};
    (void)osThreadFlagsClear(LVGL_CONTROL_COMPLETE_FLAG);
    if(DisplayTask_Post(enable_double_buffer_execute,&control_request,osWaitForever)!=osOK)
        return 0;
    uint32_t flags=osThreadFlagsWait(LVGL_CONTROL_COMPLETE_FLAG,osFlagsWaitAny,2000);
    return (flags&LVGL_CONTROL_COMPLETE_FLAG)!=0 && control_request.result;
}

static void flush_execute(void *context)
{
    LvglFlushRequest *request=(LvglFlushRequest *)context;
    int ok=request==&flush_request &&
           LCD_WriteRectStream(request->x,request->y,request->width,
                               request->height,request->pixels);
    if(ok && request->last) {
        LcdBufferStatus status;
        /* Swap only a complete LVGL frame.  Afterwards seed the new draw
         * buffer from the new front: subsequent LVGL partial areas are then
         * composited over the exact image currently being scanned out. */
        ok=LCD_Present(1000) && LCD_GetBufferStatus(&status) &&
           LCD_CopyRect(status.front,status.draw,0,0,LVGL_WIDTH,LVGL_HEIGHT,0,0);
        if(ok) {
            g_lvgl_present_count++;
            g_lvgl_frame_count++;
            g_lvgl_frame_ms=HAL_GetTick()-request->frame_start_tick;
        } else {
            g_lvgl_present_failed++;
        }
        frame_active=0;
    }
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
    if(!frame_active) {
        frame_active=1;
        frame_start_tick=HAL_GetTick();
    }
    flush_request=(LvglFlushRequest){
        .display=display,.pixels=(const uint16_t *)pixel_map,
        .x=(uint16_t)area->x1,.y=(uint16_t)area->y1,
        .width=(uint16_t)(area->x2-area->x1+1),
        .height=(uint16_t)(area->y2-area->y1+1),
        .last=lv_display_flush_is_last(display),
        .frame_start_tick=frame_start_tick
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
    if(!enable_double_buffer()) {g_lvgl_port_state=3;return 0;}
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
