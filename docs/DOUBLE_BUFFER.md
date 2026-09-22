# Double buffering, PRESENT and IRQ

Double buffering shipped September 15, 2026; the `BC` COPY/SCROLL blitter
extension described in [BLITTER.md](BLITTER.md) shipped the next day. Triple
buffering remains future work.

## Memory and drawing

The controller uses two disjoint PSRAM slots, addressed in RGB565 pixels:

| Buffer | Base in pixels | Base in bytes | Image size |
|---|---:|---:|---:|
| 0 | `000000` | `000000` | 480 x 272, 261120 bytes |
| 1 | `020000` | `040000` | 480 x 272, 261120 bytes |

The bases are hexadecimal. Each slot reserves 256 KiB: 512 KiB in total,
with 1024 bytes of padding per slot. The power-of-two step avoids an adder
in the critical address path. The onboard W955D8MBYA PSRAM IP exposes 21-bit
pixel addresses; the two slots only use the first 18 bits (1 bit selects the
slot, 17 bits address within it). They are not exposed to the master as
arbitrary physical addresses.

On reset, the front and drawing buffers are set to 0, double buffering is
disabled, the sequence is set to 0, the IRQ line is left high (inactive),
and `reset_seen` is set. This applies to any reset: power-on, button, or the
`FPGA_RST_N` pulse commanded by the MCU (see *Reset commanded by the MCU*
below). Buffer 0's initial fill with `BACKGROUND_COLOR` (black by default,
see [GRAPHICS_COMMANDS.md](GRAPHICS_COMMANDS.md)) and B7/B8/B9 compatibility
remain active regardless of double-buffering state. `ENABLE_DOUBLE` waits
for the producers already in flight and then selects the buffer opposite the
front as the drawing target. **The back buffer is not initialized or
copied:** the caller must clear it or completely rebuild it before the first
PRESENT. Even after a swap, the new back buffer still holds the previous
front's old image; partial updates need explicit handling of that leftover
content.

B7 pixels, B8 text and B9 shapes all target the back buffer once double
buffering is enabled. The drawing target cannot change mid-command: ENABLE
and PRESENT both wait for the write queues to drain and for the last PSRAM
write, including its recovery interval, before being accepted.

## PRESENT and frame boundary

An accepted PRESENT is armed once the write barrier has drained. The swap
itself happens at the next `FrameRestart`, at the start of vertical blanking
(row 277, column 0 of the current raster). This is the same frame
synchronization the display already uses; **it does not coincide exactly with
the rising edge of the LCD_SYNC pin**, which occurs one line later in the
same raster.

The swap changes the read base, not the pixels already in memory. The FIFO
is held in flush for 63 PSRAM cycles, long enough to drain any reads still
in flight; the video path is then preloaded from the new base during
blanking. Only once the flush ends does the controller complete the
command, update the sequence, and drive `FPGA_IRQ_N` low. The IRQ means
**the swap has completed and the old front buffer is now reusable**, not
"the panel has already displayed the new pixels".

IO28 is an LVCMOS33 output connected to STM32 PB0/EXTI0, falling edge.
The IRQ stays low until acknowledged with the correct sequence: it is a
level, not a pulse.

## SPI protocol

SPI mode 0, 12.5 MHz, with the same CS setup/hold and recovery/removal
margins the firmware already applies to the other opcodes. All packets
start with response `A5`.

### BA: control, 10 bytes

| TX Index | Contents |
|---:|---|
| 0 | `BA` |
| 1 | dummy `00`; RX indicates availability `C3` or busy `00` |
| 2 | operation |
| 3 | buffer required, or zero reserved |
| 4–5 | 16-bit sequence, high byte first |
| 6–7 | CRC16-CCITT, polynomial `1021`, initial `FFFF`, on bytes 2–5 |
| 8 | commit `A6` |
| 9 | dummies; RX `AC` accepted, `E1` rejected |

RX at indices 2–8 repeats the previous TX byte. A packet dropped before the
commit has no effect. After the commit, CS does not cancel the request. Bad
CRCs, unknown operations, and invalid reserved fields are not accepted.

| Operation | Buffers | Sequence | Effect |
|---|---|---|---|
| 1 ENABLE_DOUBLE | 0 | 0 | Waits for producers, enables drawing on the back; idempotent |
| 2 PRESENT | 0 or 1 | last completed + 1, modulo 65536 | Presents the back at the frame boundary |
| 3 ACK_PRESENT | 0 | last completed | Release IRQ; repeatable |
| 6 ACK_RESET | 0 | 0 | Turns off `reset_seen`; served after PSRAM calibration and initial filling |

`AC` confirms **acceptance**, not completion or semantic validity.
The BB reading distinguishes busy, completed and result. A PRESENT requires
double mode enabled, a destination different from the front, the next sequence,
and no previous IRQs awaiting confirmation. Otherwise, it ends with result `E1`.

An exact repeat of the last completed PRESENT (same sequence, same front)
completes successfully without a swap and without reasserting the IRQ, even
after that PRESENT's IRQ was already ACKed. An incorrectly sequenced ACK
ends with `E1` and leaves the IRQ unchanged. The BB result field concerns
the last completed **check** (BA or BC); the sequence field always refers to
the last completed **PRESENT**. There is no unlimited queue or deduplication
history: an old request should not be resubmitted after 65536 presentations
or after an FPGA reset.

While a BA control request is pending, B7/B8/B9 respond busy; BB stays
readable. Graphics requests already accepted continue to execute. Once the
check completes, the old front can be redrawn even before the ACK; a further
PRESENT still requires an ACK first.

### BB: status and capacity, 11 bytes

TX: `BB` followed by ten `00` dummies.

| RX Index | Contents |
|---:|---|
| 0 | `A5` |
| 1 | signature `D2` |
| 2 | protocol version `03` (`02` before `reset_seen`, `01` before blitter) |
| 3 | number of buffers `02` |
| 4 | bit 0 double enabled; bit 1 front; bit 2 IRQ pending; bit 3 control busy; bit 4 `reset_seen` (from version 3) |
| 5 | drawing buffer, 0 or 1 |
| 6–7 | last PRESENT sequence completed, high byte first |
| 8 | last check result: `00` success, `E1` error |
| 9–10 | CRC16 on RX bytes 1–8, high byte first |

The state is a consistent snapshot maintained throughout the transaction. It
crosses the SPI clock domain as stable data associated with the completion
toggle and is captured after toggle synchronization, rather than synchronizing
the sequence bits separately. During busy, it describes the last completed check.
BB also distinguishes a previous bitstream, which would respond with BB's echo.

## Reset commanded by the MCU

The MCU can reset the FPGA logic through `FPGA_RST_N`: STM32 PB1,
open drain, towards Tang Nano IO29, with a 10 kΩ external pull-up. In the
RTL, the line and the reset button go through `ResetRequestFilter`, which
requires the low level to remain asserted for at least **1 ms** of the 27
MHz clock before taking action. A disturbance on the wire does not reset
anything, and the same filter debounces the button. It is a **logical**
reset: it recalibrates the PSRAM, rechecks the fonts, and clears queues and
parsers, but does not reload the bitstream. `RECONFIG_N` is not reachable
from the Tang Nano 9K connectors.

A pulse on the wire proves nothing by itself: with the wire disconnected, the MCU
would not notice. For this reason, the FPGA exposes **`reset_seen`**, bit 4 of
byte 4 of `BB`: it turns on at every reset and turns off only with `BA ACK_RESET`.
`FPGA_ResetCycle()` uses it like this, at startup and before any other use:

1. Read `BB` and send `ACK_RESET`: `reset_seen` is off, and the test is **armed**;
2. Deselect SPI, mask EXTI0, and hold PB1 low for 10 ms;
3. Wait for the SPI response (`SPI_Setup`) and reread `BB`: `reset_seen` must
   be **on** again, otherwise the pulse did not arrive (step 60);
4. Send `ACK_RESET` again and wait for its completion. Since it is
   served after calibration and initial filling, this is also the signal
   that the FPGA is ready to draw;
5. Clear the IRQ state on the MCU side and re-enable EXTI0.

| `g_fpga_reset_state` | Meaning |
|---:|---|
| 0 | loop not executed |
| 1 | in progress |
| 2 | **reset confirmed** |
| 3 | failed after three attempts: the FPGA should not be used, the demos do not start |
| 4 | pulse sent but not verifiable: bitstream prior to version 3, or the FPGA becomes unresponsive before the pulse and recovers afterward |
| 5 | without reset line: ready, and the FPGA was **just restarted** (power or button) |
| 6 | without reset line: ready, and the FPGA **was already running** with its state (only the MCU restarted) |

### The reset line is optional

The FPGA does not require it: IO29 has a pull-up and remains inactive without the
wire. The firmware decides this using `FPGA_RESET_LINE` in `spi_diag_config.h`, and
`main()` calls `FPGA_Start()`, which chooses the appropriate path:

- **1, line connected**: `FPGA_ResetCycle()`, resetting and testing as above; if
   the reset cannot be verified, the FPGA is not used and the demos do not start.
- **0, no line connected**: `FPGA_WaitReady()`. It does not reset or prove
   anything, but sends `ACK_RESET` anyway and waits for completion. Because it is
   served only after PSRAM calibration and initial filling, the MCU waits until
   the FPGA is **really** ready instead of relying on a fixed delay. Reading the
   ACK response, `reset_seen` distinguishes a newly powered FPGA (state 5) from one that
  was already running (state 6), in which case it can maintain double buffering
  enabled or pending IRQs: `LCD_EnableDoubleBuffer` already handles them.

`g_fpga_ready_tick` reports the HAL tick in both cases, that is, the number of
milliseconds since MCU boot when the FPGA became usable. When both boards are
powered on together, this is the time the MCU actually had to wait, and it is the
value to use if a system falls back to a fixed delay.

Findings without the reset line, September 17, 2026. With only the MCU
restarted: state 6, ready 12 ms after MCU startup. With both boards switched
off and back on together, each from its own USB: state 5, ready at
**12 ms** on the first try, with the wait itself under a millisecond. The
FPGA had already finished initialization by the time the MCU could have
queried it, because SPI becomes ready only after 12 ms. This value is an
upper bound measured from MCU boot rather than from power-on; the FPGA's
actual initialization time remains unmeasured.

**Fixed delay for systems without a line and without active waiting: 200 ms**
from power-on before the first command. The margin over the 12 ms observed
covers conditions the measurement does not capture: slower power ramps,
boards turned on at different times, loading the bitstream, and locking the
PLLs. If the MCU can afford it, still read `BB` status after the delay and
repeat with a short pause until it responds; `FPGA_WaitReady()` remains the
preferred solution. `g_fpga_reset_attempts` counts attempts, and
`g_fpga_reset_ready_ms` measures the time from line release to a ready FPGA.
On the bench, September 17, 2026: state 2 on the first try, **16 ms**.

## STM32 API and demo

```c
LCD_EnableDoubleBuffer();  // It also retrieves any IRQs remaining after an MCU reset
LCD_Clear(0x0000);
LCD_DrawTextFPGA(20, 20, 0, 0, LCD_FONT_12X24, 0, 0xFFFF, 0, "Ready");
LCD_Present(1000);         // Barrier, swap, IRQ wait, and ACK
```

Check each return value: 1 means success, 0 means error. The APIs are blocking
and require only one caller. `LCD_GetBufferStatus` exposes capacity and status.
The ISR counts the front and raises a flag, but does not call SPI. `LCD_Present`
uses the EXTI flag and GPIO level, with periodic status polling to diagnose errors;
it checks that the level is low before the ACK and high afterward. A timeout or
transport error does not cause automatic retransmission: read BB to reconcile
the state. A pending IRQ must be confirmed before resubmission.

The FPGA demo reconstructs and presents 16 frames with a moving rectangle,
then presents the sample text and shapes with the message
`Double buffer + VSYNC + IRQ: OK` — 17 PRESENT calls in total. The first 16
also verify 16 EXTI edges. SWD-readable results: `g_lcd_present_count`,
`g_lcd_present_ms` (last wait, 1 ms resolution), `g_lcd_front_buffer`,
`g_lcd_present_sequence`, `g_fpga_irq_count`, `g_fpga_irq_pending`,
`g_fpga_irq_level`, `g_lcd_error`.

## Reproducible checks

```powershell
.\sim\run_spi_sim.ps1
.\sim\run_double_buffer_sim.ps1
.\sim\run_double_buffer_sim.ps1 -RealFifo
.\sim\run_sim.ps1 -Mode current
.\build.ps1
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -SerialNumber 35FF6C064D53373238602143
# Read-only; first verify that the STM32 flash matches the ELF:
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

The normal hardware test flashes the FPGA bitstream and font, then programs
the MCU Release build; it requires a bitstream already compiled and
matching the timing manifest. The runner with `LCD_SCROLL_DEMO=0` saves
`build/Release/double-buffer-result.json` and reports 17 presentations, 17
IRQ edges, demo completed, IRQ released, and no SPI/LCD errors. The general
MCU build default remains Debug; this runner's is Release.

The integration test uses the real TOP with PLL and PSRAM models. It checks
CRC, aborts, the fill barrier, front-buffer write blocking, duplicate
requests, bad ACKs, both slots, padding, and three full frames written to
memory. The `-RealFifo` variant also uses the project's RTL FIFO. The PSRAM
model does not replace electrical qualification on the bench; SWD does not
reread panel pixels.

## COPY/SCROLL extension

With the current default `LCD_SCROLL_DEMO=1`, the scroll/terminal demo runs
after the previous sample completes: 50 PRESENT/IRQs in total, one COPY, and
32 SCROLL. The runner detects the flag and saves `scroll-result.json`;
`-RequireScroll` requires the demo's scroll step to be explicitly enabled.
The BC protocol, API, and viewport consistency are described in
[BLITTER.md](BLITTER.md). BB's layout is unchanged; the version field was
bumped to `02` when the blitter shipped (it is `03` now that `reset_seen`
has also shipped), and the result field reports the last completed BA or BC
check.

Since September 16, the controller has recorded the frame-boundary signal after
synchronization and arbitration: the swap follows that signal by one cycle,
adding approximately 12 ns of PSRAM time while remaining within the same
vertical blanking interval.
The test checks this latency with its own reference register.