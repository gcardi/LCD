#ifndef LCD_SPI_H
#define LCD_SPI_H
#include <stdint.h>
extern volatile uint32_t g_lcd_demo_state;
extern volatile uint32_t g_lcd_error[6];
typedef struct {
    uint8_t enabled, front, draw, irq, busy, result, version;
    uint16_t sequence;
} LcdBufferStatus;
// Single-caller APIs. Enable waits for previous drawing and selects the back
// buffer. Its contents are undefined until explicitly cleared/redrawn.
int LCD_GetBufferStatus(LcdBufferStatus *status);
int LCD_EnableDoubleBuffer(void);
// Wait for prior drawing, swap at vertical blanking, observe IRQ, then ACK it.
// On timeout/transport error do not retry blindly: inspect status first.
int LCD_Present(uint32_t timeout_ms);
extern volatile uint32_t g_lcd_present_count, g_lcd_present_ms;
extern volatile uint32_t g_lcd_front_buffer, g_lcd_present_sequence;
extern volatile uint32_t g_fpga_irq_count, g_fpga_irq_pending, g_fpga_irq_level;
// Explicit, disjoint buffers; source must be front and destination back.
// Reject empty/out-of-screen rectangles. Wait for all PSRAM writes before return.
int LCD_CopyRect(uint8_t source,uint8_t destination,uint16_t x,uint16_t y,
                 uint16_t width,uint16_t height,uint16_t dest_x,uint16_t dest_y);
// Positive dx/dy moves right/down. Fill exposed pixels inside the viewport;
// leave everything outside it unchanged. PRESENT remains a separate operation.
int LCD_ScrollRect(uint8_t source,uint8_t destination,uint16_t x,uint16_t y,
                   uint16_t width,uint16_t height,int16_t dx,int16_t dy,uint16_t fill);
extern volatile uint32_t g_lcd_copy_count,g_lcd_scroll_count,g_lcd_copy_ms,g_lcd_scroll_ms;
extern volatile uint32_t g_lcd_scroll_demo_state;
void LCD_ScrollDemo_Run(void);
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels);
// Where LCD_WriteRect spends its time. Cycle fields are DWT counts at
// SystemCoreClock and accumulate freely; packets and retries are counts.
// A non-zero retries means the FPGA queue was still busy on arrival.
typedef struct {
    uint32_t assemble, exchange, fence, packets, retries;
} LcdProfile;
extern volatile LcdProfile g_lcd_profile;
void LCD_ProfileReset(void);
// One TX-only BE transaction per row plus a slow BF result read. The payload
// CRC is checked by the FPGA after the stream; MISO is not sampled while pixel
// bytes are in flight. Same arguments and return value as LCD_WriteRect.
int LCD_WriteRectStream(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                        const uint16_t *pixels);
// Full screen down both paths, for comparison. Read the two millisecond
// figures and the two profiles over SWD.
void LCD_StreamBench_Run(void);
extern volatile uint32_t g_lcd_bench_state,g_lcd_bench_b7_ms,g_lcd_bench_bd_ms;
extern volatile LcdProfile g_lcd_bench_b7,g_lcd_bench_bd;
extern volatile uint32_t g_lcd_fast_status_counts[5],g_lcd_fast_status_reads;
// RGB565 colors. Blocking, single-caller APIs: 1 on success, 0 on error.
// FillRect rejects empty/out-of-screen rectangles without sending pixels.
// A transport failure may leave a partially updated region, as with WriteRect.
int LCD_FillRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                 uint16_t color);
int LCD_Clear(uint16_t color);
// One-pixel-thick lines, extending right/down from (x,y), length in pixels.
// Same blocking return/error contract as FillRect; zero length or any part
// outside the screen is rejected without drawing (no clipping).
int LCD_DrawHLine(uint16_t x, uint16_t y, uint16_t length, uint16_t color);
int LCD_DrawVLine(uint16_t x, uint16_t y, uint16_t length, uint16_t color);
// FPGA Bresenham, one pixel thick, inclusive endpoints in any direction.
// A point is valid; off-screen endpoints are rejected without clipping.
int LCD_DrawLine(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1,
                 uint16_t color);

#define LCD_FONT_8X16  0u
#define LCD_FONT_12X24 1u
#define LCD_FONT_16X32 2u
#define LCD_TEXT_TRANSPARENT 0x01u
#define LCD_TEXT_WRAP        0x02u
// Render a zero-terminated UTF-8 string in the FPGA. At most 64 encoded
// bytes are accepted. box_width/box_height equal to zero extend to the
// corresponding screen edge. Drawing is clipped to the resulting box.
int LCD_DrawTextFPGA(uint16_t x,uint16_t y,uint16_t box_width,
                     uint16_t box_height,uint8_t font_id,uint8_t flags,
                     uint16_t foreground,uint16_t background,const char *utf8);
extern volatile uint32_t g_lcd_fpga_text_demo_state;
extern volatile uint32_t g_lcd_clear_ms16;
void LCD_FPGATextDemo_Run(void);

typedef struct {
    uint32_t state, rectangles, pixels, packets, elapsed_ms, failed_rect;
} LcdStressResult;
extern volatile LcdStressResult g_lcd_stress;
void LCD_Stress_Run(void);
void LCD_Demo_Run(void);
#endif
