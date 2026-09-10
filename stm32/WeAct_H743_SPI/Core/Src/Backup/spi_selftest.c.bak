#include "spi_selftest.h"
#include "spi.h"
#include "main.h"
#include "spi_diag_config.h"
#include <string.h>

#if SPI_DIAG_MATRIX
static void diagnostic_matrix(void);
#endif

// Separate, cache-line aligned buffers in DMA-accessible SRAM, not DTCM.
static uint8_t tx[4128] __attribute__((section(".spi_dma"), aligned(32)));
static uint8_t rx[4128] __attribute__((section(".spi_dma"), aligned(32)));
volatile SpiTestResult g_spi_test;
static volatile uint32_t completed, failed;
// Slow GPIO probe, independent of SPI/DMA. Each row uses no pull, pull-up,
// then pull-down on MISO; differing replies expose an undriven return line.
volatile uint8_t g_spi_gpio_probe[3][8];
static void reset_transaction_after_config(void)
{
    // Give both clock-edge domains clocks while the slave is deselected.
    // No payload is sent; CS remains high and MISO must remain high impedance.
    GPIO_InitTypeDef io={0};
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_SET);
    HAL_GPIO_WritePin(GPIOB,GPIO_PIN_13,GPIO_PIN_RESET);
    io.Pin=GPIO_PIN_13;io.Mode=GPIO_MODE_OUTPUT_PP;io.Speed=GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(GPIOB,&io);
    for(unsigned i=0;i<2;i++) {
        HAL_GPIO_WritePin(GPIOB,GPIO_PIN_13,GPIO_PIN_SET);HAL_Delay(1);
        HAL_GPIO_WritePin(GPIOB,GPIO_PIN_13,GPIO_PIN_RESET);HAL_Delay(1);
    }
    io.Mode=GPIO_MODE_AF_PP;io.Alternate=GPIO_AF5_SPI2;io.Speed=GPIO_SPEED_FREQ_MEDIUM;
    HAL_GPIO_Init(GPIOB,&io);
}
#if SPI_GPIO_PROBE
static void probe_gpio(void)
{
    GPIO_InitTypeDef io = {0};
    HAL_GPIO_WritePin(GPIOB, GPIO_PIN_13|GPIO_PIN_15, GPIO_PIN_RESET);
    io.Pin=GPIO_PIN_13|GPIO_PIN_15; io.Mode=GPIO_MODE_OUTPUT_PP;
    io.Speed=GPIO_SPEED_FREQ_LOW; HAL_GPIO_Init(GPIOB,&io);
    for(unsigned p=0;p<3;p++) {
        io.Pin=GPIO_PIN_14; io.Mode=GPIO_MODE_INPUT;
        io.Pull=p==0?GPIO_NOPULL:p==1?GPIO_PULLUP:GPIO_PULLDOWN;
        HAL_GPIO_Init(GPIOB,&io);
        HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_SET); HAL_Delay(2);
        HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_RESET); HAL_Delay(2);
        for(unsigned b=0;b<8;b++) {
            uint8_t value=(uint8_t)(0x3C+b*17), reply=0;
            for(unsigned bit=0;bit<8;bit++) {
                HAL_GPIO_WritePin(GPIOB,GPIO_PIN_15,(value&(0x80>>bit))?GPIO_PIN_SET:GPIO_PIN_RESET);
                HAL_Delay(1);
                HAL_GPIO_WritePin(GPIOB,GPIO_PIN_13,GPIO_PIN_SET);
                HAL_Delay(1); // Sample after GPIO/pad settling, not immediately after BSRR.
                reply=(uint8_t)((reply<<1)|(HAL_GPIO_ReadPin(GPIOB,GPIO_PIN_14)==GPIO_PIN_SET));
                HAL_GPIO_WritePin(GPIOB,GPIO_PIN_13,GPIO_PIN_RESET);
            }
            g_spi_gpio_probe[p][b]=reply;
        }
        HAL_Delay(1); HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_SET);
    }
    io.Pin=GPIO_PIN_13|GPIO_PIN_14|GPIO_PIN_15; io.Mode=GPIO_MODE_AF_PP;
    io.Pull=GPIO_NOPULL; io.Speed=GPIO_SPEED_FREQ_MEDIUM;
    io.Alternate=GPIO_AF5_SPI2; HAL_GPIO_Init(GPIOB,&io);
}
#endif

void HAL_SPI_TxRxCpltCallback(SPI_HandleTypeDef *hspi)
{
    if(hspi == &hspi2) completed = 1;
}
void HAL_SPI_ErrorCallback(SPI_HandleTypeDef *hspi)
{
    if(hspi == &hspi2) failed = 1;
}

// Synchronous owner of the same DMA buffers/callbacks as the boot test.
// Caller owns CS. No concurrent transfers are allowed.
int SPI_Exchange_DMA(const uint8_t *send,uint8_t *receive,uint16_t length)
{
    if(!length || length>sizeof(tx)) return 0;
    memcpy(tx,send,length);
    uint32_t cache_length=(length+31u)&~31u;
    if(SCB->CCR & SCB_CCR_DC_Msk) {
        SCB_CleanDCache_by_Addr((uint32_t*)tx,cache_length);
        SCB_CleanInvalidateDCache_by_Addr((uint32_t*)rx,cache_length);
    }
    __DSB();completed=0;failed=0;
    uint32_t start=HAL_GetTick();
    HAL_StatusTypeDef status=HAL_SPI_TransmitReceive_DMA(&hspi2,tx,rx,length);
    while(status==HAL_OK && !completed && !failed && HAL_GetTick()-start<1000) {}
    if(status!=HAL_OK || !completed || failed) {HAL_SPI_Abort(&hspi2);return 0;}
    if(SCB->CCR & SCB_CCR_DC_Msk) SCB_InvalidateDCache_by_Addr((uint32_t*)rx,cache_length);
    __DSB();memcpy(receive,rx,length);return 1;
}

// Readiness handshake over the existing link, in place of a blind delay.
//
// Only B7 and B8 are opcodes; any other leading byte takes the plain echo path,
// which answers A5 and then echoes the previous byte. An unconfigured FPGA
// cannot produce that: its pins are inputs with weak pull-ups, so MISO reads FF.
// Matching the echo therefore proves the device is configured, its PLLs are
// locked and the SPI slave is running, which a fixed HAL_Delay only assumed.
static int fpga_answers(void)
{
    // 0x00 is deliberately not an opcode, so this probe draws nothing.
    static const uint8_t probe[3] = {0x00, 0x5A, 0xC3};
    uint8_t reply[3] = {0};
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_RESET);
    HAL_Delay(1);
    int ok = SPI_Exchange_DMA(probe, reply, sizeof(probe));
    HAL_Delay(1);
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
    if(!ok) return 0;
    return reply[0]==0xA5 && reply[1]==probe[0] && reply[2]==probe[1];
}

int SPI_Setup(void)
{
    __HAL_RCC_D2SRAM1_CLK_ENABLE();
    uint32_t start = HAL_GetTick();
    uint32_t attempts = 0;
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
    int ready = 0;
    do {
        // The two SCK pulses suppress the anomaly seen after an FPGA load, and
        // must precede the first real transaction. Repeating them is harmless
        // and covers an FPGA that finished configuring only after the first try.
        reset_transaction_after_config();
        attempts++;
        ready = fpga_answers();
    } while(!ready && HAL_GetTick()-start < SPI_SETUP_TIMEOUT_MS);
    g_spi_test.ready_ms = HAL_GetTick()-start;
    g_spi_test.ready_attempts = attempts;
    return ready;
}

void SPI_SelfTest_Run(void)
{
#if SPI_DIAG_MATRIX
    diagnostic_matrix();
    return;
#endif
    static const uint16_t lengths[] = {1, 2, 17, 257, 4097};
    // SPI_Setup() has already deselected, pulsed SCK and waited for the FPGA;
    // its measurements are preserved here rather than overwritten.
    uint32_t ready_ms=g_spi_test.ready_ms, ready_attempts=g_spi_test.ready_attempts;
    g_spi_test = (SpiTestResult){.magic=0x53504954, .version=1, .state=1,
        .first_bad_index=0xFFFFFFFF,
        .ready_ms=ready_ms, .ready_attempts=ready_attempts,
        .sck_hz=HAL_RCCEx_GetPeriphCLKFreq(RCC_PERIPHCLK_SPI2) /
            (2u << (hspi2.Init.BaudRatePrescaler >> SPI_CFG1_MBR_Pos))};
    uint32_t start=HAL_GetTick();
#if SPI_GPIO_PROBE
    probe_gpio();
#endif
    for(uint32_t round=0;round<SPI_SELFTEST_ROUNDS;round++) {
        for(uint32_t t=0;t<sizeof(lengths)/sizeof(lengths[0]);t++) {
            uint16_t length=lengths[t];
            for(uint32_t i=0;i<sizeof(tx);i++) tx[i]=(uint8_t)((i*37+round*53)^(i>>3));
            // B7 and B8 are application opcodes, never send them as echo opcodes.
            if(tx[0]==0xB7 || tx[0]==0xB8) tx[0]^=0x80;
            memset(rx,0,sizeof(rx));
            if(SCB->CCR & SCB_CCR_DC_Msk) {
                SCB_CleanDCache_by_Addr((uint32_t*)tx,sizeof(tx));
                SCB_CleanInvalidateDCache_by_Addr((uint32_t*)rx,sizeof(rx));
            }
            __DSB(); completed=0; failed=0;
            HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_RESET);
            HAL_Delay(1);
            uint32_t transfer_start=HAL_GetTick();
            HAL_StatusTypeDef status=HAL_SPI_TransmitReceive_DMA(&hspi2,tx,rx,length);
            while(status==HAL_OK && !completed && !failed && HAL_GetTick()-transfer_start<1000) {}
            if(status!=HAL_OK || failed || !completed) {
                g_spi_test.hal_error=HAL_SPI_GetError(&hspi2);
                if(!g_spi_test.hal_error) g_spi_test.hal_error=0x80000000u | (uint32_t)status;
                HAL_SPI_Abort(&hspi2);
                HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
                goto fail;
            }
            // H7 HAL TxRx completion follows SPI EOT, not just DMA TC.
            HAL_Delay(1);
            HAL_GPIO_WritePin(FPGA_CS_GPIO_Port, FPGA_CS_Pin, GPIO_PIN_SET);
            if(SCB->CCR & SCB_CCR_DC_Msk) SCB_InvalidateDCache_by_Addr((uint32_t*)rx,sizeof(rx));
            __DSB();
            for(uint32_t i=0;i<length;i++) {
                uint8_t expected = i==0 ? 0xA5 : tx[i-1];
                g_spi_test.checked_bytes++;
                if(rx[i]!=expected) {
                    if(!g_spi_test.mismatches) {
                        g_spi_test.first_bad_index=i;
                        g_spi_test.expected=expected;
                        g_spi_test.actual=rx[i];
                    }
                    g_spi_test.mismatches++;
                }
            }
            g_spi_test.transfers++;
            HAL_Delay(1);
        }
    }
    if(g_spi_test.mismatches) goto fail;
    g_spi_test.elapsed_ms=HAL_GetTick()-start;
    __DMB();g_spi_test.state=2;return;
fail:
    g_spi_test.elapsed_ms=HAL_GetTick()-start;
    __DMB();g_spi_test.state=3;
}

#if SPI_DIAG_MATRIX
// Fixed uint32_t layout read via ELF symbols by diagnose-hardware.ps1.
typedef struct {
    uint32_t round,length,index,expected,actual,rx_prev,rx_next,expected_prev,expected_next;
} DiagEvent;
typedef struct {
    uint32_t hz,speed,repeat,transfers,checked,mismatches,hal_error,elapsed_ms,event_count;
    DiagEvent events[16];
} DiagCase;
volatile struct {
    uint32_t magic,version,state,mode,count;
    DiagCase cases[18];
} g_spi_diag;
_Static_assert(sizeof(DiagCase)==612, "SWD diagnostic case layout changed");
_Static_assert(sizeof(g_spi_diag)==11036, "SWD diagnostic matrix layout changed");
static uint8_t expected_rx[4128];
static uint8_t lfsr_next(uint8_t value) { return (value>>1)^((value&1)?0xB8:0); }
static uint16_t crc_byte(uint16_t crc, uint8_t value) {
    crc ^= (uint16_t)value<<8;
    for(unsigned bit=0;bit<8;bit++) crc=(uint16_t)((crc<<1)^((crc&0x8000)?0x1021:0));
    return crc;
}
static void diag_clock(uint32_t prescaler, uint32_t speed) {
    hspi2.Init.BaudRatePrescaler=prescaler;
    if(HAL_SPI_Init(&hspi2)!=HAL_OK) Error_Handler();
    GPIO_InitTypeDef io={0};
    io.Pin=GPIO_PIN_13|GPIO_PIN_14|GPIO_PIN_15;
    io.Mode=GPIO_MODE_AF_PP;io.Pull=GPIO_NOPULL;io.Speed=speed;
    io.Alternate=GPIO_AF5_SPI2;HAL_GPIO_Init(GPIOB,&io);
}
static int diag_dma(uint16_t length, volatile DiagCase *result) {
    memset(rx,0,sizeof(rx));
    if(SCB->CCR & SCB_CCR_DC_Msk) {
        SCB_CleanDCache_by_Addr((uint32_t*)tx,sizeof(tx));
        SCB_CleanInvalidateDCache_by_Addr((uint32_t*)rx,sizeof(rx));
    }
    __DSB();completed=0;failed=0;
    uint32_t start=HAL_GetTick();
    HAL_StatusTypeDef status=HAL_SPI_TransmitReceive_DMA(&hspi2,tx,rx,length);
    while(status==HAL_OK && !completed && !failed && HAL_GetTick()-start<1000) {}
    if(status!=HAL_OK || failed || !completed) {
        result->hal_error=HAL_SPI_GetError(&hspi2);
        if(!result->hal_error) result->hal_error=0x80000000u|(uint32_t)status;
        HAL_SPI_Abort(&hspi2);return 0;
    }
    if(SCB->CCR & SCB_CCR_DC_Msk) SCB_InvalidateDCache_by_Addr((uint32_t*)rx,sizeof(rx));
    __DSB();return 1;
}
static void diagnostic_matrix(void) {
    static const uint16_t lengths[]={1,2,17,257,4097};
    static const uint32_t speeds[]={GPIO_SPEED_FREQ_VERY_HIGH,GPIO_SPEED_FREQ_HIGH,GPIO_SPEED_FREQ_MEDIUM};
    __HAL_RCC_D2SRAM1_CLK_ENABLE();
    memset((void*)&g_spi_diag,0,sizeof(g_spi_diag));
    g_spi_diag.magic=0x44494147;g_spi_diag.version=1;g_spi_diag.state=1;g_spi_diag.mode=SPI_DIAG_MODE;
    HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_SET);HAL_Delay(100);
    reset_transaction_after_config();
    if(SPI_DIAG_MODE==0) probe_gpio();
    // Alternate rates on each repeated sweep to expose time-dependent effects.
    for(unsigned repeat=0;repeat<3;repeat++) for(unsigned rate=0;rate<2;rate++) for(unsigned speed=0;speed<3;speed++) {
        volatile DiagCase *result=&g_spi_diag.cases[g_spi_diag.count];
        uint32_t prescaler=rate?SPI_BAUDRATEPRESCALER_16:SPI_BAUDRATEPRESCALER_32;
        result->hz=rate?12500000:6250000;result->speed=speeds[speed];result->repeat=repeat;
        uint32_t start=HAL_GetTick();
        for(unsigned round=0;round<SPI_DIAG_ROUNDS && !result->hal_error;round++) {
            unsigned tests=SPI_DIAG_MODE==2?1:5;
            for(unsigned t=0;t<tests;t++) {
                uint16_t length=SPI_DIAG_MODE==2?4096:lengths[t];
                uint16_t crc=0xFFFF;
                uint8_t sequence=0xA5;
                for(unsigned i=0;i<sizeof(tx);i++) {
                    tx[i]=(uint8_t)((i*37+round*53)^(i>>3));
                    expected_rx[i]=SPI_DIAG_MODE==1?sequence:(i==0?0xA5:tx[i-1]);
                    sequence=lfsr_next(sequence);
                    if(i<length) crc=crc_byte(crc,tx[i]);
                }
                diag_clock(prescaler,speeds[speed]);HAL_Delay(1);
                HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_RESET);HAL_Delay(1);
                int ok=diag_dma(length,result);
                if(ok && SPI_DIAG_MODE==2) {
                    // Keep CS asserted: read FPGA's CRC at the conservative rate.
                    HAL_Delay(1);diag_clock(SPI_BAUDRATEPRESCALER_256,speeds[speed]);HAL_Delay(1);
                    length=4;memset(tx,0,sizeof(tx));
                    expected_rx[0]=0xC3;expected_rx[1]=crc>>8;expected_rx[2]=crc;expected_rx[3]=0x5A;
                    ok=diag_dma(length,result);
                }
                HAL_Delay(1);HAL_GPIO_WritePin(FPGA_CS_GPIO_Port,FPGA_CS_Pin,GPIO_PIN_SET);HAL_Delay(1);
                if(!ok) break;
                for(unsigned i=0;i<length;i++) {
                    result->checked++;
                    if(rx[i]==expected_rx[i]) continue;
                    result->mismatches++;
                    if(result->event_count<16) {
                        DiagEvent event={round,length,i,expected_rx[i],rx[i],
                            i?rx[i-1]:256,i+1<length?rx[i+1]:256,
                            i?expected_rx[i-1]:256,i+1<length?expected_rx[i+1]:256};
                        result->events[result->event_count++]=event;
                    }
                }
                result->transfers++;
            }
        }
        result->elapsed_ms=HAL_GetTick()-start;
        __DMB();g_spi_diag.count++;
    }
    // Leave the peripheral at the conservative rate with medium edges.
    diag_clock(SPI_BAUDRATEPRESCALER_32,GPIO_SPEED_FREQ_MEDIUM);
    __DMB();g_spi_diag.state=2;
}
#endif
