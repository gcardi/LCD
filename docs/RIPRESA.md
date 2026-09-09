# Punto di ripresa — 9 settembre 2026

## Ultimo stato: avvio nero uniforme, SPI 12.5 MHz

Su richiesta dell'utente: PATTERN_SOLID in FramebufferController con parametro
BACKGROUND_COLOR=16'h0000. Nessun bordo o diagonale all'avvio/reset FPGA.
LCD_BOOT_TESTS=0 in spi_diag_config.h: demo/stress grafici sono opt-in; resta
il self-test eco lungo, che non modifica lo schermo. Schede programmate,
flash verificata; eco hardware PASS 1049760 byte a 12.5 MHz, GPIO corrette.
SPI testbench PASS con controllo di tutti i 130560 pixel iniziali neri.
Gate timing PASS: sette endpoint di calibrazione ammessi, worst -1.487 ns,
nessun'altra violazione. SDC mantenuto a 40 ns, master effettivo 12.5 MHz.

Aggiunte API STM32 LCD_FillRect(x,y,w,h,color) e LCD_Clear(color), implementate
sopra LCD_WriteRect con un buffer di riga da 960 byte sullo stack. RGB565,
ritorno 1/0, nessun nuovo opcode FPGA e nessun disegno automatico aggiunto.

Comandi/primitive attuali documentati in SPI_FRAMEBUFFER.md: burst RGB565
mascherato, query disponibilita', eco diagnostica; API LCD_WriteRect lato STM32.
Nessuna primitiva fill/linee/testo/readback FPGA, LVGL non integrato.
Le sezioni seguenti sono cronologia.

## Ultimo stato: collaudo lungo, ripristinati 12.5 MHz

La prova lunga rivela errori grafici intermittenti a 25 MHz, anche quando
1049760 byte eco DMA passano. Una prova grafica DMA passa, ma la ripetizione
dopo ricaricamento FPGA fallisce: non considerare i 25 MHz qualificati.

Configurazione finale: SPI_FRAMEBUFFER=1, prescaler 16 (C/CubeMX), GPIO MEDIUM,
SPI_SELFTEST_ROUNDS=240, matrice disabilitata. SDC resta a 40 ns, piu' severo.
Risposta SPI registrata direttamente; grafica DMA con guardie CS 1 us.
A 12.5 MHz tre prove finali PASS (upload, reset STM32, reload FPGA + reset STM32):
ciascuna 1049760 byte eco, 512 rettangoli, 30035 pacchetti, zero errori.
Nessuna rilettura PSRAM nel collaudo hardware. LVGL non ancora integrato.
Prossimo lavoro: isolare il difetto a 25 MHz, oppure concordare LVGL a 12.5 MHz.
Dettagli, comandi, limiti e archivi in `docs/SPI_STRESS.md`.

Le sezioni seguenti sono cronologia, superata dal collaudo lungo.

## Ultimo stato: grafica a 25 MHz, primo collaudo PASS

Ottimizzato MISO con FIXED_FIRST_BYTE=1 / FIRST_BYTE=A5 in SpiFramebuffer.
Uscita diretta dal registro TX: rimosso il mux tx_started dal percorso al pin.
SpiSlave conserva il comportamento generico come default per SpiDiagnostic.

Configurazione attuale: SPI_FRAMEBUFFER=1, matrice disabilitata, prescaler 8,
SDC 40 ns, GPIO MEDIUM. Build/timing PASS: sei endpoint calibrazione PSRAM,
worst -1.308 ns, nessuna altra violazione. Schede caricate e flash verificata.
Test a 25000000 Hz: 40 trasferimenti, 34992 byte, zero mismatch/HAL error,
tutti i GPIO corretti, graphics_state=2. Conferma visiva a 25 MHz in attesa.
Suite SPI PASS, banco framebuffer a 25 MHz. Non ancora prova lunga a 25 MHz.
RestoreSelfTest riallinea anche frequenza/CubeMX/SDC a 12.5 MHz per l'eco pura.
Dettagli e hash in SPI_FRAMEBUFFER.md. Seguono le prove precedenti.

## Tentativo successivo: 25 MHz respinti dal timing

Il 9 settembre provato vincolo SCK 40 ns e prescaler 8 con MEDIUM.
Gate FAIL: uscita MISO da tx_started, slack -3.782 ns; MOSI minimo +0.043 ns.
Nessun caricamento ne' prova hardware a 25 MHz. Ripristinata configurazione
12.5 MHz / prescaler 16 / SDC 80 ns. Dettagli in SPI_FRAMEBUFFER.md.

## Ultimo stato hardware: rettangolo SPI visibile sul pannello

Implementato percorso SPI -> coda asincrona di un burst -> scritture PSRAM
mascherate. API STM32 `LCD_WriteRect`, rettangoli RGB565 arbitrari. Demo 67x40
a (101,81), bordo bianco e tre fasce RGB, eseguita una volta dopo il self-test.
L'utente ha confermato di vedere il rettangolo il 9 settembre 2026 e ha poi
resettato la FPGA per provarne la scomparsa (esito del reset non ancora riferito).

Configurazione: SPI_FRAMEBUFFER=1 in TOP, SPI_DIAG_MATRIX=0, 12.5 MHz MEDIUM.
Build FPGA e firmware completate; FPGA caricata in SRAM, flash STM32 verificata.
Gate timing PASS: quattro endpoint di calibrazione PSRAM, worst -1.303 ns;
nessuna nuova violazione ammessa. Primo arbitraggio respinto dal gate, risolto
separando decisione e comando con uno stato aggiuntivo, senza rilassare i vincoli.

Collaudo SWD: 40 trasferimenti, 34992 byte, zero mismatch, HAL OK, tutte le
prove GPIO corrette, graphics_state=2. Il riscontro visivo dell'utente completa
la prova del primo rettangolo; non e' una qualifica estesa della grafica.
Protocollo, comandi e limiti: `docs/SPI_FRAMEBUFFER.md`.

Reset FPGA: reinizializza la PSRAM con il pattern, eliminando il rettangolo.
La demo STM32 non si ripete automaticamente: resettare anche STM32 per reinviarla.
Il semplice reset FPGA conserva il bitstream; lo spegnimento perde la SRAM FPGA.
I runner diagnostici selezionano SPI_FRAMEBUFFER=0; per tornare alla grafica
riportarlo a 1. Il runner normale con -RequireGraphics verifica anche la demo.

Le sezioni seguenti sono cronologia precedente alla scrittura framebuffer.

## Stato precedente: diagnosi fronti GPIO completata

Configurazione normale ora a **12.5 MHz, GPIO STM32 MEDIUM**, prescaler 16,
SDC 80 ns, file CubeMX allineato. Matrice diagnostica disabilitata e FPGA
riportata all'eco (MODE=0). Nessuna modifica al cablaggio.

A 12.5 MHz MEDIUM: eco lungo 1049760 byte / 1200 trasferimenti senza errori;
sequenza autonoma FPGA 104976 byte senza errori; 24 blocchi MOSI da 4096 byte
con CRC corretto riletto a 781250 Hz. HIGH e VERY_HIGH falliscono in modo
ripetibile alla stessa frequenza. Evidenza compatibile con integrita' dei
segnali, ma non localizza fisicamente il disturbo. Nessuna misura analogica.

Dettagli, archivi e comandi: `docs/SPI_DIAGNOSTIC_RESULTS.md`.
Il runner `diagnose-hardware.ps1` offre echo/miso/mosi, -Rounds 8..80,
e -RestoreSelfTest per tornare al test normale e ricaricare le schede.
Non confondere una matrice completata con un PASS: i mismatch sono dati
diagnostici; leggere le colonne nel JSON. Il runner normale resta severo
sui mismatch DMA e rifiuta di operare con la matrice abilitata.

L'anomalia iniziale GPIO e' associata al caricamento FPGA: dopo il solo
riavvio/riprogrammazione STM32 tutte le tre prove GPIO passano. Due impulsi
SCK a CS alto prima della prima transazione eliminano l'anomalia nel test
dopo caricamento FPGA; la sola sequenza CS basso/alto non bastava.
Il firmware include ora i due impulsi, senza payload e a slave deselezionato.
Il runner normale richiede anche tutte le sequenze GPIO corrette. La causa
interna all'avvio non e' ancora dimostrata; la sequenza e' verificata al banco.
Ulteriori prove inizializzate MISO/MOSI confermano MEDIUM senza errori; nel
CRC a 6.25 MHz VERY_HIGH si e' osservato un blocco con stato errato anche
a regime. Non considerare VERY_HIGH affidabile su questo collegamento.

Le sezioni seguenti sono cronologia, superata dallo stato qui sopra.

## Stato aggiornato dopo correzione connettore

L'utente ha corretto un connettore invertito e spento/riacceso l'hardware.
Ricaricate entrambe le schede: DMA PASS a 0.78125, 1.5625, 3.125 e 6.25 MHz,
zero mismatch su 34992 byte per frequenza. A 12.5 MHz: 32 mismatch, HAL OK,
timing FPGA PASS. Arrestata la salita; configurazione riportata a 6.25 MHz
(SPI prescaler 32, SDC periodo 160 ns). Anche il file CubeMX e' aggiornato.
Il risultato espone ora la frequenza calcolata dal clock/prescaler effettivi.

Prima prova GPIO ancora anomala (`D2 BC 4D 5E 6F 80 91 A2` senza pull);
le altre due rispondono correttamente. MISO non risulta piu' flottante come
prima. Vedere `docs/SPI_PERFORMANCE.md` per tabella e limiti del collaudo.
Prima di salire oltre 6.25 MHz occorre isolare gli errori a 12.5 MHz e
l'anomalia iniziale GPIO. SRAM FPGA sempre volatile.

Le sezioni seguenti conservano la cronologia precedente alla correzione.

Sessione sospesa per riavvio del PC. Non ripartire dalla configurazione CubeMX:
firmware, endpoint FPGA e automazione del collaudo sono gia' implementati.

## Hardware e collegamenti attesi dal codice

- WeAct STM32H743VIT6: rilevata rev. V, 3.27 V via ST-LINK V2.
- Seriale ST-LINK: `35FF6C064D53373238602143`.
- Tang Nano 9K con display RGB 480x272 e PSRAM; flat circa 15–20 cm.
- L'utente ha verificato collegamenti e assenza di corti. Resta da confermare
  che la mappatura effettiva coincida con quella del bitstream qui sotto.

| STM32 | IO Tang (numero chip, non posizione connettore) | Segnale |
|---|---:|---|
| PB13 | 36 | SCK |
| PB15 | 25 | MOSI |
| PB14 | 26 | MISO |
| PB12 | 27 | CS attivo basso |
| GND | GND | Massa comune |

Alimentazioni USB separate, nessun collegamento fra rail 5 V/3.3 V.
MicroSD vuota: IO36 e' condiviso con il clock della scheda SD.

## Implementato e verificato

- CPU 480 MHz, SPI2 master mode 0, 8 bit MSB first, kernel 200 MHz,
  prescaler 256: SCK 781.25 kHz. NSS software, PB12 gestito come GPIO.
- DMA1 stream 0 TX / stream 1 RX, buffer allineati in SRAM D2 (non DTCM),
  gestione cache se attiva. Progetto CMake GCC in `stm32/WeAct_H743_SPI`.
- `src/SpiSlave.sv`: slave generico a byte, senza D/C; CS alto azzera
  il conteggio e disabilita MISO. Logica nel dominio SCK.
- `src/SpiDiagnostic.sv`, istanziato in TOP: prima risposta A5, poi
  il byte MOSI precedente; CS alto reinizializza la transazione.
  Il test SPI non modifica il framebuffer LCD.
- Simulazioni SPI superate: 525 byte RX / 515 TX nel test generico,
  32777 byte nel test diagnostico.
- Build FPGA e gate timing superati: una violazione di calibrazione PSRAM
  ammessa dalla baseline (-0.175 ns), nessun'altra violazione rilevata.
- Build firmware riuscita, entrambe le schede programmate; flash STM32
  verificata. FPGA programmata SOLO in SRAM: si perde allo spegnimento.
- `tools/Invoke-LoggedProcess.ps1` ora imposta anche la working directory
  del processo nativo, necessaria per il build CMake dalla radice del repo.
- README STM32 e documentazione SPI aggiornati. Modifiche non committate;
  preservare anche le rinomine preesistenti dei documenti in `docs/`.

## Guasto ancora aperto: collaudo hardware NON superato

40 transazioni DMA, 34992 byte confrontati, 34853 mismatch, nessun errore HAL.
Il primo byte ricevuto varia (FC/F0/00) invece di A5; blocchi successivi
quasi tutti zero. Non e' ancora una comunicazione funzionante.

Per separare SPI/DMA dai segnali e' stata aggiunta una prova GPIO lenta
prima del DMA (`probe_gpio` in `Core/Src/spi_selftest.c`). Trasmette otto
byte tre volte, con MISO senza pull, pull-up e pull-down. Atteso sempre:
`A5 3C 4D 5E 6F 80 91 A2`.

Risultato misurato:

- nessun pull: `FF FF FF FF FF FF FF FF`;
- pull-up: `FF FF FF FF FF FF FF FF`;
- pull-down: `00 00 00 00 00 00 00 00`.

Questo indica MISO apparentemente non pilotato lato STM32 durante la prova;
non dimostra da solo un errore di cablaggio. Controllare corrispondenza pin,
CS effettivo sulla FPGA e reset/abilitazione del driver MISO.
Il reset SPI in TOP dipende da Reset_Button e lock di entrambi i PLL.
Il report Gowin conferma i pin 36/25/26/27; il netlist include TBUF MISO.
Non aumentare ancora la frequenza: vincolo SCK attuale 1280 ns.

## Ripartenza

Dalla radice del repository, con entrambe le schede collegate:

```powershell
# Simula, compila, carica entrambe le schede e legge il risultato via SWD:
.\stm32\WeAct_H743_SPI\test-hardware.ps1 -SerialNumber 35FF6C064D53373238602143

# Solo lettura, se ELF locale e firmware caricato coincidono:
.\stm32\WeAct_H743_SPI\test-hardware.ps1 -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

Il runner restituisce errore se il test non passa: e' l'esito attualmente
atteso, non un problema del runner. Salva risultato e prova GPIO in
`stm32/WeAct_H743_SPI/build/Debug/hardware-result.json` (ignorato da Git).
Legge gli indirizzi dei simboli dall'ELF, senza indirizzi RAM fissi.
`-ReadOnly` non verifica che la flash corrisponda all'ELF locale.

Task VS Code disponibile nel progetto STM32:
`STM32 + FPGA: Build, upload and test SPI`.

Prima domanda rimasta aperta all'utente: confermare i quattro collegamenti
della tabella, usando numeri IO del chip come nell'immagine del pinout.
Poi diagnosticare CS/reset/MISO; non rifare configurazione o implementazione
gia' completate. ST-LINK V2 funziona, non serve passare a V3 per questo test.

## Nuova prova dopo revisione cablaggi — 9 settembre 2026, ore 10:32

Ripetuto test-hardware.ps1 completo: simulazioni PASS, build FPGA e gate
 timing PASS (sola calibrazione PSRAM -0.175 ns), SRAM FPGA caricata,
firmware STM32 caricato e flash verificata.

A 781250 Hz: stato FAIL, 40 trasferimenti, 34992 byte confrontati,
34853 mismatch, primo byte atteso A5 ricevuto 00, HAL error 0, 1525 ms.
GPIO: no pull e pull-up = otto FF; pull-down = otto 00.
Il problema di MISO apparentemente non pilotato persiste. Nessun aumento
 di frequenza effettuato e nessuna modifica a firmware/RTL/vincoli.

Il codice abilita MISO solo con CS basso e global_rst_n alto;
global_rst_n = Reset_Button & psram_pll_lock & lcd_pll_lock.
Prossimo riscontro fisico: immagine LCD presente e collegamenti effettivi
PB13->IO36, PB15->IO25, PB14->IO26, PB12->IO27, massa comune.
Il JSON dettagliato resta in stm32/WeAct_H743_SPI/build/Debug/hardware-result.json.
