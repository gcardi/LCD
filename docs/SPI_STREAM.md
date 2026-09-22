# `BD` / `BE`, stream write one line

Implemented September 16, 2026. `BD` is the original full-duplex
protocol; `BE` sends the same packet as a TX-only stream and reads the
result later with `BF`. `B7` and `BD` remain unchanged and supported as
fallbacks.

The firmware currently uses `BE/BF`: 18.75 MHz for pixels, 9.375 MHz for
ordinary commands, and 1.171875 MHz for status. MISO is not sampled
during `BE`, and the FPGA puts it in high impedance from the second byte
onward; the first byte necessarily precedes decoding of the opcode, but
the master ignores it anyway.

## Why

`B7` spends 41 bytes per 16 pixels and needs a separate SPI transaction
for every burst. A full frame is **8160 packets**, and up to commit
`2bd43c5`, just as many were needed just to query availability. Every
transaction costs more than the bytes on the wire: the firmware does two
`memcpy` calls, three cache-maintenance operations with a barrier, and a
full HAL setup with two DMA streams.

`BD` transfers **one row per transaction**: header, contiguous payload,
CRC over the payload, commit. For a full line that's 978 bytes in a
single DMA, versus thirty 41-byte packets plus thirty rounds of
handshaking.

## Format

All transactions start with the response `A5`. Big-endian bytes.

| TX Index | Contents | RX |
|---:|---|---|
| 0 | `BD` | `A5` |
| 1 | dummy | `C3` available / `00` busy |
| 2–3 | `y`, line 0…271 | echo of the previous byte |
| 4 | `group_start`, first group of 16 pixels, 0…29 | echo |
| 5 | `group_count`, number of groups, 1…30 | echo |
| 6–7 | `head_mask`, valid pixels of the first group | echo |
| 8–9 | `tail_mask`, valid pixels of the last group | echo |
| 10–11 | CRC16-CCITT on bytes 2–9 | echo |
| 12 | commit header `A6` | echo |
| 13 | dummy | `AC` header accepted / `E1` rejected |
| 14 … 13+32·group_count | payload, integer groups of 16 pixels RGB565, **low byte first** | `C3` healthy / `00` overflow |
| +2 | CRC16-CCITT on payload | echo |
| +1 | commit `A6` | echo |
| +1 | dummy | `AC` line written intact / `E1` otherwise |

CRC16-CCITT, polynomial `1021`, initial `FFFF`, reinitialized between
header and payload. Total length `32·group_count + 18`, maximum 978
bytes.

## Write-only variant `BE` and status `BF`

`BE` has exactly the same TX bytes as `BD`. Inline responses are no
longer part of the contract: the STM32 uses `HAL_SPI_Transmit_DMA`, so
SPI2 runs in simplex TX and never arms the DMA RX. When the transfer
finishes, the firmware raises CS, changes the prescaler with SPI
disabled, and queries the mailbox with `BF`.

`BF` requires nine TX bytes (`BF` followed by eight dummies) and
responds:

| RX Index | Contents |
|---:|---|
| 0 | `A5` |
| 1 | `D3`, stream state signature |
| 2 | version, currently `01` |
| 3 | bit 0 valid status, bit 1 endpoint ready for new line |
| 4–5 | line number `y` of the last `BE` |
| 6 | result |
| 7–8 | CRC16-CCITT on RX bytes 1–6 |

Results: `AC` success, `00` row rejected because the queue was busy, `E1`
invalid header, `E2` overflow during the payload, `E3` bad payload
CRC/commit, `FE` packet started but not completed. `00`, `E2`, `E3`, and
`FE` are all recoverable by resending the same line; `E1` signals a
protocol error. The firmware also waits for the ready bit before
proceeding, so it does not confuse CRC validation with the draining of
the last entry into PSRAM.

The mailbox identifies the row, not a global frame. This granularity
keeps recovery cheap and prevents `PRESENT` until every line has been
confirmed. The cost is a slow read for each line. A future mailbox for
blocks or frames could further reduce the overhead, after increasing the
queue's tail depth.

### Why whole groups and not pixels

The payload always covers **16-pixel-aligned groups**: the host pads the
ragged ends and describes them with the two masks, which the FPGA
applies to the first and last groups. When the row fits in a single
group, both masks apply together.

The first version accepted `x` and `count` in pixels and reconstructed
the masks inside the FPGA, which is more convenient for the host but
requires a variable insertion mux over 256 bits. Measured cost: **+864
LUTs, 61% to 71% of the die, and 15 setup endpoints violated** on
`FramebufferController` routes that nothing had touched — placement
pressure on a path already at its limit. With whole groups, the pixel
path is the **same byte shift register** `B7` already uses, shared
because the two opcodes are never selected together, so the cost becomes
essentially negligible.

The price is at most 30 pixels of padding per line, i.e. 60 bytes. On a
full line it's zero; on a partial LVGL area it's a negligible fraction of
what `B7` was wasting anyway.

A header is rejected if `y ≥ 272`, `group_start ≥ 30`, `group_count = 0`,
`group_start + group_count > 30`, either mask is zero, or the CRC does
not match. A rejected header leaves the rest of the transaction **inert**:
no write, no state change.

## Consistency and recovery

Like `B7`, and unlike `B8`/`B9`/`BC`, **`BD` is not atomic**. The
16-pixel groups are written to PSRAM as they arrive, so:

- the final CRC **reports** the error, it does not cancel the write: a
  corrupt line remains half-written;
- recovery means resending the same line, an idempotent operation;
- with double buffering, the line lands in the back buffer, so nothing
  wrong ever reaches the panel: just skip `PRESENT` and repeat.

SCK cannot be stalled by a slave. If the queue to PSRAM is still busy at
a group boundary, the endpoint **latches an overflow**, stops writing for
the rest of the line, and reports it two ways: the status byte on the
payload goes from `C3` to `00`, and the final commit responds `E1`. Here
too, the fix is to resend the line.

The extended measurement at 18.75 MHz showed that overflow does still
happen: 210 retries out of 13,056 lines, all `E2`. Average PSRAM
throughput is not the problem; a brief stall at a group boundary is
enough to saturate the queue's tail entry. Recovery keeps the transfer
correct, but the next gain requires a deeper elastic buffer between the
SCK domain and the PSRAM domain — `FramebufferFifo` is already parametric
in width and depth, ready for that.

## Implementation

All the work happens in the SCK domain of
[SpiFramebuffer.sv](../src/SpiFramebuffer.sv), reusing the `B7` staging
registers: the two opcodes are never selected together, so the 256-bit
burst register and its mask cost no extra resources. The current group's
address starts at `y·480 + group_start·16`, computed as `(y<<9) − (y<<5)`
to avoid a multiplier, and advances by 16 pixels for each completed
group.

The rest of the FPGA is unchanged: `BD` produces exactly the same
`address`/`pixels`/`mask` triad the controller already consumes for `B7`,
so `FramebufferController` and `TOP` are untouched.

## STM32 API

```c
int LCD_WriteRectStream(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                        const uint16_t *pixels);
```

Same arguments and the same contract as `LCD_WriteRect`, one transaction
per line. It automatically retries a rejected row, up to one second
total, counting attempts in `g_lcd_profile.retries`.

The profile is readable over SWD and separates packet assembly, the SPI
exchange, and the final barrier:

```c
typedef struct { uint32_t assemble, exchange, fence, packets, retries; } LcdProfile;
extern volatile LcdProfile g_lcd_profile;
void LCD_ProfileReset(void);
```

`LCD_STREAM_BENCH` in `spi_diag_config.h` enables `LCD_StreamBench_Run()`,
which paints the whole screen along both paths and leaves
`g_lcd_bench_b7_ms`, `g_lcd_bench_bd_ms`, `g_lcd_bench_b7`, and
`g_lcd_bench_bd` available for direct comparison. It is destructive, so
it is opt-in like `LCD_BOOT_TESTS`.

## Bench measurement, 16 September 2026

Full screen, line by line, both paths, `LCD_StreamBench_Run()` at
12.5 MHz, MCU Release build. DWT cycles converted at 480 MHz.

| | assemble | exchange | fence | total |
|---|---:|---:|---:|---:|
| `B7`, 8160 transactions | 11.5ms | 334.5 ms | 4.3ms | **383 ms** |
| `BD`, 272 transactions | 38.8ms | 181.7 ms | 4.3ms | **225 ms** |

**1.71x on the full screen.** Transport alone gains 1.84x: 334.5 →
181.7 ms, against 170 ms of pure wire time. The fixed per-transaction
cost, worth about 15 us for each `B7` packet, has practically
disappeared.

### Try `BE/BF`

On the same hardware, firmware release and GPIO `MEDIUM`:

| Pixel SCK | Status SCK | Frame time `BE/BF` | Retries | Outcome |
|---:|---:|---:|---:|---|
| 12.5 MHz | 1.5625 MHz | 226 ms | 1 | PASS, no LCD error |
| 18.75 MHz | 1.171875 MHz | 186 ms | 5 | PASS, 5 overflows recovered |
| 25 MHz | 1.5625 MHz | 175 ms | 46 | frame completed, unqualified |

In that second run, of the 46 retries, 7 were single-entry queue
overflows and 39 were incomplete packets; no payload had a bad CRC. A
repeat with GPIO slew HIGH got worse, timing out entirely (every attempt
incomplete), so the configuration was reverted to MEDIUM. The result
shows that removing MISO from the transfer works and makes errors
recoverable, but it does not qualify 25 MHz: generic SCK routing as
reported by Gowin, signal integrity, and the PSRAM queue depth all still
need work.

Extended qualification of the 18.75 MHz configuration transferred 48
frames, 13,056 lines, in 10,641 ms: 210 retries, all `E2` overflows, and
zero instances of busy, bad header, bad CRC, or incomplete packets. The
average of about 221.7 ms/frame includes overflow recovery. Higher
intermediate frequencies were never loaded onto the hardware: 21.875 MHz
failed SPI static timing analysis (Fmax about 20.763 MHz), 20.3125 MHz
failed a MOSI path by 0.445 ns, and 19.375 MHz produced a placement
regression of 0.343 ns on the PSRAM path. 18.75 MHz remains the deployed
and qualified configuration.

Two lessons worth not repeating:

- the back-of-envelope estimate was **~170 ms**, off by 80 ms, because it
  did not account for the software CRC on the payload;
- the first measurement put `BD` at 374 ms against `B7`'s 385 ms, a
  meager 3% — the bit-by-bit CRC cost **334 cycles per byte**, and over
  960 bytes of payload per line it ate up the entire 150 ms the transport
  had gained. Replacing it with a 256-entry table (512 bytes of flash)
  dropped assembly from 183.4 to 61.4 ms.

The payload is then built as **three contiguous blocks** instead of a
per-pixel decision: `memset` the header, `memcpy` the source line — RGB565
low byte first, already the same layout a `uint16_t` has in memory — and
`memset` the trailing padding, followed by a single CRC pass over the
buffer. Assembly dropped from 61.4 to 38.8 ms.

38.8 ms, 143 us per line, **~70 cycles per byte**, remain for one table
lookup and one XOR. That figure stays unexplained: the table was moved to
RAM to rule out flash latency on a chain of dependent loads, and
**nothing changed** (226 ms vs. 225), so `const` came back. Buffer and
table are in DTCM either way.

## FreeRTOS asynchronous flush, September 17, 2026

Asynchronous flush is now implemented. The HAL callback uses
`vTaskNotifyGiveFromISR()`; `DisplayTask` waits with `ulTaskNotifyTake()`.
`SPI_Transmit_DMA_Begin()` copies and starts the transfer, while
`SPI_Transmit_DMA_Wait()` closes it. Double-buffered row packets let the
next row be assembled while the DMA copy of the current one is already on
the wire.

The benchmark works in eight-line strips to prime the pipeline without
allocating an entire frame on the MCU. Release qualification after a full
reset:

| Path | Packets | Frame time | Notes |
|---|---:|---:|---|
| `B7` | 8160 | **528 ms** | full duplex reference |
| `BE/BF` asynchronous | 272 | **172-174 ms** | 2-5 retries recovered |

238 lines were prepared between `Begin` and `Wait`. The whole boot
produced 42,462 notifications for as many waits, with zero timeouts in
the last test. Compared to the 225 ms of the previous synchronous
`BE/BF`, the gain is 53 ms, about 24%; compared to `B7`, the frame is
3.07 times faster.

## Check

`sim/tb_spi_framebuffer.sv` covers, in addition to everything already
there:

- the five reasons for rejecting the header, checking that none of them
  write anything;
- an aligned group;
- a line unaligned at both head and tail, including padding, with
  neighboring pixels left intact;
- a full 480-pixel line, i.e. every group boundary;
- a bad payload CRC, reporting `E1` **without** canceling the writes
  already made;
- a forced overflow that blocks the consumer, with the status byte
  switching to `00`, commit `E1`, the first group retained, and nothing
  written beyond it;
- recovery on the next transaction.

```powershell
.\sim\run_spi_sim.ps1 -TimeoutSeconds 600
.\build.ps1
```
