# Prototype wiring

This diagram describes the wiring actually used by the firmware and FPGA
constraints. It is not a PCB schematic: Tang Nano `IO` numbers refer to chip
pins, not connector positions.

```mermaid
flowchart LR
    MCU["WeAct STM32H743<br/>SPI2 + I²C1"]
    FPGA["Tang Nano 9K<br/>GW1NR-9C + PSRAM"]
    LCD["RGB panel<br/>480 × 272"]
    TOUCH["Capacitive touch<br/>GT911"]
    GND(("Shared ground"))
    V33(("3.3 V"))
    R10K["10 kΩ<br/>external pull-up"]

    MCU -->|"PB13 / SPI2 SCK"| FPGA
    MCU -->|"PB15 / SPI2 MOSI"| FPGA
    FPGA -->|"SPI2 MISO / PB14"| MCU
    MCU -->|"PB12 / active-low CS"| FPGA
    FPGA -->|"IRQ_N / IO28 → PB0, EXTI0"| MCU
    MCU -->|"PB1, open-drain → RST_N / IO29"| FPGA
    V33 --- R10K --- FPGA

    FPGA -->|"RGB, pixel clock, and timing<br/>(local Tang Nano connection)"| LCD

    MCU -->|"PB8 / I²C1 SCL, 400 kHz"| TOUCH
    MCU <-->|"PB9 / I²C1 SDA, 400 kHz"| TOUCH
    V33 --- TOUCH
    GND --- MCU
    GND --- FPGA
    GND --- TOUCH
```

## Wired prototype

The annotated view identifies the four subsystems in the test setup. The RGB
display and touch panel connect locally to the Tang Nano, while the WeAct
talks to the FPGA and touch controller over SPI and I²C respectively.

![Annotated prototype view: display, Tang Nano, WeAct, and touch flex cable](assets/images/Prototype_02.jpg)

The display uses its own 40-pin RGB flex cable. The underside view makes clear
that there is no additional RGB wiring between the STM32 and the panel.

![Detail of the local Tang Nano to RGB-panel connection](assets/images/Prototype_03.jpg)

## Wiring table

| Function | STM32H743 | Tang Nano 9K | Notes |
|---|---|---|---|
| SPI clock | PB13, SPI2 SCK | IO36 | IO36 shares the microSD clock; leave the slot empty. |
| SPI MOSI | PB15, SPI2 MOSI | IO25 | MCU → FPGA. |
| SPI MISO | PB14, SPI2 MISO | IO26 | FPGA → MCU; FPGA output is tri-stated when CS is high. |
| SPI CS | PB12, GPIO | IO27 | Active low, driven by firmware. |
| PRESENT IRQ | PB0, EXTI0 | IO28 | Active low; remains low until the SPI ACK. |
| FPGA logic reset | PB1, open-drain | IO29 | External 10 kΩ pull-up to 3.3 V on the Tang Nano side. |
| Touch I²C clock | PB8, I²C1 SCL | CTP-SCL | 400 kHz buses. |
| Touch I²C data | PB9, I²C1 SDA | CTP-SDA | GT911 at 7-bit address `0x5D`. |
| Touch power | — | CTP-VCC | 3.3 V. |
| Ground | GND | GND / CTP-GND | Required between all boards. |

## Touch: intentionally unconnected lines

`CTP-INT` is not connected: the GT911 driver polls every 10 ms. In this
prototype `CTP-RST` is held high at 3.3 V and **must not** connect to
`FPGA_RST_N`. If touch reset or interrupt support is needed later, assign
dedicated STM32 GPIOs and update this diagram.

## Point-to-point wiring

The prototype is built on perfboard; point-to-point wires only implement the
signals listed in the table and the shared ground. The side view also shows the
touch flex-cable routing; the underneath documents the hand-built assembly and
does not introduce any additional connections.

![Side view of the prototype and touch flex cable](assets/images/Prototype_04.jpg)

![Underside view of the point-to-point perfboard wiring](assets/images/Prototype_06.jpg)

## Power and limits

The STM32 and Tang Nano can use separate USB power supplies; do not join their
5V or 3.3V rails. A shared ground is required. The display connects locally
to the Tang Nano and needs no RGB wires to the STM32, which sends only
commands and pixel data over SPI.

The Tang Nano reset button uses IO4 in the 1.8 V bank. MCU-controlled reset
therefore uses IO29, which belongs to a 3.3 V bank; it is a logical reset of
the FPGA/PSRAM, not a bitstream reconfiguration.
