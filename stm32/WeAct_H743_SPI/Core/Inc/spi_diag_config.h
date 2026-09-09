#ifndef SPI_DIAG_CONFIG_H
#define SPI_DIAG_CONFIG_H
// Set by diagnose-hardware.ps1; mode must match the FPGA build.
#define SPI_DIAG_MATRIX 0
#define SPI_DIAG_MODE 0
#define SPI_DIAG_ROUNDS 8
// Eco di qualifica. Ogni round sono 5 trasferimenti e 4374 byte, circa 37 ms
// a 12.5 MHz, e la demo del testo non parte finche' non e' finito. Otto round
// bastano a qualificare il collegamento all'avvio; test-hardware.ps1 rilegge
// questa costante e adatta le attese da solo. Per -RequireStress serve pero'
// superare 1.000.000 di byte controllati, cioe' almeno 229 round: rialzalo a
// 240 prima di quella qualifica.
#define SPI_SELFTEST_ROUNDS 8
// Opt in to destructive on-screen demo/stress drawing at boot.
#define LCD_BOOT_TESTS 0
// CPU-rendered reference and FPGA/User-Flash rendered demo are independent.
#define LCD_TEXT_DEMO 0
#define LCD_FPGA_TEXT_DEMO 1
#endif
