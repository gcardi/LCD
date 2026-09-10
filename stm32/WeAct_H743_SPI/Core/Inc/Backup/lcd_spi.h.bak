#ifndef LCD_SPI_H
#define LCD_SPI_H
#include <stdint.h>
extern volatile uint32_t g_lcd_demo_state;
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels);
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
