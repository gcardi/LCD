#ifndef SPI_DIAG_CONFIG_H
#define SPI_DIAG_CONFIG_H
// Set by diagnose-hardware.ps1; mode must match the FPGA build.
#define SPI_DIAG_MATRIX 0
#define SPI_DIAG_MODE 0
#define SPI_DIAG_ROUNDS 8
// Verification echo after SPI_Setup(). Each round is 5 transfers and 4,374 bytes,
// about 44 ms at 9.375 MHz; the text demo starts only after it finishes.
// One round proves that the echo link works before drawing; test-hardware.ps1
// reads this constant and adjusts its timeouts. -RequireStress needs more than
// 1,000,000 checked bytes, or at least 229 rounds: set it to 240 first.
#define SPI_SELFTEST_ROUNDS 240
// Slow MISO GPIO test with three pull configurations. It distinguishes a
// floating line, a line held high, and an unconfigured FPGA, but takes about
// 800 ms because it advances one bit at a time with HAL_Delay(1). Keep it off
// during normal boot; enable it for diagnosis or test-hardware.ps1.
#define SPI_GPIO_PROBE 1
// Opt in to destructive on-screen demo/stress drawing at boot.
#define LCD_BOOT_TESTS 0
// CPU-rendered reference and FPGA/User-Flash rendered demo are independent.
#define LCD_TEXT_DEMO 0
#define LCD_FPGA_TEXT_DEMO 0
#define LCD_SCROLL_DEMO 0
// Full-screen B7 versus BD comparison. Destructive like LCD_BOOT_TESTS: it
// paints the whole screen twice and takes roughly half a second, so it is
// opt-in. Read g_lcd_bench_* over SWD afterwards.
#define LCD_STREAM_BENCH 0
// Is the FPGA_RST_N reset line (PB1 -> IO29) fitted on this board?
// 1: at boot, the MCU resets the FPGA and requires proof that reset arrived;
//    without that proof, it does not use the FPGA.
// 0: no reset line. Nothing is reset or proved, but the firmware still waits for
//    the FPGA to be ready (PSRAM calibration and initial fill), rather than using
//    a fixed delay. The FPGA does not require this line: IO29 has a pull-up and
//    remains idle when left unconnected.
#define FPGA_RESET_LINE 1
#endif
