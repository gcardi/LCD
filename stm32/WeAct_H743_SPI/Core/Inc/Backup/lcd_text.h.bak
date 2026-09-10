#ifndef LCD_TEXT_H
#define LCD_TEXT_H

#include <stdint.h>

#define LCD_TEXT_CELL_WIDTH 12u
#define LCD_TEXT_CELL_HEIGHT 24u

// Opaque RGB565 rendering with a fixed 12x24 cell. Unsupported UTF-8
// codepoints are rendered as '?'. These blocking APIs are not reentrant.
int LCD_DrawCodepoint(uint16_t x, uint16_t y, uint32_t codepoint,
                      uint16_t foreground, uint16_t background);
int LCD_DrawText(uint16_t x, uint16_t y, const char *utf8,
                 uint16_t foreground, uint16_t background);

// State: 0 not requested, 1 running, 2 complete, 3 failed.
extern volatile uint32_t g_lcd_text_demo_state;
void LCD_TextDemo_Run(void);

#endif
