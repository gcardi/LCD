# Programmazione Tang Nano 9K

La configurazione verificata per questo progetto è:

- dispositivo: `GW1NR-9C` (part number `GW1NR-LV9QN88PC6/I5`);
- ID JTAG rilevato: `0x1100481B`;
- cavo per `programmer_cli`: `--cable-index 1`;
- operazione `2`: programmazione SRAM volatile;
- bitstream: `impl/pnr/LCD.fs`.

Dal 10 settembre 2026 i due script di programmazione usano **openFPGALoader**,
non `programmer_cli`: è quello che ha prodotto il primo avvio da flash riuscito
con i font a bordo. `programmer_cli` resta raggiungibile con
`-UseGowinProgrammer`, ma richiede il driver FTDI originale — con il WinUSB
installato da Zadig non vede proprio il cavo. Le due sezioni in fondo spiegano
come passare dall'uno all'altro.

Da PowerShell, nella directory del progetto:

```powershell
.\program_tang_nano_sram.ps1
```

Per usare un altro file `.fs`:

```powershell
.\program_tang_nano_sram.ps1 -Bitstream "percorso\altro_file.fs"
```

Il bitstream non viene prodotto da questo script: va generato prima con
`.\build.ps1`, oppure con sintesi e place-and-route dalla GUI di Gowin EDA.
`.\build.ps1 -Program` esegue le due cose in sequenza e programma soltanto dopo
che il gate di timing è stato superato; vedi [VERIFICATION.md](VERIFICATION.md).

Lo script termina con un'eccezione se il bitstream indicato non esiste o se
`programmer_cli` restituisce un codice diverso da zero.

A differenza di `build.ps1`, che cerca l'installazione di Gowin sotto
`C:\Program Files\Gowin`, qui il percorso di `programmer_cli.exe` è fisso e
punta a `Gowin_V1.9.12.01_x64`. Con un'altra versione installata si passa
`-ProgrammerPath`, oppure si aggiorna il percorso predefinito in
`tools/Invoke-GowinProgrammer.ps1`, che ora è l'unico punto in cui compare.

## Due trappole di programmer_cli

Entrambi gli script passano da `tools/Invoke-GowinProgrammer.ps1`, che esiste
per gestire due comportamenti scoperti il 10 settembre 2026:

- **`programmer_cli` non parte se l'ambiente definisce `PYTHONIOENCODING`.** È
  un eseguibile Python congelato e il suo interprete rifiuta la forma
  `utf-8:surrogateescape`: muore con `0xC0000409` e `Fatal Python error:
  Py_Initialize` prima ancora di aprire il cavo. Da una PowerShell interattiva
  non si vede quasi mai, ma colpisce qualunque automazione che esporti quella
  variabile. L'helper la azzera per la durata della chiamata e la ripristina.
- **`programmer_cli` esce con codice 0 anche quando stampa `Error: Verify
  Failed`.** Il solo controllo di `$LASTEXITCODE` dichiarerebbe quindi
  "programmata e verificata" una scheda mai verificata. L'helper ispeziona anche
  l'output e solleva un'eccezione se vi trova un errore.

La programmazione SRAM viene persa quando la scheda viene spenta.

Per rendere persistenti sia il bitstream sia i tre font della User Flash:

```powershell
.\program_tang_nano_flash.ps1
```

Questo passa `impl/pnr/LCD.fs` e i font insieme, e con `-UseGowinProgrammer`
usa l'operazione Gowin 6 (`embFlash Erase,Program,Verify`) invece di
openFPGALoader. In entrambi i casi il file dei font e' `user_flash_fonts.bin`:
lo script controlla che cominci per `LCDF` prima di scrivere, e per il percorso
Gowin ne trascrive un `.fi` temporaneo, perche' `programmer_cli` legge solo
quello.
Il build imposta `-bit_security 0`, necessario per consentire la verifica della
Embedded Flash durante lo sviluppo. La compressione del bitstream si disattiva
con `.\build.ps1 -NoCompress`, ma non serve a superare la verifica: provata il
10 settembre 2026, fallisce esattamente come quella compressa. Tenerla attiva.

## `Verify Failed`: non dice nulla, va accertato

`programmer_cli` fallisce **sempre** la verifica della Embedded Flash su questo
progetto, e con essa stampa `Error: Program failed`, spesso uscendo con codice 1.

Il 10 settembre 2026 avevo concluso che fosse un falso allarme innocuo. **Era
sbagliato.** Dopo una di quelle programmazioni la scheda non si è più avviata:
FPGA non configurata, `User Code 0x00000000`, e la MCU ha registrato
`ready_attempts = 167` in due secondi senza mai ricevere risposta. Altre volte,
con lo stesso messaggio, la flash si è avviata benissimo. Il messaggio quindi
**non correla** con l'esito: va accertato ogni volta.

Le due metà si accertano in modi diversi.

**User Flash, cioè i font — subito, senza togliere corrente.** Basta configurare
la logica e guardare lo schermo:

```powershell
.\program_tang_nano_sram.ps1
# poi resetta la MCU
```

Se il testo compare, i font sono corretti byte per byte: `FontStore` ne verifica
il CRC-32 sui 25.152 byte prima di accettare qualunque comando. Se invece
`g_lcd_error.phase` vale 11, l'immagine font non è valida.

**Bitstream — solo con un ciclo di alimentazione.** Subito dopo la
programmazione il dispositivo resta non configurato, quindi `Read Device Codes`
riporta `User Code 0x00000000` e il bit di CRC error, che sembra una flash vuota
ma non prova niente. Stacca e riattacca l'alimentazione, poi rileggi: se il
User Code non è più `0x00000000`, la flash è buona. Il pulsante di reset non
serve, perché qui è un reset logico e non provoca riconfigurazione.

## Programmare senza `--fiFile` cancella i font

Vale la pena ripeterlo perché è successo davvero: una programmazione del solo
bitstream, fatta per isolare un problema, ha cancellato la User Flash. Il
sintomo è preciso — `g_lcd_error.phase = 11`, byte di stato `E2` invece di `C3` —
e si ripara riprogrammando con `program_tang_nano_flash.ps1`, che passa sempre
entrambi i file.

Per rimettere in funzione la scheda subito, senza aspettare,
`program_tang_nano_sram.ps1` la configura in pochi secondi in modo volatile.

Il generatore emette `user_flash_fonts.bin`, il `.mem` per le simulazioni e un
manifest JSON. Il `.fi` non c'e' piu' fra i file versionati: e' una
trascrizione dell'immagine, non un sorgente, e lo script se lo produce quando
serve con `--fi-from`. Gli indirizzi al suo interno sono esadecimali senza
prefisso.

## Embedded Flash e User Flash sono lo stesso array

Sul GW1NR-9C bitstream e User Flash non sono due memorie distinte: occupano la
stessa flash interna. Lo si vede negli artefatti che il programmer lascia in
`impl/pnr/`: `LCD.bin` misura 444.426 byte, mentre l'immagine fusa
`merged_withUserFlash.bin` ne misura 524.288. La differenza, circa 78 KB, è
esattamente la User Flash accodata in testa al bitstream.

Da qui discende l'unica regola operativa da rispettare:

- **ogni** programmazione della Embedded Flash *senza* `--fiFile` cancella i
  font. Non è un guasto e non dà errore: `FontStore` non trova più
  l'intestazione `LCDF`, alza `fonts_error`, e da quel momento il byte di stato
  del comando testo `B8` resta `E2`. Lato STM32 la demo fallisce con
  `g_lcd_fpga_text_demo_state = 3`. Per questo va usato sempre
  `program_tang_nano_flash.ps1`, mai `programmer_cli` a mano;
- `program_tang_nano_sram.ps1` (operazione 2) è invece sicuro: tocca solo la
  SRAM di configurazione e lascia intatti i font già programmati in flash. È il
  modo giusto di iterare sull'RTL senza riscrivere ogni volta i font.

Dopo una programmazione andata a buon fine, il rendering del testo diventa
disponibile qualche millisecondo dopo il reset: `FontStore` verifica in CRC-32
i 25.152 byte dell'immagine prima di accettare comandi. Il firmware STM32
attende già questa finestra, fino a un secondo, in `text_ready()`.

## Programmare con openFPGALoader: serve il `.bin`, non il `.fi`

openFPGALoader è il percorso predefinito dei due script, ed è quello che il
10 settembre 2026 ha prodotto il primo avvio da flash riuscito con i font a
bordo. I comandi che gli script eseguono sono questi:

```powershell
# flash: bitstream + font
openFPGALoader -b tangnano9k --write-flash impl\pnr\LCD.fs --user-flash fonts\user_flash_fonts.bin
# SRAM: senza --write-flash
openFPGALoader -b tangnano9k impl\pnr\LCD.fs
```

Il file dei font da passare è **`user_flash_fonts.bin`**, l'immagine binaria
grezza — ed è l'unico artefatto dei font versionato, proprio perché non ci sia
un secondo file da sbagliare. Passare un `.fi` stampa pure `CRC check:
Success`, ma non funziona: openFPGALoader non ha un parser per il formato `.fi`
di Gowin — nel binario esistono solo `FsParser` e `RawParser` — e scrive il file
byte per byte così com'è. Il `.fi` è testo ASCII che comincia con dieci righe
`//Copyright...`, quindi in User Flash finisce quel commento al posto
dell'intestazione `LCDF` e `FontStore` rifiuta l'immagine. Il sintomo è lo
stesso della programmazione senza `--fiFile`: `g_lcd_error.phase = 11`.

Il `CRC check: Success` finale non smentisce niente di tutto questo, perché
copre **solo il bitstream**: `--verify` di openFPGALoader vale per le SPI flash
esterne, e la User Flash interna non viene riletta da nessuno. L'unico modo di
verificarla resta il CRC-32 che `FontStore` calcola a runtime.

Vale la pena notare che con lo stesso comando il programmer stampa due barre di
avanzamento distinte, una per il bitstream e una molto più breve per la User
Flash: se la seconda manca, i font non sono stati scritti.

## Un solo file dei font, e perché

I due programmatori vogliono formati diversi e nessuno dei due si accorge di
ricevere quello sbagliato: scrivono e basta, e il guasto si manifesta soltanto
come font non validi a bordo. Per non lasciare la scelta a chi programma, nel
repository c'è **un solo artefatto dei font**, `fonts/user_flash_fonts.bin`, e
il `.fi` per Gowin viene trascritto al volo in un file temporaneo:

```powershell
python .\tools\generate_user_flash_fonts.py --fi-from .\fonts\user_flash_fonts.bin --fi-out out.fi
```

La trascrizione è deterministica e verificata byte per byte contro il `.fi` che
era versionato prima. In più, `program_tang_nano_flash.ps1` controlla che
l'immagine cominci per `LCDF` prima di scrivere: è lo stesso controllo che
`FontStore` fa a bordo, ma prima del danno anziché dopo.

Che `programmer_cli` non possa mangiare il binario è accertato dentro
`JTAGLoading.exe`, il modulo che fa il lavoro: espone una classe
`UserFlashFile` con un attributo `comments`, un parser a righe (`readlines`,
`startswith`) e il riconoscimento della riga `//File Format`. È un parser
ASCII. La riga `//File Format: Hex` ha come alternativa `Bin`, che però non è
binario grezzo: sono i 32 bit scritti come 32 caratteri `0` e `1`.

Attenzione infine a una conseguenza del cambio di driver: con il WinUSB di
Zadig installato, `programmer_cli` non fallisce con un errore ma **resta
appeso**, anche solo per leggere i codici del dispositivo. Se succede, il
driver è quello sbagliato per lui.

## Nota su utilizzo di Zadig

### Per passare da GowinProgrammer (programmer_cli) a openFPGALoader

Il dispositivo da modificare è JTAG Debugger (Interface 0) — è l'interfaccia 0 (MI_00), quella JTAG. Se legata al driver FTDIBUS non va bene.

- Chiudere eventuali strumenti Gowin aperti.
- Avviare Zadig come amministratore.
- Menu Options → List All Devices (mettere la spunta, altrimenti le due interfacce non compaiono).
- Nel menu a tendina scegliere JTAG Debugger (Interface 0). Verificare sotto che il USB ID sia 0403 6010 e che l'interfaccia sia (Interface 0).
- Come driver di destinazione selezionare WinUSB con le frecce.
- Premere Replace Driver e confermare.

⚠️ Non si deve toccare JTAG Debugger (Interface 1). È l'interfaccia 1, quella che fornisce la porta seriale COM3: se sostituisci quel driver si perde la seriale.

Due effetti attesi, entrambi normali:

- programmer_cli smetterà di vedere il cavo: da quel momento si programma solo con openFPGALoader.
- Lo schermo potrebbe annerirsi durante la sostituzione, perché il dispositivo si ri-enumera.

### Per tornare indietro (per usare di nuovo programmer_cli / Gowin Programmer)

Zadig non sa reinstallare il driver FTDI, quindi si passa da Gestione dispositivi: trova il dispositivo WinUSB, Disinstalla dispositivo spuntando Elimina il software del driver, poi stacca e riattacca l'USB. Windows rimette il driver FTDI da solo e programmer_cli ricomincia a funzionare.
