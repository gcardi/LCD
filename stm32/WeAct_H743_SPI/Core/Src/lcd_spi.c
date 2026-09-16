#include "spi.h"
#include "spi_selftest.h"
#include "lcd_spi.h"
#include "main.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
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
static void dwt_enable(void)
{
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}
static void spi_guard(void)
{
    dwt_enable();
    uint32_t start=DWT->CYCCNT;
    while((uint32_t)(DWT->CYCCNT-start)<SystemCoreClock/1000000u) {}
}
// Where the pixel path spends its time, in DWT cycles at SystemCoreClock.
// Free-running accumulators: read them around a known workload, or call
// LCD_ProfileReset() first. Counts are packets and busy retries, not cycles.
volatile LcdProfile g_lcd_profile;
void LCD_ProfileReset(void)
{
    dwt_enable();
    g_lcd_profile=(LcdProfile){0};
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

// CRC16-CCITT, polynomial 1021, one table lookup per byte. The bit-at-a-time
// form this replaces cost ~334 cycles per byte, and BD streams 960 payload
// bytes per row: measured on the bench, it spent 183 ms per full screen in the
// CRC alone and gave back the whole 150 ms the new transport had saved.
// Each entry is one byte pushed through the shift register from crc = i << 8.
// Moving it to RAM was tried and measured: no change at all, 226 ms against
// 225. The remaining assembly cost is not flash latency on the table.
static const uint16_t crc16_table[256] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
    0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6,
    0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485,
    0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4,
    0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
    0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
    0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12,
    0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
    0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41,
    0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
    0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70,
    0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
    0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F,
    0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E,
    0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D,
    0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C,
    0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
    0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A,
    0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
    0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9,
    0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
    0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8,
    0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0,
};
static uint16_t crc16_byte(uint16_t crc,uint8_t value)
{
    return (uint16_t)((crc<<8)^crc16_table[(uint8_t)((crc>>8)^value)]);
}

volatile uint32_t g_lcd_present_count, g_lcd_present_ms;
volatile uint32_t g_lcd_front_buffer, g_lcd_present_sequence;

int LCD_GetBufferStatus(LcdBufferStatus *status)
{
    uint8_t tx[11]={0xBB},rx[11];
    if(!status || !exchange(tx,rx,sizeof(tx))) return 0;
    if(rx[0]!=0xA5 || rx[1]!=0xD2 || (rx[2]!=1 && rx[2]!=2) || rx[3]!=2)
        return bad(23,1,0xD2,rx[1]);
    uint16_t crc=0xFFFF;
    for(unsigned i=1;i<=8;i++) crc=crc16_byte(crc,rx[i]);
    uint16_t received=(uint16_t)((uint16_t)rx[9]<<8)|rx[10];
    if(crc!=received) return bad(24,9,crc,received);
    if((rx[4]&0xF0) || rx[5]>1) return bad(25,4,0,rx[4]);
    *status=(LcdBufferStatus){.enabled=rx[4]&1,.front=(rx[4]>>1)&1,
        .draw=rx[5],.irq=(rx[4]>>2)&1,.busy=(rx[4]>>3)&1,
        .result=rx[8],.version=rx[2],.sequence=(uint16_t)((uint16_t)rx[6]<<8)|rx[7]};
    return 1;
}

static int buffer_idle(LcdBufferStatus *status,uint32_t timeout_ms)
{
    uint32_t start=HAL_GetTick();
    do {
        if(!LCD_GetBufferStatus(status)) return 0;
        if(!status->busy) return 1;
        HAL_Delay(1);
    } while(HAL_GetTick()-start<timeout_ms);
    return bad(26,0,0,1);
}

// AC acknowledges acceptance only. The BB mailbox reports completion.
static int buffer_command(uint8_t op,uint8_t buffer,uint16_t sequence)
{
    uint8_t tx[10]={0xBA,0,op,buffer,(uint8_t)(sequence>>8),(uint8_t)sequence},rx[10];
    uint16_t crc=0xFFFF;
    for(unsigned i=2;i<=5;i++) crc=crc16_byte(crc,tx[i]);
    tx[6]=(uint8_t)(crc>>8);tx[7]=(uint8_t)crc;tx[8]=0xA6;
    if(!exchange(tx,rx,sizeof(tx))) return 0;
    if(rx[0]!=0xA5 || rx[1]!=0xC3) return bad(27,1,0xC3,rx[1]);
    for(unsigned i=2;i<=8;i++)
        if(rx[i]!=tx[i-1]) return bad(28,i,tx[i-1],rx[i]);
    if(rx[9]!=0xAC) return bad(29,9,0xAC,rx[9]);
    return 1;
}

static int acknowledge_present(uint16_t sequence)
{
    LcdBufferStatus status;
    if(!buffer_command(3,0,sequence) || !buffer_idle(&status,1000)) return 0;
    if(status.result || status.irq) return bad(30,0,0,status.result?status.result:status.irq);
    // No other caller can issue PRESENT between this ACK and flag clearing.
    g_fpga_irq_pending=0;
    g_fpga_irq_level=HAL_GPIO_ReadPin(FPGA_IRQ_N_GPIO_Port,FPGA_IRQ_N_Pin)==GPIO_PIN_SET;
    if(!g_fpga_irq_level) return bad(31,0,1,0);
    return 1;
}

int LCD_EnableDoubleBuffer(void)
{
    LcdBufferStatus status;
    if(!buffer_idle(&status,1000)) return 0;
    // Recover a completed presentation after an MCU-only reset.
    if(status.irq && !acknowledge_present(status.sequence)) return 0;
    if(!buffer_command(1,0,0) || !buffer_idle(&status,1000)) return 0;
    if(status.result || !status.enabled || status.draw==status.front)
        return bad(32,0,1,status.enabled);
    g_lcd_front_buffer=status.front;g_lcd_present_sequence=status.sequence;
    return 1;
}

int LCD_Present(uint32_t timeout_ms)
{
    LcdBufferStatus status;
    if(!timeout_ms || !buffer_idle(&status,timeout_ms)) return 0;
    if(!status.enabled || status.irq) return bad(33,0,1,status.enabled);
    uint8_t target=status.draw;
    uint16_t sequence=(uint16_t)(status.sequence+1u);
    g_fpga_irq_pending=0;
    if(!buffer_command(2,target,sequence)) return 0;
    uint32_t start=HAL_GetTick(),last_poll=start;
    do {
        // EXTI is the normal wakeup; the level also covers a missed edge.
        // Occasional status polls diagnose rejection or a disconnected wire.
        uint32_t now=HAL_GetTick();
        uint32_t low=HAL_GPIO_ReadPin(FPGA_IRQ_N_GPIO_Port,FPGA_IRQ_N_Pin)==GPIO_PIN_RESET;
        if(g_fpga_irq_pending || low || now-last_poll>=5) {
            last_poll=now;
            if(!LCD_GetBufferStatus(&status)) return 0;
            if(!status.busy) {
                if(status.result || !status.irq || status.sequence!=sequence || status.front!=target)
                    return bad(34,0,sequence,status.sequence);
                if(!low) return bad(35,0,0,1);
                g_lcd_present_ms=HAL_GetTick()-start;
                g_lcd_front_buffer=status.front;g_lcd_present_sequence=status.sequence;
                if(!acknowledge_present(sequence)) return 0;
                g_lcd_present_count++;
                return 1;
            }
        }
        HAL_Delay(1);
    } while(HAL_GetTick()-start<timeout_ms);
    return bad(36,0,sequence,status.sequence);
}

volatile uint32_t g_lcd_copy_count,g_lcd_scroll_count,g_lcd_copy_ms,g_lcd_scroll_ms;
volatile uint32_t g_lcd_scroll_demo_state;

static int blit_command(uint8_t operation,uint8_t source,uint8_t destination,
                        uint16_t x,uint16_t y,uint16_t width,uint16_t height,
                        uint16_t arg_x,uint16_t arg_y,uint16_t fill)
{
    LcdBufferStatus status;
    if(!buffer_idle(&status,1000))return 0;
    if(status.version<2)return bad(38,2,2,status.version);
    if(!status.enabled || source!=status.front || destination!=status.draw)
        return bad(39,4,status.draw,destination);
    uint8_t tx[24]={0xBC,0,operation,source,destination,0},rx[24];
    const uint16_t fields[7]={x,y,width,height,arg_x,arg_y,fill};
    for(unsigned i=0;i<7;i++){
        tx[6+2*i]=(uint8_t)(fields[i]>>8);tx[7+2*i]=(uint8_t)fields[i];
    }
    uint16_t crc=0xFFFF;
    for(unsigned i=2;i<=19;i++)crc=crc16_byte(crc,tx[i]);
    tx[20]=(uint8_t)(crc>>8);tx[21]=(uint8_t)crc;tx[22]=0xA6;
    uint32_t start=HAL_GetTick();
    if(!exchange(tx,rx,sizeof(tx)))return 0;
    if(rx[0]!=0xA5 || rx[1]!=0xC3)return bad(40,1,0xC3,rx[1]);
    for(unsigned i=2;i<=22;i++)if(rx[i]!=tx[i-1])return bad(41,i,tx[i-1],rx[i]);
    if(rx[23]!=0xAC)return bad(42,23,0xAC,rx[23]);
    if(!buffer_idle(&status,1000))return 0;
    if(status.result)return bad(43,8,0,status.result);
    if(operation){g_lcd_scroll_ms=HAL_GetTick()-start;g_lcd_scroll_count++;}
    else {g_lcd_copy_ms=HAL_GetTick()-start;g_lcd_copy_count++;}
    return 1;
}

int LCD_CopyRect(uint8_t source,uint8_t destination,uint16_t x,uint16_t y,
                 uint16_t width,uint16_t height,uint16_t dest_x,uint16_t dest_y)
{
    if(source>1 || destination>1 || source==destination || !width || !height ||
       x>=480 || y>=272 || width>480-x || height>272-y ||
       dest_x>=480 || dest_y>=272 || width>480-dest_x || height>272-dest_y)return 0;
    return blit_command(0,source,destination,x,y,width,height,dest_x,dest_y,0);
}

int LCD_ScrollRect(uint8_t source,uint8_t destination,uint16_t x,uint16_t y,
                   uint16_t width,uint16_t height,int16_t dx,int16_t dy,uint16_t fill)
{
    if(source>1 || destination>1 || source==destination || !width || !height ||
       x>=480 || y>=272 || width>480-x || height>272-y)return 0;
    return blit_command(1,source,destination,x,y,width,height,(uint16_t)dx,(uint16_t)dy,fill);
}

void LCD_ScrollDemo_Run(void)
{
    LcdBufferStatus status;
    char line[64];
    static const char *messages[]={"PSRAM: copia interna, nessun pixel sulla SPI",
        "Viewport: 442 x 176, bordi non allineati",
        "Area scoperta riempita dal comando SCROLL",
        "Nuova riga disegnata nel back buffer",
        "PRESENT: swap al blanking, IRQ confermato"};
    g_lcd_scroll_demo_state=1;
    uint32_t irq_start=g_fpga_irq_count;
    if(!LCD_EnableDoubleBuffer() || !LCD_Clear(0x0841) ||
       !LCD_DrawTextFPGA(20,8,0,0,LCD_FONT_12X24,0,0x07FF,0x0841,"Terminale FPGA") ||
       !LCD_DrawTextFPGA(20,36,0,0,LCD_FONT_8X16,0,0xFFFF,0x0841,
                        "COPY / SCROLL / fill RGB565 / VSYNC + IRQ") ||
       !LCD_FillRect(18,59,444,178,0x07E0) || !LCD_FillRect(19,60,442,176,0) ||
       !LCD_DrawTextFPGA(20,248,0,0,LCD_FONT_8X16,0,0xFFE0,0x0841,
                        "32 righe - cornice e sfondo preservati") || !LCD_Present(1000) ||
       !LCD_GetBufferStatus(&status) ||
       !LCD_CopyRect(status.front,status.draw,0,0,480,272,0,0))goto fail;
    // Both buffers now have identical borders/background. Only the viewport
    // needs updating on subsequent frames; no full-frame copy in the loop.
    for(unsigned n=1;n<=32;n++){
        if(!LCD_GetBufferStatus(&status) ||
           !LCD_ScrollRect(status.front,status.draw,19,60,442,176,0,-16,0))goto fail;
        (void)snprintf(line,sizeof(line),"%02u > %s",n,messages[(n-1)%5]);
        if(!LCD_DrawTextFPGA(23,220,434,16,LCD_FONT_8X16,LCD_TEXT_TRANSPARENT,
                            (n%5)==0?0x07FF:0xFFFF,0,line) || !LCD_Present(1000))goto fail;
        HAL_Delay(120);
    }
    if(g_fpga_irq_count-irq_start!=33){bad(44,0,33,g_fpga_irq_count-irq_start);goto fail;}
    g_lcd_scroll_demo_state=2;return;
fail:
    g_lcd_scroll_demo_state=3;
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
    if(!LCD_EnableDoubleBuffer()) {g_lcd_fpga_text_demo_state=3;return;}
    // Rebuild every back frame: partial redraws would retain older contents.
    // Exercise both physical buffers and the IRQ/ACK cycle before the sample.
    uint32_t irq_start=g_fpga_irq_count;
    for(unsigned frame=0;frame<16;frame++) {
        if(!LCD_Clear(0x0000) ||
           !LCD_DrawTextFPGA(24,32,0,0,LCD_FONT_12X24,0,0x07FF,0,
                            "Double buffer / VSYNC / IRQ") ||
           !LCD_FillRect((uint16_t)(24+frame*24),112,40,64,(frame&1)?0x07E0:0xF800) ||
           !LCD_Present(1000)) {g_lcd_fpga_text_demo_state=3;return;}
        HAL_Delay(80);
    }
    if(g_fpga_irq_count-irq_start!=16) {
        bad(37,0,16,g_fpga_irq_count-irq_start);g_lcd_fpga_text_demo_state=3;return;
    }
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
       !LCD_DrawLine(350,193,315,208,0xFD20) ||
       !LCD_DrawTextFPGA(20,244,0,0,LCD_FONT_8X16,0,0x07E0,0,
                        "Double buffer + VSYNC + IRQ: OK") ||
       !LCD_Present(1000)) {
        g_lcd_fpga_text_demo_state=3;return;
    }
    g_lcd_fpga_text_demo_state=2;
}
// Arbitrary rectangle; unselected pixels in edge bursts are masked in PSRAM.
int LCD_WriteRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                  const uint16_t *pixels)
{
    if(!pixels || !w || !h || x>=480 || y>=272 || w>480-x || h>272-y) return 0;
    uint32_t mark;
    dwt_enable();
    for(unsigned row=0;row<h;row++) for(unsigned bx=x&~15u;bx<x+w;bx+=16) {
        uint8_t tx[41]={0xB7,0},rx[41];
        uint32_t address=(y+row)*480+bx;
        if(!g_lcd_error[0]) g_lcd_error[1]=address;
        mark=DWT->CYCCNT;
        uint16_t mask=0;
        tx[2]=address>>16;tx[3]=address>>8;tx[4]=address;
        for(unsigned i=0;i<16;i++) if(bx+i>=x && bx+i<x+w) {
            uint16_t pixel=pixels[row*w+bx+i-x];
            mask|=(uint16_t)(1u<<i);tx[7+2*i]=pixel;tx[8+2*i]=pixel>>8;
        }
        tx[5]=mask>>8;tx[6]=mask;tx[39]=0x5A;
        g_lcd_profile.assemble+=DWT->CYCCNT-mark;
        // No separate B7 poll: byte 1 of this very packet carries the same
        // readiness, because the FPGA latches accept_packet from that condition
        // at index 0. A busy answer commits nothing, so resending the identical
        // packet is safe and idempotent.
        uint32_t start=HAL_GetTick();
        for(;;) {
            mark=DWT->CYCCNT;
            int sent=exchange(tx,rx,41);
            g_lcd_profile.exchange+=DWT->CYCCNT-mark;
            if(!sent) return 0;
            if(rx[0]!=0xA5) return bad(5,0,0xA5,rx[0]);
            if(rx[1]==0xC3) break;
            if(rx[1]!=0) return bad(6,1,0xC3,rx[1]);
            g_lcd_profile.retries++;
            if(HAL_GetTick()-start>=1000) return bad(4,1,0xC3,rx[1]);
        }
        if(rx[40]!=0xAC) return bad(7,40,0xAC,rx[40]);
        for(unsigned i=2;i<40;i++) if(rx[i]!=tx[i-1]) return bad(8,i,tx[i-1],rx[i]);
        g_lcd_profile.packets++;
        if(g_lcd_stress.state==1) g_lcd_stress.packets++;
    }
    mark=DWT->CYCCNT;
    int done=ready();
    g_lcd_profile.fence+=DWT->CYCCNT-mark;
    return done;
}
// BD carries one row per transaction: header, contiguous RGB565 payload, a
// CRC over that payload, and a commit. At most 12 + 2*480 + 4 = 976 bytes, so
// a full-width row always fits a single DMA. Returns 1 accepted, 0 hard error,
// -1 retryable (the FPGA was busy, or reported overflow / payload CRC).
static uint8_t stream_tx[1024], stream_rx[1024];
static int stream_row(uint16_t y,uint16_t x,uint16_t count,const uint16_t *row)
{
    unsigned last_column=x+count-1u;
    unsigned first=x>>4, groups=(last_column>>4)-first+1u;
    uint16_t head=(uint16_t)(0xFFFFu<<(x&15u));
    uint16_t tail=(uint16_t)(0xFFFFu>>(15u-(last_column&15u)));
    uint32_t mark=DWT->CYCCNT;
    uint8_t *p=stream_tx;
    p[0]=0xBD;p[1]=0;
    p[2]=(uint8_t)(y>>8);p[3]=(uint8_t)y;
    p[4]=(uint8_t)first;p[5]=(uint8_t)groups;
    p[6]=(uint8_t)(head>>8);p[7]=(uint8_t)head;
    p[8]=(uint8_t)(tail>>8);p[9]=(uint8_t)tail;
    uint16_t crc=0xFFFF;
    for(unsigned i=2;i<=9;i++) crc=crc16_byte(crc,p[i]);
    p[10]=(uint8_t)(crc>>8);p[11]=(uint8_t)crc;p[12]=0xA6;p[13]=0;
    crc=0xFFFF;
    unsigned n=14;
    // Whole groups only, built as three contiguous runs instead of a decision
    // per pixel: pad, the source row verbatim, pad. RGB565 low byte first is
    // exactly how a uint16_t already sits in memory here, so the body is a
    // straight copy. Then one tight pass for the CRC over the whole payload.
    unsigned pad_head=x-first*16u;
    unsigned pad_tail=(first+groups)*16u-1u-last_column;
    unsigned payload=n;
    if(pad_head) {memset(p+n,0,pad_head*2u);n+=pad_head*2u;}
    memcpy(p+n,row,count*2u);n+=count*2u;
    if(pad_tail) {memset(p+n,0,pad_tail*2u);n+=pad_tail*2u;}
    for(unsigned i=payload;i<n;i++)
        crc=(uint16_t)((crc<<8)^crc16_table[(uint8_t)((crc>>8)^p[i])]);
    p[n]=(uint8_t)(crc>>8);p[n+1]=(uint8_t)crc;p[n+2]=0xA6;p[n+3]=0;
    n+=4u;
    // Split the two costs the way the B7 path does, so the payload CRC and
    // the padding loop are not hidden inside the transfer figure.
    g_lcd_profile.assemble+=DWT->CYCCNT-mark;
    mark=DWT->CYCCNT;
    int sent=exchange(stream_tx,stream_rx,(uint16_t)n);
    g_lcd_profile.exchange+=DWT->CYCCNT-mark;
    if(!sent) return 0;
    if(stream_rx[0]!=0xA5) return bad(45,0,0xA5,stream_rx[0]);
    if(stream_rx[1]!=0xC3) {
        if(stream_rx[1]!=0) return bad(46,1,0xC3,stream_rx[1]);
        return -1; // queue still draining; the row was never started
    }
    for(unsigned i=2;i<=12;i++)
        if(stream_rx[i]!=stream_tx[i-1]) return bad(47,i,stream_tx[i-1],stream_rx[i]);
    // A header refused while the endpoint reported free is a protocol fault,
    // not backpressure: the fields and CRC were built here.
    if(stream_rx[13]!=0xAC) return bad(48,13,0xAC,stream_rx[13]);
    if(stream_rx[n-1]!=0xAC) return -1;
    return 1;
}

// Same contract as LCD_WriteRect, one transaction per row instead of one per
// sixteen pixels. Rows commit as they stream, so a refused row leaves part of
// itself behind; resending it is idempotent and nothing reaches the panel
// before PRESENT.
int LCD_WriteRectStream(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                        const uint16_t *pixels)
{
    if(!pixels || !w || !h || x>=480 || y>=272 || w>480-x || h>272-y) return 0;
    uint32_t mark;
    dwt_enable();
    for(unsigned row=0;row<h;row++) {
        uint32_t start=HAL_GetTick();
        for(;;) {
            int outcome=stream_row((uint16_t)(y+row),x,w,pixels+(size_t)row*w);
            if(outcome>0) break;
            if(outcome==0) return 0;
            g_lcd_profile.retries++;
            if(HAL_GetTick()-start>=1000) return bad(49,0,0xAC,0xE1);
        }
        g_lcd_profile.packets++;
    }
    mark=DWT->CYCCNT;
    int done=ready();
    g_lcd_profile.fence+=DWT->CYCCNT-mark;
    return done;
}

// Full screen down both paths, one row at a time so a single row buffer does.
// State: 1 running, 2 done, 3 B7 failed, 4 BD failed.
volatile uint32_t g_lcd_bench_state,g_lcd_bench_b7_ms,g_lcd_bench_bd_ms;
volatile LcdProfile g_lcd_bench_b7,g_lcd_bench_bd;
void LCD_StreamBench_Run(void)
{
    static uint16_t row[480];
    uint32_t start;
    for(unsigned i=0;i<480;i++) row[i]=(uint16_t)(i*37u+1u);
    g_lcd_bench_state=1;
    LCD_ProfileReset();start=HAL_GetTick();
    for(unsigned y=0;y<272;y++)
        if(!LCD_WriteRect(0,(uint16_t)y,480,1,row)){g_lcd_bench_state=3;return;}
    g_lcd_bench_b7_ms=HAL_GetTick()-start;g_lcd_bench_b7=g_lcd_profile;
    LCD_ProfileReset();start=HAL_GetTick();
    for(unsigned y=0;y<272;y++)
        if(!LCD_WriteRectStream(0,(uint16_t)y,480,1,row)){g_lcd_bench_state=4;return;}
    g_lcd_bench_bd_ms=HAL_GetTick()-start;g_lcd_bench_bd=g_lcd_profile;
    g_lcd_bench_state=2;
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
