# FreeRTOS on the STM32H743

## Migration and asynchronous DMA

FreeRTOS 10.6.2 and CMSIS-RTOS v2 come from the same
`STM32Cube_FW_H7_V1.13.0` package the project already uses. The LCD APIs stay
blocking for the caller, but the DMA wait no longer polls internally: the HAL
callback wakes `DisplayTask` directly with `vTaskNotifyGiveFromISR()`, and the
task waits with `ulTaskNotifyTake()`.

`main()` initializes devices and kernels, creates the objects, and calls
`osKernelStart()`. `defaultTask` is intentionally empty: it just updates its
own stack high-water mark and sleeps. `DisplayTask` runs the existing boot
sequence (`SPI_Setup`, FPGA reset/test, self-test, and whichever demos are
enabled), then blocks on `displayQueue`.

The queue carries `DisplayRequest` entries: a function to execute plus a
pointer to its context. `DisplayTask_Post()` copies the descriptor into the
queue but not the context, which must stay valid until execution runs. The
wrappers `SPI_Exchange_DMA`, `SPI_Transmit_DMA`, and `SPI_SetBaudRatePrescaler`
reject any caller other than `DisplayTask`: SPI2 and the FPGA have a single
owner, enforced in code, not just by convention.

## Tick HAL and priority

SysTick belongs to FreeRTOS. The 1 ms HAL tick comes from TIM6 in
`stm32h7xx_hal_timebase_tim.c`, with `HAL_TIM_MODULE_ENABLED` active. Explicit
waits in the LCD/self-test code use `osDelay()`, which yields the CPU.

EXTI0, SPI2, DMA1 Stream 0, and DMA1 Stream 1 all sit at NVIC priority 5,
equal to `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY`. SPI callbacks now
call the FreeRTOS `...FromISR` API and request a context switch when the
unblocked task has sufficient priority. PendSV and SysTick sit at 15.

## Row transfer and pipeline

`SPI_Exchange_DMA()` and `SPI_Transmit_DMA()` keep the blocking contract, but
now sleep on the notification instead of spin-polling a `completed` flag.
For the `BE` stream, `SPI_Transmit_DMA_Begin()` copies the packet into the
private D2 SRAM buffer and starts the DMA; `SPI_Transmit_DMA_Wait()` waits
for the notification. The direct-to-task notification slot therefore belongs
to the SPI transport layer.

`LCD_WriteRectStream()` uses two `StreamPacket` buffers in DTCM. After
`Begin` on the current line, it builds the next line in the other buffer,
then runs `Wait` and reads the `BF` result. A retry preserves both the
current packet and the next one already built. The DMA never sees these
buffers directly: it only transmits the aligned copy held in the `.spi_dma`
section.

## Memory and DMA

The 32 KiB FreeRTOS heap, task stacks, and dynamic objects stay in DTCM. This
is intentional: the core accesses it directly, and DMA never needs to. DMA
buffers stay static in the `.spi_dma` section, 32-byte aligned and placed in
D2 RAM; the wrappers copy data in and out and handle cache maintenance.

Invariant: **never pass a task's local buffer to a HAL DMA, nor a pointer
from the FreeRTOS heap**. If the heap is ever moved to AXI RAM, data shared
with DMA will need cache-line alignment and `SCB_CleanDCache_by_Addr` /
`SCB_InvalidateDCache_by_Addr` calls in the right places.

## Stack measurement

Initial stacks are 128 words for `defaultTask` and 1024 words (4096 bytes)
for `DisplayTask`. These are allocation sizes, not final margins; at runtime
the following are updated:

- `g_display_stack_high_water_words` and `g_display_stack_high_water_bytes`;
- `g_default_stack_high_water_words` and `g_default_stack_high_water_bytes`.

`uxTaskGetStackHighWaterMark(NULL)` returns the minimum free space seen since
the task was created, expressed in `StackType_t` units, i.e. 4-byte words on
this Cortex-M7. `DisplayTask`'s measurement is taken after boot completes and
after each request. Read it via SWD after the worst-case load, then the
stack allocation can be reduced while keeping an explicit margin.
`configCHECK_FOR_STACK_OVERFLOW=2` and the malloc-failed hook halt the
firmware and set `g_freertos_failure` (4 for overflow, 3 for heap
exhaustion).

## Hardware qualification

Release hardware qualification passed on September 17, 2026 on STM32
prototype `35FF6C064D53373238602143`: 1200 transfers, 1,049,760 bytes
verified, zero mismatches, zero HAL/LCD errors, and 512 rectangles /
354,528 pixels in the graphics stress test. The double-buffer plus scroll
demo completed 50 `PRESENT` calls with 50 IRQ edges; full-screen COPY took
14 ms, a 442x176 SCROLL took 8 ms, and the `PRESENT` wait took 18 ms. Three
further consecutive resets repeated the same 50/50 result.

The minimum stack margin seen during the asynchronous qualification is
855 words (3420 bytes) for `DisplayTask` and 91 words (364 bytes) for
`defaultTask`. `g_freertos_failure` stayed at zero throughout. During
qualification a race surfaced in the confirmation path: polling could see
`FPGA_IRQ_N` low and send the ACK before the EXTI callback had counted the
edge. `LCD_Present()` now also requires `g_fpga_irq_count` to advance before
sending the ACK.

Final qualification of the asynchronous flush: 42,462 notifications for
42,462 waits, zero timeouts, and 238 lines built between `Begin` and `Wait`.
The eight-lines-per-strip benchmark measures 528 ms for `B7` and 172-174 ms
for `BE`/`BF`; the previous synchronous `BE`/`BF` implementation measured
225 ms. Stress, the 50 PRESENT/50 IRQ check, and repeated reset all remain
PASS.

The boot logo added later introduces an explicit FPGA gate: `BB` reports
busy, and no graphics command, including `BE`, is accepted until the last
logo burst has reached the PSRAM controller. The APIs and the DMA pipeline
are unchanged; the polling already used by `FPGA_ResetCycle()` absorbs the
short extra wait before `ACK_RESET`.
