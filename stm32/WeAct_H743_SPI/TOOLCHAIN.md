# Origine e toolchain del progetto STM32

Documento di corredo al firmware `WeAct_H743_SPI`, ancora in stato abbozzato:
descrive da dove nasce il progetto, quali file appartengono al generatore e
quali sono scritti a mano, e come rigenerarlo senza perdere il lavoro manuale.
Cablaggio, build, upload e risultati dei collaudi sono nel [README](README.md).

## Da dove nasce

Il progetto e' stato creato con **STM32CubeMX 6.18.1** (database `DB.6.0.181`),
selezionando la generazione di codice per **CMake** e non per STM32CubeIDE o
Makefile. Il file di configurazione e' `WeAct_H743_SPI.ioc`, unica sorgente di
verita' per pinout, clock e periferiche.

| Voce | Valore |
|---|---|
| MCU | STM32H743VIT6, LQFP100 (`Mcu.UserName=STM32H743VITx`) |
| Scheda | WeAct MiniSTM32H743, definita come `board=custom` |
| Pacchetto firmware | STM32Cube FW_H7 V1.13.0 |
| Toolchain di destinazione | `ProjectManager.TargetToolchain=CMake` |
| SYSCLK | 480 MHz |
| Periferiche | SPI2 master full duplex, DMA1 (SPI2_TX, SPI2_RX), GPIO |

Le opzioni di Project Manager rilevanti sono `KeepUserCode=true`,
`BackupPrevious=true` e `CoupleFile=true`: la rigenerazione conserva le sezioni
`USER CODE`, salva le versioni precedenti in `Core/*/Backup/*.bak` e mantiene la
struttura a file separati per periferica (`gpio.c`, `spi.c`, `dma.c`).

## Ambiente di sviluppo

Il progetto si apre in **Visual Studio Code** con il plugin ufficiale ST
*STM32CubeIDE for Visual Studio Code*. Sulla macchina di sviluppo sono presenti
i componenti `stmicroelectronics.stm32cube-ide-build-cmake` 1.46.0,
`-build-analyzer` 1.4.0, `-bundles-manager` 1.4.0 e `-clangd` 1.0.6, affiancati
da `ms-vscode.cmake-tools`, `ms-vscode.cpptools` e `marus25.cortex-debug`.
Un'eventuale estensione di terze parti `bmd.stm32-for-vscode` non serve a questo
progetto e conviene tenerla disattivata per evitare configurazioni concorrenti.

Strumenti da riga di comando usati dagli script, con le versioni del primo
collaudo:

| Strumento | Versione | Provenienza |
|---|---|---|
| STM32CubeCLT | 1.17.0 | `C:\ST\STM32CubeCLT_1.17.0` |
| arm-none-eabi-gcc | 12.3.1 (GNU Tools for STM32 12.3.rel1) | CubeCLT |
| STM32_Programmer_CLI | incluso nel CubeCLT | usato da `build.ps1` |
| CMake | 4.1.1 | PATH |
| Ninja | 1.13.2 | PATH |

`build.ps1` cerca `STM32_Programmer_CLI.exe` nel PATH e poi in
`C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/`; con installazioni diverse si usa
`-ProgrammerPath`. Compilatore, CMake e Ninja devono essere raggiungibili dal
PATH: il file toolchain non ne codifica il percorso assoluto.

Le build e gli upload passano dagli script PowerShell del progetto, richiamabili
anche come task VS Code (`.vscode/tasks.json`), non dai comandi dell'estensione:
cosi' la stessa procedura vale in VS Code, da terminale e in una eventuale CI.
Non e' committato alcun `launch.json`; il debug ST-LINK va configurato in locale
(cortex-debug o il debugger dell'estensione ST) e resta un punto aperto.

## Chi possiede quale file

**Rigenerati da CubeMX a ogni Generate Code** (non modificare fuori dalle
sezioni `USER CODE`):

- `Core/Inc/*.h` e `Core/Src/*.c` generati: `main`, `gpio`, `spi`, `dma`,
  `stm32h7xx_it`, `stm32h7xx_hal_msp`, `stm32h7xx_hal_conf`, `system_stm32h7xx`,
  `syscalls`, `sysmem`
- `Drivers/` (HAL/LL e CMSIS), `startup_stm32h743xx.s`, `STM32H743xx_FLASH.ld`
- `cmake/stm32cubemx/CMakeLists.txt`, che elenca sorgenti, include e macro
- `Core/*/Backup/*.bak`, copie della generazione precedente

**Generati una volta sola e da allora manutenuti a mano** (CubeMX li crea al
primo Generate Code e non li sovrascrive, come dichiara l'intestazione del file):

- `CMakeLists.txt` di primo livello
- `CMakePresets.json` (preset `Debug` e `Release`, generatore Ninja, output in
  `build/<preset>/`)
- `cmake/gcc-arm-none-eabi.cmake` (Cortex-M7, `fpv5-d16`, float ABI hard)
- `cmake/starm-clang.cmake`, toolchain alternativa generata ma non usata dai
  preset

**Interamente scritti a mano:**

- `Core/Src/spi_selftest.c`, `Core/Inc/spi_selftest.h`, `Core/Inc/spi_diag_config.h`
- `cmake/spi_dma.ld`, script linker supplementare
- `build.ps1`, `test-hardware.ps1`, `diagnose-hardware.ps1`
- `.vscode/tasks.json`, `README.md`, questo documento

Sotto `stm32/` il `.gitignore` esclude `build/`, artefatti oggetto ed ELF,
`compile_commands.json`, `CMakeUserPresets.json`, `.mxproject` e lo stato locale
dell'editor; `.ioc`, sorgenti, `Drivers/`, script linker e i file `.vscode/`
condivisibili restano tracciati.

## Regole per non perdere le modifiche

1. Il codice applicativo sta fuori dai file generati oppure dentro le sezioni
   `USER CODE BEGIN/END`. In `main.c` la parte manuale e' solo l'inclusione di
   `spi_selftest.h` e la chiamata `SPI_SelfTest_Run()` in `USER CODE BEGIN 2`.
2. I sorgenti utente si aggiungono al `target_sources` del `CMakeLists.txt` di
   primo livello, mai in `cmake/stm32cubemx/CMakeLists.txt` che viene riscritto.
3. La sezione `.spi_dma` in RAM_D2 e' definita in `cmake/spi_dma.ld` e agganciata
   con `target_link_options`, senza toccare `STM32H743xx_FLASH.ld` generato.
4. Le modifiche a pinout, clock, DMA e parametri SPI si fanno nell'`.ioc` e non
   nel codice: `spi.c` e `gpio.c` verrebbero riscritti alla generazione
   successiva.
5. Dopo un Generate Code conviene controllare il diff Git, inclusi i `.bak`, e
   ricompilare prima di programmare.

## Corrispondenza fra .ioc e firmware

L'`.ioc` e' allineato alla configurazione collaudata: SPI2 master full duplex,
8 bit, `SPI_BAUDRATEPRESCALER_16` pari a 12.5 Mbit/s, NSS software con
`FPGA_CS` su PB12 (uscita, livello alto all'avvio, GPIO speed HIGH),
SCK/MISO/MOSI su PB13/PB14/PB15 con GPIO speed MEDIUM. I fronti MEDIUM sono una
scelta deliberata: a 12.5 MHz i fronti piu' rapidi introducevano errori, come
descritto in [../../docs/SPI_DIAGNOSTIC_RESULTS.md](../../docs/SPI_DIAGNOSTIC_RESULTS.md).
Cambiando prescaler o GPIO speed vanno aggiornati sia l'`.ioc` sia il vincolo
timing SPI lato FPGA.

I buffer DMA stanno in RAM_D2 allineati a 32 byte; il codice generato non abilita
la cache dati, ma il self-test esegue comunque clean/invalidate condizionati a
`SCB->CCR`, cosi' resta corretto se la cache verra' attivata.

`diagnose-hardware.ps1` riscrive `Core/Inc/spi_diag_config.h` per selezionare la
matrice diagnostica; non tocca l'`.ioc`. Al termine di una sessione di diagnosi
si ripristina il firmware normale con `-RestoreSelfTest`, altrimenti resta
caricata una variante che non corrisponde al test standard.

## Rigenerare il progetto da CubeMX

1. Aprire `WeAct_H743_SPI.ioc` (doppio clic, oppure dal pannello dell'estensione
   ST in VS Code) con STM32CubeMX 6.18.1 o superiore.
2. Verificare in Project Manager che Toolchain/IDE sia **CMake** e che
   *Keep User Code when re-generating* sia attivo.
3. Generate Code, poi in VS Code eliminare la cartella `build/` se la struttura
   dei sorgenti e' cambiata e rieseguire `.\build.ps1`.
4. Controllare il diff: modifiche inattese al `CMakeLists.txt` di primo livello o
   a `cmake/gcc-arm-none-eabi.cmake` indicano che CubeMX li ha ricreati da zero
   (succede se vengono cancellati) e vanno riportate le personalizzazioni:
   sorgente `spi_selftest.c` e `target_link_options` con `spi_dma.ld`.

## Stato e limiti

Il firmware oggi esegue solo il self-test SPI verso lo slave FPGA; non c'e'
ancora il protocollo del display. Il preset `Release` esiste ma non e' collaudato
sull'hardware, il debug non e' configurato nel repository e la linea READY non e'
implementata. Gli esiti dei collaudi e i limiti misurati sono nel
[README](README.md) e in [../../docs/SPI_PERFORMANCE.md](../../docs/SPI_PERFORMANCE.md).
