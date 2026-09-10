#include "spi.h"
#include "spi_selftest.h"
#include "lcd_spi.h"
#include "main.h"
#include <stdint.h>
// State: 0 diagnostic endpoint, 1 running, 2 submitted, 3 failure.
volatile uint32_t g_lcd_demo_state;
volatile uint32_t g_lcd_fpga_text_demo_state;
volatile LcdStressResult g_lcd_stress;
// First failing exchange: phase, address, byte index, expected, actual, HAL error.
volatile uint32_t g_lcd_error[6];
static int bad(uint32_t phase,uint32_t index,uint32_t expected,uint32_t actual)
{
    if(!g_lcd_error[0]) {
        g_lcd_error[2]=index;g_lcd_error[3]=expected;g_lcd_error[4]=actual;
        g_lcd_error[5]=HAL_SPI_GetError(&hspi2);g_lcd_error[0]=phase;
    }
    return 0;
}
static void spi_guard(void)
{
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
    uint32_t start=DWT->CYCCNT;
    while((uint32_t)(DWT->CYCCNT-start)<SystemCoreClock/1000000u) {}
}
static int exchange(uint8_t *tx, uint8_t *rx, uint16_t n)
{
    spi_guard(); // CS high recovery before selecting the next packet.
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_RESET);
    spi_guard();
    HAL_StatusTypeDef status=SPI_Exchange_DMA(tx,rx,n)?HAL_OK:HAL_ERROR;
    spi_guard(); // Hold CS after EOT, with SCK settled low.
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
    if(status!=HAL_OK) { bad(1,0,HAL_OK,status);HAL_SPI_Abort(&hspi2); return 0; }
    return 1;
}
static int ready(void)
{
    uint8_t tx[2]={0xB7,0},rx[2];
    uint32_t start=HAL_GetTick();
    do {
        if(!exchange(tx,rx,2)) return 0;
        if(rx[0]!=0xA5) return bad(2,0,0xA5,rx[0]);
        if(rx[1]==0xC3) return 1;
        if(rx[1]!=0) return bad(3,1,0xC3,rx[1]);
        HAL_Delay(1);
    } while(HAL_GetTick()-start<1000);
    return bad(4,1,0xC3,rx[1]);
}

static uint16_t crc16_byte(uint16_t crc,uint8_t value)
{
    crc^=(uint16_t)value<<8;
    for(unsigned bit=0;bit<8;bit++)
        crc=(uint16_t)((crc<<1)^((crc&0x8000u)?0x1021u:0u));
    return crc;
}

static int text_ready(void)
{
    uint8_t tx[2]={0xB8,0},rx[2];
    uint32_t start=HAL_GetTick();
    do {
        if(!exchange(tx,rx,2)) return 0;
        if(rx[0]!=0xA5) return bad(9,0,0xA5,rx[0]);
        if(rx[1]==0xC3) return 1;
        // 00 means renderer busy; E2 means the User Flash CRC is still being
        // checked. A damaged/unprogrammed image remains E2 until timeout.
        if(rx[1]!=0 && rx[1]!=0xE2) return bad(10,1,0xC3,rx[1]);
        HAL_Delay(1);
    } while(HAL_GetTick()-start<1000);
    return bad(11,1,0xC3,rx[1]);
}

// The shape queue is the text queue, so the wait is the same one; the poll
// uses B9 rather than B8 because a fill touches no font and must stay usable
// on a board whose User Flash image is missing or corrupt, where B8 answers E2.
static int shape_ready(void)
{
    uint8_t tx[2]={0xB9,0},rx[2];
    uint32_t start=HAL_GetTick();
    do {
        if(!exchange(tx,rx,2)) return 0;
        if(rx[0]!=0xA5) return bad(16,0,0xA5,rx[0]);
        if(rx[1]==0xC3) return 1;
        if(rx[1]!=0) return bad(17,1,0xC3,rx[1]);
        HAL_Delay(1);
    } while(HAL_GetTick()-start<1000);
    return bad(18,1,0xC3,rx[1]);
}

int LCD_DrawTextFPGA(uint16_t x,uint16_t y,uint16_t box_width,
                     uint16_t box_height,uint8_t font_id,uint8_t flags,
                     uint16_t foreground,uint16_t background,const char *utf8)
{
    uint8_t tx[85]={0},rx[85];
    unsigned length=0;
    if(!utf8 || x>=480 || y>=272 || box_width>480 || box_height>272 ||
       font_id>LCD_FONT_16X32 || (flags&~3u)) return 0;
    while(length<=64 && utf8[length]) length++;
    if(length>64) return 0;

    tx[0]=0xB8;tx[2]=font_id;tx[3]=flags;
    tx[4]=(uint8_t)(x>>8);tx[5]=(uint8_t)x;
    tx[6]=(uint8_t)(y>>8);tx[7]=(uint8_t)y;
    tx[8]=(uint8_t)(box_width>>8);tx[9]=(uint8_t)box_width;
    tx[10]=(uint8_t)(box_height>>8);tx[11]=(uint8_t)box_height;
    tx[12]=(uint8_t)(foreground>>8);tx[13]=(uint8_t)foreground;
    tx[14]=(uint8_t)(background>>8);tx[15]=(uint8_t)background;
    tx[16]=(uint8_t)length;
    for(unsigned i=0;i<length;i++) tx[17+i]=(uint8_t)utf8[i];
    uint16_t crc=0xFFFF;
    for(unsigned i=2;i<=16+length;i++) crc=crc16_byte(crc,tx[i]);
    tx[17+length]=(uint8_t)(crc>>8);tx[18+length]=(uint8_t)crc;
    tx[19+length]=0xA6;
    unsigned packet_length=21+length;

    if(!text_ready() || !exchange(tx,rx,(uint16_t)packet_length)) return 0;
    if(rx[0]!=0xA5) return bad(12,0,0xA5,rx[0]);
    if(rx[1]!=0xC3) return bad(13,1,0xC3,rx[1]);
    for(unsigned i=2;i+1<packet_length;i++)
        if(rx[i]!=tx[i-1]) return bad(14,i,tx[i-1],rx[i]);
    if(rx[packet_length-1]!=0xAC)
        return bad(15,packet_length-1,0xAC,rx[packet_length-1]);
    return text_ready();
}

// Tempo di sedici clear a schermo intero, in millisecondi. Sedici perche'
// HAL_GetTick ha risoluzione di 1 ms e un singolo clear e' dello stesso ordine.
volatile uint32_t g_lcd_clear_ms16;

void LCD_FPGATextDemo_Run(void)
{
    g_lcd_fpga_text_demo_state=1;
    uint32_t clear_start=HAL_GetTick();
    for(unsigned i=0;i<16;i++)
        if(!LCD_Clear(0x0000)) {g_lcd_fpga_text_demo_state=3;return;}
    g_lcd_clear_ms16=HAL_GetTick()-clear_start;
    // Origine e dimensioni non multiple di 16 di proposito: se le maschere dei
    // bordi fossero sbagliate il rettangolo verrebbe largo o stretto di qualche
    // pixel, e il testo trasparente sopra lo rende evidente.
    if(!LCD_Clear(0x0000) ||
       !LCD_FillRect(300,118,101,53,0x0010) ||
       !LCD_DrawTextFPGA(16,12,0,0,LCD_FONT_16X32,0,0x07FF,0,"Tang Nano 9K") ||
       !LCD_DrawTextFPGA(20,54,0,0,LCD_FONT_12X24,0,0xFFFF,0,
                         "STM32 -> FPGA @ 12.5 MHz") ||
       !LCD_DrawTextFPGA(20,88,0,0,LCD_FONT_8X16,0,0x07E0,0,
                         "Accenti: \xC3\xA0 \xC3\xA8 \xC3\xA9 \xC3\xAC \xC3\xB2 \xC3\xB9  Frecce: \xE2\x86\x90 \xE2\x86\x91 \xE2\x86\x92 \xE2\x86\x93") ||
       !LCD_DrawTextFPGA(20,120,220,72,LCD_FONT_12X24,LCD_TEXT_WRAP,
                         0xFFE0,0,"Wrap automatico dentro un box stretto") ||
       !LCD_DrawTextFPGA(20,210,0,0,LCD_FONT_8X16,LCD_TEXT_TRANSPARENT,
                         0xFD20,0,"Font bitmap residenti nella User Flash") ||
       !LCD_DrawTextFPGA(308,136,0,0,LCD_FONT_8X16,LCD_TEXT_TRANSPARENT,
                         0xFFE0,0,"FILL B9") ||
       !LCD_DrawTextFPGA(430,236,50,32,LCD_FONT_16X32,0,0xF81F,0,"CLIP") ||
       // One-pixel lines: full-screen edges plus an unaligned inner frame.
       !LCD_DrawHLine(0,0,480,0xFFFF) ||
       !LCD_DrawHLine(0,271,480,0xFFFF) ||
       !LCD_DrawVLine(0,0,272,0x07FF) ||
       !LCD_DrawVLine(479,0,272,0x07FF) ||
       !LCD_DrawHLine(299,117,103,0xFFE0) ||
       !LCD_DrawHLine(299,171,103,0xFFE0) ||
       !LCD_DrawVLine(299,117,55,0xF81F) ||
       !LCD_DrawVLine(401,117,55,0xF81F) ||
       // Eight-direction star in the unused area right of the text.
       !LCD_DrawLine(350,193,315,178,0xF800) ||
       !LCD_DrawLine(350,193,335,175,0xFFE0) ||
       !LCD_DrawLine(350,193,365,175,0x07E0) ||
       !LCD_DrawLine(350,193,385,178,0x07FF) ||
       !LCD_DrawLine(350,193,385,208,0x001F) ||
       !LCD_DrawLine(350,193,365,211,0xF81F) ||
       !LCD_DrawLine(350,193,335,211,0xFFFF) ||
       !LCD_DrawLine(350,193,315,208,0xFD20)) {
        g_lcd_fpga_text_demo_state=3;return;
    }
    g_lcd_fpga_text_demo_state=2;
}
// Arbitrary rectangle; unselected pixels in edge bursts are masked in PSRAM.
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels)
{
    if(!pixels || !w || !h || x>=480 || y>=272 || w>480-x || h>272-y) return 0;
    for(unsigned row=0;row<h;row++) for(unsigned bx=x&~15u;bx<x+w;bx+=16) {
        uint8_t tx[41]={0xB7,0},rx[41];
        uint32_t address=(y+row)*480+bx;
        if(!g_lcd_error[0]) g_lcd_error[1]=address;
        uint16_t mask=0;
        tx[2]=address>>16;tx[3]=address>>8;tx[4]=address;
        for(unsigned i=0;i<16;i++) if(bx+i>=x && bx+i<x+w) {
            uint16_t pixel=pixels[row*w+bx+i-x];
            mask|=(uint16_t)(1u<<i);tx[7+2*i]=pixel;tx[8+2*i]=pixel>>8;
        }
        tx[5]=mask>>8;tx[6]=mask;tx[39]=0x5A;
        if(!ready() || !exchange(tx,rx,41)) return 0;
        if(rx[0]!=0xA5) return bad(5,0,0xA5,rx[0]);
        if(rx[1]!=0xC3) return bad(6,1,0xC3,rx[1]);
        if(rx[40]!=0xAC) return bad(7,40,0xAC,rx[40]);
        for(unsigned i=2;i<40;i++) if(rx[i]!=tx[i-1]) return bad(8,i,tx[i-1],rx[i]);
        if(g_lcd_stress.state==1) g_lcd_stress.packets++;
    }
    return ready();
}
// Shared B9 transport. Callers validate coordinates before any SPI traffic.
static int draw_shape(uint8_t shape,uint16_t x,uint16_t y,
                       uint16_t a,uint16_t b,uint16_t color)
{
    uint8_t tx[18]={0},rx[18];
    tx[0]=0xB9;tx[2]=shape;tx[3]=0; // 0 rectangle, 1 line; reserved flags zero.
    tx[4]=(uint8_t)(x>>8);tx[5]=(uint8_t)x;
    tx[6]=(uint8_t)(y>>8);tx[7]=(uint8_t)y;
    tx[8]=(uint8_t)(a>>8);tx[9]=(uint8_t)a;
    tx[10]=(uint8_t)(b>>8);tx[11]=(uint8_t)b;
    tx[12]=(uint8_t)(color>>8);tx[13]=(uint8_t)color;
    uint16_t crc=0xFFFF;
    for(unsigned i=2;i<=13;i++) crc=crc16_byte(crc,tx[i]);
    tx[14]=(uint8_t)(crc>>8);tx[15]=(uint8_t)crc;
    tx[16]=0xA6;

    if(!shape_ready() || !exchange(tx,rx,18)) return 0;
    if(rx[0]!=0xA5) return bad(19,0,0xA5,rx[0]);
    if(rx[1]!=0xC3) return bad(20,1,0xC3,rx[1]);
    for(unsigned i=2;i<17;i++)
        if(rx[i]!=tx[i-1]) return bad(21,i,tx[i-1],rx[i]);
    if(rx[17]!=0xAC) return bad(22,17,0xAC,rx[17]);
    return shape_ready();
}

int LCD_FillRect(uint16_t x,uint16_t y,uint16_t w,uint16_t h,uint16_t color)
{
    if(!w || !h || x>=480 || y>=272 || w>480-x || h>272-y) return 0;
    return draw_shape(0,x,y,w,h,color);
}

int LCD_DrawLine(uint16_t x0,uint16_t y0,uint16_t x1,uint16_t y1,uint16_t color)
{
    if(x0>=480 || x1>=480 || y0>=272 || y1>=272) return 0;
    if(y0==y1) return LCD_DrawHLine(x0<x1?x0:x1,y0,
                                    (uint16_t)((x0<x1?x1-x0:x0-x1)+1),color);
    if(x0==x1) return LCD_DrawVLine(x0,y0<y1?y0:y1,
                                    (uint16_t)((y0<y1?y1-y0:y0-y1)+1),color);
    return draw_shape(1,x0,y0,x1,y1,color);
}

int LCD_Clear(uint16_t color)
{
    return LCD_FillRect(0,0,480,272,color);
}

int LCD_DrawHLine(uint16_t x, uint16_t y, uint16_t length, uint16_t color)
{
    return LCD_FillRect(x,y,length,1,color);
}

int LCD_DrawVLine(uint16_t x, uint16_t y, uint16_t length, uint16_t color)
{
    return LCD_FillRect(x,y,1,length,color);
}

void LCD_Demo_Run(void)
{
    static uint16_t pixels[67*40];
    uint8_t probe_tx[2]={0xB7,0},probe_rx[2];
    g_lcd_demo_state=1;
    if(!exchange(probe_tx,probe_rx,2)) {g_lcd_demo_state=3;return;}
    if(probe_rx[0]==0xA5 && probe_rx[1]==0xB7) {g_lcd_demo_state=0;return;}
    for(unsigned y=0;y<40;y++) for(unsigned x=0;x<67;x++)
        pixels[y*67+x]=(x==0 || x==66 || y==0 || y==39)?0xFFFF:
                      x<22?0xF800:x<44?0x07E0:0x001F;
    g_lcd_demo_state=LCD_WriteRect(101,81,67,40,pixels)?2:3;
}

void LCD_Stress_Run(void)
{
    static uint16_t pixels[67*40];
    uint32_t start=HAL_GetTick();
    g_lcd_stress=(LcdStressResult){.state=1,.failed_rect=0xFFFFFFFF};
    for(unsigned n=0;n<512;n++) {
        unsigned w=1+(n*17)%67,h=1+(n*13)%40;
        unsigned x=(n*37)%(481-w),y=(n*29)%(273-h);
        // Force all four screen corners regularly, including the last pixel.
        switch(n%8) {
          case 0:x=0;y=0;break;
          case 1:x=480-w;y=0;break;
          case 2:x=0;y=272-h;break;
          case 3:x=480-w;y=272-h;break;
        }
        for(unsigned i=0;i<w*h;i++) pixels[i]=(uint16_t)((i*73+n*997)^(i<<7));
        if(!LCD_WriteRect(x,y,w,h,pixels)) {
            g_lcd_stress.failed_rect=n;
            g_lcd_stress.elapsed_ms=HAL_GetTick()-start;
            g_lcd_stress.state=3;return;
        }
        g_lcd_stress.rectangles++;
        g_lcd_stress.pixels+=w*h;
    }
    g_lcd_stress.elapsed_ms=HAL_GetTick()-start;
    g_lcd_stress.state=2;
}
