# Verifica del progetto

## COPY e SCROLL — 16 settembre 2026

Protocollo e demo: [BLITTER.md](BLITTER.md).

- Nove testbench SPI/grafica/FIFO passati: aggiunti 99 casi COPY/SCROLL
  e 10.000 parole FIFO, inclusi full/empty, overflow, wrap e clock concorrenti.
- Integrazione TOP finale con FIFO RTL reale: PASS, 12 casi blitter, quattro
  PRESENT e otto frame completi (1.044.480 pixel);
  verifica di CRC/aborti, barriera, busy, geometrie errate, maschere, padding,
  isolamento front/back e delle risposte PSRAM dal flusso video.
- Risincronizzazione con FIFO reale: recupero al frame successivo, 0/4 frame
  danneggiati dopo l'underrun indotto.
- FPGA: zero violazioni setup/hold/recovery/removal, Fmax PSRAM 81.909 MHz
  per clock 81 MHz; 5209 risorse logiche, 3659 registri, 3 BSRAM.
  Build `-NoCompress`, PlaceOption 1, vincoli invariati.
- MCU Debug e Release compilate. FPGA/font e MCU Release caricati; CRC del
  bitstream verificato e flash MCU confrontata con l'ELF.
- Banco: una COPY, 32 SCROLL, 50 PRESENT/IRQ; zero errori e IRQ finale alto.
  COPY completa 14 ms, ultimo SCROLL del viewport 8 ms, ultimo PRESENT 16 ms.
  Risultato: `stm32/WeAct_H743_SPI/build/Release/scroll-result.json`.

Le sezioni seguenti conservano i risultati delle tappe precedenti.

## Double buffering - 15 settembre 2026

Protocollo e comandi: [DOUBLE_BUFFER.md](DOUBLE_BUFFER.md).

- Sette testbench SPI/grafica: PASS.
- `run_double_buffer_sim.ps1`, FIFO modello e reale: PASS, tre frame interi
  (391680 pixel) per esecuzione, due swap, CRC/aborti, barriera mentre B9 lavora,
  blocco comandi concorrenti, isolamento del front, duplicati e ACK errati.
  La variante reale include anche B7 mascherato e B8 nel back.
- `run_sim.ps1 -Mode current`: PASS, dopo underrun quattro frame integri;
  FIFO RTL reale, nessuna regressione del recupero al frame successivo.
- Build FPGA: nessuna violazione setup/hold/recovery/removal, nessuna eccezione
  di calibrazione usata. Fmax PSRAM 84.277 MHz per clock operativo 81 MHz.
  Log/manifest: `impl/build.log`, `impl/verification.json`.
- Build MCU Debug e Release: PASS; Release installata con verifica flash.
- Banco: 17 PRESENT completati e 17 fronti EXTI, IRQ confermato e rilasciato,
  4374 byte eco senza mismatch, nessun errore LCD/HAL. Clear 8 ms;
  ultima attesa PRESENT 12 ms. Immagine finale confermata dall'utente.

Il test PSRAM e' comportamentale. Non sono state eseguite rilettura fisica dei
pixel del pannello, misura strumentale dei fronti VSYNC/IRQ o prova di power-cycle.

## Comandi riproducibili

Per il protocollo SPI e le primitive grafiche eseguire anche
`./sim/run_spi_sim.ps1`. Comprende nove testbench, incluso `tb_line_renderer`:
124 linee confrontate con un riferimento basato su arrotondamento razionale,
tutte le direzioni, estremi e punti singoli, maschere e fusione dei burst,
backpressure e rilascio ritardato dell'acknowledgement come nel CDC del TOP.
`tb_spi_framebuffer` verifica inoltre B9 tipo 1: CRC, limiti, tipo/flags
invalidi, aborto prima del commit, coda occupata e conservazione del comando
pendente anche quando il master interroga B8. La regressione conserva B7,
testo B8 e fill B9 tipo 0. Questi test verificano i pixel simulati; il controllo
SWD al banco verifica stati ed errori del trasporto, senza rileggere la PSRAM.

Da PowerShell, nella radice del repository:

```powershell
.\sim\run_sim.ps1 -Mode all
.\build.ps1
.\sim\test_verification.ps1
```

Servono Icarus Verilog e `vvp` di oss-cad-suite (default `C:\oss-cad-suite`),
Gowin EDA V1.9.12.01 e la cronologia Git contenente `1e9337d` per `legacy`.
I percorsi si possono indicare con `-OssCadSuite` e `-GowinRoot`.
La build non programma la scheda; `-Program` programma solo dopo il timing gate.

Ogni comando fallisce con un'eccezione/codice non nullo in caso di errore.
Il runner elimina gli output precedenti prima della compilazione, seleziona
esplicitamente il top del testbench e richiede sia exit code zero sia il marker
`PASS: frame_resync`. Conserva stdout/stderr nei log, senza nascondere errori
di compilazione. Ripristina PATH e YOSYSHQ_ROOT al termine.

Il timeout simulato è 200 ms; quello reale è 900 s per processo, configurabile
con `-TimeoutSeconds`. Quest'ultimo protegge anche da un simulatore che non
avanza nel tempo. In caso di interruzione/timeout il runner termina il processo;
su PowerShell 7 termina anche gli eventuali processi figli del compilatore/EDA.
Windows PowerShell 5.1 garantisce la terminazione del processo diretto (`vvp`
non genera figli). L'output non bufferizzato mostra il primo millisecondo,
l'audit e ogni frame completato.

## Contratto della simulazione

Il modello PSRAM registra le scritture e confronta tutti i 130.560 pixel con
un riferimento calcolato con modulo/divisione, indipendente dai contatori
incrementali del generatore. Il riferimento segue il pattern selezionato;
per il commit storico usa le barre, senza riferimenti a parametri inesistenti.

Le letture restituiscono una rampa di indirizzi a 16 bit, anziché il framebuffer
acquisito. Questo verifica separatamente scrittura e allineamento dello stream;
non è una simulazione completa dell'IP Gowin.

Per ciascuna modalità si richiedono:

- due frame completi, senza errori, prima del guasto;
- 130.560 pixel attivi per ogni frame controllato;
- starvation di 150 us nell'area visibile, con FIFO effettivamente vuota e
  corruzione osservata nel frame colpito;
- quattro frame successivi senza errori per `current` e `model`;
- quattro frame successivi corrotti per `legacy`: è un successo atteso della
  regressione storica, non un'autorizzazione ad accettare errori nell'RTL attuale;
- nessun beat PSRAM perso a causa di FIFO piena;
- DE, HSYNC e VSYNC confrontati a ogni pixel con un riferimento temporale
  indipendente dai contatori del DUT; RGB nero nel blanking;
- per l'RTL attuale, uscite stabili sul fronte di discesa e un VSYNC per frame.

Le uscite vengono campionate dopo l'assestamento degli aggiornamenti RTL.
La modalità storica tiene conto di uscite combinatorie, DE di mezzo periodo e
VSYNC bloccato a zero; non le valuta come se fossero già registrate.

## Raster misurato, mantenuto invariato

Questa verifica fissa il comportamento esistente. Non corregge implicitamente
il raster né lo certifica rispetto al datasheet del pannello.

| Grandezza | Valore attuale |
|---|---:|
| Clock LCD nominale | 9 MHz |
| Riga ordinaria | 561 clock |
| Frame | 297 righe più un clock finale = 166.618 clock |
| Frequenza di frame nominale | circa 54,016 Hz |
| Area attiva | 480 × 272 pixel |
| HSYNC alto | 50 clock per riga ordinaria |
| VSYNC alto, RTL attuale | 10.660 clock, circa 1,184 ms |

Il contatore orizzontale include il valore 560. Quello verticale raggiunge 297
per un solo clock prima del reset del raster. VSYNC parte dalla riga 278;
`FrameRestart` è alla riga 277. Ne risultano 19 righe complete più un clock di
VSYNC alto, e un intervallo HSYNC allungato di un clock a cavallo del frame.
Un'eventuale correzione deve modificare deliberatamente questo contratto e
va poi verificata anche sul pannello.

## Timing della build

`tools/Test-TimingReport.ps1` controlla tool, dispositivo, corner, clock,
Fmax e tabelle setup/hold/recovery/removal/pulse-width. Report mancanti,
troncati o non riconosciuti fanno fallire la build.

L'eccezione storica consente al massimo sette endpoint setup, con slack non
inferiore a −1,960 ns, esclusivamente da `calib_0` ai pin `CALIB` degli otto
IDES4 della PSRAM, da `psram_clk_81` a `mem_clk_162`. Ogni altra violazione,
anche interna all'IP, è un errore. Il numero di endpoint negativi individuati
deve corrispondere al riepilogo: una tabella insufficiente non vale come PASS.
Le motivazioni e i limiti dell'eccezione restano in `src/LCD.sdc`.

`impl/build.log` contiene il log completo. `impl/verification.json` registra
data UTC, toolchain, risultati e SHA-256 del bitstream e del report appena
generati. I vecchi artefatti di verifica vengono invalidati prima della build.

## Baseline del 7 settembre 2026

RTL funzionale invariato rispetto a `2b474e3`; modificati gli strumenti di
verifica e la documentazione. Tool: Icarus 14.0 devel
`s20260301-322-ga4989d023-dirty`, Gowin V1.9.12.01.

| Prova | Esito |
|---|---|
| Audit scritture, tutte le modalità | 130.560 pixel corretti |
| `current`, FIFO RTL | 0/4 frame successivi corrotti; 7 VSYNC in 7 frame |
| `model`, FIFO comportamentale | 0/4 frame successivi corrotti; 7 VSYNC in 7 frame |
| `legacy`, commit `1e9337d` | danno persistente atteso: 4/4 frame corrotti |
| Nuova sintesi e place-and-route | completati, timing gate superato |
| Setup di calibrazione residui | 4 endpoint, worst slack −0,666 ns |
| Hold/recovery/removal/pulse-width | nessuna violazione |
| Fmax PSRAM / LCD / XTAL | 86,562 / 71,716 / 99,053 MHz |
| Prove negative | 18 errori riconosciuti, sia PowerShell 7 sia Windows PowerShell 5.1 |

Tempi osservati su questa macchina, con altre verifiche in esecuzione:
circa 346 s per `current`, 89 s per `model`, 70 s per `legacy`. La simulazione
con FIFO RTL è sensibilmente più costosa del modello comportamentale:
l'indicazione precedente «circa un minuto» non era adeguata per `current`.

Le prove negative in `sim/test_verification.ps1` usano copie sotto
`sim/build/verification_checks`, il compilatore reale e mutazioni del report
Gowin appena verificato. Controllano compilazione fallita con `.vvp` precedente,
uscita senza PASS, `$fatal`, watchdog reale, pixel scritto errato, sincronismo
errato, timeout simulato, assenza di underrun e violazioni/report fuori baseline.
Se il report non contiene più percorsi negativi di calibrazione, la relativa
fixture deve essere aggiornata esplicitamente: i casi non vengono saltati.

Questi risultati non sostituiscono una prova hardware: il modello non riproduce
calibrazione, comportamento elettrico, metastabilità o tutti i tempi dell'IP
PSRAM. Non sono stati introdotti nuovi test di reset a metà frame, variazioni
di latenza PSRAM o guasti protratti attraverso il blanking verticale.
