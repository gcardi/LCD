# Programmazione Tang Nano 9K

La configurazione verificata per questo progetto è:

- dispositivo: `GW1NR-9C`;
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

La programmazione SRAM viene persa quando la scheda viene spenta.
