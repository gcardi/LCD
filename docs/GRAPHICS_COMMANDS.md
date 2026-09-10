# Comandi grafici supportati

Riferimento unico di tutto ciò che si può disegnare, aggiornato al 10 settembre
2026. Per il dettaglio byte per byte dei due protocolli vedere
[SPI_FRAMEBUFFER.md](SPI_FRAMEBUFFER.md) e [SPI_TEXT.md](SPI_TEXT.md); qui c'è
l'elenco completo, i limiti e ciò che **non** esiste.

Il quadro si legge su due livelli. La FPGA espone **due soli opcode SPI**, tutto
il resto è software sull'STM32 costruito sopra il primo dei due.

## Livello FPGA: gli opcode SPI

| Opcode | Cosa fa |
|---|---|
| `B7` | scrive un burst mascherato di 16 pixel RGB565 in PSRAM |
| `B8` | disegna una stringa UTF-8 con i font della User Flash |
| altro | percorso di eco diagnostica: risponde `A5` e poi l'eco del byte precedente |

Non ci sono altri opcode. In particolare non esistono comandi FPGA per
cancellare, riempire rettangoli, tracciare linee o cerchi, copiare aree,
rileggere i pixel o cambiare il colore di sfondo iniziale.

Il colore con cui la FPGA inizializza il framebuffer è
`FramebufferController.BACKGROUND_COLOR`, un **parametro di sintesi**: per
cambiarlo si ricompila il bitstream, non si manda un comando.

### Byte di stato

Sono gli stessi per entrambi gli opcode e vanno letti nell'ordine in cui
arrivano.

| Byte | Significato |
|---|---|
| `A5` | primo byte di risposta, sempre presente: lo slave è vivo |
| `C3` | comando accettabile, c'è posto nella coda |
| `00` | occupato: coda piena per `B7`, rendering in corso per `B8`; ritentare |
| `AC` | pacchetto accettato e messo in esecuzione |
| `E1` | pacchetto rifiutato: parametri fuori campo o CRC errato |
| `E2` | solo per `B8`: font non validi in User Flash, comando non disponibile |

`E2` è il sintomo che si vede quando la User Flash è stata cancellata o scritta
male; lato STM32 corrisponde a `g_lcd_error.phase = 11`. Vedi
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

## Livello STM32: l'API C

Da `Core/Inc/lcd_spi.h`. Tutte bloccanti, non rientranti, un solo chiamante.
Ritornano 1 in caso di successo e 0 per errore.

| Funzione | Cosa fa | Come |
|---|---|---|
| `LCD_WriteRect(x,y,w,h,pixels)` | rettangolo di pixel RGB565 arbitrari | burst `B7` |
| `LCD_FillRect(x,y,w,h,color)` | riempimento uniforme | burst `B7` |
| `LCD_Clear(color)` | riempie tutto il display | burst `B7` |
| `LCD_DrawTextFPGA(...)` | testo reso **dalla FPGA** | comando `B8` |

`LCD_FillRect` e `LCD_Clear` non sono comandi FPGA: sono cicli software che
riusano `LCD_WriteRect` con una riga da 480 pixel sullo stack (960 byte). Non
allocano un framebuffer completo. Rifiutano rettangoli vuoti o fuori schermo
**senza clipping**, e in caso di errore di trasporto l'area può restare
aggiornata a metà: non annullano le scritture già accettate.

`LCD_DrawTextFPGA` invece fa clipping, perché il riquadro è parte del protocollo.

### Testo renderizzato dalla CPU: esiste ancora, ma è superato

`Core/Inc/lcd_text.h` espone `LCD_DrawCodepoint` e `LCD_DrawText`, che
disegnano con una tabella 12x24 residente nella flash **dell'STM32** e mandano
i pixel come rettangoli `B7`. È il prototipo che ha preceduto il renderer FPGA:
cella fissa 12x24 soltanto, sfondo sempre opaco, nessun clipping e nessun
ritorno a capo. Si usa `LCD_DrawTextFPGA` al suo posto; resta perché è un utile
termine di paragone e non dipende dalla User Flash.

## Programmi di collaudo

Non sono primitive grafiche ma disegnano, quindi vale la pena sapere che
esistono. Si accendono dai flag in `Core/Inc/spi_diag_config.h`.

| Simbolo | Flag | Cosa disegna |
|---|---|---|
| `LCD_Demo_Run` | `LCD_BOOT_TESTS` | rettangolo 67x40 a (101,81), bordi non allineati |
| `LCD_Stress_Run` | `LCD_BOOT_TESTS` | rettangoli ripetuti per la qualifica prolungata |
| `LCD_TextDemo_Run` | `LCD_TEXT_DEMO` | testo con i font CPU |
| `LCD_FPGATextDemo_Run` | `LCD_FPGA_TEXT_DEMO` | testo con i font FPGA |

Ciascuno pubblica il proprio stato in una variabile globale letta via SWD dal
runner di collaudo: 0 non richiesto, 1 in corso, 2 completato, 3 fallito.

## Cosa manca, in breve

Utile averlo scritto per non ricercarlo ogni volta. Non esistono: linee,
cerchi, poligoni, blit fra aree del framebuffer, rilettura dei pixel, doppio
framebuffer, sincronizzazione con il vblank esposta al master, cambio del
colore di sfondo a runtime, font proporzionali, rotazione o scalatura dei
glifi. Un rettangolo può comparire progressivamente, perché non c'è doppio
buffer: il tearing è atteso.

Le idee per superare parte di questi limiti sono raccolte in
[LVGL_IMPL.md](LVGL_IMPL.md), che è però uno studio speculativo.
