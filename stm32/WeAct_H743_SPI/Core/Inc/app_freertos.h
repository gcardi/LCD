/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file    app_freertos.h
  * @brief   Application FreeRTOS declarations.
  ******************************************************************************
  */
/* USER CODE END Header */

#ifndef APP_FREERTOS_H
#define APP_FREERTOS_H

#ifdef __cplusplus
extern "C" {
#endif

#include "cmsis_os.h"

extern osThreadId_t defaultTaskHandle;
extern osThreadId_t DisplayTaskHandle;
extern osThreadId_t GuiTaskHandle;
extern osMessageQueueId_t displayQueueHandle;

void MX_FREERTOS_Init(void);

#ifdef __cplusplus
}
#endif

#endif /* APP_FREERTOS_H */
