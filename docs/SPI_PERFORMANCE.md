# SPI testing

> History of SPI measurements: the configurations mentioned belong to their
> respective tests. Current state in [RIPRESA.md](RIPRESA.md); MCU
> Debug/Release comparison in [MCU_RELEASE_COMPARISON.md](MCU_RELEASE_COMPARISON.md).

**Later update:** Edge-rate diagnostics reached a PASS at 12.5 MHz with STM32
GPIO set to `MEDIUM`, including 1049760 bytes in the long echo test. The
current configuration uses PLL2 at 150 MHz: 18.75 MHz TX-only for pixels,
9.375 MHz for ordinary commands and 1.171875 MHz for status, GPIO `MEDIUM`
and SDC at 53.333 ns. See
[SPI_DIAGNOSTIC_RESULTS.md](SPI_DIAGNOSTIC_RESULTS.md). The following table
documents the previous ramp-up with GPIO `VERY_HIGH`, not the current limit.

After fixing a reversed connector and powering the boards back on,
full-duplex DMA works. Each step includes simulation, an FPGA build with the
updated SCK period, gate timing, FPGA SRAM load, STM32 upload and
verification, and a comparison of 34992 bytes across 40 transactions
(1/2/17/257/4097 bytes).

| SCK MHz | Prescaler on 200 MHz | Mismatch | HAL | FPGA Timing |
|---:|---:|---:|---|---|
| 0.78125 | 256 | 0 | OK | PASS |
| 1.5625 | 128 | 0 | OK | PASS |
| 3.125 | 64 | 0 | OK | PASS |
| 6.25 | 32 | 0 | OK | PASS |
| 12.5 | 16 | 32 | OK | PASS |

At 12.5 MHz, the first error occurred at index 153 of a transaction: EB
expected, A5 received. Higher frequencies were not attempted. Configuration
reported at 6.25 MHz (160 ns constraint, max I/O budget 10 ns and MISO min
-3 ns). The timing PASS does not qualify the integrity of the real signals
and wiring; the cause of the errors at 12.5 MHz has not yet been isolated.

A separate anomaly remains in the first slow GPIO exchange: no-pull returns
`D2 BC 4D 5E 6F 80 91 A2`, while pull-up and pull-down both return
`A5 3C 4D 5E 6F 80 91 A2`. Moving the sampling to after waiting for the
clock to go high did not fix it. The runner's PASS covers the DMA, not the
GPIO test.

Frequency sweep logs and JSON are in `stm32/WeAct_H743_SPI/build/Debug/`
(`sweep-<Hz>.log`, `hardware-<Hz>.json`, ignored by Git). These are short
tests: 6.25 MHz is the last step that passed, not a qualification of
long-term reliability or of future framebuffer writes.

# SPI preliminary assessment - 2026-09-08

This is a design estimate, not a hardware qualification. Functional RTL
unchanged. No test bitstreams were loaded onto the card.

## STM32H743

The DS12110 rev 11 datasheet distinguishes between silicon revisions. At
3.3V, SPI1/2/3 master tops out at 100 MHz for rev V (table 195), while table
96, covering rev Y, shows 133 MHz. Do not use the commercial 150 MHz figure
as the SPI2 master limit. Check REV_ID via debugger: 0x2003 = V, 0x1003 = Y
(RM0433).

Sources:
- https://www.st.com/resource/en/datasheet/stm32h743vi.pdf
- https://www.st.com/resource/en/reference_manual/rm0433-stm32h742-stm32h743-753-and-stm32h750-value-line-advanced-armbased-32bit-mcus-stmicroelectronics.pdf

## Gowin experiment on the isolated module

Tool V1.9.12.01, GW1NR-LV9QN88PC6/I5, setup corner Slow 1.14V 85C C6/I5, hold
corner Fast 1.26V 0C. Top module `SpiSlave`, SCK on pin 36, MOSI on 25, MISO
on 26 (8 mA drive), CS on 27. The other, parallel ports are exposed as
automatically assigned I/O: they do not represent the eventual pin placement
alongside the FIFO, parser and LCD.

Exploratory project and log in `sim/build/spi_timing/` (output ignored by Git).

| Try | Result |
|---|---|
| Only create_clock at 50 MHz | Fmax reported 122.784 MHz; internal timing only |
| 50 MHz I/O Budget | MISO setup slack -6.886 ns; Fmax 29.611 MHz |
| 25 MHz I/O Budget | MISO setup slack +2.965 ns; Fmax 29.351 MHz; zero setup/hold violations |

Reports: `internal_only_50MHz.tr`, `io_budget_50MHz.tr` and
`impl/pnr/probe.tr` (last test at 25 MHz).

Exploratory budget: MOSI input delay max 3 ns, min 0, relative to the
falling edge; MISO output delay max 3 ns relative to the rising edge. For
the 25 MHz test the min MISO is -3 ns (STM32 rev V hold); the earlier 50 MHz
test had a min of -1 ns and only serves to quantify the setup failure. The
3 ns max output represents 2 ns of STM32 setup plus 1 ns of budget, total
per connection. These are not wiring measurements. Real load, ringing,
duty-cycle distortion and jitter are not modeled. Reset, CS, the first TX
bit, the parallel interfaces and CDC are not qualified by this experiment.

Gowin reports PR1014: the `spi_sck_d` clock is routed through generic
routing resources. Clock routing needs to be resolved/verified in the real
integration. Pin 36 having a GCLKC name alone does not guarantee use of a
dedicated global network. The mux after the TX register and the clock-pin ->
register -> MISO path contribute to the limit: at 25 MHz this chain amounts
to approximately 14.035 ns, to which the 3 ns external budget is added, out
of 20 ns available.

Conclusion: 25 MHz full duplex is a well-motivated first test target based
on the exploratory STA; approximately 29 MHz is the estimated threshold of
this implementation/budget, not a limit of the FPGA family. 50 MHz, and then
80-100 MHz for writes, are targets to verify after integration, clock/I/O
optimization and hardware testing. Slower status reads can keep MISO from
limiting pixel upload speed.

## Next write-only review — September 16, 2026

The proposal in the last paragraph has been implemented as `BE`/`BF`. `BE`
uses TX-only DMA and does not sample MISO; `BF` reads the result and CRC at
1.171875 MHz. `BD` full-duplex remains available. A full frame takes 226 ms
at 12.5 MHz and 186 ms at 18.75 MHz, with 1 and 5 retries recovered
respectively.

At 25 MHz the frame is reconstructed thanks to retry, but 46 of the 272
lines need it (7 overflows, 39 incomplete packets), and this is not a
qualified result. This confirms that the MISO return path has effectively
been removed from the heavy traffic, but the next observed limit is
SCK/queuing, not the internal STA at 122 MHz.

The extended test at 18.75 MHz completed 48 frames, 13,056 lines, in
10,641 ms with 210 retries, all overflow `E2`, and no busy, bad-header,
CRC-incorrect or incomplete-packet errors. The frequency search stopped
before a hardware load: 21.875 MHz fails SPI STA (Fmax approx. 20.763 MHz),
20.3125 MHz failed on a 0.445 ns MOSI path and 19.375 MHz had a PSRAM
placement regression of 0.343 ns. The deployed configuration therefore
remains 18.75 MHz `MEDIUM`, with the MISO constraint conservatively verified
at the same frequency even though the actual reads happen more slowly.

## RGB565 bandwidth 480 x 272

Frame = 261120 bytes. Ideal values, without headers, pauses, rendering or waiting:

| SCK MHz | MB/s decimal | ms/frame | full frames/s |
|---:|---:|---:|---:|
|25|3.125|83.56|11.97|
|40|5.000|52.22|19.15|
|50|6.250|41.78|23.94|
|80|10.000|26.11|38.30|
|100|12.500|20.89|47.87|

30 full frames/s requires at least 62.6688 Mbit/s; 60 requires 125.3376
Mbit/s. Partial LVGL updates reduce the data transferred. The panel scan
frequency is independent of these values.

## Proposed architecture for DMA

- Short header (opcode, coordinates, length, sequence), contiguous payload,
  optional final CRC. No additional per-pixel or per-byte flags.
- SPI remains 8-bit: DMA sends an entire buffer without per-byte
  intervention. Define the RGB565 byte order in the protocol, even if
  little-endian, to avoid swapping.
- Two LVGL draw buffers; DMA buffer in SRAM accessible to DMA1/2, not DTCM;
  clean the D-cache on TX for 32-byte line-aligned regions, or use a
  non-cacheable MPU region.
- Ensure there is space for the block before starting DMA (credits, or a
  READY signal external to SPI). Do not assume that a low READY will
  automatically abort an already-started DMA.
- Asynchronous RX FIFO and a burst PSRAM writer with scan-out priority. Size
  the FIFO for the maximum stall time and for the allowed burst size;
  average speed alone is not enough. At 100 MHz, 4 KiB absorbs approximately
  328 us of stall if initially empty; this is an example, not a verified
  sizing.
- Keep CS low until the actual end of the SPI transaction (EOT), not just
  the end of DMA. Handle RX even during TX if full-duplex is kept.
- Return the buffer to LVGL only when the driver no longer uses it; PSRAM
  writes may complete after SPI reception finishes and require a fence.

FIFO/CDC, parser, arbiter and concurrent-display PSRAM bandwidth
measurements are still missing. Before promising a maximum frequency:
integrate these blocks, constrain real I/O and clocks, then verify long DMA
transfers with sequences/CRCs and the display active.
