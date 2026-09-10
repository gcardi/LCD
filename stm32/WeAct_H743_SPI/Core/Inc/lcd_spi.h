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

// Two faces only. 16x32 was dropped because the three together did not fit in
// the flash alongside the bitstream; see docs/PROGRAMMING.md.
#define LCD_FONT_8X16  0u
#define LCD_FONT_12X24 1u
#define LCD_TEXT_TRANSPARENT 0x01u
#define LCD_TEXT_WRAP        0x02u
// Render a zero-terminated UTF-8 string in the FPGA. At most 64 encoded
// bytes are accepted. box_width/box_height equal to zero extend to the
// corresponding screen edge. Drawing is clipped to the resulting box.
int LCD_DrawTextFPGA(uint16_t x,uint16_t y,uint16_t box_width,
                     uint16_t box_height,uint8_t font_id,uint8_t flags,
                     uint16_t foreground,uint16_t background,const char *utf8);
extern volatile uint32_t g_lcd_fpga_text_demo_state;
void LCD_FPGATextDemo_Run(void);

typedef struct {
    uint32_t state, rectangles, pixels, packets, elapsed_ms, failed_rect;
} LcdStressResult;
extern volatile LcdStressResult g_lcd_stress;
void LCD_Stress_Run(void);
void LCD_Demo_Run(void);
#endif
