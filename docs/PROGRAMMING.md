# Programmazione Tang Nano 9K

La configurazione verificata per questo progetto è:

- dispositivo: `GW1NR-9C` (part number `GW1NR-LV9QN88PC6/I5`);
- ID JTAG rilevato: `0x1100481B`;
- cavo per `programmer_cli`: `--cable-index 1`;
- operazione `2`: programmazione SRAM volatile;
- bitstream: `impl/pnr/LCD.fs`.

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

Questo usa l'operazione Gowin 6 (`embFlash Erase,Program,Verify`) passando
insieme `impl/pnr/LCD.fs` e `fonts/user_flash_fonts.fi`.
Il build imposta `-bit_security 0`, necessario per consentire la verifica della
Embedded Flash durante lo sviluppo. La compressione del bitstream si disattiva
con `.uild.ps1 -NoCompress`, ma non serve a superare la verifica: provata il
10 settembre 2026, fallisce esattamente come quella compressa. Tenerla attiva.

Se la programmazione fallisce con `Error: Program failed`, prova un ciclo di
alimentazione della Tang Nano prima di ripetere: l'unico tentativo riuscito
finora era il primo dopo l'accensione. Nel frattempo `program_tang_nano_sram.ps1`
riporta la scheda in funzione in pochi secondi, in modo volatile. Gli indirizzi del `.fi` sono esadecimali
senza prefisso e il generatore emette anche `.mem`, `.bin` e un manifest JSON.

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
