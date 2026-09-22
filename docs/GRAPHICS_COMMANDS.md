# Graphics commands supported

Single reference of everything that can be drawn, verified on September 22nd
2026 against `src/SpiFramebuffer.sv`, `src/TextRenderer.sv`, `src/BlitRenderer.sv`
and the implementations in `stm32/WeAct_H743_SPI/Core/Src/`. For the byte-level
layout of `B7`/`BD`/`BE`/`BF` see [SPI_FRAMEBUFFER.md](SPI_FRAMEBUFFER.md) and
[SPI_STREAM.md](SPI_STREAM.md), for `B8` see [SPI_TEXT.md](SPI_TEXT.md), for
`BC` see [BLITTER.md](BLITTER.md), and for `BA`/`BB` see
[DOUBLE_BUFFER.md](DOUBLE_BUFFER.md). `B9` is described here in full, since it
has no other home. What follows is the complete list, its limitations, and
what **doesn't** exist.

The picture can be read on two levels: the FPGA exposes **eight SPI opcodes**
across drawing, streaming, buffering and status; the STM32 API prepares
packets and handles waits, responses, and errors.

## FPGA layer: SPI opcodes

| Opcode | What it does |
|---|---|
| `B7` | writes a masked burst of 16 RGB565 pixels to PSRAM |
| `BD` / `BE` | writes an entire line in one streaming transaction; `BD` is full-duplex, `BE` is TX-only; [protocol](SPI_STREAM.md) |
| `B8` | draws a UTF-8 string with User Flash fonts |
| `B9` | fills a rectangle or draws a line in RGB565, without transferring individual pixels |
| `BC` | COPY/SCROLL front → back, with RGB565 fill on exposed pixels; [protocol](BLITTER.md) |
| `BA` | enable double buffering, request PRESENT, confirm IRQ (`ACK_PRESENT`), or confirm reset (`ACK_RESET`) |
| `BB` | reads capacity and buffer state, CRC-checked |
| `BF` | reads the result of the last `BE` row, CRC-checked; [protocol](SPI_STREAM.md) |
| other | diagnostic echo path: responds `A5`, then echoes the previous byte |

Double buffering and the `BA`/`BB` protocol are described in
[DOUBLE_BUFFER.md](DOUBLE_BUFFER.md). The APIs are `LCD_EnableDoubleBuffer`,
`LCD_GetBufferStatus` and `LCD_Present(timeout_ms)`. After enabling, `B7`/`BD`/
`BE`/`B8`/`B9` draw into the back buffer; `PRESENT` waits for pending writes,
swaps at the frame boundary, and confirms the IRQ over SPI.

`B9` also draws one-pixel-thick horizontal or vertical lines through
rectangles of height or width 1, and clears the whole screen by filling it
with a color. There is no FPGA command for circles, pixel readback, or
changing the initial background color at runtime.

The color the FPGA initializes the framebuffer with is
`FramebufferController.BACKGROUND_COLOR`, a **synthesis parameter**: changing
it recompiles the bitstream, no command sets it at runtime. The visible
background can still be changed at runtime with `LCD_Clear`.

### Status bytes

Shared by every opcode except `BF`, and must be read in the order in which
they arrive.

| Byte | Meaning |
|---|---|
| `A5` | first response byte, always present: the slave is alive |
| `C3` | acceptable command, there is room in the queue |
| `00` | busy: queue full for `B7`/`BD`/`BE`, shared queue/renderer busy for `B8`/`B9`; retry |
| `AC` | packet accepted and executed |
| `E1` | packet rejected: parameters out of range or bad CRC |
| `E2` | only for `B8`: invalid fonts in User Flash, command not available |

`E2` may be transient during initial font verification; it persists when the
User Flash has been erased or is malformed. The API waits up to one second —
the availability timeout of `B8` — and even a persistent busy or `E2`
produces phase 9–11 in `g_lcd_error`, explained below in
[Diagnostics](#diagnostics-reading-the-error). `B9` does not use fonts and
stays available even with invalid User Flash. See
[PROGRAMMING.md](PROGRAMMING.md).

### `B7`, write framebuffer

A burst covers 16 pixels starting from a linear address **multiple of 16**
and less than 130,560 (480×272). A 16-bit mask selects which of the 16
pixels are actually written, which is what allows non-16-aligned rectangles:
the edge bursts use partial masks. The commit happens on receipt of the `5A`
byte.

There is no CRC before commit and no rollback: a transmission error can only
be caught by the echo *after* the write has already been accepted.

### `BD` / `BE`, stream write one line

This is the preferred pixel path. A single transaction carries a header, a
contiguous payload, a CRC over the payload, and a commit: 976 bytes in one
DMA for a full line, against the thirty 41-byte `B7` packets that used to be
needed. `x` and `count` are expressed in pixels, not in groups of 16, so the
payload carries no padding and matches the pixel map a client already
provides.

`BD` keeps full-duplex inline responses for compatibility and diagnostics.
`BE` transmits the same bytes without sampling MISO and reports the result
later through `BF`, which reduces receive work and pixel-path overhead. This
variant targets a higher frame rate when the display is driven by LVGL
through a `flush` callback: `GuiTask` and `DisplayTask` already use it to
send RGB565 rectangles to the FPGA framebuffer.

Like `B7`, this write is not atomic: groups are written as they arrive, the
final CRC reports without cancelling, and recovery means resending the line.
Full format, overflow semantics and API in [SPI_STREAM.md](SPI_STREAM.md).

### `B8`, text

A single packet closed by a CRC16-CCITT (init `FFFF`, polynomial `1021`) and
an `A6` commit byte. The CRC is checked **before** drawing, so a transmission
error here causes the command to be rejected instead of corrupting the
screen — unlike `B7`.

| Parameter | Values |
|---|---|
| font_id | 0 = 8x16, 1 = 12x24, 2 = 16x32 |
| flags | bit 0 transparent background, bit 1 word wrapping |
| box | clipping frame; 0 in width or height extends to the edge of the screen |
| string | UTF-8, at most 64 encoded bytes |

The glyph subset is printable ASCII, Latin-1, the euro sign, and the four
arrows; an absent codepoint becomes `?`. Cells are monospaced. Clipping to
the box and to the screen is always active. A new line starts on the newline
character, and also automatically when the wrap flag is set; without wrap,
the part of the string to the right of the box is discarded.

### `B9`, rectangles and lines

An 18-byte packet, regardless of area, describes the shape. The FPGA
generates the masked bursts in PSRAM. It shares the queue and renderer with
`B8`: text and fills execute one at a time.

The gain here is protocol arithmetic, not an estimate: `B7` carries 16
pixels per 41-byte packet, so clearing the screen means 8160 packets and
about 334 kB on the wire; `B9` does the same thing with **one 18-byte
packet**. This keeps the interface usable from a small MCU that neither
generates nor transfers pixels.

Measured on the bench with `g_lcd_clear_ms16`: **128 ms for sixteen
full-screen clears, i.e. 8 ms each**. The bottleneck is no longer the SPI but
the renderer, which builds the bursts serially: 8160 bursts of 16 pixels at
27 MHz, plus the handshake into the PSRAM domain. That is roughly 37 times
less than the ~300 ms the same operation costs pixel by pixel through `B7`.

| Offset | MOSI field |
|---:|---|
| 0 | opcode `B9` |
| 1 | dummy/status, sent as zero by the API |
| 2 | shape type: `00` = rectangle, `01` = line |
| 3 | reserved flags: `00` |
| 4..5 | x of the rectangle / x0 of the line, big endian |
| 6..7 | y of the rectangle / y0 of the line, big endian |
| 8..9 | width of the rectangle / x1 of the line, big endian |
| 10..11 | height of the rectangle / y1 of the line, big endian |
| 12..13 | RGB565 color, big endian |
| 14..15 | CRC16-CCITT on bytes 2..13, init `FFFF`, polynomial `1021`, big endian |
| 16 | commit `A6` |
| 17 | dummy, reads the outcome |

Keep CS low for the whole packet. MISO returns `A5` at offset 0, `C3` or `00`
at offset 1, the echo of the previous MOSI byte through offsets 2..16, and
finally `AC` or `E1` at offset 17. A separate two-byte poll `B9 00` reads
availability without drawing. After `AC`, poll until `C3` returns, as
`LCD_FillRect` does; this is not the same as waiting for vblank.

For the rectangle, on the wire x must be 0..479 and y 0..271; width 0..1023,
height 0..511. The renderer clips to the edge of the screen; a zero
dimension extends to the corresponding edge. **The C API is more
restrictive**: it requires non-null dimensions and a rectangle entirely on
screen.

For the line, both endpoints must fit on screen: x0/x1 0..479, y0/y1 0..271.
Endpoints included, one pixel thick, any direction, no clipping or
anti-aliasing. Coincident endpoints draw a single point. The FPGA uses
integer Bresenham: `dx=abs(x1-x0)`, `dy=-abs(y1-y0)`, `err=dx+dy`; each step
uses the same `e2=2*err`, advancing X if `e2>=dy` and Y if `e2<=dx`. On exact
ties, swapping the endpoints can select a different pixel. Consecutive
pixels that land in the same aligned burst on the same line are merged into
a single mask.

Older bitstreams that only support type 0 reject type 1 with `E1`: update
the FPGA before using `LCD_DrawLine` for diagonal lines. The protocol does
not yet expose capability negotiation.

Invalid type, flags, coordinates or CRC reject the command before drawing.
After the commit is accepted, raising CS does not cancel the operation. CRC
checking does not make the update visually atomic: the FPGA writes
progressively to the selected target. With double buffering enabled, the
changes become visible together after `PRESENT`.

## STM32 level: the C API and use from C++

Declared in `Core/Inc/lcd_spi.h`. All calls block, none re-enter, and each
has a single caller. They return 1 on success, 0 on error.

| Function | What it does | How |
|---|---|---|
| `LCD_WriteRect(x,y,w,h,pixels)` | arbitrary RGB565 pixel rectangle | `B7` bursts |
| `LCD_WriteRectStream(x,y,w,h,pixels)` | same contract, one row per SPI transaction | `BE` write, `BF` result |
| `LCD_FillRect(x,y,w,h,color)` | uniform fill | one `B9` command plus polling |
| `LCD_Clear(color)` | fills the entire display | `LCD_FillRect(0,0,480,272,color)` |
| `LCD_DrawHLine(x,y,length,color)` | horizontal line, 1 pixel thick | `LCD_FillRect(x,y,length,1,color)` |
| `LCD_DrawVLine(x,y,length,color)` | vertical line, 1 pixel thick | `LCD_FillRect(x,y,1,length,color)` |
| `LCD_DrawLine(x0,y0,x1,y1,color)` | line with inclusive endpoints, any direction | H/V delegates to `LCD_DrawHLine`/`LCD_DrawVLine`; diagonal uses `B9` type 1 |
| `LCD_DrawTextFPGA(...)` | text rendered **by the FPGA** | `B8` command |
| `LCD_CopyRect(source,dest,x,y,w,h,dest_x,dest_y)` | copies a rectangle between the two PSRAM buffers | `BC` COPY; see [BLITTER.md](BLITTER.md) |
| `LCD_ScrollRect(source,dest,x,y,w,h,dx,dy,fill)` | translates a viewport, fills exposed pixels | `BC` SCROLL; see [BLITTER.md](BLITTER.md) |

`LCD_FillRect` builds two 18-byte local buffers (TX/RX), without touching
line pixels or the full framebuffer. It waits for `B9` availability before
sending and after acceptance. `LCD_WriteRect` sends arbitrary pixels through
`B7`; `pixels` holds `w*h` contiguous RGB565 values, row by row.
`LCD_WriteRectStream` follows the same contract through `BE`/`BF` instead,
overlapping the assembly of the next row with the DMA transfer of the
current one. Both `LCD_WriteRect` and `LCD_FillRect` reject empty or
off-screen rectangles **without clipping**. An error detected after a commit
does not undo writes already accepted: a return of 0 does not guarantee the
screen is unchanged.

`LCD_DrawTextFPGA` clips, because the box is part of the protocol. The API
accepts x < 480, y < 272, box_width <= 480, box_height <= 272, font_id 0..2,
only the two defined flag bits, and a non-null UTF-8 C string of at most 64
bytes excluding the terminator. It waits for the renderer after sending.

The lines extend right/down: the last pixel is respectively `x+length-1` or
`y+length-1`. Zero length, and lines even only partially off-screen, return
0 without sending any command; length 1 draws a single pixel. For a thicker
line use `LCD_FillRect` directly.

`LCD_CopyRect` and `LCD_ScrollRect` require double buffering enabled, source
equal to the current front buffer and destination equal to the current back
buffer; both reject out-of-screen or zero-size rectangles before sending
anything. See [BLITTER.md](BLITTER.md) for the COPY/SCROLL contract,
including how `LCD_ScrollDemo_Run` uses them together with `PRESENT`.

```c
LCD_DrawHLine(0, 0, 480, 0xFFFF);   // whole first row, white
LCD_DrawVLine(479, 0, 272, 0xF800); // whole last column, red
// Check the return value: 1 success, 0 error.
```

Complete signatures are in
[`lcd_spi.h`](../stm32/WeAct_H743_SPI/Core/Inc/lcd_spi.h).
There is no separate C++ wrapper; the current graphics headers do not
include `extern "C"` guards. To call implementations compiled as C from a
C++ file, include them like this:

```cpp
extern "C" {
#include "lcd_spi.h"
#include "lcd_text.h" // only if the CPU-rendered path is also used
}
```

### CPU-rendered text: still there, but outdated

`Core/Inc/lcd_text.h` exposes `LCD_DrawCodepoint` and `LCD_DrawText`, which
draw from a fixed 12x24 glyph table resident in **STM32** flash and send
pixels as `B7` rectangles. It is the prototype that preceded the FPGA
renderer: fixed 12x24 cell only, background always opaque, no clipping or
automatic wrap. `LCD_DrawText` handles `\n` and ignores `\r`; it validates
the box before sending pixels. Use `LCD_DrawTextFPGA` instead; this path
stays because it is a useful point of comparison and does not depend on User
Flash.

## Testing programs

They are not graphics primitives, but they draw, so it is worth knowing they
exist. Each is gated by a flag in `Core/Inc/spi_diag_config.h`.

| Symbol | Flag | What it draws |
|---|---|---|
| `LCD_TextDemo_Run` | `LCD_TEXT_DEMO` | text with CPU-rendered fonts |
| `LCD_FPGATextDemo_Run` | `LCD_FPGA_TEXT_DEMO` | double-buffered frames, then clear, fills, H/V lines, an eight-ray `B9` star, and FPGA text |
| `LCD_StreamBench_Run` | `LCD_STREAM_BENCH` | full screen twice, once via `B7` and once via `BE`, for comparison |
| `LCD_ScrollDemo_Run` | `LCD_SCROLL_DEMO` | terminal-style demo: `COPY` for the static frame, 32 rounds of `SCROLL` plus text for the moving log |
| `LCD_Demo_Run` | `LCD_BOOT_TESTS` | rectangle 67x40 at (101,81), edges not 16-aligned |
| `LCD_Stress_Run` | `LCD_BOOT_TESTS` | repeated rectangles for extended qualification |

Each publishes its state in a global variable read via SWD by the test
runner: 0 not requested, 1 running, 2 complete, 3 failed. The FPGA text demo
also exposes `g_lcd_clear_ms16`: total milliseconds for 16 full-screen
clears, measured after the graphics/text sample. The stream benchmark
exposes `g_lcd_bench_b7_ms`/`g_lcd_bench_bd_ms` and the matching
`LcdProfile` structs; the scroll demo checks its own IRQ count against the
33 `PRESENT` calls it issues.

## Diagnostics: reading the error

When a primitive returns 0, the failure is recorded in `g_lcd_error`, a
`uint32_t[6]` read via SWD by the test runner:

| Index | Contents |
|---:|---|
| 0 | phase; **0 means no error** |
| 1 | address |
| 2 | index of the byte in the packet |
| 3 | expected value |
| 4 | value received |
| 5 | HAL error code |

**Only the first fault is recorded**: later calls do not overwrite it, so
the phase points to where things first went wrong, not where they last did.

| Phase | Where | Meaning |
|---:|---|---|
| 1 | any exchange | SPI HAL transfer failed |
| 2–4 | waiting on `B7` | first byte not `A5`; state not `C3`/`00`; timeout (4 is reused for the busy retry inside a `B7` send) |
| 5, 6 | `LCD_WriteRect` send | first byte not `A5`; second byte not `C3`/`00` |
| 7, 8 | `LCD_WriteRect` send | commit outcome not `AC`; echo mismatch |
| 9–11 | waiting on `B8` | first byte not `A5`; state not `C3`/`00`/`E2`; timeout |
| 12–15 | `LCD_DrawTextFPGA` | first byte not `A5`; second byte not `C3`; echo mismatch; commit not `AC` |
| 16–18 | waiting on `B9` | first byte not `A5`; state not `C3`/`00`; timeout |
| 19–22 | `B9` send | first byte not `A5`; second byte not `C3`; echo mismatch; outcome `E1` — **the FPGA rejected the shape** |
| 23–25 | `BB` | wrong signature/version/buffer count; CRC mismatch; reserved bits set |
| 26 | any command | timeout waiting for the buffer to go idle |
| 27–29 | `BA` send | first/second byte wrong; echo mismatch; commit not `AC` |
| 30, 31 | `ACK_PRESENT` | result or IRQ still set after the ack; IRQ line still low afterwards |
| 32 | `LCD_EnableDoubleBuffer` | rejected, not enabled, or buffer selection unchanged |
| 33, 34, 36 | `LCD_Present` | not enabled or IRQ already pending; completion status mismatch; timeout |
| 37 | `LCD_FPGATextDemo_Run` | EXTI edge count different from the 16 presentations |
| 38–43 | `BC` (`LCD_CopyRect`/`LCD_ScrollRect`) | bitstream too old for blit (version < 2); source/destination role mismatch; first/second byte wrong; echo mismatch; commit not `AC`; result nonzero after completion |
| 44 | `LCD_ScrollDemo_Run` | EXTI edge count different from the 33 presentations |
| 49 | `LCD_WriteRectStream` | retry timeout after 1 s |
| 50 | `BE` transfer | DMA begin or wait failed |
| 51–57 | `BF` (`fast_stream_status`) | prescaler change/restore failed; exchange failed; signature/version wrong; CRC mismatch; reported `y` mismatch; ready bit timeout; unexpected result byte |
| 58 | `ACK_RESET` | result or `reset_seen` still set after the ack |
| 59, 60 | FPGA reset pulse | no SPI response after the pulse; **`reset_seen` still off after the pulse: reset did not arrive** |

The most informative phase is **22**. It means the packet arrived intact but
the renderer did not accept it, and the causes are few: wrong CRC16,
out-of-range coordinates on the wire, non-zero reserved flags, or a type-`01`
shape sent to **an older bitstream that only knows rectangles**. That last
case is the most misleading, because the firmware looks correct: if
`LCD_DrawLine` only fails on diagonals while horizontals and verticals work,
it is the FPGA that needs reprogramming, not the code.

Phase **11** has the same significance for text: it is the signature of a
User Flash image that is erased or malformed. See
[PROGRAMMING.md](PROGRAMMING.md).

### When firmware and bitstream are not the same version

It is worth recognizing the symptom, because it once cost a wrong diagnosis.
The demo always stopped at the same point — the first five texts drawn, then
nothing from the sixth onward — with phase 9, i.e. the first byte reading
`00` instead of `A5`. That byte is a constant preloaded into the shift
register: reading it as zero means the SPI slave was not driving the line, a
state it should never be in.

The cause was not electrical: there was a stale bitstream on the board from
before the last RTL change, so firmware and logic were speaking different
contracts. Rebuilding and reprogramming fixed it without touching anything
else.

The quick way to rule this out is to compare dates: if `impl/pnr/LCD.fs` is
older than a file under `src/`, the board is not running what you are
reading in the sources. A fault that is **deterministic and always on the
same command** points to a mismatch like this; faulty wiring instead
produces errors that are scattered and irreproducible.

## What's missing, in short

COPY and SCROLL between front/back are described in
[BLITTER.md](BLITTER.md). There is still no dedicated command for circles or
polygons, no pixel readback, no triple buffering, no way to change the
initial background parameter at runtime, and no proportional fonts, glyph
rotation, or scaling. Direct drawing into the buffer visible on reset
remains subject to tearing; enable double buffering and use `PRESENT` for
frame-boundary updates.
