# Extended SPI and graphics testing, as of September 9th

> Current status: [GRAPHICS_COMMANDS.md](GRAPHICS_COMMANDS.md) and
> [RIPRESA.md](RIPRESA.md). To repeat the stress test, enable the GPIO
> probe, 240 echo rounds and the graphics tests; normal startup does not
> enable them.

## Result

Extended qualification **does not pass at 25 MHz**: the DMA echo passes, but
graphics traffic shows intermittent errors. Final configuration **12.5 MHz
MEDIUM**, prescaler 16 in C and CubeMX. The SDC is set to 40 ns, more
restrictive than the actual master clock; the same bitstream is used for
comparing frequencies.

At 12.5 MHz, with the final firmware, three PASS runs were recorded: STM32
load, STM32 reset only, and FPGA reload followed by STM32 reset. Each run
checks:

- 1200 DMA echo transfers, 1049760 bytes, zero mismatches and zero HAL errors;
- all three GPIO tests correct;
- 512 rectangles, 354528 active pixels and 30035 graphics packets;
- stress state 2, LCD error phase 0, demo drawn successfully.

Sum of the three final runs: 3149280 echo bytes, 1536 rectangles, 1063584
active pixels and 90105 graphics packets. No PSRAM pixel readback was
performed in any of them: the hardware graphics checks verify SPI echo and
acceptance, while the simulated bench verifies data, masks and PSRAM
addresses. The reload test is not a power-supply off/on cycle.

## What the 25 MHz test revealed

With HAL graphics firmware in polling mode, the first error occurred at
rectangle index 172 (indices from zero). After adding diagnostics for the
first error, the observed index was 70, with a final response of 5A instead
of AC, and no HAL error. A 1 us CS guard does not fix it: failure at index
126 with the same response.

At 12.5 MHz the same polling test passes. Registering the response directly
in the SCK domain improves the path to TX but does not eliminate the defect
by itself: at 25 MHz, polling still fails even with the new bitstream (index
46).

Moving graphics traffic to DMA, a 25 MHz test completes all 512 rectangles;
after an FPGA reload, however, it fails at index 275, on the `B7 00` poll: A5
arrives instead of C3/00. The long echo test also passes in this run.
Therefore neither this first DMA PASS nor the earlier timing closure qualify
prolonged graphics traffic at 25 MHz. The physical/RTL/peripheral cause
remains to be isolated; the results do not prove that DMA solves the
problem, nor that it is only a wiring issue. LVGL has not been integrated:
the agreed condition for a 25 MHz PASS is still missing.

## Changes retained

`SPI_SELFTEST_ROUNDS` in spi_diag_config.h controls the echo duration; the
runner reads the expected counts from the configuration. The default value
is now 8, down from 240 as of September 10, 2026, because the long echo
delayed the text appearing at each startup by nine seconds. `-RequireStress`,
however, demands over 1,000,000 bytes checked, i.e. at least 229 rounds:
before that qualification the value must be brought back to 240 and the
firmware recompiled. The runner now checks this in advance and reports it,
instead of failing at the end on the total count. The echo pattern's first
byte, `B7`, is replaced with `37` so it doesn't trigger the graphics parser.

`LCD_Stress_Run()` varies width 1..67, height 1..40, position and pixels,
regularly forcing the four corners and non-aligned coordinates. It stops at
the first mismatch, without a retry that could hide it. `g_lcd_stress` holds
status, rectangle/pixel/packet counts, elapsed time and the index of the
failed rectangle. `g_lcd_error` holds phase, address, byte index, expected
value, received value and HAL error.

`SPI_Exchange_DMA()` reuses the aligned buffers in SRAM D2 and the self-test
callbacks, with cache and timeout management; the caller owns CS and waits
for completion. It does not support concurrent transfers. The graphics
firmware uses 1 us CS guards based on the DWT counter, without changing the
SCK frequency during packets. The demo is sent before and after the stress
test; the panel retains the test's rectangles, overlaid, together with the
final RGB rectangle.

The FPGA now registers the next response on the edge that completes the RX
byte, eliminating the combinational index/status mux feeding the TX
register. Protocol unchanged, SPI/framebuffer suite PASS. Final build at 40
ns: gate timing PASS, four allowed PSRAM calibration endpoints, worst slack
-0.669 ns, no hold/recovery/removal violations and no new exceptions.

## Reproduction

Now that the boot screen is solid black, enable `LCD_BOOT_TESTS=1` first in
Core/Inc/spi_diag_config.h, then rebuild/flash with the following command.
When finished, set it back to 0 and reload the STM32 to keep the boot
background uniform.


```powershell
# Build/upload and full test in the current configuration (standard SPI at 9.375 MHz):
./stm32/WeAct_H743_SPI/test-hardware.ps1 -RequireGraphics -RequireStress -TimeoutSeconds 120 -SerialNumber 35FF6C064D53373238602143
# Read-only when the firmware and ELF match:
./stm32/WeAct_H743_SPI/test-hardware.ps1 -ReadOnly -RequireGraphics -RequireStress -TimeoutSeconds 120 -SerialNumber 35FF6C064D53373238602143
```

To repeat after an STM32 reset, use the reset button or CubeProgrammer's
`-rst`, then run the ReadOnly command. To repeat after a reload, use
program_tang_nano_sram.ps1, reset the STM32 and read again. Results are
saved to the hardware JSON; ReadOnly does not trigger a new test and does
not check for ELF matching on its own.

Archives under `stm32/WeAct_H743_SPI/build/Debug/` (ignored by Git):
`stress-first-fail.json`, `stress-commit-fail.json`, `stress-guard-25-fail.json`,
`stress-guard-12m5-pass.json`, `stress-registered-status-fail.json`,
`stress-dma25-warm-pass.json`, `stress-dma25-reload-fail.json`,
`stress-dma12m5-upload-pass.json`, `stress-dma12m5-reset-pass.json`,
`stress-dma12m5-reload-pass.json`. The `stress-final-12m5` archive contains
ELF, bitstream, timing report, metadata and the three final tests.
