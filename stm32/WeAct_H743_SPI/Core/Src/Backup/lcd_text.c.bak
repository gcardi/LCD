#include "lcd_text.h"
#include "lcd_font_12x24.h"
#include "lcd_spi.h"
#include <stddef.h>

#define LCD_WIDTH 480u
#define LCD_HEIGHT 272u
#define ASCII_FIRST 0x20u
#define ASCII_LAST 0x7Eu
#define LATIN1_FIRST 0xA0u
#define LATIN1_LAST 0xFFu
#define LATIN1_INDEX 95u
#define EXTRA_INDEX 191u

volatile uint32_t g_lcd_text_demo_state;

static unsigned font_index(uint32_t codepoint)
{
    if(codepoint>=ASCII_FIRST && codepoint<=ASCII_LAST)
        return (unsigned)(codepoint-ASCII_FIRST);
    if(codepoint>=LATIN1_FIRST && codepoint<=LATIN1_LAST)
        return LATIN1_INDEX+(unsigned)(codepoint-LATIN1_FIRST);
    switch(codepoint) {
      case 0x20AC: return EXTRA_INDEX+0u;
      case 0x2190: return EXTRA_INDEX+1u;
      case 0x2191: return EXTRA_INDEX+2u;
      case 0x2192: return EXTRA_INDEX+3u;
      case 0x2193: return EXTRA_INDEX+4u;
      default: return (unsigned)('?'-ASCII_FIRST);
    }
}

static uint32_t decode_utf8(const char **cursor)
{
    const unsigned char *p=(const unsigned char *)*cursor;
    uint32_t codepoint;
    unsigned length;
    if(p[0]<0x80u) { *cursor=(const char *)(p+1); return p[0]; }
    if((p[0]&0xE0u)==0xC0u) { codepoint=p[0]&0x1Fu; length=2; }
    else if((p[0]&0xF0u)==0xE0u) { codepoint=p[0]&0x0Fu; length=3; }
    else if((p[0]&0xF8u)==0xF0u) { codepoint=p[0]&0x07u; length=4; }
    else { *cursor=(const char *)(p+1); return '?'; }
    for(unsigned i=1;i<length;i++) {
        if(p[i]==0 || (p[i]&0xC0u)!=0x80u) {
            *cursor=(const char *)(p+1);return '?';
        }
        codepoint=(codepoint<<6)|(p[i]&0x3Fu);
    }
    *cursor=(const char *)(p+length);
    if((length==2 && codepoint<0x80u) ||
       (length==3 && codepoint<0x800u) ||
       (length==4 && codepoint<0x10000u) ||
       codepoint>0x10FFFFu || (codepoint>=0xD800u && codepoint<=0xDFFFu))
        return '?';
    return codepoint;
}

static void raster_glyph(uint16_t *pixels, unsigned stride, unsigned x,
                         unsigned index, uint16_t foreground,
                         uint16_t background)
{
    for(unsigned row=0;row<LCD_FONT_12X24_HEIGHT;row++) {
        uint16_t bits=lcd_font_12x24_bitmap[index][row];
        for(unsigned column=0;column<LCD_FONT_12X24_WIDTH;column++)
            pixels[row*stride+x+column]=
                (bits&(1u<<(LCD_FONT_12X24_WIDTH-1u-column)))?
                foreground:background;
    }
}

int LCD_DrawCodepoint(uint16_t x, uint16_t y, uint32_t codepoint,
                      uint16_t foreground, uint16_t background)
{
    if(x>LCD_WIDTH-LCD_TEXT_CELL_WIDTH || y>LCD_HEIGHT-LCD_TEXT_CELL_HEIGHT)
        return 0;
    uint16_t pixels[LCD_TEXT_CELL_WIDTH*LCD_TEXT_CELL_HEIGHT];
    raster_glyph(pixels,LCD_TEXT_CELL_WIDTH,0,font_index(codepoint),
                 foreground,background);
    return LCD_WriteRect(x,y,LCD_TEXT_CELL_WIDTH,LCD_TEXT_CELL_HEIGHT,pixels);
}

int LCD_DrawText(uint16_t x, uint16_t y, const char *utf8,
                 uint16_t foreground, uint16_t background)
{
    static uint16_t pixels[LCD_WIDTH*LCD_TEXT_CELL_HEIGHT];
    const char *p;
    unsigned columns=0,max_columns=0,lines=1;
    if(!utf8 || x>=LCD_WIDTH || y>=LCD_HEIGHT) return 0;

    // Validate the complete bounding box before changing the display.
    for(p=utf8;*p;) {
        uint32_t codepoint=decode_utf8(&p);
        if(codepoint=='\r') continue;
        if(codepoint=='\n') {
            if(columns>max_columns) max_columns=columns;
            columns=0;lines++;
        } else columns++;
    }
    if(columns>max_columns) max_columns=columns;
    if(max_columns>(LCD_WIDTH-x)/LCD_TEXT_CELL_WIDTH ||
       lines>(LCD_HEIGHT-y)/LCD_TEXT_CELL_HEIGHT) return 0;

    p=utf8;
    for(unsigned line=0;line<lines;line++) {
        const char *line_start=p,*q=p;
        columns=0;
        while(*q) {
            uint32_t codepoint=decode_utf8(&q);
            if(codepoint=='\n') break;
            if(codepoint!='\r') columns++;
        }
        unsigned pixel_width=columns*LCD_TEXT_CELL_WIDTH;
        const char *r=line_start;
        unsigned column=0;
        while(r<q && *r) {
            uint32_t codepoint=decode_utf8(&r);
            if(codepoint=='\n') break;
            if(codepoint!='\r') {
                raster_glyph(pixels,pixel_width,column*LCD_TEXT_CELL_WIDTH,
                             font_index(codepoint),foreground,background);
                column++;
            }
        }
        if(pixel_width && !LCD_WriteRect(x,(uint16_t)(y+line*LCD_TEXT_CELL_HEIGHT),
                                         (uint16_t)pixel_width,LCD_TEXT_CELL_HEIGHT,pixels))
            return 0;
        p=q;
    }
    return 1;
}

void LCD_TextDemo_Run(void)
{
    g_lcd_text_demo_state=1;
    if(!LCD_Clear(0x0000) ||
       !LCD_DrawText(24,20,"Tang Nano 9K",0x07FF,0x0000) ||
       !LCD_DrawText(24,56,"STM32 + FPGA @ 12.5 MHz",0xFFFF,0x0000) ||
       !LCD_DrawText(24,92,"Temperatura: 23,5 " "\xC2\xB0" "C",0xFFE0,0x0000) ||
       !LCD_DrawText(24,128,"Accenti: " "\xC3\xA0 \xC3\xA8 \xC3\xA9 \xC3\xAC \xC3\xB2 \xC3\xB9",0x07E0,0x0000) ||
       !LCD_DrawText(24,164,"Frecce: " "\xE2\x86\x90 \xE2\x86\x91 \xE2\x86\x92 \xE2\x86\x93",0xF81F,0x0000) ||
       !LCD_DrawText(24,200,"Fixed cell 12 x 24",0xFD20,0x0000)) {
        g_lcd_text_demo_state=3;return;
    }
    g_lcd_text_demo_state=2;
}
