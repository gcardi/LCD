#include "display_task.h"
#include "app_freertos.h"
#include "main.h"
#include "spi_selftest.h"
#include "lcd_spi.h"
#include "lcd_text.h"
#include "spi_diag_config.h"
#include "FreeRTOS.h"
#include "task.h"

volatile uint32_t g_display_stack_high_water_words;
volatile uint32_t g_display_stack_high_water_bytes;
volatile uint32_t g_default_stack_high_water_words;
volatile uint32_t g_default_stack_high_water_bytes;
volatile uint32_t g_freertos_failure;

static void record_stack_margin(void)
{
    UBaseType_t words = uxTaskGetStackHighWaterMark(NULL);
    g_display_stack_high_water_words = (uint32_t)words;
    g_display_stack_high_water_bytes = (uint32_t)words * sizeof(StackType_t);
}

int DisplayTask_IsOwner(void)
{
    return osKernelGetState() == osKernelRunning &&
           osThreadGetId() == DisplayTaskHandle;
}

osStatus_t DisplayTask_Post(DisplayRequestHandler execute, void *context,
                            uint32_t timeout_ticks)
{
    if (execute == NULL || displayQueueHandle == NULL) return osErrorParameter;
    DisplayRequest request = {.execute = execute, .context = context};
    return osMessageQueuePut(displayQueueHandle, &request, 0, timeout_ticks);
}

void DisplayTask_Run(void)
{
    /* Bring up and qualify the link before accepting display requests. */
    SPI_Setup();
    int fpga_ok = FPGA_Start();
    (void)fpga_ok;
    SPI_SelfTest_Run();

#if LCD_TEXT_DEMO
    if (fpga_ok && g_spi_test.state == 2) LCD_TextDemo_Run();
#endif
#if LCD_FPGA_TEXT_DEMO
    if (fpga_ok && g_spi_test.state == 2) LCD_FPGATextDemo_Run();
#endif
#if LCD_STREAM_BENCH
    if (fpga_ok && g_spi_test.state == 2 && !g_lcd_error[0]) LCD_StreamBench_Run();
#endif
#if LCD_SCROLL_DEMO
    if (fpga_ok && g_spi_test.state == 2 && !g_lcd_error[0]) LCD_ScrollDemo_Run();
#endif
#if LCD_BOOT_TESTS
    if (fpga_ok && g_spi_test.state == 2) {
        LCD_Demo_Run();
        if (g_lcd_demo_state == 2) {
            LCD_Stress_Run();
            if (g_lcd_stress.state == 2) LCD_Demo_Run();
        }
    }
#endif

    g_fpga_irq_level =
        HAL_GPIO_ReadPin(FPGA_IRQ_N_GPIO_Port, FPGA_IRQ_N_Pin) == GPIO_PIN_SET;
    record_stack_margin();

    for (;;) {
        DisplayRequest request;
        if (osMessageQueueGet(displayQueueHandle, &request, NULL,
                              osWaitForever) == osOK) {
            if (request.execute != NULL) request.execute(request.context);
            record_stack_margin();
        }
    }
}
