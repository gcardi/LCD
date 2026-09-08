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
punta a `Gowin_V1.9.12.01_x64`. Con un'altra versione installata va aggiornata
la variabile `$programmer` in `program_tang_nano_sram.ps1`.

La programmazione SRAM viene persa quando la scheda viene spenta.
