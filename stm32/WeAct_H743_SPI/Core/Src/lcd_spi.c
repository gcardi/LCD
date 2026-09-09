#include "spi.h"
#include "spi_selftest.h"
#include "lcd_spi.h"
#include "main.h"
#include <stdint.h>
// State: 0 diagnostic endpoint, 1 running, 2 submitted, 3 failure.
volatile uint32_t g_lcd_demo_state;
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
