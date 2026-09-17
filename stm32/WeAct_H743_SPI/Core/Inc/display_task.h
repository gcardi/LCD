#ifndef DISPLAY_TASK_H
#define DISPLAY_TASK_H

#include "cmsis_os2.h"
#include <stdint.h>

/*
 * The display task is the only owner of SPI2 and the FPGA/LCD API. A queued
 * request copies this descriptor, not the pointed-to context: the producer
 * must keep context valid until execute() has run.
 */
typedef void (*DisplayRequestHandler)(void *context);

typedef struct {
    DisplayRequestHandler execute;
    void *context;
} DisplayRequest;

extern volatile uint32_t g_display_stack_high_water_words;
extern volatile uint32_t g_display_stack_high_water_bytes;
extern volatile uint32_t g_default_stack_high_water_words;
extern volatile uint32_t g_default_stack_high_water_bytes;
extern volatile uint32_t g_freertos_failure;

osStatus_t DisplayTask_Post(DisplayRequestHandler execute, void *context,
                            uint32_t timeout_ticks);
int DisplayTask_IsOwner(void);
void DisplayTask_Run(void);

#endif /* DISPLAY_TASK_H */
