# COPY, SCROLL e demo terminale

## Funzioni

L'opcode `BC` copia rettangoli fra i due framebuffer PSRAM oppure esegue uno
scroll con riempimento automatico. Richiede double buffering abilitato,
**sorgente front e destinazione back**. Non accetta copie nello stesso buffer
né scritture nel buffer visualizzato.

- `COPY_RECT`: copia il rettangolo sorgente nella posizione destinazione.
- `SCROLL_RECT`: trasla il contenuto entro un viewport e riempie ogni pixel
  scoperto con il colore RGB565 passato nel comando.
- Il contenuto fuori dal rettangolo destinazione rimane invariato.
- Coordinate fuori schermo, dimensioni nulle e rettangoli parzialmente esterni
  vengono rifiutati prima di leggere o scrivere memoria. Nessun clipping implicito.
- `dx > 0` sposta a destra, `dy > 0` verso il basso; entrambi possono essere
  negativi. Zero copia il viewport senza traslazione. Se lo spostamento scopre
  tutto il viewport, il comando riempie tutto senza letture sorgente.

PRESENT resta separato: dopo SCROLL il micro può aggiungere la nuova riga di
testo nel back, poi presentare il risultato al confine del frame. COPY/SCROLL
non generano IRQ; il completamento è segnalato da BB. L'IRQ resta quello di PRESENT.

## Contratto e implementazione

BC condivide la mailbox di controllo con BA. Dal commit alla conclusione blocca
l'accettazione di nuovi comandi BA/BC e B7/B8/B9. Aspetta che i produttori già
accettati finiscano, compreso il recupero dopo l'ultima scrittura PSRAM.

`BlitRenderer.sv`, nel dominio PSRAM a 81 MHz, costruisce burst destinazione
mascherati di 16 pixel. Una cache di un burst sorgente gestisce origini e
posizioni destinazione con allineamenti diversi; i dati rimangono nel registro
di risposta del controller fino alla lettura successiva. I pixel vengono
selezionati in più stadi per limitare il percorso combinatorio.

`FramebufferController.sv` arbitra anche le letture del blitter. Dati e validità della risposta PSRAM sono acquisiti insieme in un registro
prima dell’arbitraggio. Le risposte del blitter
sono indirizzate al registro di copia e **non entrano nella FIFO video**.
Il display conserva la priorità quando la FIFO non è quasi piena. Al blanking
una lettura del blitter in corso termina prima del flush video; una lettura
video precedente può essere drenata e scartata, come nel percorso esistente.

La mailbox si libera soltanto dopo il completamento dell'ultima scrittura,
non quando l'ultimo burst è stato semplicemente accettato. La sorgente rimane
stabile e nessun altro produttore può scrivere durante la copia. Un errore di
trasporto non provoca retry automatici: leggere prima lo stato e verificare
che i ruoli front/back non siano cambiati.

## Protocollo BC, 24 byte

| Indice TX | Campo |
|---:|---|
| 0 | `BC` |
| 1 | dummy `00`; RX `C3` disponibile, `00` occupato |
| 2 | operazione: `00` COPY, `01` SCROLL |
| 3 | buffer sorgente, 0 o 1 |
| 4 | buffer destinazione, 0 o 1, diverso dal sorgente |
| 5 | riservato, zero |
| 6-7 | x del rettangolo sorgente / viewport |
| 8-9 | y del rettangolo sorgente / viewport |
| 10-11 | larghezza |
| 12-13 | altezza |
| 14-15 | COPY: x destinazione; SCROLL: dx con segno |
| 16-17 | COPY: y destinazione; SCROLL: dy con segno |
| 18-19 | SCROLL: colore RGB565; COPY: zero riservato |
| 20-21 | CRC16-CCITT sui byte 2-19, iniziale `FFFF`, polinomio `1021` |
| 22 | commit `A6` |
| 23 | dummy; RX `AC` accettato, `E1` rifiutato |

Campi a 16 bit: byte alto prima. Gli spostamenti sono signed 16 bit in
complemento a due, inclusi -32768 e +32767. RX[0] è `A5`; RX[2..22] ripete
il byte TX precedente. CS prima del commit annulla il pacchetto; dopo il
commit non cancella l'operazione.

CRC, tipo, identificativi dei buffer e campi riservati sono controllati prima
del commit. `AC` significa accettazione, non successo dell'esecuzione: limiti
geometrici e ruolo front/back vengono verificati dalla logica di esecuzione.
Attendere `busy=0` su BB e controllare il risultato `00` oppure `E1`.

La versione restituita da BB passa a **2**, mantenendo invariato il pacchetto
di stato di 11 byte. La versione 2 annuncia BC COPY/SCROLL; la versione 1
supporta solo il precedente double buffering. La sequenza BB resta quella
dell'ultimo PRESENT e non viene incrementata da COPY/SCROLL. Il campo risultato
riguarda l'ultimo controllo BA o BC concluso.

## API STM32

```c
LCD_CopyRect(front, back, sx, sy, width, height, dest_x, dest_y);
LCD_ScrollRect(front, back, x, y, width, height, dx, dy, fill_rgb565);
```

API bloccanti, un solo chiamante, ritorno 1 successo / 0 errore. I limiti
sono verificati anche lato MCU prima del traffico SPI; la versione BB deve
supportare il blitter. Le API attendono il completamento con timeout di 1 s.
Come per il disegno precedente, un errore di trasporto può lasciare un
aggiornamento parziale nel back. Il front rimane protetto.

Per un terminale di 11 righe con font 8x16, viewport `(19,60,442,176)`:

```c
LcdBufferStatus status;
// Verificare il risultato di ogni chiamata.
LCD_GetBufferStatus(&status);
LCD_ScrollRect(status.front, status.draw, 19, 60, 442, 176, 0, -16, 0x0000);
LCD_DrawTextFPGA(23, 220, 434, 16, LCD_FONT_8X16,
                LCD_TEXT_TRANSPARENT, 0xFFFF, 0, "Nuova riga");
LCD_Present(1000);
```

**Coerenza del resto dello schermo:** inizializzare i due buffer con la stessa
cornice e lo stesso sfondo. Nella demo si disegna la finestra, la si presenta,
poi una sola COPY a schermo intero inizializza il back. Il ciclo successivo
aggiorna soltanto il viewport. Se cambia qualcosa fuori dal viewport, occorre
aggiornare anche l'altro buffer o ricostruire quelle aree prima dello swap.

## Demo e collaudo

`LCD_SCROLL_DEMO=1` abilita `LCD_ScrollDemo_Run()` dopo il campione grafico
precedente. La demo inizializza la finestra, copia una volta tutto lo schermo
e inserisce 32 righe, con scroll di 16 pixel e riempimento nero. Cornice e
sfondo esterni restano fermi. La demo termina sulle ultime 11 righe.

Variabili SWD: `g_lcd_scroll_demo_state` (1 in corso, 2 completata, 3 fallita),
`g_lcd_copy_count`, `g_lcd_scroll_count`, `g_lcd_copy_ms`, `g_lcd_scroll_ms`.
Gli ultimi due tempi includono invio e polling del completamento, con risoluzione
1 ms; non sono misure della sola latenza PSRAM.

```powershell
.\sim\run_spi_sim.ps1 -TimeoutSeconds 180
.\sim\run_double_buffer_sim.ps1 -Blit
.\sim\run_double_buffer_sim.ps1 -Blit -RealFifo
.\sim\run_sim.ps1 -Mode current
.\build.ps1 -NoCompress
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -RequireScroll -SerialNumber 35FF6C064D53373238602143
# Solo lettura, verificando prima la corrispondenza flash MCU / ELF:
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -RequireScroll -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

Il runner hardware richiede entrambi i flag `LCD_FPGA_TEXT_DEMO=1` e
`LCD_SCROLL_DEMO=1`: attende 50 PRESENT/IRQ complessivi (17 precedenti e 33
del terminale), una COPY e 32 SCROLL, nessun errore e IRQ finale rilasciato.
Salva `build/Release/scroll-result.json`. Anche senza `-RequireScroll` rileva
automaticamente `LCD_SCROLL_DEMO=1`; con il flag esplicito rifiuta una
configurazione che abbia disabilitato la demo.

Il test unitario verifica 99 casi contro un riferimento per pixel, compresi
entrambi gli slot, padding, spostamenti estremi e handshake ritardati.
L'integrazione TOP verifica anche pacchetti errati/interrotti, barriera durante
il fill, blocco di comandi concorrenti, isolamento front/back, letture video
separate e presentazione dopo copie e scroll. La PSRAM è un modello: il
collaudo hardware e la conferma visiva restano verifiche distinte.

La FIFO video usa un flag Full registrato con confronto anticipato del
puntatore successivo. Il test `tb_framebuffer_fifo` verifica 10.000 parole in
ordine, riempimento completo, tentativi di overflow, svuotamento, più giri dei
puntatori e produttore/consumatore su clock diversi. Il segnale di fine
calibrazione e i confronti della sequenza PRESENT sono registrati prima di
entrare nel controllo della memoria, per ridurre i percorsi combinatori a 81 MHz.

## Risultati al banco — 16 settembre 2026

FPGA e font caricati in flash, firmware STM32 Release programmato e verificato.
Il collaudo SWD passa: 50 PRESENT/IRQ, una COPY, 32 SCROLL, nessun errore
SPI/LCD/HAL, IRQ finale alto. `g_lcd_scroll_demo_state=2`, front 0 e sequenza 50.

| Operazione | Tempo MCU osservato |
|---|---:|
| COPY 480x272 | 14 ms |
| Ultimo SCROLL 442x176, dx=0, dy=-16 | 8 ms |
| Ultimo PRESENT | 16 ms |
| Clear completo B9 | 8 ms |

Tempi inclusivi di invio e attesa, risoluzione 1 ms; non sono limiti massimi.
La demo fa una sola COPY completa all'inizio, poi aggiorna soltanto il viewport.

Build FPGA `-NoCompress`, PlaceOption 1: zero violazioni di timing,
Fmax PSRAM 81.909 MHz a fronte degli 81 MHz operativi; 5209 risorse logiche,
3659 registri e 3 BSRAM. Nessun vincolo SDC allentato. Il controller usa codifica
one-hot e registra il confine sincronizzato del frame per un ulteriore ciclo
PSRAM (circa 12 ns), sempre nel blanking verticale.

Risultato macchina: `stm32/WeAct_H743_SPI/build/Release/scroll-result.json`.

Verifica finale della versione caricata con `-Blit -RealFifo`: PASS, 12 casi,
quattro swap e otto frame interi (1.044.480 pixel). L'utente ha osservato lo
scorrimento e l'arresto dopo le 32 righe, come previsto dalla demo.
