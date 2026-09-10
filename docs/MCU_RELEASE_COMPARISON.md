# Confronto MCU Debug / Release — 2026-09-10

Stessi sorgenti STM32H743 e stessa FPGA, SPI 12.5 MHz. Debug `-O0 -g3`,
Release `-Os -g0`. Dimensioni del firmware con configurazione di avvio normale:

| Occupazione (byte) | Debug | Release |
|---|---:|---:|
| Flash (`text + data`) | 39740 | 20316 |
| RAM statica (`data + bss`) | 10312 | 10312 |

Riduzione flash: 19424 byte (48.88%). La dimensione del file ELF, che include
metadati e simboli, non viene usata come misura della flash.

Collaudo temporaneamente abilitato con `SPI_SELFTEST_ROUNDS=240`,
`SPI_GPIO_PROBE=1`, `LCD_BOOT_TESTS=1`; demo testo FPGA attiva.
Tre esecuzioni per preset, con upload iniziale verificato e reset fra le prove.

| Tempo firmware (ms) | Debug | Release | Riduzione |
|---|---:|---:|---:|
| Eco SPI, 1200 trasferimenti / 1049760 byte | 8712 | 8472 | 2.75% |
| Grafica, 512 rettangoli / 354528 pixel (media) | 2257 | 1889.3 | 16.29% |

Tutte e sei le prove superate, senza mismatch o errori HAL/LCD. Eco identica
nelle tre ripetizioni di ciascun preset; grafica Debug: 2257/2257/2257 ms,
Release: 1888/1888/1892 ms.

L'eco comprende attese `HAL_Delay`: non misura la banda SPI pura.
Il clock SPI resta invariato. Il test grafico misura generazione e invio dei
rettangoli, non il frame rate del pannello. Risoluzione temporale: 1 ms.
I controlli software verificano eco, GPIO, stati demo/testo, contatori grafici
e assenza di errori HAL/LCD; non sostituiscono l'osservazione visiva del display.

Il runner `stm32/WeAct_H743_SPI/test-hardware.ps1` ora accetta `-Preset Release`
per leggere i simboli ELF corretti e salvare i risultati nella directory del preset.
Log e JSON delle singole prove: `stm32/WeAct_H743_SPI/build/benchmark-*`.
Impostazioni di collaudo ripristinate; lasciata sulla MCU la Release normale,
con upload verificato. Controllo SWD finale superato: eco su 4374 byte,
testo FPGA completato, nessun errore HAL/LCD. Risultato in
`stm32/WeAct_H743_SPI/build/Release/final-normal-result.json`.
Il preset predefinito di `build.ps1` resta Debug: per le prossime compilazioni
Release specificare `-Preset Release`.
