#ifndef SPI_DIAG_CONFIG_H
#define SPI_DIAG_CONFIG_H
// Set by diagnose-hardware.ps1; mode must match the FPGA build.
#define SPI_DIAG_MATRIX 0
#define SPI_DIAG_MODE 0
#define SPI_DIAG_ROUNDS 8
// Eco di verifica dopo SPI_Setup(). Ogni round sono 5 trasferimenti e 4374 byte,
// circa 44 ms a 9,375 MHz, e la demo del testo non parte finche' non e' finito.
// Un round basta a dimostrare che il collegamento eco funziona davvero prima di
// disegnare; test-hardware.ps1 rilegge questa costante e adatta le attese da
// solo. Per -RequireStress servono pero' oltre 1.000.000 di byte controllati,
// cioe' almeno 229 round: portarlo a 240 prima di quella qualifica.
#define SPI_SELFTEST_ROUNDS 240
// Prova GPIO lenta su MISO, tre configurazioni di pull. E' lo strumento che
// distingue una linea flottante da una tenuta alta da una FPGA non configurata,
// ma costa circa 800 ms perche' procede un bit alla volta con HAL_Delay(1).
// Tenerla spenta all'avvio normale e accenderla per diagnosticare o per
// test-hardware.ps1, che ne pretende l'esito.
#define SPI_GPIO_PROBE 1
// Opt in to destructive on-screen demo/stress drawing at boot.
#define LCD_BOOT_TESTS 1
// CPU-rendered reference and FPGA/User-Flash rendered demo are independent.
#define LCD_TEXT_DEMO 0
#define LCD_FPGA_TEXT_DEMO 1
#define LCD_SCROLL_DEMO 1
// Full-screen B7 versus BD comparison. Destructive like LCD_BOOT_TESTS: it
// paints the whole screen twice and takes roughly half a second, so it is
// opt-in. Read g_lcd_bench_* over SWD afterwards.
#define LCD_STREAM_BENCH 1
// Linea di reset FPGA_RST_N (PB1 -> IO29) montata su questa scheda?
// 1: all'avvio la MCU resetta la FPGA e pretende la prova che il reset sia
//    arrivato; senza prova la FPGA non viene usata.
// 0: nessuna linea. Non si resetta niente e non si dimostra niente, ma si
//    aspetta comunque che la FPGA sia davvero pronta (calibrazione PSRAM e
//    riempimento iniziale) invece di fidarsi di un ritardo fisso.
// La FPGA non ha bisogno della linea: IO29 ha la pull-up e senza filo sta a riposo.
#define FPGA_RESET_LINE 1
#endif
