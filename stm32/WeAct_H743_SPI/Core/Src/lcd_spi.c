#include "spi.h"
#include "lcd_spi.h"
#include "main.h"
#include <stdint.h>
// State: 0 diagnostic endpoint, 1 running, 2 submitted, 3 failure.
volatile uint32_t g_lcd_demo_state;
static int exchange(uint8_t *tx, uint8_t *rx, uint16_t n)
{
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_RESET);
    HAL_StatusTypeDef status=HAL_SPI_TransmitReceive(&hspi2,tx,rx,n,100);
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
    if(status!=HAL_OK) { HAL_SPI_Abort(&hspi2); return 0; }
    return 1;
}
static int ready(void)
{
    uint8_t tx[2]={0xB7,0},rx[2];
    uint32_t start=HAL_GetTick();
    do {
        if(!exchange(tx,rx,2) || rx[0]!=0xA5) return 0;
        if(rx[1]==0xC3) return 1;
        if(rx[1]!=0) return 0;
        HAL_Delay(1);
    } while(HAL_GetTick()-start<1000);
    return 0;
}
// Arbitrary rectangle; unselected pixels in edge bursts are masked in PSRAM.
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels)
{
    if(!pixels || !w || !h || x>=480 || y>=272 || w>480-x || h>272-y) return 0;
    for(unsigned row=0;row<h;row++) for(unsigned bx=x&~15u;bx<x+w;bx+=16) {
        uint8_t tx[41]={0xB7,0},rx[41];
        uint32_t address=(y+row)*480+bx;
        uint16_t mask=0;
        tx[2]=address>>16;tx[3]=address>>8;tx[4]=address;
        for(unsigned i=0;i<16;i++) if(bx+i>=x && bx+i<x+w) {
            uint16_t pixel=pixels[row*w+bx+i-x];
            mask|=(uint16_t)(1u<<i);tx[7+2*i]=pixel;tx[8+2*i]=pixel>>8;
        }
        tx[5]=mask>>8;tx[6]=mask;tx[39]=0x5A;
        if(!ready() || !exchange(tx,rx,41) || rx[0]!=0xA5 || rx[1]!=0xC3 || rx[40]!=0xAC) return 0;
        for(unsigned i=2;i<40;i++) if(rx[i]!=tx[i-1]) return 0;
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
