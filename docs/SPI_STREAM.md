# `BD` / `BE`, scrittura in streaming di una riga

Implementazione del 16 settembre 2026. `BD` e' il protocollo full-duplex
originale; `BE` usa lo stesso pacchetto come stream TX-only e legge il risultato
in seguito con `BF`. `B7` e `BD` restano invariati e supportati come fallback.

Il firmware usa attualmente `BE/BF`: 18,75 MHz per i pixel, 9,375 MHz per i
comandi ordinari e 1,171875 MHz per lo stato. MISO non viene campionato durante
`BE` e la FPGA lo mette in alta
impedenza dal secondo byte; il primo byte precede necessariamente la decodifica
dell'opcode ma viene comunque ignorato dal master.

## Perché

`B7` spende 41 byte per 16 pixel e richiede una transazione SPI a sé stante per
ogni burst. Un frame intero sono **8160 pacchetti**, e fino al commit `2bd43c5`
ne servivano altrettanti solo per interrogare la disponibilità. Ogni transazione
non costa solo i byte sul filo: il firmware fa due `memcpy`, tre operazioni di
manutenzione cache con barriera e un setup HAL completo di due stream DMA.

`BD` trasferisce **una riga per transazione**. Header, payload contiguo, CRC sul
payload, commit. Per una riga intera sono 978 byte in un solo DMA, contro
trenta pacchetti da 41 più trenta round di handshake.

## Formato

Tutte le transazioni iniziano con la risposta `A5`. Byte big-endian.

| Indice TX | Contenuto | RX |
|---:|---|---|
| 0 | `BD` | `A5` |
| 1 | dummy | `C3` disponibile / `00` occupato |
| 2–3 | `y`, riga 0…271 | eco del byte precedente |
| 4 | `group_start`, primo gruppo da 16 pixel, 0…29 | eco |
| 5 | `group_count`, numero di gruppi, 1…30 | eco |
| 6–7 | `head_mask`, pixel validi del primo gruppo | eco |
| 8–9 | `tail_mask`, pixel validi dell'ultimo gruppo | eco |
| 10–11 | CRC16-CCITT sui byte 2–9 | eco |
| 12 | commit header `A6` | eco |
| 13 | dummy | `AC` header accettato / `E1` rifiutato |
| 14 … 13+32·group_count | payload, gruppi interi da 16 pixel RGB565, **byte basso per primo** | `C3` sano / `00` overflow |
| +2 | CRC16-CCITT sul payload | eco |
| +1 | commit `A6` | eco |
| +1 | dummy | `AC` riga integra e scritta / `E1` |

CRC16-CCITT, polinomio `1021`, iniziale `FFFF`, reinizializzato fra header e
payload. Lunghezza totale `32·group_count + 18`, al massimo 978 byte.

## Variante write-only `BE` e stato `BF`

`BE` ha esattamente gli stessi byte TX di `BD`. Le risposte inline non fanno
parte del contratto: STM32 usa `HAL_SPI_Transmit_DMA`, quindi SPI2 passa in
simplex TX e non arma la DMA RX. Al termine il firmware porta CS alto, cambia
il prescaler con SPI disabilitata e interroga il mailbox con `BF`.

`BF` richiede nove byte TX (`BF` seguito da otto dummy) e risponde:

| Indice RX | Contenuto |
|---:|---|
| 0 | `A5` |
| 1 | `D3`, firma stato stream |
| 2 | versione, attualmente `01` |
| 3 | bit 0 stato valido, bit 1 endpoint pronto per una nuova riga |
| 4–5 | numero di riga `y` dell'ultimo `BE` |
| 6 | risultato |
| 7–8 | CRC16-CCITT sui byte RX 1–6 |

Risultati: `AC` successo, `00` riga rifiutata per coda occupata, `E1` header
non valido, `E2` overflow durante il payload, `E3` CRC/commit payload errato,
`FE` pacchetto iniziato ma non completato. `00`, `E2`, `E3` e `FE` sono
recuperabili rispedendo la stessa riga; `E1` indica un errore di protocollo.
Il firmware aspetta anche il bit ready prima di procedere, quindi non confonde
la validazione CRC con lo svuotamento dell'ultima entry verso la PSRAM.

Il mailbox identifica la riga, non un frame globale. Questa granularita' rende
la riparazione economica e impedisce `PRESENT` finche' tutte le righe non sono
state confermate; costa pero' una lettura lenta per riga. Un futuro mailbox per
blocchi o frame potra' ridurre ulteriormente l'overhead dopo aver aumentato la
profondita' della coda.

### Perché gruppi interi e non pixel

Il payload copre **sempre gruppi allineati a 16 pixel**: l'host riempie di
padding le estremità irregolari e le descrive con le due maschere, che l'FPGA
applica al primo e all'ultimo gruppo. Quando la riga sta in un gruppo solo si
applicano entrambe.

La prima versione accettava `x` e `count` al pixel e ricostruiva le maschere
nell'FPGA, il che è più comodo per l'host ma richiede un mux a inserimento
variabile su 256 bit. Misurato: **+864 LUT, dal 61% al 71% del die, e 15
endpoint setup violati** su percorsi di `FramebufferController` che nessuno
aveva toccato — pressione di placement su un percorso già al limite. Con i
gruppi interi il percorso pixel è lo **stesso shift register a byte** che `B7`
già usa, condiviso perché i due opcode non sono mai selezionati insieme, e il
costo in logica torna trascurabile.

Il prezzo è al massimo 30 pixel di padding per riga, cioè 60 byte. Su una riga
piena è zero; su un'area parziale di LVGL è una frazione trascurabile di quanto
`B7` sprecava comunque.

Un header è rifiutato se `y ≥ 272`, `group_start ≥ 30`, `group_count = 0`,
`group_start + group_count > 30`, una delle due maschere è nulla, oppure il CRC
non torna. Un header rifiutato rende **inerte** il resto della transazione:
nessuna scrittura, nessuno stato modificato.

## Coerenza e recupero

Come `B7`, e a differenza di `B8`/`B9`/`BC`, **`BD` non è atomico**. I gruppi da
16 pixel vengono scritti in PSRAM mentre arrivano, quindi:

- il CRC finale **segnala**, non annulla: una riga corrotta resta scritta a metà;
- la riparazione è **rispedire la stessa riga**, operazione idempotente;
- con il double buffering la riga sta nel back, quindi nulla di sbagliato
  raggiunge il pannello: basta non chiamare `PRESENT` e ripetere.

SCK non può essere fermato da uno slave. Se la coda verso la PSRAM è ancora
occupata al confine di un gruppo, l'endpoint **latcha un overflow**, smette di
scrivere per il resto della riga e lo riporta in due modi: il byte di stato sul
payload passa da `C3` a `00`, e il commit finale risponde `E1`. Anche qui la cura
è rispedire la riga.

La misura prolungata a 18,75 MHz ha mostrato che l'overflow puo' invece
accadere: 210 retry su 13.056 righe, tutti `E2`. La velocita' media della PSRAM
non e' il problema; basta un breve stallo al confine di un gruppo per saturare
la coda a una entry. Il recupero rende il trasferimento corretto, ma il prossimo
guadagno richiede un buffer elastico piu' profondo fra dominio SCK e dominio
PSRAM — `FramebufferFifo` è già parametrico in larghezza e profondità.

## Implementazione

Tutto il lavoro sta nel dominio SCK di [SpiFramebuffer.sv](../src/SpiFramebuffer.sv),
e riusa i registri di staging di `B7`: i due opcode non sono mai selezionati
insieme, quindi il burst da 256 bit e la sua maschera non costano risorse extra.
L'indirizzo del gruppo corrente parte da `y·480 + group_start·16`, calcolato
come `(y<<9) − (y<<5)` per non introdurre un moltiplicatore, e avanza di 16
pixel a ogni gruppo completato.

Il resto dell'FPGA non cambia: `BD` produce esattamente la stessa terna
`address`/`pixels`/`mask` che il controller consuma già da `B7`, quindi
`FramebufferController` e `TOP` sono intatti.

## API STM32

```c
int LCD_WriteRectStream(uint16_t x, uint16_t y, uint16_t w, uint16_t h,
                        const uint16_t *pixels);
```

Stessi argomenti e stesso contratto di `LCD_WriteRect`, una transazione per riga.
Riprova automaticamente una riga rifiutata, fino a un secondo, contando i
tentativi in `g_lcd_profile.retries`.

Il profilo è leggibile via SWD e distingue assemblaggio del pacchetto, scambio
SPI e barriera finale:

```c
typedef struct { uint32_t assemble, exchange, fence, packets, retries; } LcdProfile;
extern volatile LcdProfile g_lcd_profile;
void LCD_ProfileReset(void);
```

`LCD_STREAM_BENCH` in `spi_diag_config.h` abilita `LCD_StreamBench_Run()`, che
dipinge lo schermo intero lungo entrambi i percorsi e lascia in
`g_lcd_bench_b7_ms`, `g_lcd_bench_bd_ms`, `g_lcd_bench_b7` e `g_lcd_bench_bd` il
confronto diretto. È distruttivo, quindi è opt-in come `LCD_BOOT_TESTS`.

## Misura al banco, 16 settembre 2026

Schermo intero riga per riga, entrambi i percorsi, `LCD_StreamBench_Run()` a
12,5 MHz, MCU Release. Cicli DWT convertiti a 480 MHz.

| | assemble | exchange | fence | totale |
|---|---:|---:|---:|---:|
| `B7`, 8160 transazioni | 11,5 ms | 334,5 ms | 4,3 ms | **383 ms** |
| `BD`, 272 transazioni | 38,8 ms | 181,7 ms | 4,3 ms | **225 ms** |

**1,71x sullo schermo intero.** Il trasporto da solo fa 1,84x: 334,5 -> 181,7 ms,
contro 170 ms di puro tempo di filo. Il costo fisso per transazione, che sui
pacchetti `B7` valeva circa 15 us ciascuno, è praticamente sparito.

### Prova `BE/BF`

Sul medesimo hardware, firmware Release e GPIO `MEDIUM`:

| Pixel SCK | Stato SCK | Totale frame `BE/BF` | Retry | Esito |
|---:|---:|---:|---:|---|
| 12,5 MHz | 1,5625 MHz | 226 ms | 1 | PASS, nessun errore LCD |
| 18,75 MHz | 1,171875 MHz | 186 ms | 5 | PASS, 5 overflow recuperati |
| 25 MHz | 1,5625 MHz | 175 ms | 46 | frame completato, non qualificato |

Nella seconda esecuzione i 46 retry erano 7 overflow della coda a una entry e
39 pacchetti incompleti; nessun CRC payload errato. Una ripetizione con slew
GPIO `HIGH` e' peggiorata fino al timeout (tutti i tentativi incompleti), quindi
la configurazione e' tornata a `MEDIUM`. Il risultato dimostra che togliere MISO
dal trasferimento funziona e rende gli errori recuperabili, ma non qualifica
25 MHz: restano il routing generico di SCK segnalato da Gowin, l'integrita' del
segnale e la profondita' della coda verso PSRAM.

La qualifica prolungata della configurazione a 18,75 MHz ha trasferito 48 frame,
13.056 righe, in 10.641 ms: 210 retry, tutti overflow `E2`, e zero busy, header
errati, CRC errati o pacchetti incompleti. La media di circa 221,7 ms/frame
include il recupero degli overflow. Le prove dicotomiche superiori non sono
state caricate sull'hardware: 21,875 MHz ha fallito la STA SPI (Fmax circa
20,763 MHz), 20,3125 MHz ha fallito un percorso MOSI di 0,445 ns e 19,375 MHz
ha prodotto una regressione di placement sul percorso PSRAM di 0,343 ns. Per
questo la configurazione distribuita e qualificata resta 18,75 MHz.

Due lezioni che vale la pena non ripetere:

- la stima a tavolino era **~170 ms**, cioè sbagliata di 80 ms, perché non
  teneva conto del CRC software sul payload;
- la prima misura dava `BD` a 374 ms contro 385, un misero 3%. Il CRC bit per
  bit costava **334 cicli per byte** e su 960 byte di payload per riga si
  mangiava per intero i 150 ms che il trasporto aveva guadagnato. Sostituito con
  una tabella da 256 voci (512 byte di flash), l'assemblaggio è sceso da 183,4 a
  61,4 ms. Senza la scomposizione `assemble`/`exchange`/`fence` del profilo, il
  colpevole sarebbe rimasto invisibile.

Il payload viene poi costruito come **tre blocchi contigui** invece che con una
decisione per pixel: `memset` di testa, `memcpy` della riga sorgente — in
RGB565 byte basso per primo, che è già come un `uint16_t` sta in memoria — e
`memset` di coda, seguiti da una sola passata di CRC sul buffer. L'assemblaggio
è sceso da 61,4 a 38,8 ms.

Restano 38,8 ms, 143 us per riga, **~70 cicli per byte** per un lookup e uno
XOR. Resta senza spiegazione: la tabella è stata spostata in RAM per escludere
la latenza flash su una catena di load dipendenti, e **non è cambiato nulla**
(226 ms contro 225), quindi è tornata `const`. Buffer e tabella stanno comunque
tutti in DTCM.

Il prossimo guadagno non sta qui. Con il **flush asincrono** — DMA non
bloccante e callback di fine trasferimento — l'assemblaggio della riga
successiva si sovrappone al DMA della precedente, e quei 38,8 ms spariscono del
tutto invece di essere limati. Su 272 transazioni da 978 byte rende molto più
di quanto avrebbe reso sulle 8160 da 41.

## Verifica

`sim/tb_spi_framebuffer.sv` copre, oltre a tutto il preesistente:

- i cinque motivi di rifiuto dell'header, verificando che non scrivano nulla;
- un gruppo allineato;
- una riga non allineata in testa e in coda, padding compreso, con i pixel
  confinanti intatti;
- una riga intera da 480 pixel, cioè tutti i confini di gruppo;
- un CRC di payload sbagliato, che riporta `E1` **senza** annullare le scritture;
- un overflow forzato bloccando il consumatore, con il byte di stato che passa a
  `00`, il commit `E1`, il primo gruppo conservato e nulla scritto oltre;
- il recupero sulla transazione successiva.

```powershell
.\sim\run_spi_sim.ps1 -TimeoutSeconds 600
.\build.ps1
```
