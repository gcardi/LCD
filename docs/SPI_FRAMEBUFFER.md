# Write framebuffer via SPI

> Update: the current pixel path uses the write-only stream `BE` at
> 18.75 MHz and reads status separately at 1.171875 MHz. See
> [SPI_STREAM.md](SPI_STREAM.md). The 12.5 MHz testing and the 25 MHz
> results below are history from the previous `B7` protocol.

First implementation: `SpiFramebuffer.sv` transfers masked bursts to
PSRAM through a one-element asynchronous queue. `LCD_WriteRect` composes
them to update arbitrary RGB565 rectangles within 480x272.

## Boot and primitives available

The FPGA initializes every pixel to black (RGB565 0000), even after
reset. `FramebufferController.BACKGROUND_COLOR` is a synthesis parameter:
FFFF for white, F800 for red, 07E0 for green, 001F for blue. The selected
pattern is PATTERN_SOLID; earlier patterns remain in the source as
diagnostic tools. The initial color cannot currently be edited through an
SPI command.

The STM32 build uses `LCD_BOOT_TESTS=0`: the demo and the graphics stress
test do not run. The current font check uses `LCD_FPGA_TEXT_DEMO=1` with
`LCD_TEXT_DEMO=0`, and it touches the framebuffer only after the startup
DMA echo self-test has finished. To run the boot tests, set
`LCD_BOOT_TESTS=1` in `spi_diag_config.h` and recompile/reflash; set it
back to 0 for a clean startup. The test runner rejects
`-RequireGraphics`/`-RequireStress` if graphics tests are disabled in the
local configuration.

The complete, up-to-date list of everything that can be drawn, the SPI
opcodes, and the STM32 API is in
**[GRAPHICS_COMMANDS.md](GRAPHICS_COMMANDS.md)**: the table that used to
live here has moved there, so there is only one list to keep in sync.
This document remains the byte-by-byte protocol reference for `B7`, plus
the bench-test log.

The write command uses a linear address aligned to 16 pixels; the STM32
function handles coordinates, rows, and rectangle edges. This addressing
describes `B7` only. The protocol also includes `B8` (FPGA text from User
Flash) and `B9` (hardware fill). `LCD_FillRect` and `LCD_Clear` send an
18-byte `B9` packet plus polling, without touching buffer pixels;
`LCD_DrawHLine` and `LCD_DrawVLine` use the same command with thickness 1.
The APIs are synchronous, returning 1 on success and 0 on error.
`LCD_DrawLine` adds diagonal lines: `B9` type 1 carries two inclusive
endpoints and is drawn with Bresenham in the FPGA; it requires an updated
bitstream. `FillRect` and the line functions reject zero dimensions or
off-screen areas without clipping. `B8`/`B9` check the CRC before commit;
`B7` has no CRC. An error detected after a commit does not undo the
drawing already issued. Copy and pixel readback are not implemented.

```c
if (!LCD_Clear(0x0000)) { /* error: clear to black */ }
if (!LCD_FillRect(20, 30, 100, 60, 0xF800)) { /* error: red rectangle */ }
```

With `LCD_FPGA_TEXT_DEMO=1`, the current test calls clear, fill, and FPGA
text in sequence. To avoid drawing anything at startup, keep
`LCD_TEXT_DEMO`, `LCD_FPGA_TEXT_DEMO`, and `LCD_BOOT_TESTS` all disabled.
`LCD_Demo_Run` and `LCD_Stress_Run` remain separate test programs.

History note: the following paragraph describes the CPU-side text
prototype, written before rendering moved to the FPGA. It remains valid
for `lcd_text.h`, but the way to draw text today is `LCD_DrawTextFPGA`
with the `B8` opcode.

The text prototype uses a 12x24 table in STM32 internal flash: 196
glyphs, a 9408-byte bitmap, covering printable ASCII, Latin-1, the euro
sign, and the arrows. `LCD_DrawText` decodes UTF-8, uses opaque monospaced
cells, and substitutes missing glyphs with `?`. It handles `\n`, ignores
`\r`, performs no automatic wrapping or clipping, and checks the whole
footprint before drawing. The table can be regenerated from the BDF
sources and license stored in `third_party/terminus-font-4.49.1-master`;
it does not yet use the FPGA's User Flash.

## Protocol

SPI mode 0, MSB first, 12.5 MHz, STM32 GPIO MEDIUM. One packet per CS
pulse. The two initial CS-high pulses remain necessary, as in the earlier
test.

| Byte Offset | MOSI | MISO |
|---|---|---|
| 0 | B7 | A5 |
| 1 | 00 | C3 if the queue is free, 00 if busy |
| 2..4 | pixel address, 24-bit big endian | echo of the previous byte |
| 5..6 | 16-bit mask, big endian | echo |
| 7..38 | 16 RGB565 pixels, low byte before high byte | echo |
| 39 | 5A, commit | echo |
| 40 | 00 | AC accepted, E1 rejected |

Address must be a multiple of 16 and less than 130560. Bit i of the mask
enables pixel i. Pixel 0 sits in the lower half of the first PSRAM word.
Availability can be queried by sending just `B7 00` and then raising CS;
if busy, retry in a new transaction. Availability is sampled at the end
of the opcode byte.

The commit happens on full reception of byte 39 (5A), before CS rises. An
earlier abort produces no writes; an abort after the commit does not undo
them. Bytes after offset 40 are ignored by the `B7` parser. Opcodes other
than `B7`, `B8`, and `B9` keep the diagnostic echo behavior (respond A5,
then echo the previous byte). Do not send arbitrary data starting with
one of these three opcodes as an echo test while the graphics endpoint is
active.

## Arbitration and CDC

The published payload stays stable until the controller confirms it.
Request and acknowledge use two-stage synchronized toggles; the payload
crosses as a bus held stable throughout. CS only clears the parser, not
the queue. Both domains must share the same global reset assertion; do
not reset them separately.

The controller finishes the pattern initialization, then prioritizes
video reads. It accepts a write only when the video FIFO is almost full,
using a separate state for the command. It copies the burst into local
registers before releasing the queue's tail. The mask enables both bytes
of each selected pixel. A frame restart that occurs during a write is
latched and applied only after the burst and the PSRAM recovery time
complete; a write is never stopped halfway.

## Firmware and testing

`Core/Inc/lcd_spi.h` exposes `LCD_WriteRect(x,y,w,h,pixels)`. The buffer
holds `w*h` uint16_t values in row order. It returns 1 on successful
submission, 0 for bad parameters, timeout, or an unexpected response. The
transport uses DMA with a synchronous wait and 1 us CS guard intervals.
The earlier DMA self-test still runs before the demo.

The demo draws a 67x40 rectangle at (101,81): white border, red interior,
and additional green and blue regions. Misaligned edges exercise the
masks. `g_lcd_demo_state`: 0 not requested, 1 in progress, 2 sent, 3
error. State 2 confirms transport, echo, and acceptance; it is not a
read-back of the pixels from PSRAM and does not by itself confirm the
image on the panel.

```powershell
./stm32/WeAct_H743_SPI/test-hardware.ps1 -RequireGraphics -SerialNumber 35FF6C064D53373238602143
```

First enable `LCD_BOOT_TESTS=1` and `SPI_GPIO_PROBE=1`; the runner checks
both. To use the Release ELF, add `-Preset Release`. Restore the startup
flags after testing and recompile/reflash.

Requires `localparam SPI_FRAMEBUFFER = 1` in TOP and `SPI_DIAG_MATRIX 0`.
The runner also saves `graphics_state` in the JSON result and fails if it
differs from 2. `diagnose-hardware.ps1` instead selects
`SPI_FRAMEBUFFER=0`; its `-RestoreSelfTest` also restores pure echo at
12.5 MHz (prescaler 16, SDC 80 ns). To return to graphics, set the
parameter back to 1 and repeat the command above.

## Checks and limits

`sim/run_spi_sim.ps1` includes an integrated SPI/controller bank with a
memory model that captures bursts and masks. It covers payload and beat
order, unselected pixels, a busy queue, invalid addresses, byte/packet
abort, queue reuse, and a frame restart during a write.

For `B7` there is no CRC before commit, and there is no rollback,
readback, or double framebuffer. A transmission error can only be
signaled by the echo after a write has already been accepted. A
rectangle may appear progressively (tearing). This is the functional
basis for LVGL, not yet its integration, nor a measurement of maximum
graphics throughput.

## Result on the bench, 9 September 2026

FPGA loaded to SRAM and STM32 firmware programmed with flash
verification. SPI test: 40 transfers, 34992 bytes, zero mismatches, zero
HAL errors, three correct GPIO probes. Demo: graphics_state=2. The user
visually confirmed the rectangle on the panel, then reset the FPGA to
check that it disappeared. Resetting the FPGA reinitializes the pattern;
to redraw, reset the STM32.

Final timing: four PSRAM calibration endpoints allowed, worst case
-1.303 ns, no hold/recovery/removal violations. Bitstream SHA256:
`971555FD7E3BCB5AB009EBD3FF3CB9C6054ADE0E4A5C7AF1E549584AB7014ACF`.
ELF SHA256: `A9D1BE892C4693BC320C268F41D57DF9CDC6BF2E925D53C5031CCBA951C5FA96`.
SWD results in `stm32/WeAct_H743_SPI/build/Debug/hardware-result.json`;
the read was performed immediately after flash loading and verification.

Completed simulations: SPI suite with the framebuffer bank PASS; video
regression with a real FIFO PASS (341.2 s, before the command/state
separation), and video model regression on the final RTL PASS (83.4 s).
Both recover starting from the frame after the underrun, with zero
damaged frames over the following four. The SPI/controller bank was
rerun after the final arbitration change.

## 25 MHz attempt, September 9, 2026

Tested STM32 prescaler 8 with a 40 ns SCK constraint (20 ns half-cycle),
keeping GPIO MEDIUM and a 10 ns I/O budget. The FPGA build finishes, but
gate-level timing rejects the path
`graphics.spi_framebuffer/slave/tx_started_s0/Q` ->
`SPI_MISO_s3/O`: slack -3.782 ns. The path runs from the falling edge to
the next rising edge, with 5.289 ns skew and 8.493 ns data delay. The
most critical MOSI route has only +0.043 ns margin. The four PSRAM
calibration violations stay within baseline, worst -1.303 ns.

No bitstream was loaded at 25 MHz, and no hardware testing was done at
this frequency. STM32, CubeMX sources, and the SDC constraint were
restored to 12.5 MHz. Proceeding requires optimizing the MISO path and
rechecking the MOSI margin; reducing the prescaler alone is not enough.
The attempt report is archived at
`stm32/WeAct_H743_SPI/build/Debug/trial-25mhz/timing-25mhz.tr`.

## MISO optimization and first PASS at 25 MHz

On September 9, SpiSlave gained the `FIXED_FIRST_BYTE` option.
SpiFramebuffer enables it with `FIRST_BYTE=A5`: the TX register
initializes with the first MSB already loaded, so the pin is driven
directly from `tx_shift[7]`. In short, this eliminates the `tx_started`
selector and the mux on the data; tri-state control still belongs to CS.
The generic contract remains the default for SpiDiagnostic and for
variable-first-byte FIFO sources.

SDC 40 ns, I/O budget still 10 ns, prescaler 8, GPIO MEDIUM, wiring
unchanged. SPI suite PASS, including the framebuffer bank bumped to
25 MHz. Gate timing PASS: six PSRAM calibration endpoints allowed, worst
-1.308 ns; no hold/recovery/removal violations and no new exceptions. The
minimum margin in the PSRAM domain is narrow (+0.017 ns); recheck the
gate-level timing on every subsequent build.

FPGA programmed to SRAM and STM32 flash verified. Normal test:
25,000,000 Hz actual, 40 transfers, 34992 bytes, zero mismatches, HAL OK,
three correct GPIO probes, graphics_state=2. This is a first test at
25 MHz, not the million-byte-plus long test previously run at 12.5 MHz.
Visual confirmation of the new 25 MHz run is still pending.

Bitstream SHA256: `1FA0EDDC47B68BAD53D4295CA0AA5BE1BEBD319E0382890CA04466BDA35E1A87`.
ELF SHA256: `312C94BF2E8296B4B8D5239D23E1606199BC5464BB53340E5B6C2F4077CA06C7`.
Configuration left at 25 MHz for graphics. RestoreSelfTest instead
returns to the qualified diagnostic configuration at 12.5 MHz; to
reactivate 25 MHz, realign `SPI_FRAMEBUFFER=1`, prescaler 8 in both C and
CubeMX, and SDC 40 ns.
