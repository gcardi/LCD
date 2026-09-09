# Scrittura framebuffer via SPI

> Aggiornamento: il collaudo lungo rileva errori grafici intermittenti a 25 MHz.
> Configurazione corrente 12.5 MHz, qualificata in tre prove prolungate.
> Vedere [SPI_STRESS.md](SPI_STRESS.md); i risultati successivi a 25 MHz sono cronologia.

Prima implementazione: `SpiFramebuffer.sv` trasferisce burst mascherati alla
PSRAM tramite una coda asincrona di un elemento. `LCD_WriteRect` li compone
per aggiornare rettangoli RGB565 arbitrari entro 480x272.

## Avvio e primitive disponibili

La FPGA inizializza ogni pixel a nero (RGB565 0000), anche dopo il reset.
`FramebufferController.BACKGROUND_COLOR` e' un parametro di sintesi: FFFF per
bianco, F800 rosso, 07E0 verde, 001F blu. Il pattern selezionato e' PATTERN_SOLID;
i precedenti pattern restano nel sorgente come strumenti diagnostici.
Il colore iniziale non e' attualmente modificabile con un comando SPI.

Lo STM32 usa `LCD_BOOT_TESTS=0`: demo e stress grafici non vengono eseguiti.
La prova font corrente usa il flag separato `LCD_TEXT_DEMO=1` e modifica il
framebuffer dopo che l'eco DMA di avvio e' terminata.
Per provarli impostare LCD_BOOT_TESTS=1 in spi_diag_config.h e ricompilare/caricare;
riportare a 0 per l'avvio uniforme. Il runner rifiuta -RequireGraphics/-RequireStress
se i test grafici sono disabilitati nella configurazione locale.

| Livello | Operazione implementata |
|---|---|
| SPI | B7 00: verifica spazio nella coda, ritorna A5 e C3 oppure 00 |
| SPI | B7 + indirizzo + maschera + 16 pixel + 5A: scrittura di un burst mascherato; dummy finale per leggere AC/E1 |
| SPI diagnostico | Eco A5, poi byte precedente, con opcode iniziale diverso da B7 |
| API STM32 | LCD_WriteRect(x,y,w,h,pixels): rettangolo di pixel RGB565, anche non allineato |
| API STM32 | LCD_FillRect(x,y,w,h,color): riempimento uniforme RGB565 |
| API STM32 | LCD_Clear(color): riempimento uniforme di tutto il display 480x272 |
| API STM32 | LCD_DrawCodepoint(...): glifo opaco fixed 12x24 RGB565 |
| API STM32 | LCD_DrawText(...): stringa UTF-8 fixed 12x24, anche multilinea |

Il comando di scrittura usa un indirizzo lineare allineato a 16 pixel. Coordinate,
righe e bordi del rettangolo vengono gestiti dalla funzione STM32.
Non ci sono primitive FPGA per clear/fill rettangoli, linee, cerchi, testo,
font, copia di aree o lettura dei pixel. Fill, clear e testo sono primitive software STM32, non nuovi comandi FPGA:
riutilizzano LCD_WriteRect con una riga da 480 pixel (960 byte sullo stack).
Non allocano un framebuffer completo. Sono sincrone, restituiscono 1 in caso
di successo e 0 per errore. FillRect rifiuta dimensioni nulle e rettangoli fuori
schermo senza clipping; in caso di errore di trasporto l'area puo' risultare
aggiornata parzialmente. Non annullano scritture gia' accettate.

```c
if (!LCD_Clear(0x0000)) { /* errore: pulizia a nero */ }
if (!LCD_FillRect(20, 30, 100, 60, 0xF800)) { /* errore: rettangolo rosso */ }
```

Con `LCD_TEXT_DEMO=1`, la prova corrente chiama clear e testo automaticamente.
Riportandolo a 0 nessuna primitiva grafica viene chiamata all'avvio.
LCD_Demo_Run e LCD_Stress_Run restano programmi di collaudo separati.

Il prototipo testo usa una tabella 12x24 nella flash interna STM32: 196 glifi,
9408 byte bitmap, ASCII stampabile, Latin-1, euro e frecce. `LCD_DrawText`
decodifica UTF-8, usa celle monospaziate opache e sostituisce con `?` i glifi
mancanti. Non esegue wrapping o clipping e verifica l'intero ingombro prima di
disegnare. La tabella e' riproducibile dal BDF e dalla licenza conservati in
`third_party/terminus-font-4.49.1-master`; non usa ancora la User Flash FPGA.

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
timeout o risposta errata. Il trasporto usa DMA con attesa sincrona e guardie CS di 1 us.
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
-RestoreSelfTest ripristina l'eco pura a 12.5 MHz (prescaler 16, SDC 80 ns). Per tornare alla grafica impostare il
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

## Tentativo a 25 MHz, 9 settembre 2026

Provati prescaler STM32 8 e vincolo SCK 40 ns (semiperiodo 20 ns), mantenendo
GPIO MEDIUM e budget I/O di 10 ns. La build FPGA termina, ma il gate timing
rifiuta il percorso `graphics.spi_framebuffer/slave/tx_started_s0/Q` ->
`SPI_MISO_s3/O`: slack -3.782 ns. Percorso dal fronte di discesa al successivo
fronte di salita, skew 5.289 ns e data delay 8.493 ns. Il percorso MOSI piu'
critico ha solo +0.043 ns. Le quattro violazioni di calibrazione PSRAM restano
entro baseline, worst -1.303 ns.

Nessun caricamento a 25 MHz, nessuna prova hardware a questa frequenza.
Ripristinati sorgenti STM32, CubeMX e vincolo SDC a 12.5 MHz. Per procedere
occorre ottimizzare il percorso MISO e ricontrollare anche il margine MOSI;
non basta ridurre il prescaler. Il report del tentativo e' archiviato in
`stm32/WeAct_H743_SPI/build/Debug/trial-25mhz/timing-25mhz.tr`.

## Ottimizzazione MISO e primo PASS a 25 MHz

Il 9 settembre SpiSlave ha acquisito l'opzione FIXED_FIRST_BYTE. SpiFramebuffer
la abilita con FIRST_BYTE=A5: il registro TX inizializzato contiene gia' il primo
MSB, quindi il pin riceve direttamente tx_shift[7]. Eliminati in sintesi il
selettore tx_started e la maschera sul dato; resta il controllo tri-state con CS.
Il contratto generico resta il default per SpiDiagnostic e sorgenti FIFO variabili.

SDC 40 ns, budget I/O ancora 10 ns, prescaler 8, GPIO MEDIUM, cablaggio invariato.
Suite SPI PASS, incluso il banco framebuffer portato a 25 MHz. Gate timing PASS:
sei endpoint di calibrazione PSRAM ammessi, worst -1.308 ns; nessuna violazione
hold/recovery/removal e nessuna nuova eccezione. Il margine minimo nel dominio
PSRAM e' stretto (+0.017 ns); ricontrollare il gate a ogni successiva build.

FPGA programmata in SRAM e flash STM32 verificata. Collaudo normale:
25000000 Hz effettivi, 40 trasferimenti, 34992 byte, zero mismatch, HAL OK,
tre probe GPIO corrette e graphics_state=2. E' un primo collaudo a 25 MHz,
non la prova lunga da oltre un milione di byte eseguita in precedenza a 12.5 MHz.
Conferma visiva della nuova esecuzione a 25 MHz ancora in attesa.

Bitstream SHA256: `1FA0EDDC47B68BAD53D4295CA0AA5BE1BEBD319E0382890CA04466BDA35E1A87`.
ELF SHA256: `312C94BF2E8296B4B8D5239D23E1606199BC5464BB53340E5B6C2F4077CA06C7`.
Configurazione lasciata a 25 MHz per la grafica. RestoreSelfTest torna invece
alla configurazione diagnostica qualificata a 12.5 MHz; per riattivare i 25 MHz
riallineare SPI_FRAMEBUFFER=1, prescaler 8 nel C e CubeMX, e SDC 40 ns.
