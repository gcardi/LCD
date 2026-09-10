#ifndef SPI_DIAG_CONFIG_H
#define SPI_DIAG_CONFIG_H
// Set by diagnose-hardware.ps1; mode must match the FPGA build.
#define SPI_DIAG_MATRIX 0
#define SPI_DIAG_MODE 0
#define SPI_DIAG_ROUNDS 8
// Eco di verifica dopo SPI_Setup(). Ogni round sono 5 trasferimenti e 4374 byte,
// circa 33 ms a 12.5 MHz, e la demo del testo non parte finche' non e' finito.
// Un round basta a dimostrare che il collegamento eco funziona davvero prima di
// disegnare; test-hardware.ps1 rilegge questa costante e adatta le attese da
// solo. Per -RequireStress servono pero' oltre 1.000.000 di byte controllati,
// cioe' almeno 229 round: portarlo a 240 prima di quella qualifica.
#define SPI_SELFTEST_ROUNDS 1
// Prova GPIO lenta su MISO, tre configurazioni di pull. E' lo strumento che
// distingue una linea flottante da una tenuta alta da una FPGA non configurata,
// ma costa circa 800 ms perche' procede un bit alla volta con HAL_Delay(1).
// Tenerla spenta all'avvio normale e accenderla per diagnosticare o per
// test-hardware.ps1, che ne pretende l'esito.
#define SPI_GPIO_PROBE 0
// Opt in to destructive on-screen demo/stress drawing at boot.
#define LCD_BOOT_TESTS 0
// CPU-rendered reference and FPGA/User-Flash rendered demo are independent.
#define LCD_TEXT_DEMO 0
#define LCD_FPGA_TEXT_DEMO 1
#endif
