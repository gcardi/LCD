# Comandi grafici supportati

Riferimento unico di tutto ciò che si può disegnare, aggiornato al 10 settembre
2026. Verificato contro `src/SpiFramebuffer.sv`, `src/TextRenderer.sv` e le
implementazioni in `stm32/WeAct_H743_SPI/Core/Src/`. Per il dettaglio byte per
byte di B7 e B8 vedere [SPI_FRAMEBUFFER.md](SPI_FRAMEBUFFER.md) e
[SPI_TEXT.md](SPI_TEXT.md); B9 è descritto qui. Qui c'è
l'elenco completo, i limiti e ciò che **non** esiste.

Il quadro si legge su due livelli: la FPGA espone **tre opcode grafici SPI**;
l'API STM32 prepara i pacchetti e gestisce attese, risposte ed errori.

## Livello FPGA: gli opcode SPI

| Opcode | Cosa fa |
|---|---|
| `B7` | scrive un burst mascherato di 16 pixel RGB565 in PSRAM |
| `B8` | disegna una stringa UTF-8 con i font della User Flash |
| `B9` | riempie un rettangolo o traccia una linea RGB565, senza trasferire i singoli pixel |
| altro | percorso di eco diagnostica: risponde `A5` e poi l'eco del byte precedente |

Non ci sono altri opcode grafici. `B9` permette anche linee orizzontali o
verticali spesse un pixel tramite rettangoli di altezza o larghezza 1, e di cancellare tutto lo
schermo riempiendolo con un colore. Non esistono comandi FPGA per tracciare
cerchi, copiare aree, rileggere i pixel o cambiare il parametro del
colore di sfondo iniziale.

Il colore con cui la FPGA inizializza il framebuffer è
`FramebufferController.BACKGROUND_COLOR`, un **parametro di sintesi**: per
cambiarlo si ricompila il bitstream, non si manda un comando.

### Byte di stato

Sono condivisi dai tre opcode, con l'eccezione di `E2`, e vanno letti nell'ordine in cui
arrivano.

| Byte | Significato |
|---|---|
| `A5` | primo byte di risposta, sempre presente: lo slave è vivo |
| `C3` | comando accettabile, c'è posto nella coda |
| `00` | occupato: coda piena per `B7`, coda/renderer condiviso occupato per `B8` e `B9`; ritentare |
| `AC` | pacchetto accettato e messo in esecuzione |
| `E1` | pacchetto rifiutato: parametri fuori campo o CRC errato |
| `E2` | solo per `B8`: font non validi in User Flash, comando non disponibile |

`E2` può essere transitorio durante la verifica iniziale dei font; persiste
quando la User Flash è stata cancellata o scritta male. L'API attende fino a
un secondo: il timeout di disponibilità di B8, anche per occupato persistente,
produce la fase 11 in `g_lcd_error`, spiegata sotto in
[Diagnostica](#diagnostica-leggere-lerrore). B9 non usa i font e resta
disponibile anche con User Flash non valida. Vedi
[PROGRAMMING.md](PROGRAMMING.md).

### `B7`, scrittura framebuffer

Un burst copre 16 pixel a partire da un indirizzo lineare **multiplo di 16** e
minore di 130.560 (480×272). Una maschera a 16 bit sceglie quali dei 16 pixel
scrivere davvero, ed è ciò che permette rettangoli non allineati: i bordi
usano maschere parziali. Il commit avviene alla ricezione del byte `5A`.

Non c'è CRC prima del commit, né rollback: un errore di trasmissione può essere
segnalato dall'eco *dopo* che la scrittura è stata accettata.

### `B8`, testo

Pacchetto unico chiuso da un CRC16-CCITT (init `FFFF`, polinomio `1021`) e da
un byte di commit `A6`. Il CRC è verificato **prima** di disegnare, quindi qui
un errore di trasmissione fa rifiutare il comando invece di sporcare lo
schermo — a differenza di `B7`.

| Parametro | Valori |
|---|---|
| font_id | 0 = 8x16, 1 = 12x24, 2 = 16x32 |
| flags | bit 0 sfondo trasparente, bit 1 ritorno a capo automatico |
| box | riquadro di clipping; 0 in larghezza o altezza si estende al bordo schermo |
| stringa | UTF-8, al massimo 64 byte codificati |

Il subset di glifi è ASCII stampabile, Latin-1, euro e le quattro frecce; un
codepoint assente diventa `?`. Le celle sono monospaziate. Il clipping al box e
allo schermo è sempre attivo. Il ritorno a capo avviene sul carattere di
nuova riga, e in più automaticamente se è impostato il flag wrap; senza wrap la
parte a destra del box viene scartata.

### `B9`, rettangoli e linee

Un pacchetto di **18 byte**, indipendentemente dall'area, descrive la forma.
La FPGA genera i burst mascherati in PSRAM. Condivide coda e renderer con B8:
testo e riempimenti vengono eseguiti uno alla volta.

È qui che sta il guadagno, ed è aritmetica del protocollo, non una stima:
`B7` trasporta 16 pixel per pacchetto da 41 byte, quindi cancellare lo schermo
significa 8160 pacchetti e circa 334 kB sul filo; `B9` fa la stessa cosa con
**un pacchetto da 18 byte**. Per questo l'interfaccia resta usabile da una MCU
piccola, che non deve né generare né trasferire i pixel.

| Offset | Campo MOSI |
|---:|---|
| 0 | opcode `B9` |
| 1 | dummy/status, inviato a zero dall'API |
| 2 | tipo forma: `00` = rettangolo, `01` = linea |
| 3 | flags riservati: `00` |
| 4..5 | x del rettangolo / x0 della linea, big endian |
| 6..7 | y del rettangolo / y0 della linea, big endian |
| 8..9 | larghezza del rettangolo / x1 della linea, big endian |
| 10..11 | altezza del rettangolo / y1 della linea, big endian |
| 12..13 | colore RGB565, big endian |
| 14..15 | CRC16-CCITT sui byte 2..13, init `FFFF`, polinomio `1021`, big endian |
| 16 | commit `A6` |
| 17 | dummy per leggere l'esito |

Tenere CS basso per il pacchetto. MISO restituisce `A5` all'offset 0,
`C3` oppure `00` all'offset 1, eco del byte MOSI precedente agli offset
2..16, infine `AC` o `E1` all'offset 17. Un poll separato di due byte
`B9 00` legge la disponibilità senza disegnare. Dopo `AC`, fare polling
finché torna `C3`, come fa `LCD_FillRect`; non equivale ad attendere il vblank.

Per il rettangolo, sul filo x deve essere 0..479 e y 0..271;
larghezza 0..1023, altezza 0..511.
Il renderer taglia al bordo dello schermo; dimensione zero estende fino al
bordo corrispondente. **L'API C è più restrittiva**: richiede dimensioni non
nulle e rettangolo interamente nello schermo.

Per la linea, entrambi gli estremi devono stare nello schermo: x0/x1 0..479,
y0/y1 0..271. Estremi inclusi, spessore un pixel, tutte le direzioni, nessun
clipping o antialiasing. Estremi coincidenti disegnano un punto.
La FPGA usa Bresenham intero: `dx=abs(x1-x0)`, `dy=-abs(y1-y0)`,
`err=dx+dy`; per ogni passo usa lo stesso `e2=2*err`, avanza X se `e2>=dy`
e Y se `e2<=dx`. Nei casi esattamente a metà, invertire gli estremi può
selezionare un pixel diverso. I pixel consecutivi sullo stesso burst
allineato e sulla stessa riga vengono riuniti in una maschera unica.

I bitstream precedenti, che supportano solo tipo 0, rifiutano tipo 1 con
`E1`: aggiornare anche la FPGA quando si usa `LCD_DrawLine` per linee oblique.
Il protocollo non espone ancora una negoziazione delle capacità.

Tipo, flags, coordinate o CRC non validi fanno rifiutare il comando prima
del disegno. Dopo il commit accettato, alzare CS non annulla l'operazione.
La verifica CRC non rende l'aggiornamento visivamente atomico: la FPGA
scrive progressivamente, senza doppio framebuffer.

## Livello STM32: l'API C e l'uso da C++

Da `Core/Inc/lcd_spi.h`. Tutte bloccanti, non rientranti, un solo chiamante.
Ritornano 1 in caso di successo e 0 per errore.

| Funzione | Cosa fa | Come |
|---|---|---|
| `LCD_WriteRect(x,y,w,h,pixels)` | rettangolo di pixel RGB565 arbitrari | burst `B7` |
| `LCD_FillRect(x,y,w,h,color)` | riempimento uniforme | un comando `B9` più polling |
| `LCD_Clear(color)` | riempie tutto il display | `LCD_FillRect(0,0,480,272,color)`, quindi `B9` |
| `LCD_DrawHLine(x,y,length,color)` | linea orizzontale, spessore 1 pixel | `LCD_FillRect(x,y,length,1,color)`, quindi `B9` |
| `LCD_DrawVLine(x,y,length,color)` | linea verticale, spessore 1 pixel | `LCD_FillRect(x,y,1,length,color)`, quindi `B9` |
| `LCD_DrawLine(x0,y0,x1,y1,color)` | linea con estremi inclusi, qualsiasi direzione | B9 tipo 1; H/V e punto usano il percorso fill tipo 0 |
| `LCD_DrawTextFPGA(...)` | testo reso **dalla FPGA** | comando `B8` |

`LCD_FillRect` costruisce due buffer locali di 18 byte (TX/RX), senza riga di
pixel né framebuffer completo. Attende la disponibilità B9 prima dell'invio
e dopo l'accettazione. `LCD_WriteRect` continua a inviare i pixel arbitrari
tramite B7; `pixels` contiene `w*h` valori RGB565 contigui, per righe.
Entrambe rifiutano rettangoli vuoti o fuori schermo **senza clipping**.
Un errore rilevato dopo un commit non annulla le scritture già accettate:
un ritorno 0 non garantisce che lo schermo sia rimasto invariato.

`LCD_DrawTextFPGA` invece fa clipping, perché il riquadro è parte del protocollo.
L'API accetta x < 480, y < 272, box_width <= 480 e box_height <= 272,
font_id 0..2, solo i due flag definiti e una stringa C UTF-8 non nulla di
massimo 64 byte, escluso il terminatore. Attende il renderer dopo l'invio.

Le linee si estendono a destra/in basso: l'ultimo pixel è rispettivamente
`x+length-1` o `y+length-1`. Lunghezza zero e linee anche solo parzialmente
fuori schermo restituiscono 0 senza inviare comandi; lunghezza 1 disegna un pixel.
Per una linea più spessa usare direttamente `LCD_FillRect`.

```c
LCD_DrawHLine(0, 0, 480, 0xFFFF);   // intera prima riga, bianca
LCD_DrawVLine(479, 0, 272, 0xF800); // intera ultima colonna, rossa
// Controllare il valore restituito: 1 successo, 0 errore.
```

Le firme complete sono in
[`lcd_spi.h`](../stm32/WeAct_H743_SPI/Core/Inc/lcd_spi.h).
Non esiste un wrapper C++ separato; gli header grafici attuali non includono
guardie `extern "C"`. Per chiamare le implementazioni compilate come C da
un file C++, includerli così:

```cpp
extern "C" {
#include "lcd_spi.h"
#include "lcd_text.h" // solo se si usa anche il renderer CPU
}
```

### Testo renderizzato dalla CPU: esiste ancora, ma è superato

`Core/Inc/lcd_text.h` espone `LCD_DrawCodepoint` e `LCD_DrawText`, che
disegnano con una tabella 12x24 residente nella flash **dell'STM32** e mandano
i pixel come rettangoli `B7`. È il prototipo che ha preceduto il renderer FPGA:
cella fissa 12x24 soltanto, sfondo sempre opaco, nessun clipping né wrap
automatico. `LCD_DrawText` gestisce `\n` e ignora `\r`; valida l'intero
riquadro prima di inviare i pixel. Si usa `LCD_DrawTextFPGA` al suo posto; resta perché è un utile
termine di paragone e non dipende dalla User Flash.

## Programmi di collaudo

Non sono primitive grafiche ma disegnano, quindi vale la pena sapere che
esistono. Si accendono dai flag in `Core/Inc/spi_diag_config.h`.

| Simbolo | Flag | Cosa disegna |
|---|---|---|
| `LCD_Demo_Run` | `LCD_BOOT_TESTS` | rettangolo 67x40 a (101,81), bordi non allineati |
| `LCD_Stress_Run` | `LCD_BOOT_TESTS` | rettangoli ripetuti per la qualifica prolungata |
| `LCD_TextDemo_Run` | `LCD_TEXT_DEMO` | testo con i font CPU |
| `LCD_FPGATextDemo_Run` | `LCD_FPGA_TEXT_DEMO` | clear, rettangolo, cornici H/V e stella a otto raggi B9, testo FPGA |

Ciascuno pubblica il proprio stato in una variabile globale letta via SWD dal
runner di collaudo: 0 non richiesto, 1 in corso, 2 completato, 3 fallito.
La demo FPGA espone anche `g_lcd_clear_ms16`: millisecondi complessivi di
16 clear a schermo intero, misurati prima del campione grafico/testuale.

## Diagnostica: leggere l'errore

Quando una primitiva restituisce 0, il motivo resta registrato in
`g_lcd_error`, un `uint32_t[6]` letto via SWD dal runner di collaudo:

| Indice | Contenuto |
|---:|---|
| 0 | fase; **0 significa nessun errore** |
| 1 | indirizzo |
| 2 | indice del byte nel pacchetto |
| 3 | valore atteso |
| 4 | valore ricevuto |
| 5 | codice di errore HAL |

Viene registrato **solo il primo guasto**: le chiamate successive non
sovrascrivono il record, quindi la fase indica dove le cose sono andate storte
la prima volta, non l'ultima.

| Fase | Dove | Significato |
|---:|---|---|
| 1 | `exchange` | il trasferimento SPI HAL è fallito |
| 2, 3, 4 | attesa `B7` | primo byte non `A5`; stato non `C3`/`00`; timeout |
| 5, 6 | `LCD_WriteRect` | primo byte non `A5`; secondo byte non `C3` |
| 7, 8 | `LCD_WriteRect` | esito del commit non `AC`; eco non corrispondente |
| 9, 10 | attesa `B8` | primo byte non `A5`; stato non `C3`/`00`/`E2` |
| 11 | attesa `B8` | timeout: font non validi, o renderer bloccato |
| 12, 13 | `LCD_DrawTextFPGA` | primo byte non `A5`; secondo byte non `C3` |
| 14, 15 | `LCD_DrawTextFPGA` | eco non corrispondente; esito non `AC` |
| 16, 17 | attesa `B9` | primo byte non `A5`; stato non `C3`/`00` |
| 18 | attesa `B9` | timeout: renderer occupato oltre un secondo |
| 19, 20 | `B9`, invio | primo byte non `A5`; secondo byte non `C3` |
| 21 | `B9`, invio | eco non corrispondente: problema di trasporto |
| 22 | `B9`, invio | esito `E1`: **la FPGA ha rifiutato la forma** |

La fase più informativa è la **22**. Significa che il pacchetto è arrivato
integro ma il renderer non lo ha accettato, e le cause sono poche: CRC16
sbagliato, coordinate fuori dai limiti sul filo, flag diversi da zero, oppure
tipo forma `01` inviato a **un bitstream più vecchio che conosce solo il
rettangolo**. Quest'ultimo caso è il più insidioso perché il firmware sembra
corretto: se `LCD_DrawLine` fallisce solo sulle oblique, mentre orizzontali e
verticali funzionano, è la FPGA a essere da riprogrammare, non il codice.

La fase **11** ha un valore analogo per il testo: è la firma di una User Flash
cancellata o scritta male. Vedi [PROGRAMMING.md](PROGRAMMING.md).

## Cosa manca, in breve

Utile averlo scritto per non ricercarlo ogni volta. Non esistono: cerchi,
poligoni come comando dedicato, blit fra aree del framebuffer, rilettura dei pixel, doppio
framebuffer, sincronizzazione con il vblank esposta al master, cambio del
parametro di sfondo iniziale a runtime, font proporzionali, rotazione o scalatura dei
glifi. Un rettangolo può comparire progressivamente, perché non c'è doppio
buffer: il tearing è atteso.
Il contenuto di sfondo visibile si può invece cambiare a runtime con `LCD_Clear`.

Le idee per superare parte di questi limiti sono raccolte in
[LVGL_IMPL.md](LVGL_IMPL.md), che è però uno studio speculativo. Per copie,
scroll, framebuffer multipli e ROP vedere [BLITTING_ROP_STUDY.md](BLITTING_ROP_STUDY.md),
anch'esso solo studio, senza implementazione.
