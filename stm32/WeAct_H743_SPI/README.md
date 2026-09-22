# WeAct H743 / Tang Nano 9K firmware

Project source (STM32CubeMX with CMake generation), VS Code environment,
generated files and regeneration rules: [TOOLCHAIN.md](TOOLCHAIN.md).

Current state: SPI 9.375 MHz, B7 pixels, B8 FPGA text, B9 fill/clear and
horizontal/vertical lines. `LCD_DrawLine` uses B9 type 1 for diagonal lines
with inclusive endpoints and also requires the newer FPGA bitstream. API and
protocol: [GRAPHICS_COMMANDS.md](../../docs/GRAPHICS_COMMANDS.md).
The dated sections below preserve the testing history.

## LVGL 9

Submodule `../../third_party/lvgl` provides LVGL v9.6.0. `GuiTask` runs the UI
and queues each flush to `DisplayTask`, which remains the exclusive owner of
SPI2. The demo uses RGB565 partial buffers: two 20-row buffers in D2 RAM. At
the end of each LVGL frame, `DisplayTask` runs `PRESENT` and a front-to-draw
`COPY` to preserve the base for subsequent partial updates without tearing.

## Double buffering and PRESENT

BA/BB and `LCD_EnableDoubleBuffer`, `LCD_GetBufferStatus`, `LCD_Present` are
implemented. The demo features 16 animated frames plus a final one, with IRQ
verification. Protocol and limits: [DOUBLE_BUFFER.md](../../docs/DOUBLE_BUFFER.md).
Testing from this folder:

```powershell
.\test-double-buffer.ps1 -SerialNumber 35FF6C064D53373238602143
.\test-double-buffer.ps1 -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

Default preset is Release. The first command requires an already-verified
bitstream: it programs the FPGA/fonts and the MCU. The second checks that the
STM32 flash matches the ELF and reads the results without resetting.

## COPY, scroll and terminal

`LCD_CopyRect` and `LCD_ScrollRect` use `BC` (requires BB version 2). Scroll
takes an RGB565 fill color for the area it uncovers; `PRESENT` stays separate
so text can still be added before the swap.
`LCD_SCROLL_DEMO=1` adds 32 scrolling rows in a viewport, preserving the frame
and background. Total: 50 PRESENT/IRQ, one COPY and 32 SCROLL.

```powershell
.\test-double-buffer.ps1 -RequireScroll -SerialNumber 35FF6C064D53373238602143
```

The runner auto-detects the demo flag; `-RequireScroll` requires it
explicitly. Details: [BLITTER.md](../../docs/BLITTER.md).

## Build and upload

Open this folder in VS Code. You need CMake, Ninja, and arm-none-eabi-gcc on
`PATH`, plus the STM32CubeProgrammer CLI (already included with CubeCLT).

```powershell
.\build.ps1                  # configure and build Debug
.\build.ps1 -ListProbes      # list probes, without connecting to the target
.\build.ps1 -Program -SerialNumber <serial>
```

`-Program` builds, writes the ELF to the addresses it contains, verifies the
flash, and resets the MCU. It stops if any step fails; there is no mass erase
or option-byte modification. The serial number is required to explicitly
select the target when multiple probes are connected. Programming overwrites
firmware only in the affected flash regions.

Options: `-Preset Release`, `-SwdFrequencyKHz 1000`, `-ProgrammerPath <path>`,
`-UnderReset` (requires NRST connected). Close any debug session holding the
probe before uploading. Logs and artifacts go to `build/<preset>/`, excluded
from Git.

In VS Code: Terminal > Run Task > STM32: Build and upload Debug. The task
prompts for the serial number. Ctrl+Shift+B only runs the build.

## Wiring implemented

These Tang Nano numbers are FPGA IOs, not connector pin positions. The wiring
is implemented in `TOP` and constrained in the LCD project.

| WeAct | Tang Nano IO | Signal |
|---|---:|---|
| GND | GND | Common ground |
| PB13 | 36 | SCK |
| PB15 | 25 | MOSI |
| PB14 | 26 | MISO |
| PB12 / FPGA_CS | 27 | CS, active low |
| PB0 / FPGA_IRQ_N | 28 | PRESENT notification, active low until ACK |
| PB1 / FPGA_RST_N | 29 | FPGA logic reset, open drain, active low; 10 kΩ pull-up to the Tang Nano's 3V3 |

The `FPGA_RST_N` pull-up must be mounted on the Tang Nano, between IO29 and
the 3V3 pin (never 5V: IO29 is in the 3.3V bank), not in the middle of the
wire or on the STM32 side. If the MCU connection is disconnected, IO29 must
stay firmly high: with only the internal pull-up, a disturbance longer than
1 ms would reset the logic.

The IRQ IO28 -> PB0 connection is confirmed working. The MCU side configures
EXTI0 on the falling edge, with a pull-up and NVIC priority 5 (subpriority 0).
IO28 is now driven by the FPGA: an edge signals a completed swap. The ISR
raises a flag; `LCD_Present` reads `BB` and confirms the event via `BA`.

No D/C line. READY is not yet implemented and is not needed for this short
test. The Tang Nano's microSD slot must stay empty (SCK IO36 is shared). Each
board is powered from its own USB; only grounds and signals are shared
between boards, without joining their 5 V or 3.3 V rails. Logic is 3.3 V, use
short cables, and a 10 kΩ pull-up on CS to the Tang Nano's 3.3 V. Do not drive
the Tang Nano's 1.8 V buttons/reset with the MCU.

ST-LINK: SWDIO -> PA13, SWCLK -> PA14, GND -> GND, NRST -> NRST recommended.
On probes with a VTref input, connect it to the 3.3 V target. Don't confuse
VTref with the 3.3 V power output some probes/clones provide; the WeAct board
is USB powered.

## Automatic hardware test

From the repository root:

Normal firmware has `SPI_GPIO_PROBE=0`; for this runner, enable
`SPI_GPIO_PROBE=1` in `Core/Inc/spi_diag_config.h`. Stress testing also needs
`SPI_SELFTEST_ROUNDS=240` and `LCD_BOOT_TESTS=1`; restore these settings after
qualification. The `-Require*` flags verify these prerequisites.

```powershell
.\stm32\WeAct_H743_SPI\test-hardware.ps1 -SerialNumber 35FF6C064D53373238602143
```

Runs the SPI simulation, builds and uploads the FPGA bitstream to SRAM, builds
and uploads the STM32 firmware, then reads the result over ST-LINK. Also
available as the VS Code task `STM32 + FPGA: Build, upload and test SPI`. The
SRAM bitstream is lost when the Tang Nano powers off: repeat the command after
a power cycle.

`-ReadOnly` only reads results, using local ELF symbols; use it only when
that ELF is the one actually loaded. The recorded hash identifies the local
file but is not a flash check in this mode. `-Preset Release` also selects
the Release ELF and results for the runner; the default remains Debug.

`SpiDiagnostic` returns `A5` for the first byte after CS goes low, then echoes
the previous MOSI bytes. It does not touch the framebuffer. Before DMA, a
slow GPIO test sends eight bytes under three MISO pull configurations (no
pull, pull-up, pull-down). The expected response is `A5 3C 4D 5E 6F 80 91 A2`
in all three cases.

The normal firmware runs one round: 5 DMA transfers at 9.375 Mbit/s, GPIO
drive MEDIUM (lengths 1, 2, 17, 257, 4097), testing 4374 bytes. The
240-round qualification performs 1200 transfers and checks 1,049,760 bytes.
Buffers live in SRAM D2, aligned to 32 bytes, with cache management when the
cache is enabled. CS is raised after the SPI transfer completes. The result
is stored in `g_spi_test`; the runner saves `build/<preset>/hardware-result.json`
and fails on timeout or mismatch. The extra RAM section and the test source
are wired in by the CMake user file, without modifying the CubeMX-generated
linker script.

## Result of the first test (2026-09-08)

Simulations passed (525 generic RX / 515 TX bytes, 32777 diagnostic bytes),
FPGA build with gate timing passed, FPGA and STM32 uploads verified.
ST-LINK V2 detects STM32 rev. V, power supply 3.27 V.

**Hardware test failed:** 40 transfers completed, no HAL errors,
34853 mismatches on 34992 bytes. The GPIO test reads FF with pull-up and 00
with pull-down: MISO appears undriven on the STM32 side even with CS driven
low. Check the four signal connections and the slave-select wiring; this
result does not yet qualify the connection or the maximum speed.

Update 2026-09-09: after fixing a reversed connector, the DMA test passes at
0.78125, 1.5625, 3.125, and 6.25 MHz. At 12.5 MHz, 32 mismatches appear across
34992 bytes despite timing PASS. Current configuration: 6.25 MHz, prescaler
32, SPI constraint 160 ns; CubeMX aligned. Do not raise the frequency further
before diagnosing the errors. An anomaly remains in the first two bytes of
the first no-pull GPIO test; pull-up/pull-down results are correct. The
runner determines PASS from the DMA test and reports the GPIO bytes
separately. Results and limitations: [SPI_PERFORMANCE.md](../../docs/SPI_PERFORMANCE.md).

Subsequent diagnosis: at 12.5 MHz, MEDIUM edge drive eliminates the errors
across the tests performed (long echo: 1049760 bytes, autonomous sequence:
104976 bytes, MOSI: 24 blocks of 4096 bytes with correct CRC). Current
configuration: prescaler 16, GPIO MEDIUM, SDC 80 ns; CubeMX aligned. The
normal test has been reloaded and passes the DMA comparison. The first-test
GPIO anomaly does not reappear when only the STM32 is restarted after the
FPGA has been loaded.

The new `diagnose-hardware.ps1 -SerialNumber <serial> -Mode echo|miso|mosi`
runs three repetitions at 4.6875/9.375 MHz and VERY_HIGH/HIGH/MEDIUM edge
drive; `-Rounds 80` extends the test. It saves up to 16 events per case, with
neighboring bytes, total counters, and hash-identified artifacts. Mismatches
are diagnostic evidence and do not fail the runner on their own; check the
results. `-RestoreSelfTest` disables the matrix and reloads the normal test.
Procedure and results: [SPI_DIAGNOSTIC_RESULTS.md](../../docs/SPI_DIAGNOSTIC_RESULTS.md).

The firmware now initializes the slave with two SCK pulses while CS is high,
before the first transaction. After reloading the FPGA, all three GPIO tests
pass; the normal runner now checks them in addition to the DMA test.
Toggling CS alone, without clocking, was not enough. See the diagnostic
report for the limits of this initialization sequence and later tests.

## Historical graphics update at 25 MHz

That test's configuration was prescaler 8, GPIO MEDIUM, SDC 40 ns, and
`SPI_FRAMEBUFFER=1`. The new serializer with a fixed first byte `A5` passed
timing and the initial hardware test (34992 bytes with no errors, demo
accepted). See [SPI_FRAMEBUFFER.md](../../docs/SPI_FRAMEBUFFER.md). Later
results superseded this operating point.

## Status after prolonged testing

The initial PASS at 25 MHz is not confirmed by the extended graphics test.
Qualification configuration: prescaler 16, 12.5 MHz MEDIUM, 240 echo rounds
and 512 rectangles via DMA. Since September 10, 2026 the default round count
is 1, to avoid delaying startup; it must be set back to 240 to re-run this
qualification. Three full test runs pass after upload/reset/reload. SDC was
40 ns during this qualification; the current value is 80 ns. Details and the
`-RequireStress` command are in [SPI_STRESS.md](../../docs/SPI_STRESS.md). The
earlier sections mentioning 25 MHz describe the state before the extended
test.

## Smooth startup

`LCD_BOOT_TESTS=0` leaves the graphics demo and stress test disabled. The
current font test enables `LCD_FPGA_TEXT_DEMO=1` separately
(`LCD_TEXT_DEMO=0`) and therefore replaces the black background with the text
sample after the SPI echo. The demo and stress test require
`LCD_BOOT_TESTS=1` in `Core/Inc/spi_diag_config.h` and a re-upload. The
`-RequireGraphics` and `-RequireStress` flags check this setting. See
[SPI_FRAMEBUFFER.md](../../docs/SPI_FRAMEBUFFER.md) for the distinction
between the FPGA burst command and the STM32 rectangle API.

## 12x24 text prototype

`lcd_text.c` adds `LCD_DrawCodepoint()` and `LCD_DrawText()`: fixed 12x24
cells, opaque RGB565 rendering, and UTF-8 input. The glyph subset covers
printable ASCII, Latin-1, the euro sign, and the four arrows: 196 glyphs and
9408 bytes of bitmap in STM32 flash. Unavailable characters become `?`;
newlines and carriage returns are handled, without wrapping or clipping.

The data is generated from the normal-weight 12x24 BDF font with:

```powershell
python ../../tools/generate_lcd_font.py `
  ../../third_party/terminus-font-4.49.1-master/ter-u24n.bdf `
  Core/Inc/lcd_font_12x24.h Core/Src/lcd_font_12x24.c
```

The source is distributed under SIL OFL 1.1; attribution, checksum, and
license text are in `../../third_party/terminus-font-4.49.1-master`.
`LCD_TEXT_DEMO=1` shows the CPU-rendered prototype sample after the SPI
self-test; `-RequireText` checks via SWD that the rendering was sent. Set the
flag back to 0 to keep the screen black after startup.

Testing 2026-09-09: PASS at 12.5 MHz, 1,049,760 SPI bytes with no mismatches,
`text_state=2`. Visual confirmation for ASCII, degree sign, accented
characters, and arrows; no apparent glyph corruption or mistranslation.
