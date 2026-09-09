#ifndef LCD_SPI_H
#define LCD_SPI_H
#include <stdint.h>
extern volatile uint32_t g_lcd_demo_state;
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels);
typedef struct {
    uint32_t state, rectangles, pixels, packets, elapsed_ms, failed_rect;
} LcdStressResult;
extern volatile LcdStressResult g_lcd_stress;
void LCD_Stress_Run(void);
void LCD_Demo_Run(void);
#endif
