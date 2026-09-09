#ifndef SPI_DIAG_CONFIG_H
#define SPI_DIAG_CONFIG_H
// Set by diagnose-hardware.ps1; mode must match the FPGA build.
#define SPI_DIAG_MATRIX 0
#define SPI_DIAG_MODE 0
#define SPI_DIAG_ROUNDS 8
#define SPI_SELFTEST_ROUNDS 240
// Opt in to destructive on-screen demo/stress drawing at boot.
#define LCD_BOOT_TESTS 0
// CPU-rendered reference and FPGA/User-Flash rendered demo are independent.
#define LCD_TEXT_DEMO 0
#define LCD_FPGA_TEXT_DEMO 1
#endif
