# `BD`, scrittura in streaming di una riga

Implementazione del 16 settembre 2026. Sostituisce `B7` come percorso pixel
preferito; `B7` resta invariato e supportato.

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

In pratica l'overflow non dovrebbe accadere: un gruppo impiega 20,5 µs ad
arrivare a 12,5 MHz, mentre il dominio memoria lo smaltisce in meno di un
microsecondo. La coda a una entry è quindi ampiamente sufficiente, e il campo
`retries` del profilo firmware è lì per dimostrarlo sul banco invece che a parole.
Se un giorno dovesse saturare, il rimedio è un buffer elastico fra dominio SCK e
dominio PSRAM — `FramebufferFifo` è già parametrico in larghezza e profondità.

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
