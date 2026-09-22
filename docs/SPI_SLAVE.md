# SPI slave for STM32

`src/SpiSlave.sv` implements SPI mode 0 (CPOL=0, CPHA=0), full duplex,
8-bit, MSB first, CS active low. The module is framebuffer-independent and
is shared by SpiFramebuffer for graphics and by SpiDiagnostic for
self-test. The graphics connection first passed qualification at 25 MHz
with GPIO drive MEDIUM; see [SPI_FRAMEBUFFER.md](SPI_FRAMEBUFFER.md) for
results and limits. It transports bytes only: it does not interpret
commands, data, or protocol flags, and it needs no D/C pin — any
command/data distinction is encoded in the bytes by the higher-level
protocol.

## Parallel interface

All parallel signals belong to the `spi_sck` domain.

| Signal | Contract |
|---|---|
| `rx_push` | Combinational write-enable, asserted on the SCK rising edge that captures the eighth bit |
| `rx_data[7:0]` | Full byte, valid on the same edge as `rx_push` |
| `tx_data[7:0]` | Head of a show-ahead source, such as an asynchronous FIFO |
| `tx_valid` | The source has a byte ready on `tx_data` |
| `tx_take` | Combinational read-enable: consumes the byte on the SCK rising edge that samples the first bit |
| `spi_miso` | Value driven onto the MISO pin |
| `spi_miso_oe` | Enables the MISO output driver; low during reset or while CS is high |

Conceptual example of the receiving side:

```systemverilog
always @(posedge spi_sck) begin
    if (rx_push) begin
        // Write to the FIFO: 8-bit data is rx_data.
        // A real FIFO must also manage pointers and full/empty.
    end
end
```

`rx_push` is not a registered notification to be sampled on the PSRAM
clock or on a later SCK edge. Use it as the FIFO write-enable on that same
edge; this is also what captures the last byte when the master stops
generating clocks immediately afterward. Outside the qualifying edge,
`rx_data` does not hold a stable value.

The TX source must present the first byte before CS falls and hold it
until `tx_take`. For subsequent bytes, data and validity must be stable
from the falling edge that closes the previous byte to the first rising
edge of the new byte. Do not change availability or data during this
window. After `tx_take` the source can advance: the current byte is
latched internally. If `tx_valid=0`, `IDLE_BYTE` (default FF) is
transmitted without being consumed. A transaction aborted after the first
bit has already consumed the TX byte: there is no rollback. A response to
a received command requires dummy bytes, or a subsequent transaction and
an availability rule yet to be defined.

## First byte fixed and MISO output

The default `FIXED_FIRST_BYTE=0` preserves the generic show-ahead
contract. With `FIXED_FIRST_BYTE=1`, the first byte of each transaction
must be known before synthesis and match `FIRST_BYTE` (default A5). The
wrapper must also present it on `tx_data` with `tx_valid=1` at the first
`tx_take`. The TX register initializes to `FIRST_BYTE` and MISO is driven
directly from its bit 7: this eliminates the `tx_started` selector and the
active-byte mux entirely. Output disable is still guaranteed by
`spi_miso_oe` at the TOP level. With the slave deselected, the internal
value of `spi_miso` is not significant.

SpiFramebuffer enables this option, as it always starts with A5.
SpiDiagnostic retains the generic default, and was previously qualified
at 12.5 MHz. Do not use the parameter for a FIFO whose first byte can
vary.

## Slave Select and resync

`spi_cs_n` is the Slave Select (SS, also called CS; NSS in STM32). The
suffix `_n` indicates that it is active low:

- SS low: bytes are exchanged, including consecutive ones within the same
  transaction.
- SS high: disables MISO and clears the bit counter without requiring
  further clocking. At the next selection, the first rising edge captures
  bit 7 of a new byte. A partial RX byte is discarded.

The master can then resynchronize SPI by bringing SS high, driving SCK
low before the next selection, and starting a new transaction. This
resets the bit counter, but it neither detects errors nor cancels
complete bytes already delivered. Any parser-level recovery requires
rules of its own in the protocol: the byte queue alone does not preserve
SS transaction boundaries.

## Clock, reset and integration

- MOSI is sampled on rising edges; MISO updates on falling edges. The
  first MSB is available before the first clock.
- CS high asynchronously resets the serializer state, discarding any
  incomplete RX byte. The global reset `rst_n` is active low.
- SCK must be low at selection time. Respect setup/hold and
  recovery/removal timing between reset/CS release and the first clock;
  release reset while CS is high.
- Do not reset the downstream FIFO on every CS: complete bytes must
  remain queued.
- For high-impedance MISO, use this at TOP level:

```systemverilog
assign SPI_MISO = spi_miso_oe ? spi_miso : 1'bz;
```

- Add asynchronous FIFOs to cross the SCK/PSRAM domain. Do not connect
  `rx_push`, `tx_take`, or the data bus directly to logic in another
  clock domain.
- The module implements no READY, overflow, or backpressure signaling.
  The upper level must guarantee RX space for the authorized block and
  report errors itself.
- TX FIFOs synchronized to SCK may take several clocks to update their
  empty flag after a write from the other domain. Define a
  handshake/preload sequence before expecting a response: do not assume
  data is available while SCK is stopped.
- Add pin, SCK clock, and I/O delay constraints at integration time, and
  check the paths between opposite edges (half period) as well.

CubeMX: SPI master, full duplex, 8-bit, MSB first, CPOL low, CPHA 1 edge,
NSS software, NSS pulse and CRC disabled. CS is a GPIO; no D/C pin is
needed. Starting point 1 MHz; the maximum frequency has not yet been
qualified with place-and-route or hardware measurements. Testbench
frequencies are not a timing certification.

## Check

```powershell
.\sim\run_spi_sim.ps1
```

The testbench checks full duplex operation, first-MSB visibility, TX
source progress, consecutive bytes and pauses with CS low, idle TX,
activity while CS is high, abort after 1..7 bits, last byte without extra
clocks, reset mid-byte, and 256 pseudorandom byte pairs with variable SCK
periods. Timeouts and mismatches produce an error; the runner looks for
the PASS marker. Log in `sim/build`.
