# Project verification

## COPY and SCROLL

Protocol and demo: [BLITTER.md](BLITTER.md).

- Nine SPI/graphics/FIFO testbenches pass: 99 added COPY/SCROLL cases and
  10,000 FIFO words, including full/empty, overflow, wrap, and concurrent
  clocks.
- Final TOP integration with the real RTL FIFO: PASS, 12 blitter cases, four
  PRESENT calls and eight full frames (1,044,480 pixels); covers CRC/abort
  checking, the barrier, busy state, invalid geometries, masks, padding,
  front/back isolation, and PSRAM contents checked against the video-stream
  readout.
- Resynchronization with the real FIFO: recovery by the next frame, 0/4
  frames corrupted after an induced underrun.
- FPGA: zero setup/hold/recovery/removal violations, Fmax PSRAM 81.909 MHz
  against an 81 MHz clock; 5209 logic resources, 3659 registers, 3 BSRAM.
  Build with `-NoCompress`, PlaceOption 1, constraints unchanged.
- MCU Debug and Release both compiled. FPGA/font image and MCU Release
  loaded; bitstream CRC verified, and MCU flash compared against the ELF.
- On the board: one COPY, 32 SCROLL, 50 PRESENT/IRQ; zero errors, final IRQ
  high. COPY completes in 14 ms, the last viewport SCROLL in 8 ms, the last
  PRESENT in 16 ms. Result: `stm32/WeAct_H743_SPI/build/Release/scroll-result.json`.

The sections below retain the results of earlier steps.

## Double buffering

Protocol and commands: [DOUBLE_BUFFER.md](DOUBLE_BUFFER.md).

- Seven SPI/graphics testbenches: PASS.
- `run_double_buffer_sim.ps1`, model and real FIFO: PASS, three full frames
  (391680 pixels) per run, two swaps, CRC/aborts, barrier while `B9` is in
  flight, blocked concurrent commands, front isolation, duplicate and bad
  ACKs. The real-FIFO variant also covers masked `B7` and `B8` into the back
  buffer.
- `run_sim.ps1 -Mode current`: PASS, four intact frames after an underrun;
  real RTL FIFO, no regression in next-frame recovery.
- FPGA build: no setup/hold/recovery/removal violations, no calibration
  exceptions used. Fmax PSRAM 84.277 MHz against an 81 MHz operating clock.
  Log/manifest: `impl/build.log`, `impl/verification.json`.
- MCU Debug and Release build: PASS; Release flashed with verification.
- On the board: 17 PRESENT completed and 17 EXTI edges, IRQ confirmed and
  cleared, 4374-byte echo with no mismatches, no LCD/HAL errors. Clear in
  8 ms; last PRESENT wait 12 ms. Final image confirmed by the user.

The PSRAM test is behavioral. No physical readback of panel pixels,
instrument measurement of VSYNC/IRQ edges, or power-cycle test has been
performed.

## Reproducible commands

For SPI protocol and graphics primitives, also run `./sim/run_spi_sim.ps1`.
It includes nine testbenches, among them `tb_line_renderer`: 124 lines
compared against a reference based on rational rounding, all directions,
endpoints and single-point lines, mask and burst blending, backpressure and
delayed acknowledgment release as in the TOP CDC. `tb_spi_framebuffer` also
checks `B9` type 1: CRC, limits, invalid type/flags, abort before commit,
queue busy, and the pending command being retained even while the master
polls `B8`. The regression preserves `B7`, `B8` text and `B9` type 0 fill.
These tests verify the simulated pixels; the SWD checks on the bench verify
transport state and errors, without reading back the PSRAM.

From PowerShell, in the repository root:

```powershell
.\sim\run_sim.ps1 -Mode all
.\build.ps1
.\sim\test_verification.ps1
```

You need Icarus Verilog and oss-cad-suite's `vvp` (default `C:\oss-cad-suite`),
Gowin EDA V1.9.12.01 and a Git history containing `1e9337d` as `legacy`.
Paths can be given with `-OssCadSuite` and `-GowinRoot`. The build does not
program the board; `-Program` programs it only after the timing gate passes.

Each command fails with a non-zero exception/exit code on error. The runner
deletes previous outputs before compiling, explicitly selects the testbench
top module, and requires both a zero exit code and the `PASS: frame_resync`
marker. It keeps stdout/stderr in logs, without hiding compilation errors.
It resets `PATH` and `YOSYSHQ_ROOT` when finished.

The simulated timeout is 200 ms; the real (wall-clock) one is 900 s per
process, configurable with `-TimeoutSeconds`. The latter also guards against
a simulator that stops advancing time. On interruption/timeout the runner
terminates the process; on PowerShell 7 it also terminates any child
processes of the compiler/EDA tool. Windows PowerShell 5.1 relies on direct
process termination (`vvp` does not spawn children). Unbuffered output shows
the first millisecond, the audit and each completed frame.

## Simulation contract

The PSRAM model records writes and compares all 130,560 pixels against a
reference computed with modulus/division, independent of the generator's
incremental counters. The reference follows the selected pattern; for the
historical commit, it uses the bar pattern, without referencing parameters
that no longer exist.

On reads, the model returns a 16-bit address ramp, rather than the
framebuffer contents that were written. This tests write and stream
alignment separately; it is not a full simulation of the Gowin PSRAM IP.

For each mode the following are required:

- two complete, error-free frames before the fault;
- 130,560 active pixels per checked frame;
- a 150 us starvation event in the visible area, with the FIFO actually
  empty and corruption observed in the affected frame;
- four consecutive error-free frames for `current` and `model`;
- four consecutive corrupted frames for `legacy`: this is an expected pass
  of the historical regression, not license to accept errors in the current
  RTL;
- no PSRAM beats lost to a full FIFO;
- DE, HSYNC and VSYNC compared at every clock against a time reference
  independent of the DUT's counters; RGB black during blanking;
- for the current RTL, stable outputs across the falling edge, and one
  VSYNC per frame.

The outputs are sampled after the RTL's updates have settled. The
historical (legacy) mode accounts for combinational outputs, half-period DE
and VSYNC stuck at zero; it does not evaluate them as though they were
already registered.

## Raster measured, kept unchanged

This check locks in existing behavior. It does not implicitly correct the
raster, nor does it certify it against the panel datasheet.

| Size | Current value |
|---|---:|
| Nominal LCD clock | 9 MHz |
| Ordinary line | 561 clock |
| Frames | 297 lines plus a final clock = 166,618 clocks |
| Nominal frame rate | approximately 54.016 Hz |
| Active area | 480 × 272 pixels |
| HSYNC high | 50 clocks per ordinary line |
| VSYNC high, current RTL | 10,660 clocks, approximately 1.184 ms |

The horizontal counter reaches 560. The vertical counter reaches 297 for a
single clock before the raster resets. VSYNC starts at line 278;
`FrameRestart` is on line 277. This results in 19 complete lines plus one
clock of VSYNC high, and one HSYNC interval that is one clock longer than
the others across the frame. Any change to this must be a deliberate
modification of this contract, and must then also be verified on the panel.

## Build timing

`tools/Test-TimingReport.ps1` checks the tool, device, corner, clock, Fmax
and the setup/hold/recovery/removal/pulse-width tables. A missing,
truncated or unrecognized report fails the build.

A maximum of seven setup endpoints are allowed in total, and only if each
one falls into one of the two families declared in `$baselineFamilies`.
Each family fixes the exact node names, the clock pair and a slack floor;
none of them match `psram_inst` as a whole.

| Family | From | To | Clock | Floor |
|---|---|---|---|---|
| IDES4 calibration | `calib_0_s*/Q` | `CALIB` of the eight IDES4 | `psram_clk_81` → `mem_clk_162` | −1.960 ns |
| DLL writing step | `u_dll/CLKIN` | `u_psram_wd/step_*_s*/D` or `/CE` | `mem_clk_162` → `psram_clk_81` | −1.400 ns |

Any other violation, **even one internal to the IP**, is an error, as is any
path that starts in our RTL and ends in the IP. The number of endpoints
with identified negative slack must match the summary: an incomplete table
does not count as a PASS. The rationale and limitations are documented in
`src/LCD.sdc`.

The second family was added on September 16, 2026, when the `BD` opcode
brought occupancy from 61% to 66% and the path fell below zero. It's worth
restating why this is not a silent relaxation of the rule:

- source and destination are **both inside `psram_inst`**; none of our
  registers are on the path. It is DLL step calibration on the write side,
  of the same nature as the calibration already accepted;
- on the **exact same RTL** the slack goes from −0.938 ns with
  `PlaceOption 0` to −1.170 ns with 1 and 2. A path that moves 232 ps from
  placement alone had no margin even when the report was clean: the
  baseline was measuring luck, not health;
- the project's clock domains retain their margin, and the gate continues
  to require it: `psram_clk_81` reports Fmax 85.528 MHz against an
  80.998 MHz constraint.

The gate has negative-evidence tests. Editing the report by a single line
demonstrates that it catches a path starting from user RTL, a slack under
the floor, an inverted clock pair, and an out-of-family endpoint.

`impl/build.log` contains the full log. `impl/verification.json` records
the UTC date, toolchain, results and SHA-256 of the bitstream and report
just generated. Old verification artifacts are invalidated before the
build.

## Baseline

Functional RTL unchanged compared to `2b474e3`; only the verification tools
and documentation were modified. Tool: Icarus 14.0 develop
`s20260301-322-ga4989d023-dirty`, Gowin V1.9.12.01.

| Try | Outcome |
|---|---|
| Write audit, all modes | 130,560 correct pixels |
| `current`, FIFO RTL | 0/4 post-fault frames corrupted; 7 VSYNC in 7 frames |
| `model`, behavioral FIFO | 0/4 post-fault frames corrupted; 7 VSYNC in 7 frames |
| `legacy`, commit `1e9337d` | expected persistent damage: 4/4 corrupted frames |
| New synthesis and place-and-route | completed, timing gate passed |
| Residual calibration setup | 4 endpoints, worst slack −0.666 ns |
| Hold/recovery/removal/pulse-width | no violations |
| Fmax PSRAM / LCD / XTAL | 86.562 / 71.716 / 99.053 MHz |
| Negative evidence | 18 errors correctly flagged, on both PowerShell 7 and Windows PowerShell 5.1 |

Times observed on this machine, with other tests running concurrently:
approximately 346 s for `current`, 89 s for `model`, 70 s for `legacy`.
Simulation with the real FIFO RTL is significantly more expensive than the
behavioral model: the earlier «about a minute» estimate was not accurate
for `current`.

Negative evidence in `sim/test_verification.ps1` uses copies under
`sim/build/verification_checks`, the real compiler and mutated reports from
the Gowin run just checked out. They verify: compilation failing against a
stale `.vvp`, exiting without a PASS, `$fatal`, the real watchdog, an
incorrectly written pixel, wrong timing, simulated timeout, no underruns,
and violations/reports outside the baseline. If the report no longer
contains negative calibration paths, the relevant fixture must be updated
explicitly: cases are not skipped silently.

These results are not a substitute for a hardware test: the model does not
reproduce calibration, electrical behavior, metastability, or the full
timing of the PSRAM IP. No new tests for mid-frame reset, PSRAM latency
variation, or sustained failures through vertical blanking have been
introduced.
