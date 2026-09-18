# Logo di avvio

Al reset la FPGA disegna un logo al centro del pannello, prima di accettare
qualsiasi comando SPI. Non serve un MCU acceso, non serve un `B7`: se la scheda
ha corrente e la User Flash è programmata, il logo compare. È il primo segnale
visibile che bitstream e User Flash sono coerenti fra loro.

![Il logo di avvio](../resources/BootLogo.png)

I pixel stanno nella stessa immagine di User Flash che porta i font, in coda
alle tre tabelle Terminus. Non sono nel bitstream, e questa è la scelta che
decide tutto il resto: cambiare logo è rigenerare un file e riprogrammare la
flash, non risintetizzare. Anche posizione e dimensioni arrivano dalla flash,
non da parametri RTL.

## Formato

L'immagine di User Flash sale a **versione 2**. La parola 6 dell'header (offset
24, little endian) porta l'offset in byte della sezione logo; zero significa che
non c'è. I font non si spostano: la sezione va in fondo, dopo di loro, così
aggiungere, cambiare o togliere il logo non muove un solo offset di glifo.

Header dell'immagine, per la parte che riguarda qui:

| Offset | Campo |
|---:|---|
| 0..3 | magic `LCDF` |
| 4..5 | versione, ora `2` |
| 6..7 | byte di header, `64` |
| 8..11 | byte totali dell'immagine |
| 12..15 | CRC-32 del payload |
| 24..27 | offset della sezione logo, `0` se assente |

La sezione è autodescrittiva: la geometria viaggia con i pixel, quindi il fabric
legge la dimensione di ciò che sta per disegnare invece di fidarsi di una
costante.

| Offset nella sezione | Campo |
|---:|---|
| 0..3 | magic `LGO1` |
| 4..5 | larghezza |
| 6..7 | altezza |
| 8..11 | formato, `1` = RGB565 |
| 12..13 | origine x |
| 14..15 | origine y |
| 16.. | pixel RGB565 little endian, per righe |

Una parola di flash porta **due pixel**, e ogni riga comincia su una parola: da
qui il vincolo di larghezza pari, l'unico che il generatore impone oltre a
"deve stare nel pannello". Con larghezza dispari la seconda riga partirebbe a
metà parola e tutto lo scorrimento del flusso andrebbe fuori passo.

L'immagine attuale è `resources/BootLogo.png`, 128x72, centrata a (176,100).
Costa **18.448 byte** dei 77.824 della User Flash: l'immagine complessiva passa
da 25.152 a 43.600 byte e ne restano liberi 34.224.

## Generazione

```powershell
python .\tools\generate_user_flash_fonts.py .\third_party\terminus-font-4.49.1-master .\fonts --logo .\resources\BootLogo.png
.\program_tang_nano_flash.ps1
```

`--logo` accetta qualsiasi formato che Pillow sappia aprire. L'alfa viene
composta qui sopra il nero, non portata in flash: il fabric disegna un
rettangolo pieno, senza maschera e senza rileggere il framebuffer. La
conversione a RGB565 arrotonda al livello rappresentabile più vicino invece di
troncare, così il bianco resta bianco. Il centraggio è calcolato dal generatore,
quindi spostare il logo non richiede una nuova sintesi.

Il generatore rifiuta larghezza dispari, immagine vuota e qualsiasi cosa più
grande di 480x272, e stampa a fine corsa geometria, byte e numero di colori
distinti.

**La trappola da conoscere:** rigenerare l'immagine *senza* `--logo` produce un
file perfettamente valido, con il CRC giusto, che si programma senza un
avvertimento — e lascia la scheda muta all'avvio. Dimenticare una parola sulla
riga di comando è il modo più facile di perdere il logo, e il solo posto in cui
il guasto si vede è il pannello. Per questo la simulazione ha una variante
apposta, `+nologo`, descritta più sotto.

## Cosa controlla la FPGA

`FontStore` legge il descrittore **dopo** che il CRC-32 ha già garantito ogni
byte dell'immagine. I controlli che fa non riguardano quindi la corruzione, ma
il layout: servono a riconoscere un'immagine il cui logo non è quello che questo
fabric sa disegnare. Sono quattro, uno per parola del sotto-header — magic,
dimensioni, formato, origine — e verificano anche che il rettangolo si chiuda
dentro il pannello.

Un logo che non passa uno qualsiasi di questi controlli **viene scartato, e i
font salgono lo stesso**. Il testo è la funzione, il logo è decorazione: non ha
senso perdere il primo per il secondo. Allo stesso modo, l'offset nell'header
viene creduto solo se è una parola dentro il payload.

La versione invece è confrontata per intero: un'immagine e un bitstream di
versioni diverse si rifiutano a vicenda invece di leggere da un layout che si è
spostato. In pratica non capita, perché si programmano insieme
([PROGRAMMING.md](PROGRAMMING.md)).

## Come viene disegnato

`TextRenderer` disegna il logo **una volta per reset**, prima di accettare il
primo comando. Riusa il percorso del riempimento B9: stessa camminata sul
rettangolo, stessa costruzione dei burst, con la differenza che il colore fisso
è sostituito dal flusso di pixel letto dalla flash. Si consuma un pixel
memorizzato per ogni colonna selezionata, e le colonne fuori dal rettangolo
vengono saltate senza toccare il flusso.

Non serve un multiply per scorrere l'immagine: un puntatore a parola che avanza
basta, perché la larghezza è pari e ogni parola porta i due pixel successivi.

Il logo **non consuma un comando SPI**. `TextRenderer` alza `boot_complete`
solo dopo che l'ultimo burst è stato accettato; `SpiFramebuffer` risincronizza
quel livello nel dominio SCK con due flip-flop. Fino ad allora `BB` espone
`busy=1` e B7/B8/B9/BA/BC/BD/BE non accettano lavoro. Il firmware resta quindi
nel polling di disponibilità e non può sovrapporre il primo flush al logo.

Questo sbarramento è necessario anche se `command_take` resta basso durante il
logo: B7/BD/BE usano la coda diretta e non passano da `TextRenderer`. Senza il
segnale esplicito avrebbero potuto scrivere mentre il logo era ancora in coda,
lasciando che gli ultimi burst di avvio sovrascrivessero pixel dell'MCU.

L'ordine rispetto al riempimento iniziale del framebuffer non richiede logica
dedicata: `FramebufferController` non serve alcun update finché la calibrazione
PSRAM e il riempimento non sono finiti, quindi i burst del logo restano
nell'handshake e arrivano dopo. Il logo si posa sul pattern diagonale di avvio.

## Costo all'avvio

La validazione è una camminata bit-seriale sul CRC di tutta l'immagine, quindi
cresce con l'immagine: con il logo `fonts_ready` sale a **16,5 ms** dal reset
invece dei circa 9,5 ms della sola immagine font. Disegnare i 9.216 pixel ne
aggiunge **1,4 ms**. Sono i numeri misurati in simulazione a 27 MHz; sul
pannello non sono osservabili separatamente, perché tutto questo finisce prima
che il primo frame sia visibile.

## Verifica

`sim/tb_boot_logo.sv` pilota `FontStore` e `TextRenderer` insieme, senza alcun
comando SPI, e confronta ogni pixel scritto con una copia indipendente della
stessa immagine di User Flash letta dal file. Dimostra che ogni pixel del
rettangolo è scritto **esattamente una volta**, con il colore memorizzato in
flash, all'indirizzo che il framebuffer si aspetta; che nulla fuori dal
rettangolo viene toccato; e che il logo non consuma un comando. Non dimostra
l'handshake CDC in `TOP` né l'arbitraggio PSRAM.

`tb_spi_framebuffer` verifica inoltre che una scrittura diretta venga respinta
prima di `boot_complete`; `tb_double_buffer` attraversa il `TOP`, controlla
`BB busy`, prova B7 e B9 durante lo sbarramento, quindi confronta l'intero
framebuffer di boot anche dopo un secondo reset comandato dalla MCU.

```powershell
.\sim\run_spi_sim.ps1
```

Il test fa parte della suite e ha dato:

```
fonts_ready at 16528889000, logo 128x72 at (176,100), base word 6292
PASS: boot_logo 9216 pixels, all matching the User Flash image
```

Con `+nologo` l'aspettativa si rovescia: il testbench pretende un'immagine
generata senza logo, e verifica che i font salgano comunque mentre non viene
disegnato **niente**. È la regressione da temere, quella che altrimenti si
vedrebbe solo sul pannello. Va eseguito su un'immagine rigenerata senza
`--logo`, quindi non è nella suite automatica:

```powershell
python .\tools\generate_user_flash_fonts.py .\third_party\terminus-font-4.49.1-master $env:TEMP\nologo
copy $env:TEMP\nologo\user_flash_fonts.mem .\fonts\user_flash_fonts.mem
vvp -N .\sim\build\tb_boot_logo.vvp +nologo
```

Ricordarsi di rigenerare l'immagine **con** `--logo` subito dopo.
