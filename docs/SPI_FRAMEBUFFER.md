# Scrittura framebuffer via SPI

Prima implementazione: `SpiFramebuffer.sv` trasferisce burst mascherati alla
PSRAM tramite una coda asincrona di un elemento. `LCD_WriteRect` li compone
per aggiornare rettangoli RGB565 arbitrari entro 480x272.

## Protocollo

SPI mode 0, MSB first, 12.5 MHz, GPIO STM32 MEDIUM. Un pacchetto per CS.
I due impulsi iniziali a CS alto restano necessari come nel collaudo precedente.

| Offset byte | MOSI | MISO |
|---|---|---|
| 0 | B7 | A5 |
| 1 | 00 | C3 se coda libera, 00 se occupata |
| 2..4 | indirizzo pixel, big endian a 24 bit | eco del byte precedente |
| 5..6 | maschera a 16 bit, big endian | eco |
| 7..38 | 16 pixel RGB565, byte basso prima del byte alto | eco |
| 39 | 5A, commit | eco |
| 40 | 00 | AC accettato, E1 rifiutato |

Indirizzo multiplo di 16 e minore di 130560. Il bit i della maschera abilita
il pixel i. Pixel 0 nella meta' bassa del primo word PSRAM. Si puo' interrogare
la disponibilita' inviando solo B7 00, poi alzando CS. Se occupata, riprovare
in una nuova transazione. La disponibilita' e' campionata alla fine dell'opcode.

Il commit avviene alla ricezione completa di 5A, prima di alzare CS. Un aborto
precedente non produce scritture; un aborto dopo il commit non le annulla.
Byte successivi al byte 40 sono ignorati dal parser. Un opcode diverso da B7
mantiene l'eco diagnostica A5, byte precedente. Non usare dati arbitrari che
iniziano con B7 come prova eco quando l'endpoint grafico e' attivo.

## Arbitraggio e CDC

Il payload pubblicato resta stabile fino alla conferma del controller. Request
ed acknowledgement usano toggle sincronizzati a due stadi; il payload attraversa
come bus mantenuto stabile. CS azzera solo il parser, non la coda. Entrambi i
domini devono condividere l'assert del reset globale; non resettarli separatamente.

Il controller completa l'inizializzazione del pattern, poi privilegia le letture
video. Accetta una scrittura quando la FIFO video e' almost-full, usando uno stato
separato per il comando. Copia il burst in registri locali prima di liberare la
coda. La maschera abilita entrambi i byte di ciascun pixel selezionato.
Un frame restart durante la scrittura viene conservato e applicato dopo il burst
e il tempo di recupero PSRAM. Non si interrompe una scrittura a meta'.

## Firmware e prova

`Core/Inc/lcd_spi.h` espone `LCD_WriteRect(x,y,w,h,pixels)`. Il buffer contiene
w*h uint16_t in ordine di riga. Ritorna 1 per invio riuscito, 0 per parametri,
timeout o risposta errata. Questa prima versione usa HAL sincrona, non DMA.
Il test DMA precedente resta eseguito prima della demo.

La demo disegna a (101,81) un rettangolo 67x40, bordo bianco e interno rosso,
verde e blu. I bordi non allineati esercitano le maschere. `g_lcd_demo_state`:
0 endpoint diagnostico, 1 in corso, 2 inviato, 3 errore. Il valore 2 verifica
trasporto, eco e accettazione; non e' una rilettura dei pixel dalla PSRAM e non
conferma da solo l'immagine sul pannello.

```powershell
./stm32/WeAct_H743_SPI/test-hardware.ps1 -RequireGraphics -SerialNumber 35FF6C064D53373238602143
```

Richiede `localparam SPI_FRAMEBUFFER = 1` in TOP e `SPI_DIAG_MATRIX 0`.
Il runner salva anche `graphics_state` nel risultato JSON e fallisce se diverso
da 2. `diagnose-hardware.ps1` seleziona invece SPI_FRAMEBUFFER=0; anche
-RestoreSelfTest ripristina l'eco pura. Per tornare alla grafica impostare il
parametro a 1 e ripetere il comando sopra.

## Verifiche e limiti

`sim/run_spi_sim.ps1` include il banco integrato SPI/controller con memoria
che acquisisce i burst e le maschere. Copre payload e ordine dei beat, pixel
non selezionati, coda occupata, indirizzi invalidi, aborto di byte/pacchetto,
riuso della coda e frame restart durante una scrittura.

Non c'e' CRC prima del commit, rollback, readback o doppio framebuffer.
Un errore di trasmissione puo' essere segnalato dall'eco dopo che una scrittura
e' stata accettata. Un rettangolo puo' apparire progressivamente (tearing).
Questa e' la base funzionale per LVGL, non ancora la sua integrazione o una
misura della massima velocita' grafica.

## Esito al banco, 9 settembre 2026

FPGA caricata in SRAM e firmware STM32 programmato con verifica flash.
Test SPI: 40 trasferimenti, 34992 byte, zero mismatch e zero errori HAL;
tre probe GPIO corrette. Demo: graphics_state=2. L'utente ha confermato
visivamente il rettangolo sul pannello, poi ha resettato la FPGA per provarne
la scomparsa. Il reset reinizializza il pattern; per ridisegnare resettare STM32.

Timing finale: quattro endpoint di calibrazione PSRAM ammessi, worst -1.303 ns,
nessuna violazione hold/recovery/removal. Bitstream SHA256:
`971555FD7E3BCB5AB009EBD3FF3CB9C6054ADE0E4A5C7AF1E549584AB7014ACF`.
ELF SHA256: `A9D1BE892C4693BC320C268F41D57DF9CDC6BF2E925D53C5031CCBA951C5FA96`.
Risultati SWD in `stm32/WeAct_H743_SPI/build/Debug/hardware-result.json`;
la lettura ReadOnly e' stata eseguita subito dopo caricamento e verifica flash.

Simulazioni completate: suite SPI con banco framebuffer PASS; regressione
video con FIFO reale PASS (341.2 s, prima della separazione dello stato comando),
modello video sull'RTL finale PASS (83.4 s). Entrambe recuperano dal frame
successivo all'underrun, zero frame danneggiati sui quattro successivi.
Il banco SPI/controller e' stato ripetuto dopo la modifica finale all'arbitraggio.
