# SPI diagnosis at 12.5 MHz
## Result

The link moves to 12.5 MHz with STM32 GPIO set to `MEDIUM`. The wiring was
not modified. `HIGH` and `VERY_HIGH` edge settings produce repeatable
errors. The echo passes at 6.25 MHz, but a subsequent CRC test found a block
with an incorrect status even at 6.25 MHz `VERY_HIGH`: use `MEDIUM`.

The long echo test uses three repetitions of 400 transactions by default,
with lengths 1, 2, 17, 257, 4097 and a variable deterministic pattern.

| GPIO STM32 | Echo errors at 6.25 MHz / 1049760 bytes | Echo errors at 12.5 MHz / 1049760 bytes |
|---|---:|---:|
| VERY_HIGH | 0 | 33664 |
| HIGH | 0 | 21970 |
| MEDIUM | 0 | 0 |

Separate tests at 12.5 MHz, three repetitions per setting:

| Try | VERY_HIGH | HIGH | MEDIUM |
|---|---|---|---|
| Echo MOSI -> MISO, 104976 bytes | errors | errors | 0 errors |
| Standalone FPGA sequence, 104976 bytes | errors/restarts | errors/restarts | 0 errors |
| MOSI, 24 blocks of 4096 bytes with CRC slow reread | bad check | bad check | all 24 CRCs corrected |

All cases completed without HAL errors. The CRC test's total byte count
refers to 98304 bytes of payload; on the return path, only 96 bytes of
status appear, not the entire payload. Each FPGA variant passes gate timing
before being loaded. An earlier byte-parallel CRC implementation was
rejected by the timing gate over a PSRAM calibration path at -2.596 ns and
was never loaded; the bit-serial version passes the gate without any
threshold changes.

## Interpretation and limits

`GPIO_SPEED_FREQ_*` adjusts edge slew rate, not SPI frequency. Changing just
this setting during the matrix test drastically changes the outcome. The
result supports the hypothesis of a signal-integrity problem; it does not
demonstrate which wire or circuit is generating the noise.

In the first archived echo errors, the received byte is A5 while its
neighbors are correct. The autonomous (MISO) sequence restarts from A5, EA,
75...: this is consistent with a reinitialization of the slave state. A
dedicated SCK/CS/reset measurement is needed to distinguish electrical noise
from internal RTL behavior. The autonomous sequence removes the dependency
on MOSI data, but it still uses SCK, CS and the shared reset: it is not an
isolated measurement of the MISO wire alone.

The CRC is CRC-16/CCITT-FALSE (polynomial 1021, initial FFFF, MSB first, no
final reflection/XOR). The FPGA receives 4096 bytes and then responds C3,
CRC high byte, CRC low byte, 5A. The master keeps CS low and switches to
781250 Hz for the status read. An incorrect status response can also
indicate a loss of alignment, not just a bad MOSI bit. Simulations cover
both flows: the frequency switch while CS is low, and the abort of a
partial transaction.

Modes require distinct bitstreams: error counts across modes do not
directly compare the same physical implementation. The comparisons between
edge settings and frequencies within a single matrix run use the same
bitstream and firmware.

The first transaction after an FPGA load has a separate anomaly: the first
GPIO test reads `D2 BC` instead of `A5 3C`; without a preliminary GPIO test,
the first reading of the autonomous sequence at 6.25 MHz also received `D2`
instead of `A5`. The first CRC block at 6.25 MHz also failed; the following
ones pass. The fully operational tests do not yet qualify this initial
condition. No analog measurements, temperature variation or tests above
12.5 MHz were made. This is not a qualification of future framebuffer
writes.

## Reproduction and artifacts

From the project root:

```powershell
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode echo
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode miso
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode mosi
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode echo -Rounds 80
# Restore the normal echo test, fill out/upload both forms, and verify:
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -RestoreSelfTest
```

The runner sets `MODE` in both the TOP module and the C configuration,
enables the matrix, and constrains SCK to an 80 ns period before the build.
This configuration stays active until `-RestoreSelfTest` is requested; that
option restores normal echo mode. The normal test's frequency and edge
settings live in `spi.c` and the `probe_gpio` function. Mismatches are
recorded as diagnostic, non-fatal findings; timeouts, incomplete dumps, HAL
errors and illegal timing raise an exception. The normal runner refuses to
run with an active matrix configuration.

Each archive in `stm32/WeAct_H743_SPI/build/Debug/` contains result.json,
matrix.bin, the ELF, the bitstream, the timing report and artifact hashes:

- diagnostic-echo-20260909-105509: initial matrix, 8 rounds;
- diagnostic-miso-20260909-105616: autonomous sequence;
- diagnostic-mosi-20260909-105832: bit-serial CRC;
- diagnostic-echo-20260909-110023: long array, 80 rounds.

These archives are ignored by Git. Each case saves up to 16 errors with the
expected and received values, round, length, index and previous/next bytes;
the value 256 indicates a missing neighbor. Total counters are not limited
to the 16 archived events. RAM layout is verified with a static assert,
addresses are read from ELF symbols, and no SWD addresses are hardcoded in
the runner.

## Initialization after FPGA loading

Follow-up experiments with the same echo bitstream:

- FPGA + STM32 load, no added initialization: first GPIO test reads `D2 BC`;
- STM32 upload/reset only, FPGA already running: all GPIO tests correct;
- CS toggled low/high without clocking after FPGA load: anomaly unchanged;
- two slow SCK pulses with CS held high before the first transaction: all
  three GPIO tests correct, and DMA at 12.5 MHz `MEDIUM` without errors.

The firmware now executes these two pulses with the slave deselected, after
the initial 100 ms wait. This does not discard a data transaction: no slave
is selected during the two pulses. It is an initialization sequence
verified empirically; it does not constitute a definitive explanation of the
FPGA's internal startup behavior. The normal runner now also requires that
all three GPIO exchanges match the expected sequence.

Evidence: diagnose-final-cold.json, diagnose-final-warm.json,
diagnose-cs-init.json, diagnose-idle-clocks.json in build/Debug.

Re-checking with the added initialization:

- diagnostic-miso-20260909-110820: first transaction now succeeds; `MEDIUM`
  without errors at both frequencies, 104976 bytes per frequency;
- diagnostic-mosi-20260909-110856: first block fixed; all 24 blocks correct
  at `MEDIUM` for each frequency. `VERY_HIGH` at 6.25 MHz shows a freeze
  with four bad status bytes in the second repetition, so not all
  `VERY_HIGH` defects are limited to first boot or to 12.5 MHz.

The final normal test uses 12.5 MHz, `MEDIUM` edges, `MODE=0`, matrix
disabled. The normal check was repeated after reloading both boards.
