/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file    freertos.c
  * @brief   FreeRTOS objects and task entry points.
  ******************************************************************************
  */
/* USER CODE END Header */

#include "FreeRTOS.h"
#include "task.h"
#include "main.h"
#include "cmsis_os.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "display_task.h"
#include "lvgl_demo.h"
#include "lvgl_port.h"
#include "touch_probe.h"
/* USER CODE END Includes */

osThreadId_t defaultTaskHandle;
const osThreadAttr_t defaultTask_attributes = {
  .name = "defaultTask",
  .stack_size = 128 * 4,
  .priority = (osPriority_t) osPriorityLow,
};

osThreadId_t DisplayTaskHandle;
const osThreadAttr_t DisplayTask_attributes = {
  .name = "DisplayTask",
  .stack_size = 1024 * 4,
  .priority = (osPriority_t) osPriorityNormal,
};

osThreadId_t GuiTaskHandle;
const osThreadAttr_t GuiTask_attributes = {
  .name = "GuiTask",
  .stack_size = 2048 * 4,
  .priority = (osPriority_t) osPriorityBelowNormal,
};

osMessageQueueId_t displayQueueHandle;
const osMessageQueueAttr_t displayQueue_attributes = {
  .name = "displayQueue"
};

static void StartDefaultTask(void *argument);
static void StartDisplayTask(void *argument);
static void StartGuiTask(void *argument);

void MX_FREERTOS_Init(void)
{
  displayQueueHandle = osMessageQueueNew(8, sizeof(DisplayRequest),
                                         &displayQueue_attributes);
  if (displayQueueHandle == NULL) {
    g_freertos_failure = 1;
    Error_Handler();
  }

  defaultTaskHandle = osThreadNew(StartDefaultTask, NULL,
                                  &defaultTask_attributes);
  DisplayTaskHandle = osThreadNew(StartDisplayTask, NULL,
                                  &DisplayTask_attributes);
  GuiTaskHandle = osThreadNew(StartGuiTask, NULL, &GuiTask_attributes);
  if (defaultTaskHandle == NULL || DisplayTaskHandle == NULL ||
      GuiTaskHandle == NULL) {
    g_freertos_failure = 2;
    Error_Handler();
  }
}

static void StartDefaultTask(void *argument)
{
  /* USER CODE BEGIN StartDefaultTask */
  (void)argument;
  Touch_Probe_Run();
  for (;;) {
    UBaseType_t words = uxTaskGetStackHighWaterMark(NULL);
    g_default_stack_high_water_words = (uint32_t)words;
    g_default_stack_high_water_bytes = (uint32_t)words * sizeof(StackType_t);
    osDelay(1000);
  }
  /* USER CODE END StartDefaultTask */
}

static void StartDisplayTask(void *argument)
{
  /* USER CODE BEGIN StartDisplayTask */
  (void)argument;
  DisplayTask_Run();
  osThreadExit();
  /* USER CODE END StartDisplayTask */
}

static void StartGuiTask(void *argument)
{
  (void)argument;
  while (!g_display_boot_complete && !g_freertos_failure) osDelay(1);
  if (!g_display_ready || g_freertos_failure || !LVGL_Port_Init()) {
    g_lvgl_demo_state = 3;
    osThreadExit();
  }
  LVGL_Demo_Create();
  for (;;) {
    LVGL_Port_Service(5);
    osDelay(5);
  }
}

void vApplicationMallocFailedHook(void)
{
  g_freertos_failure = 3;
  taskDISABLE_INTERRUPTS();
  for (;;) {}
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *task_name)
{
  (void)task;
  (void)task_name;
  g_freertos_failure = 4;
  taskDISABLE_INTERRUPTS();
  for (;;) {}
}
