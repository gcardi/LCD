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

Al reset: front 0, disegno 0, double buffering disabilitato, sequenza 0, IRQ alto.
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
| 2 | versione protocollo `02` (`01` prima del blitter) |
| 3 | numero di buffer `02` |
| 4 | bit 0 double abilitato; bit 1 front; bit 2 IRQ pendente; bit 3 controllo occupato |
| 5 | buffer di disegno, 0 o 1 |
| 6–7 | ultima sequenza PRESENT completata, byte alto prima |
| 8 | risultato ultimo controllo: `00` successo, `E1` errore |
| 9–10 | CRC16 sui byte RX 1–8, byte alto prima |

Lo stato è un'istantanea coerente mantenuta per tutto il pacchetto. Attraversa
il dominio SPI come dati stabili associati al toggle di completamento: viene
acquisito dopo la sincronizzazione del toggle, non sincronizzando separatamente
i bit della sequenza. Durante busy descrive l'ultimo controllo completato.
BB distingue anche un bitstream precedente, che risponderebbe con l'eco di BB.

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
