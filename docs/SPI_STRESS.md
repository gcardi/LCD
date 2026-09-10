# Collaudo prolungato SPI e grafica — 9 settembre 2026

## Esito

La qualifica prolungata **non passa a 25 MHz**: l'eco DMA passa, ma il flusso
grafico presenta errori intermittenti. Configurazione finale **12.5 MHz MEDIUM**,
prescaler 16 in C e CubeMX. SDC conservato a 40 ns, piu' restrittivo del clock
master effettivo; lo stesso bitstream serve al confronto fra frequenze.

A 12.5 MHz, con firmware finale e risposte registrate, tre esecuzioni PASS:
caricamento STM32, solo reset STM32, ricaricamento FPGA seguito da reset STM32.
Ogni esecuzione verifica:

- 1200 trasferimenti eco DMA, 1049760 byte, zero mismatch e HAL error;
- tutte e tre le prove GPIO corrette;
- 512 rettangoli, 354528 pixel attivi e 30035 pacchetti grafici;
- stato stress 2, fase errore LCD 0, demo inviata correttamente.

Somma delle tre esecuzioni finali: 3149280 byte eco, 1536 rettangoli,
1063584 pixel attivi e 90105 pacchetti grafici. Non e' stata effettuata una
rilettura PSRAM dei pixel: i controlli grafici verificano eco e accettazione
SPI, mentre il banco simulato verifica dati, maschere e indirizzi PSRAM.
La prova di ricaricamento non e' uno spegnimento/riaccensione delle alimentazioni.

## Cosa ha rivelato il test a 25 MHz

Con il firmware grafico HAL in polling, errore iniziale al rettangolo di indice
172 (indici da zero). Aggiunta diagnostica del primo errore, si osserva indice
70 con risposta finale 5A anziche' AC, senza HAL error. Una guardia CS di 1 us
non risolve: fallimento a indice 126 con la stessa risposta.

A 12.5 MHz lo stesso test polling passa. Registrare direttamente la risposta
nel dominio SCK migliora il percorso verso TX ma non elimina da solo il difetto:
a 25 MHz il polling fallisce anche con il nuovo bitstream (indice 46).

Portando il traffico grafico su DMA, una prova a 25 MHz completa tutti i 512
rettangoli; dopo ricaricamento FPGA, pero', fallisce a indice 275, nella query
B7 00: arriva A5 invece di C3/00. Il test lungo eco passa anche in questa prova.
Quindi ne' il primo PASS DMA ne' la chiusura timing qualificano il collegamento
grafico prolungato a 25 MHz. La causa fisica/RTL/periferica resta da isolare;
i risultati non dimostrano che DMA risolva il problema o che sia solo cablaggio.
LVGL non e' stato integrato: la condizione concordata del PASS a 25 MHz manca.

## Modifiche conservate

`SPI_SELFTEST_ROUNDS` in spi_diag_config.h controlla la durata dell'eco; il
runner ricava i conteggi attesi dalla configurazione. Il valore predefinito e'
ora 8, sceso da 240 il 10 settembre 2026 perche' l'eco lunga ritardava di nove
secondi la comparsa del testo a ogni avvio. `-RequireStress` pretende pero'
oltre 1.000.000 di byte controllati, cioe' almeno 229 round: prima di quella
qualifica va riportato a 240 e il firmware ricompilato. Il runner lo verifica
ora in anticipo e lo dice, invece di fallire alla fine sul totale. Il primo byte B7 viene
sostituito con 37 nel pattern eco per non attivare il parser grafico.

`LCD_Stress_Run()` varia larghezza 1..67, altezza 1..40, posizione e pixel,
forzando regolarmente i quattro angoli e coordinate non allineate. Si ferma
al primo errore, senza retry che possano nasconderlo. `g_lcd_stress` conserva
stato, rettangoli/pixel/pacchetti, tempo e indice del rettangolo fallito.
`g_lcd_error` conserva fase, indirizzo, indice byte, atteso, ricevuto e HAL error.

`SPI_Exchange_DMA()` riusa buffer allineati in SRAM D2 e callback del self-test,
con gestione cache e timeout; il chiamante possiede CS e attende la conclusione.
Non supporta trasferimenti concorrenti. Il firmware grafico usa guardie CS di
1 us basate sul contatore DWT, senza cambiare la frequenza SCK durante i pacchetti.
La demo viene inviata prima e dopo lo stress; il pannello conserva i rettangoli
del test, sovrapposti, insieme al rettangolo RGB finale.

La FPGA registra la risposta successiva sul fronte che completa il byte RX,
eliminando il mux combinazionale index/status verso il registro TX. Protocollo
invariato, suite SPI/framebuffer PASS. Build finale a 40 ns: gate timing PASS,
quattro endpoint di calibrazione PSRAM ammessi, worst -0.669 ns, nessuna
violazione hold/recovery/removal e nessuna nuova eccezione.

## Riproduzione

Dopo la modifica per l'avvio nero uniforme, abilitare prima `LCD_BOOT_TESTS=1`
in Core/Inc/spi_diag_config.h, poi ricompilare/caricare con il comando seguente.
Al termine riportarlo a 0 e ricaricare STM32 per mantenere lo sfondo uniforme.


```powershell
# Build/upload e prova completa nella configurazione corrente 12.5 MHz:
./stm32/WeAct_H743_SPI/test-hardware.ps1 -RequireGraphics -RequireStress -TimeoutSeconds 120 -SerialNumber 35FF6C064D53373238602143
# Solo lettura quando firmware/ELF coincidono:
./stm32/WeAct_H743_SPI/test-hardware.ps1 -ReadOnly -RequireGraphics -RequireStress -TimeoutSeconds 120 -SerialNumber 35FF6C064D53373238602143
```

Per ripetere dopo reset STM32, usare il pulsante reset o CubeProgrammer -rst,
poi il comando ReadOnly. Per il ricaricamento usare program_tang_nano_sram.ps1,
resettare STM32 e leggere di nuovo. I risultati vengono salvati nel JSON hardware;
la sola lettura non avvia un nuovo test e non verifica da sola la corrispondenza ELF.

Archivi sotto `stm32/WeAct_H743_SPI/build/Debug/` (ignorati da Git):
`stress-first-fail.json`, `stress-commit-fail.json`, `stress-guard-25-fail.json`,
`stress-guard-12m5-pass.json`, `stress-registered-status-fail.json`,
`stress-dma25-warm-pass.json`, `stress-dma25-reload-fail.json`,
`stress-dma12m5-upload-pass.json`, `stress-dma12m5-reset-pass.json`,
`stress-dma12m5-reload-pass.json`. L'archivio `stress-final-12m5` contiene ELF,
bitstream, report timing, metadati e le tre prove finali.
