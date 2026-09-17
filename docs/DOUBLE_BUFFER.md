# Double buffering, PRESENT e IRQ

Implementazione del 15 settembre 2026. Blitter, scroll e triple buffering restano futuri.

## Memoria e disegno

Il controller usa due slot PSRAM disgiunti, indirizzati in pixel RGB565:

| Buffer | Base in pixel | Base in byte | Dimensione immagine |
|---|---:|---:|---:|
| 0 | `000000` | `000000` | 480 x 272, 261120 byte |
| 1 | `020000` | `040000` | 480 x 272, 261120 byte |

Le basi sono esadecimali. Ogni slot riserva 256 KiB: in totale 512 KiB,
con 1024 byte di padding per slot. Il passo a potenza di due evita un sommatore
nel percorso critico degli indirizzi. L'IP locale W955D8MBYA espone indirizzi
pixel a 21 bit; gli slot usano soltanto i primi 18 bit. Non vengono esposti
indirizzi fisici arbitrari al master.

Al reset: front 0, disegno 0, double buffering disabilitato, sequenza 0, IRQ alto,
`reset_seen` acceso. Vale per qualunque reset: accensione, pulsante e linea
`FPGA_RST_N` comandata dalla MCU (vedi sotto, *Reset comandato dalla MCU*).
L'inizializzazione a nero del buffer 0 e la compatibilità B7/B8/B9 restano attive.
`ENABLE_DOUBLE` aspetta le operazioni precedenti e seleziona come destinazione
il buffer opposto al front. **Il back non viene inizializzato né copiato:**
il chiamante deve cancellarlo o ricostruirlo completamente prima del primo PRESENT.
Anche dopo ogni swap il back contiene una vecchia immagine; gli aggiornamenti
parziali richiedono una gestione esplicita della coerenza.

B7 pixel, B8 testo e B9 forme usano tutti il back quando il modo è abilitato.
Il target non può cambiare durante un comando: ENABLE/PRESENT chiudono
l'ammissione di nuovi comandi grafici e aspettano entrambe le code e l'ultima
scrittura PSRAM, incluso il suo intervallo di recupero.

## PRESENT e confine del frame

Una presentazione accettata viene armata dopo la barriera di scrittura.
Lo scambio avviene al successivo `FrameRestart` fresco, all'inizio del blanking
verticale (riga 277, colonna 0 del raster attuale). È la sincronizzazione di
frame già usata dal display; **non coincide esattamente con il fronte del pin
LCD_SYNC**, che nell'attuale raster sale una riga dopo.

Il cambio riguarda la base di lettura, non i pixel in memoria. La FIFO viene
svuotata per 63 cicli PSRAM, lasciando drenare eventuali letture precedenti;
il video viene poi precaricato dalla nuova base durante il blanking.
Solo al termine del flush il controller completa il comando, aggiorna la
sequenza e porta `FPGA_IRQ_N` basso. L'IRQ significa **swap effettuato e vecchio
front riutilizzabile**, non "il pannello ha già mostrato tutti i nuovi pixel".

IO28 è un'uscita LVCMOS33 collegata a STM32 PB0/EXTI0, fronte di discesa.
L'IRQ resta basso fino a un ACK con la sequenza corretta. Non è un impulso.

## Protocollo SPI

SPI mode 0, 12.5 MHz, CS protetto dagli intervalli già usati dal firmware.
Tutti i pacchetti iniziano con risposta `A5`.

### BA: controllo, 10 byte

| Indice TX | Contenuto |
|---:|---|
| 0 | `BA` |
| 1 | dummy `00`; RX indica disponibilità `C3` oppure occupato `00` |
| 2 | operazione |
| 3 | buffer richiesto, oppure zero riservato |
| 4–5 | sequenza a 16 bit, byte alto prima |
| 6–7 | CRC16-CCITT, polinomio `1021`, iniziale `FFFF`, sui byte 2–5 |
| 8 | commit `A6` |
| 9 | dummy; RX `AC` accettato, `E1` rifiutato |

RX agli indici 2–8 ripete il byte TX precedente. Un pacchetto interrotto prima
del commit non ha effetto. Dopo il commit CS non annulla la richiesta.
CRC errato, operazione sconosciuta e campi riservati non validi non vengono accettati.

| Operazione | Buffer | Sequenza | Effetto |
|---|---|---|---|
| 1 ENABLE_DOUBLE | 0 | 0 | Attende i produttori, abilita disegno sul back; idempotente |
| 2 PRESENT | 0 o 1 | ultima completata + 1, modulo 65536 | Presenta il back al confine del frame |
| 3 ACK_PRESENT | 0 | ultima completata | Rilascia IRQ; ripetibile |
| 6 ACK_RESET | 0 | 0 | Spegne `reset_seen`; servito dopo calibrazione PSRAM e riempimento iniziale |

`AC` conferma **l'accettazione**, non il completamento né la validità semantica.
La lettura BB distingue occupato, completato e risultato. Un PRESENT richiede
modo double abilitato, destinazione diversa dal front, sequenza successiva e
nessun IRQ precedente da confermare. In caso contrario termina con risultato `E1`.

La ripetizione esatta dell'ultimo PRESENT completato (stessa sequenza e stesso
front) termina con successo senza scambio e senza rigenerare IRQ, anche dopo ACK.
Un ACK con sequenza errata termina con `E1` e lascia l'IRQ invariato.
Il risultato BB riguarda l'ultimo **controllo** terminato; la sequenza riguarda
sempre l'ultimo **PRESENT** completato. Non esiste una coda illimitata o una
cronologia di deduplicazione: una vecchia richiesta non va riproposta dopo
65536 presentazioni, né attraversando un reset FPGA.

Mentre il controllo è pendente BA e B7/B8/B9 rispondono occupato; BB resta leggibile.
Le richieste grafiche già accettate proseguono. A controllo completato si può
ridisegnare il vecchio front anche prima dell'ACK; un altro PRESENT richiede l'ACK.

### BB: stato e capacità, 11 byte

TX: `BB` seguito da dieci dummy `00`.

| Indice RX | Contenuto |
|---:|---|
| 0 | `A5` |
| 1 | firma `D2` |
| 2 | versione protocollo `03` (`02` prima di `reset_seen`, `01` prima del blitter) |
| 3 | numero di buffer `02` |
| 4 | bit 0 double abilitato; bit 1 front; bit 2 IRQ pendente; bit 3 controllo occupato; bit 4 `reset_seen` (dalla versione 3) |
| 5 | buffer di disegno, 0 o 1 |
| 6–7 | ultima sequenza PRESENT completata, byte alto prima |
| 8 | risultato ultimo controllo: `00` successo, `E1` errore |
| 9–10 | CRC16 sui byte RX 1–8, byte alto prima |

Lo stato è un'istantanea coerente mantenuta per tutto il pacchetto. Attraversa
il dominio SPI come dati stabili associati al toggle di completamento: viene
acquisito dopo la sincronizzazione del toggle, non sincronizzando separatamente
i bit della sequenza. Durante busy descrive l'ultimo controllo completato.
BB distingue anche un bitstream precedente, che risponderebbe con l'eco di BB.

## Reset comandato dalla MCU

La MCU può resettare la logica della FPGA attraverso `FPGA_RST_N`: STM32 PB1,
open drain, verso Tang Nano IO29, con pull-up esterna da 10 kΩ. Nell'RTL la
linea e il pulsante di reset passano per `ResetRequestFilter`, che richiede il
livello basso per almeno **1 ms** sul quarzo a 27 MHz prima di agire: un disturbo
raccolto dal filo non resetta niente, e lo stesso filtro elimina i rimbalzi del
pulsante. È un reset **logico**: ricalibra la PSRAM, ricontrolla i font e
ripulisce code e parser, ma non ricarica il bitstream. `RECONFIG_N` non è
raggiungibile dai connettori della Tang Nano 9K.

Un impulso sul filo non dimostra niente da solo: con il filo staccato la MCU non
se ne accorgerebbe. Per questo la FPGA espone **`reset_seen`**, bit 4 del byte 4
di `BB`: si accende a ogni reset e si spegne soltanto con `BA ACK_RESET`.
`FPGA_ResetCycle()` lo usa così, all'avvio e prima di qualunque altro uso:

1. legge `BB` e manda `ACK_RESET`: `reset_seen` spento, prova **armata**;
2. deseleziona la SPI, maschera EXTI0 e tiene PB1 basso per 10 ms;
3. aspetta la risposta SPI (`SPI_Setup`) e rilegge `BB`: `reset_seen` deve
   essere di nuovo **acceso**, altrimenti l'impulso non è arrivato (fase 60);
4. manda di nuovo `ACK_RESET` e ne attende il completamento: siccome viene
   servito dopo calibrazione e riempimento iniziale, questo è anche il segnale
   che la FPGA è pronta per disegnare;
5. ripulisce lo stato IRQ lato MCU e riabilita EXTI0.

| `g_fpga_reset_state` | Significato |
|---:|---|
| 0 | ciclo non eseguito |
| 1 | in corso |
| 2 | **reset dimostrato** |
| 3 | fallito dopo tre tentativi: la FPGA non va usata, le demo non partono |
| 4 | impulso inviato ma non dimostrabile: bitstream precedente alla versione 3, oppure FPGA muta prima dell'impulso e viva dopo |
| 5 | senza linea di reset: pronta, e la FPGA era **appena ripartita** (accensione o pulsante) |
| 6 | senza linea di reset: pronta, e la FPGA **stava già girando** con il suo stato (è ripartita solo la MCU) |

### La linea di reset è facoltativa

La FPGA non ne ha bisogno: IO29 ha la pull-up e senza filo resta a riposo. È il
firmware a decidere, con `FPGA_RESET_LINE` in `spi_diag_config.h`, e `main()`
chiama `FPGA_Start()`, che sceglie il percorso:

- **1, linea montata**: `FPGA_ResetCycle()`, reset con prova come sopra; senza
  prova la FPGA non viene usata e le demo non partono;
- **0, nessuna linea**: `FPGA_WaitReady()`. Non resetta e non dimostra niente, ma
  manda comunque `ACK_RESET` e ne attende il completamento. Siccome viene servito
  solo dopo calibrazione PSRAM e riempimento iniziale, la MCU aspetta che la FPGA
  sia **davvero** pronta invece di fidarsi di un ritardo fisso. Letto prima
  dell'ACK, `reset_seen` distingue una FPGA appena accesa (stato 5) da una che
  stava già girando (stato 6), nel qual caso può conservare doppio buffer
  abilitato o IRQ pendenti: `LCD_EnableDoubleBuffer` li gestisce già.

`g_fpga_ready_tick` riporta in entrambi i casi il tick HAL, cioè i millisecondi
dall'avvio della MCU, in cui la FPGA è diventata utilizzabile. Su un'accensione
comune delle due schede è il tempo che la MCU ha dovuto aspettare davvero, ed è
il dato da usare se un sistema dovesse ripiegare su un ritardo fisso.

Primo riscontro senza linea, con la sola MCU riavviata: stato 6, pronta a 12 ms
dall'avvio della MCU, demo complete. Non è ancora la misura di un'accensione
comune, perché la FPGA era già accesa.

`g_fpga_reset_attempts` conta i tentativi, `g_fpga_reset_ready_ms` misura il tempo
dal rilascio della linea alla FPGA pronta. Sul banco, il 17 settembre 2026:
stato 2 al primo tentativo, **16 ms**.

## API STM32 e demo

```c
LCD_EnableDoubleBuffer();  // recupera anche un IRQ rimasto dopo reset della MCU
LCD_Clear(0x0000);
LCD_DrawTextFPGA(20, 20, 0, 0, LCD_FONT_12X24, 0, 0xFFFF, 0, "Pronto");
LCD_Present(1000);         // barriera, swap, attesa IRQ e ACK
```

Controllare ogni valore di ritorno: 1 successo, 0 errore. Le API sono bloccanti
e richiedono un solo chiamante. `LCD_GetBufferStatus` espone capacità e stato.
L'ISR conta il fronte e alza un flag; non chiama SPI. `LCD_Present` usa flag
EXTI e livello GPIO, con polling periodico di stato per diagnosticare errori;
verifica il livello basso prima dell'ACK e alto dopo. Un timeout o errore di
trasporto non provoca una ritrasmissione automatica: leggere BB per riconciliare
lo stato. Un IRQ pendente va confermato prima di una nuova presentazione.

La demo FPGA ricostruisce e presenta 16 immagini con un rettangolo in movimento,
poi presenta il campione testo/forme con la scritta `Double buffer + VSYNC + IRQ: OK`.
Le prime 16 presentazioni verificano anche 16 fronti EXTI. Risultati leggibili SWD:
`g_lcd_present_count`, `g_lcd_present_ms` (ultima attesa, risoluzione 1 ms),
`g_lcd_front_buffer`, `g_lcd_present_sequence`, `g_fpga_irq_count`,
`g_fpga_irq_pending`, `g_fpga_irq_level`, `g_lcd_error`.

## Verifiche riproducibili

```powershell
.\sim\run_spi_sim.ps1
.\sim\run_double_buffer_sim.ps1
.\sim\run_double_buffer_sim.ps1 -RealFifo
.\sim\run_sim.ps1 -Mode current
.\build.ps1
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -SerialNumber 35FF6C064D53373238602143
# Solo lettura; verifica prima la corrispondenza della flash STM32 con l'ELF:
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

Il test hardware normale programma flash FPGA e font, poi MCU Release; richiede
un bitstream già compilato e corrispondente al manifest di timing. Il runner
con `LCD_SCROLL_DEMO=0` salva `build/Release/double-buffer-result.json` e pretende 17 presentazioni,
17 fronti IRQ, demo completata, IRQ rilasciato e nessun errore SPI/LCD.
Il default della build MCU generale resta Debug; quello di questo runner è Release.

Il test di integrazione usa il TOP reale con modelli di PLL e PSRAM. Verifica
CRC, aborti, barriera durante fill, blocco delle scritture nel front, duplicati,
ACK errati, entrambi gli slot, padding e tre frame interi rispetto alla memoria.
La variante `-RealFifo` usa anche la FIFO RTL del progetto. Il modello PSRAM
non sostituisce la qualifica elettrica al banco; SWD non rilegge i pixel del pannello.

## Estensione COPY/SCROLL (16 settembre)

Con il default corrente `LCD_SCROLL_DEMO=1`, dopo il campione precedente viene
eseguita la demo terminale: 50 PRESENT/IRQ complessivi, una COPY e 32 SCROLL.
Il runner rileva il flag e salva `scroll-result.json`; `-RequireScroll` richiede
esplicitamente anche la demo scroll. Protocollo BC, API e coerenza dei viewport
sono descritti in [BLITTER.md](BLITTER.md). BB mantiene il layout e passa a
versione 2; il risultato riguarda l'ultimo controllo BA o BC concluso.

Dal 16 settembre il controller registra il segnale di confine del frame
sincronizzato prima dell'arbitraggio: lo swap segue quel segnale di un ciclo
PSRAM aggiuntivo (circa 12 ns), all'interno dello stesso blanking verticale.
Il test controlla questa latenza con un proprio registro di riferimento.
