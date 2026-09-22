# COPY, SCROLL, and the terminal demo

## Functions

The `BC` opcode copies rectangles between the two PSRAM framebuffers, or
performs a scroll with automatic fill. It requires double buffering enabled,
with **source equal to the front buffer and destination equal to the back
buffer**. Copying within the same buffer, or writing to the displayed
(front) buffer, is rejected.

- `COPY_RECT`: copies the source rectangle to the destination position.
- `SCROLL_RECT`: translates the content within a viewport and fills every
  pixel it exposes with the RGB565 color passed in the command.
- Content outside the destination rectangle is left unchanged.
- Off-screen coordinates, zero dimensions, and partially off-screen
  rectangles are rejected before any memory read or write. There is no
  implicit clipping.
- `dx > 0` moves right, `dy > 0` moves down; both can be negative. Zero
  translation copies the viewport as-is. If the shift moves the source
  entirely out of the viewport, the command fills it in full without
  reading the source.

PRESENT remains separate: after a SCROLL, the MCU can add the new line of
text to the back buffer, then present the result at the frame boundary.
COPY/SCROLL do not generate IRQs; completion is reported through BB. The
IRQ stays reserved for PRESENT.

## Contract and implementation

BC shares the control mailbox with BA. From commit to completion it blocks
acceptance of new BA/BC and B7/B8/B9 commands, waiting for producers already
accepted to finish, including the recovery interval after the last PSRAM
write.

`BlitRenderer.sv`, in the 81 MHz PSRAM domain, builds destination bursts
masked to 16 pixels. A one-burst source cache absorbs the different
alignments between source and destination positions; the cached data stays
in the controller's response register until the next read. Pixel selection
is staged across multiple cycles to bound the combinational path.

`FramebufferController.sv` also arbitrates the blitter's PSRAM reads. Data
and PSRAM response validity are captured together in one register before
arbitration. The blitter's read results go to its own read-back register
and **never enter the video FIFO**. The display keeps priority whenever the
FIFO is not almost full. At blanking, an in-progress blitter read finishes
before the video flush begins; a video read already in flight is instead
drained and discarded, as with the existing scan-out path.

The mailbox is freed only after the last write has completed, not when the
last burst was merely accepted. The source buffer stays stable, and no
other producer can write to it while a copy is in progress. A transport
error does not trigger automatic retries: read the status first and check
that the front/back roles have not changed.

## BC protocol, 24 bytes

| TX Index | Field |
|---:|---|
| 0 | `BC` |
| 1 | dummy `00`; RX `C3` available, `00` busy |
| 2 | operation: `00` COPY, `01` SCROLL |
| 3 | source buffer, 0 or 1 |
| 4 | destination buffer, 0 or 1, different from source |
| 5 | reserved, zero |
| 6-7 | x of the source rectangle / viewport |
| 8-9 | y of the source rectangle / viewport |
| 10-11 | width |
| 12-13 | height |
| 14-15 | COPY: x destination; SCROLL: dx, with sign |
| 16-17 | COPY: y destination; SCROLL: dy, with sign |
| 18-19 | SCROLL: RGB565 color; COPY: zero, reserved |
| 20-21 | CRC16-CCITT on bytes 2-19, initial `FFFF`, polynomial `1021` |
| 22 | commit `A6` |
| 23 | dummies; RX `AC` accepted, `E1` rejected |

16-bit fields: high byte first. `dx`/`dy` are signed 16-bit two's
complement, including -32768 and +32767. RX[0] is `A5`; RX[2..22] repeats
the previous TX byte. CS dropped before the commit cancels the packet; after
the commit it does not cancel the operation.

CRC, operation type, buffer identifiers, and reserved fields are checked
before the commit. `AC` means acceptance, not execution success: geometric
limits and the front/back role are verified by the execution logic. Wait
for `busy=0` on BB and check the result, `00` or `E1`.

The version returned by BB changes to **2**, leaving the 11-byte status
packet unchanged. Version 2 announces BC COPY/SCROLL; version 1 only
supports the earlier double-buffering-only protocol. The BB sequence field
still refers to the last PRESENT and is not incremented by COPY/SCROLL. The
result field concerns the last completed BA or BC check.

## STM32 API

```c
LCD_CopyRect(front, back, sx, sy, width, height, dest_x, dest_y);
LCD_ScrollRect(front, back, x, y, width, height, dx, dy, fill_rgb565);
```

Blocking API, single caller, returns 1 on success and 0 on error. The same
limits are also checked on the MCU side before any SPI traffic; the BB
version must support the blitter. Both calls wait for completion with a 1 s
timeout. As with the rest of the design, a transport error can leave a
partial update in the back buffer; the front buffer stays protected.

For an 11 line terminal with 8x16 font, viewport `(19,60,442,176)`:

```c
LcdBufferStatus status;
// Check the result of each call.
LCD_GetBufferStatus(&status);
LCD_ScrollRect(status.front, status.draw, 19, 60, 442, 176, 0, -16, 0x0000);
LCD_DrawTextFPGA(23, 220, 434, 16, LCD_FONT_8X16,
                LCD_TEXT_TRANSPARENT, 0xFFFF, 0, "Nuova riga");
LCD_Present(1000);
```

**Consistency of the rest of the screen:** initialize both buffers with the
same frame and background. In the demo, the window is drawn, presented, and
then a single full-screen COPY initializes the back buffer; every following
cycle only updates the viewport. If something changes outside the
viewport, the other buffer needs the same update, or those areas need
rebuilding, before the next swap.

## Demo and testing

`LCD_SCROLL_DEMO=1` enables `LCD_ScrollDemo_Run()`, which runs after the
earlier graphics sample. The demo initializes the window, copies the whole
screen once, then inserts 32 lines, each with a 16-pixel scroll and black
fill. The frame and the background outside the viewport stay unchanged. The
demo ends with the last 11 lines of the log still on screen.

SWD variables: `g_lcd_scroll_demo_state` (1 in progress, 2 completed, 3
failed), `g_lcd_copy_count`, `g_lcd_scroll_count`, `g_lcd_copy_ms`,
`g_lcd_scroll_ms`. The last two times include sending and polling for
completion, with 1 ms resolution; they are not measures of PSRAM latency
alone.

```powershell
.\sim\run_spi_sim.ps1 -TimeoutSeconds 180
.\sim\run_double_buffer_sim.ps1 -Blit
.\sim\run_double_buffer_sim.ps1 -Blit -RealFifo
.\sim\run_sim.ps1 -Mode current
.\build.ps1 -NoCompress
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -RequireScroll -SerialNumber 35FF6C064D53373238602143
# Read-only: first verify that the STM32 flash matches the ELF:
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -RequireScroll -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

The hardware runner requires both the `LCD_FPGA_TEXT_DEMO=1` and
`LCD_SCROLL_DEMO=1` flags: it waits for 50 PRESENT/IRQs in total (17 from
the earlier demo and 33 from the terminal), one COPY and 32 SCROLL, no
errors, and the IRQ released at the end. It saves
`build/Release/scroll-result.json`. Without `-RequireScroll` it
auto-detects `LCD_SCROLL_DEMO=1`; with the explicit flag it rejects a
configuration that has the demo disabled.

The unit test checks 99 cases against a per-pixel reference, covering both
slots, padding, extreme shifts, and delayed handshakes. The TOP-level
integration test also checks bad/malformed packets, the barrier during the
fill, blocking of concurrent commands, front/back isolation, separate video
reads, and presentation after copies and scrolls. PSRAM is a model: the
hardware testing and visual confirmation remain separate checks.

The video FIFO uses a registered `Full` flag, computed with an early
comparison against the pointer value the next edge will produce. The
`tb_framebuffer_fifo` test checks 10,000 words in order, full fill, overflow
attempts, emptying, multiple pointer wraparounds, and producer/consumer on
different clocks. The completion signal, the calibration flag, and the
PRESENT sequence comparisons are all captured in registers one cycle before
reaching the memory-control state machine, keeping the combinational paths
within the 81 MHz budget.

## Bench results — September 16, 2026

FPGA and fonts loaded in flash, STM32 Release firmware programmed and
verified. SWD test passes: 50 PRESENT/IRQ, one COPY, 32 SCROLL, no
SPI/LCD/HAL errors, final IRQ high. `g_lcd_scroll_demo_state=2`, front 0
and sequence 50.

| Operation | Observed MCU time |
|---|---:|
| COPY 480x272 | 14 ms |
| Last SCROLL 442x176, dx=0, dy=-16 | 8 ms |
| Last PRESENT | 16 ms |
| Clear complete B9 | 8 ms |

Times include sending and waiting, 1 ms resolution; they are not upper
bounds. The demo performs a single full COPY at the start, then only
updates the viewport on every following cycle.

FPGA build `-NoCompress`, PlaceOption 1: zero timing violations, Fmax PSRAM
81.909 MHz against the operational 81 MHz; 5209 logic resources, 3659
registers, and 3 BSRAM. No loose SDC constraints. The controller uses
one-hot state encoding and registers the synchronized frame-boundary signal
for one additional PSRAM cycle (about 12 ns), always within the vertical
blanking interval.

Machine-readable result: `stm32/WeAct_H743_SPI/build/Release/scroll-result.json`.

Final verification of the version loaded with `-Blit -RealFifo`: PASS, 12 cases,
four swaps and eight full frames (1,044,480 pixels). The user observed it
scrolling and stopping after 32 lines, as expected from the demo.
