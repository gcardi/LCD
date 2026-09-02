# Tang Nano 9K RGB LCD experiment

Esperimento FPGA per pilotare un pannello LCD RGB 480×272 con una Sipeed
Tang Nano 9K.

Il progetto inizializza la PSRAM integrata con un frame buffer RGB565, lo legge
a burst attraverso una FIFO dual-clock e genera i segnali di timing del display.
Il pattern corrente è formato da otto barre orizzontali colorate, alte 34 righe.

![Barre orizzontali visualizzate sul pannello LCD](docs/assets/images/HBars.jpg)

## Struttura

- `src/TOP.sv`: integrazione di clock, PSRAM, frame buffer, FIFO e display;
- `src/FramebufferController.sv`: scrittura e lettura del frame buffer in PSRAM;
- `src/VGA_Timing.sv`: timing RGB 480×272 e conversione RGB565;
- `src/ResetSynchronizer.sv`: reset asincrono in assert, sincrono in rilascio;
- `src/FramebufferFifo.sv`: FIFO dual-clock con almost-full pipelined;
- `src/PulseSynchronizer.sv`: trasporto di un impulso fra domini di clock;
- `src/LCD.cst`: assegnazione dei pin della Tang Nano 9K;
- `src/LCD.sdc`: vincoli di timing e gruppi di clock asincroni;
- `LCD.gprj`: progetto Gowin EDA.

## Build e programmazione

Il flusso attualmente verificato usa Gowin EDA per il dispositivo
`GW1NR-LV9QN88PC6/I5`. Aprire `LCD.gprj` e avviare sintesi e place-and-route;
il bitstream risultante è `impl/pnr/LCD.fs`.

Per caricarlo nella SRAM volatile da PowerShell:

```powershell
.\program_tang_nano_sram.ps1
```

Ulteriori dettagli sono in [PROGRAMMING.md](PROGRAMMING.md).

Il `.gitignore` prevede anche output prodotti da Yosys, nextpnr-gowin e Apicula,
tipicamente raccolti in `build/`. Il controller PSRAM usato qui è però un IP
Gowin: per un flusso interamente open-source, come quello proposto da Lushay
Labs, questa parte deve essere sostituita con un'implementazione compatibile.


## Simulazione

`sim/` contiene un testbench che inietta un underrun della FIFO a metà area
visibile e conta quanti frame restano danneggiati dopo il guasto. Serve
Icarus Verilog (oss-cad-suite):

```powershell
.\sim\run_sim.ps1                # RTL attuale
.\sim\run_sim.ps1 -Mode model    # con la FIFO comportamentale di riferimento
.\sim\run_sim.ps1 -Mode legacy   # RTL pre-fix: dimostra il danno permanente
```

Il modello di PSRAM ignora i dati scritti e risponde con un pattern derivato
dall'indirizzo. È deliberato: le barre orizzontali non possono rivelare un
disallineamento del frame buffer, una rampa per-pixel sì.
