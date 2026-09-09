# Collaudo SPI - 2026-09-09

**Aggiornamento successivo:** la diagnosi dei fronti ha ottenuto PASS a
12.5 MHz con GPIO STM32 MEDIUM, inclusi 1049760 byte nel test eco lungo.
Configurazione corrente: prescaler 16, SDC 80 ns, GPIO MEDIUM. Vedere
[risultati diagnostici](SPI_DIAGNOSTIC_RESULTS.md). La tabella seguente
documenta la precedente salita con GPIO VERY_HIGH, non il limite attuale.

Dopo aver corretto un connettore invertito e riacceso le schede, il DMA
full duplex funziona. Ogni passo comprende simulazione, build FPGA con
periodo SCK aggiornato, gate timing, caricamento SRAM FPGA, upload e verifica
STM32 e confronto di 34992 byte in 40 transazioni (1/2/17/257/4097 byte).

| SCK MHz | Prescaler su 200 MHz | Mismatch | HAL | Timing FPGA |
|---:|---:|---:|---|---|
| 0.78125 | 256 | 0 | OK | PASS |
| 1.5625 | 128 | 0 | OK | PASS |
| 3.125 | 64 | 0 | OK | PASS |
| 6.25 | 32 | 0 | OK | PASS |
| 12.5 | 16 | 32 | OK | PASS |

A 12.5 MHz primo errore all'indice 153 di una transazione: atteso EB,
ricevuto A5. Non sono state tentate frequenze superiori. Configurazione
riportata a 6.25 MHz (vincolo 160 ns, budget I/O max 10 ns e MISO min -3 ns).
Il PASS del timing non qualifica integrita' dei segnali e cablaggio reali;
la causa degli errori a 12.5 MHz non e' ancora isolata.

Resta un'anomalia separata nel primo scambio GPIO lento: no-pull restituisce
`D2 BC 4D 5E 6F 80 91 A2`, mentre pull-up e pull-down restituiscono entrambi
`A5 3C 4D 5E 6F 80 91 A2`. Spostare il campionamento dopo l'attesa sul clock
alto non l'ha risolta. Il PASS del runner riguarda il DMA, non la prova GPIO.

Log e JSON per frequenza sono in `stm32/WeAct_H743_SPI/build/Debug/`
(`sweep-<Hz>.log`, `hardware-<Hz>.json`, ignorati da Git).
Sono prove brevi: 6.25 MHz e' l'ultimo passo superato, non una qualifica
di affidabilita' prolungata o della futura scrittura del framebuffer.

# Valutazione preliminare SPI - 2026-09-08

Questa e' una stima di progetto, non una qualifica hardware. RTL funzionale
invariato. Nessun bitstream di prova e' stato caricato sulla scheda.

## STM32H743

Il datasheet DS12110 rev 11 distingue le revisioni del silicio. A 3.3 V,
SPI1/2/3 master ha un massimo di 100 MHz per rev V (tabella 195), mentre
la tabella 96 relativa a rev Y riporta 133 MHz. Non usare il dato commerciale
150 MHz come limite SPI2 master. Verificare REV_ID tramite debugger:
0x2003 = V, 0x1003 = Y (RM0433).

Fonti:
- https://www.st.com/resource/en/datasheet/stm32h743vi.pdf
- https://www.st.com/resource/en/reference_manual/rm0433-stm32h742-stm32h743-753-and-stm32h750-value-line-advanced-armbased-32bit-mcus-stmicroelectronics.pdf

## Esperimento Gowin sul modulo isolato

Tool V1.9.12.01, GW1NR-LV9QN88PC6/I5, setup Slow 1.14 V 85 C C6/I5,
hold Fast 1.26 V 0 C. Top SpiSlave, SCK pin 36, MOSI 25, MISO 26 (8 mA),
CS 27. Gli altri port paralleli sono esposti come I/O assegnati automaticamente:
non rappresentano il futuro posizionamento con FIFO, parser e LCD.

Progetto esplorativo e log in `sim/build/spi_timing/` (output ignorato da Git).

| Prova | Risultato |
|---|---|
| Solo create_clock a 50 MHz | Fmax riportata 122.784 MHz; solo timing interno |
| Budget I/O a 50 MHz | MISO setup slack -6.886 ns; Fmax 29.611 MHz |
| Budget I/O a 25 MHz | MISO setup slack +2.965 ns; Fmax 29.351 MHz; zero violazioni setup/hold |

Report: `internal_only_50MHz.tr`, `io_budget_50MHz.tr` e
`impl/pnr/probe.tr` (ultima prova a 25 MHz).

Budget esplorativo: MOSI input delay max 3 ns, min 0, rispetto al fronte
di discesa; MISO output delay max 3 ns rispetto al fronte di salita. Per
la prova a 25 MHz il min MISO e' -3 ns (hold STM32 rev V); la precedente
prova a 50 MHz aveva min -1 ns e serve solo a quantificare il fallimento setup.
I 3 ns max in uscita rappresentano 2 ns di setup STM32 piu' 1 ns di budget
complessivo per collegamento. Non sono misure del cablaggio. Non sono modellati
carico reale, ringing, duty-cycle distortion e jitter. Reset, CS, primo bit TX,
interfacce parallele e CDC non sono qualificati da questo esperimento.

Gowin segnala PR1014: clock spi_sck_d instradato su risorse generiche.
Occorre risolvere/verificare il clock routing nell'integrazione reale. Il solo
nome GCLKC del pin 36 non garantisce l'uso di una rete globale dedicata.
Il mux dopo il registro TX e il percorso clock-pin -> registro -> MISO
contribuiscono al limite: a 25 MHz questa catena vale circa 14.035 ns,
a cui si aggiungono i 3 ns esterni, su 20 ns disponibili.

Conclusione: 25 MHz full duplex e' un primo obiettivo di collaudo motivato
dalla STA esplorativa; circa 29 MHz e' la soglia stimata di questa specifica
implementazione/budget, non il limite della famiglia FPGA. 50 MHz e poi
80-100 MHz in scrittura sono obiettivi da verificare dopo integrazione,
ottimizzazione clock/I/O e test hardware. Letture di stato piu' lente possono
evitare che MISO limiti la velocita' di upload dei pixel.

## Banda RGB565 480 x 272

Frame = 261120 byte. Valori ideali, senza header, pause, rendering o attese:

| SCK MHz | MB/s decimali | ms/frame | frame completi/s |
|---:|---:|---:|---:|
|25|3.125|83.56|11.97|
|40|5.000|52.22|19.15|
|50|6.250|41.78|23.94|
|80|10.000|26.11|38.30|
|100|12.500|20.89|47.87|

30 frame completi/s richiedono almeno 62.6688 Mbit/s; 60 richiedono
125.3376 Mbit/s. Gli aggiornamenti parziali LVGL riducono i dati trasferiti.
La frequenza di scansione del pannello e' indipendente da questi valori.

## Architettura proposta per DMA

- Header breve (opcode, coordinate, lunghezza, sequenza), payload contiguo,
  eventuale CRC finale. Nessun flag aggiuntivo per ogni pixel o byte.
- SPI resta a 8 bit: il DMA invia un intero buffer senza intervento per byte.
  Definire l'ordine RGB565 nel protocollo, anche little-endian, per evitare swap.
- Due draw buffer LVGL; buffer DMA in SRAM accessibile a DMA1/2, non DTCM;
  clean D-cache TX su regioni allineate a linee da 32 byte oppure MPU non-cacheable.
- Garantire spazio per il blocco prima del DMA (crediti o READY esterno alla SPI).
  Non presumere che READY basso interrompa automaticamente un DMA gia' avviato.
- FIFO RX asincrona e writer PSRAM a burst con priorita' allo scan-out.
  FIFO dimensionata sul massimo tempo di stallo e sulla dimensione autorizzata;
  la sola velocita' media non basta. A 100 MHz 4 KiB assorbono circa 328 us
  di stallo se inizialmente vuoti; e' un esempio, non una dimensione verificata.
- Tenere CS basso fino alla fine effettiva SPI (EOT), non al solo termine DMA.
  Gestire RX anche durante TX se si mantiene la configurazione full duplex.
- Restituire il buffer a LVGL quando il driver non lo usa piu'; l'esecuzione
  delle scritture PSRAM puo' terminare dopo la ricezione SPI e richiedere un fence.

Mancano FIFO/CDC, parser, arbitro e misure di banda PSRAM concorrente al display.
Prima di promettere la frequenza massima: integrare questi blocchi, vincolare
I/O e clock reali, poi verificare lunghi DMA con sequenze/CRC e display attivo.
