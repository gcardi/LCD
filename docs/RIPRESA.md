# Punto di ripresa - 17 settembre 2026

## Stato corrente: reset della FPGA comandato dalla MCU, con prova

Nuovo filo **STM32 PB1 → Tang Nano IO29**, open drain, pull-up esterna da 10 kΩ
verso il 3V3 della Tang Nano. Pin scelti sugli schemi ufficiali: IO29 è nel
banco 2 a 3,3 V e affianca IO28 (IRQ) su J5; PB1 affianca PB0 (IRQ) sul
connettore P2 della WeAct e non ha funzioni sulla scheda. Il pulsante di reset
esistente sta sul pin 4, banco a **1,8 V**: è il motivo per cui la MCU ha un pin
suo invece di condividere quella rete. `RECONFIG_N` non è su nessun connettore,
quindi il reset possibile è solo quello logico.

**RTL.** `ResetRequestFilter` combina pulsante e linea MCU sul quarzo a 27 MHz e
agisce solo dopo **1 ms** di livello basso continuo: un disturbo sul filo non
resetta la logica, e lo stesso filtro chiude finalmente il debounce del pulsante
rimasto in sospeso. La richiesta filtrata alimenta sia l'albero di reset sia
l'IP PSRAM, che quindi ricalibra. `FramebufferController` ha il flag
`reset_seen`, acceso a ogni reset e spento solo da `BA` operazione 6
`ACK_RESET`; `BB` passa alla versione 3 e lo espone nel bit 4 del byte 4.

**Firmware.** `FPGA_ResetCycle()` gira subito dopo `SPI_Setup()`: spegne
`reset_seen`, dà un impulso di 10 ms con SPI deselezionata ed EXTI0 mascherato,
aspetta la FPGA e pretende di ritrovare `reset_seen` acceso. Poi rimanda
`ACK_RESET`, che viene servito solo dopo calibrazione e riempimento iniziale, e
quindi dice anche che la FPGA è pronta. Se il reset non è dimostrato dopo tre
tentativi, le demo grafiche non partono. PB1 è configurato nel `.ioc` e nel
codice generato come lo produrrebbe CubeMX: open drain, livello iniziale alto,
nessuna pull. Estesi anche i controlli di `LCD_GetBufferStatus`, che accettava
solo le versioni 1 e 2 e riservava il bit 4: col bitstream nuovo avrebbe spento
il doppio buffer con le fasi 23 e 25.

**Verifiche.** Simulazione `tb_double_buffer` in tutte e tre le varianti, con
glitch da 0,5 ms ignorato, reset effettivo dopo 1 ms, IRQ inattiva durante il
reset, `reset_seen` riacceso, riempimento iniziale rieseguito e `ACK_RESET`.
Suite SPI con nove banchi PASS. Build: gate di timing PASS, cinque endpoint di
calibrazione ammessi, worst −0,739 ns, zero hold/recovery/removal; 5896/8640
logiche, 3802 registri, **CLS 87%**, da tenere d'occhio. Al banco:
**`g_fpga_reset_state = 2` al primo tentativo, FPGA pronta 16 ms dopo il
rilascio**, autotest SPI a zero errori, demo testo e scroll complete, 50 PRESENT
con 50 fronti IRQ.

Due trappole del banco di simulazione, emerse qui. L'impulso di reset di 400 ns
che inizializzava il progetto viene giustamente ignorato dal filtro: ora dura
2 ms. E il controllo di scansione non azzerava il conteggio dei fotogrammi al
reset, quindi dopo un reset comandato fotografava la memoria prima del nuovo
riempimento iniziale. La prima ipotesi, una corsa fra reset asincrono e fronte
di clock, era sbagliata: l'ha smentita una stampa dei tempi, non un ragionamento.

## Stato precedente: percorso pixel in streaming (16 settembre)

**Punto operativo finale del 16 settembre.** PLL2 alimenta SPI2 a 150 MHz:
`BE` usa `/8` (18,75 MHz, TX-only), i comandi ordinari `/16` (9,375 MHz) e
`BF` `/128` (1,171875 MHz). Il vincolo FPGA resta conservativamente a
18,75 MHz anche per MISO e chiude il gate timing. Una prova di 48 frame ha
trasferito 13.056 righe senza errori CRC, header o pacchetti incompleti; i 210
retry erano tutti overflow recuperati della coda a una entry. I tentativi a
21,875 e 20,3125 MHz non chiudono la STA SPI; quello a 19,375 MHz ha prodotto
una regressione di placement PSRAM. `.ioc`, codice generato e runner sono
allineati al kernel clock da 150 MHz.

Il trasporto dei pixel è stato rifatto in due passi, entrambi indipendenti dal
cablaggio, che resta il vincolo fisico aperto.

**Primo passo, solo firmware.** La `ready()` prima di ogni pacchetto `B7` era
ridondante: il byte 1 del pacchetto dati porta già la stessa disponibilità,
perché l'FPGA campiona `accept_packet` da quella condizione all'indice 0. Un
rifiuto non committa nulla, quindi il pacchetto si rispedisce. Le transazioni
per frame scendono da 16.320 a 8160, e ogni transazione non costa solo byte:
due `memcpy`, tre operazioni di cache con barriera e un setup HAL di due stream
DMA. Aggiunto `LcdProfile` per misurare via SWD dove va il tempo, con il campo
`retries` che dice se la coda a una entry dell'FPGA satura davvero mai.

**Secondo passo, nuovo opcode `BD`.** Una riga per transazione invece di trenta
pacchetti: header, payload contiguo, CRC sul payload, commit. Per una riga piena
978 byte in un solo DMA. Riferimento completo: [SPI_STREAM.md](SPI_STREAM.md).

L'implementazione sta tutta nel dominio SCK. `BD` produce la stessa terna
`address`/`pixels`/`mask` che il controller consumava già, quindi
`FramebufferController` e `TOP` sono rimasti intatti.

**Lezione sul costo in logica, vale la pena ricordarla.** La prima versione
accettava `x` e `count` al pixel e costruiva le maschere nell'FPGA. Comodo per
l'host, ma richiede un mux a inserimento variabile su 256 bit: misurati **+864
LUT, dal 61% al 71% del die, e 15 endpoint setup violati** — non nel codice
nuovo, bensì su `init_y → memory_address` dentro `FramebufferController`, che
non era stato toccato. Pura pressione di placement su un percorso già al limite.
Attribuzione confermata ricostruendo il bitstream con il solo
`SpiFramebuffer.sv` di HEAD: zero violazioni, 5209/8640 logiche.

La versione definitiva trasporta **gruppi interi allineati a 16 pixel**, con
head e tail mask nell'header e il padding a carico dell'host (≤ 60 byte per
riga). Così il percorso pixel è lo stesso shift register a byte di `B7`,
condiviso perché i due opcode non sono mai selezionati insieme, e il costo in
logica torna trascurabile.

Nota di portabilità: il parser Gowin rifiuta `5'd1?x:y` senza spazio attorno al
punto interrogativo, dove Icarus lo accetta. Sintomo: *Illegal use of 'x' or 'z'
character in a decimal number*.

**Seconda eccezione nel gate di timing.** Anche dopo il rifacimento restavano
cinque endpoint setup, tutti **interni all'IP PSRAM cifrato**: due della famiglia
di calibrazione IDES4 già ammessa e tre su `u_dll/CLKIN → u_psram_wd/step_*`,
cioè la taratura del passo DLL sul lato scrittura. Nessuno tocca RTL nostro, e
nessuna `PlaceOption` chiude: 0 dà −0,938 ns, 1 e 2 danno −1,170.

Quei 232 ps di differenza **sullo stesso identico RTL** sono il dato che ha
deciso: un percorso che si sposta così per solo piazzamento non aveva margine
nemmeno quando il report era pulito. Il gate lì stava misurando fortuna, non
salute del progetto. È stata quindi aggiunta una seconda famiglia in
`$baselineFamilies`, con nomi dei nodi ancorati, coppia di clock fissata e
pavimento a −1,400 ns, e con prove negative che verificano il rifiuto di un
percorso da RTL utente, di uno slack sotto il pavimento, di una coppia di clock
invertita e di un endpoint fuori famiglia. Dettagli in
[VERIFICATION.md](VERIFICATION.md).

Build finale: **PASS**, 5 endpoint di calibrazione, worst −1,17 ns, zero
hold/recovery/removal. 5698/8640 logiche (66%), 3753 registri (56%), 3 BSRAM.
Fmax `psram_clk_81` 85,528 MHz contro un vincolo di 80,998: i domini del
progetto conservano il loro margine.

**Misurato al banco:** schermo intero **383 ms con `B7`, 225 ms con `BD`**,
cioè **1,71x**. Il solo trasporto fa 1,83x (334,5 -> 183,0 ms); il resto se lo
prende l'assemblaggio del pacchetto. La stima a tavolino diceva ~170 ms ed era
sbagliata. Dettaglio e lezioni in [SPI_STREAM.md](SPI_STREAM.md).

La prima misura dava `BD` a un inutile 3% dal `B7`: il CRC software bit per bit
costava 334 cicli per byte e su 960 byte per riga annullava tutto il guadagno
del trasporto. Sostituito con una tabella da 256 voci, e il loop per pixel con tre blocchi
contigui (`memset`/`memcpy`/`memset` più una passata di CRC): assemblaggio da
183,4 a 61,4 a 38,8 ms. Gli ultimi 38,8 ms restano inspiegati — spostare la
tabella in RAM non ha cambiato nulla — ma spariranno da soli col flush
asincrono, che sovrappone l'assemblaggio al DMA. `LCD_STREAM_BENCH` in `spi_diag_config.h`
accende `LCD_StreamBench_Run()`, che dipinge lo schermo lungo entrambi i
percorsi e lascia il confronto in `g_lcd_bench_*`. È distruttivo, quindi opt-in.

Verifica: i nove testbench passano, `tb_spi_framebuffer` esteso con i cinque
rifiuti di header, gruppo allineato, riga non allineata in testa e in coda, riga
intera da 480 pixel, CRC di payload sbagliato e overflow forzato con recupero.

**Collaudo al banco superato, 16 settembre 2026.** Qualifica scroll: 50
presentazioni, 50 fronti EXTI, zero errori SPI/LCD, COPY schermo intero 14 ms,
SCROLL 442x176 8 ms, attesa PRESENT 18 ms; immagine confermata a vista
dall'utente. Stress: 1200 trasferimenti, **1.049.760 byte con zero mismatch**,
prova GPIO corretta su tutte e tre le configurazioni di pull, 512 rettangoli,
354.528 pixel, 30.035 pacchetti in 1432 ms. Entrambi sul bitstream con `BD` e
con le tre violazioni di calibrazione ammesse: **se la taratura del passo DLL
fosse compromessa, 50 swap consecutivi con COPY e SCROLL in PSRAM lo avrebbero
mostrato.** Non è una dimostrazione formale, ma è l'evidenza che il gate da solo
non poteva dare.

**Trappola trovata dallo stress.** La guardia in `spi_selftest.c` che evita di
spedire un opcode come primo byte dell'eco conosceva solo `B7` e `B8`. Il
pattern rende `tx[0] = (round*53) & 0xFF`, quindi `BA`, `BB`, `BC` e `BD`
cadono ai round 18, 47, 76 e 105, e `B9` al 245 — appena fuori dai 240
eseguiti, che è il motivo per cui non era mai emerso. `BA`/`BB`/`BC` erano lì
dal 15 settembre e i 240 round non venivano più eseguiti dalla qualifica del
9 settembre: mina armata da un giorno, indipendente da `BD`. Guardia estesa
all'intervallo `B7..BD` e applicata anche al percorso della matrice
diagnostica, che ne era privo.

Da ricordare: il collaudo con 240 round allunga il boot oltre i 20 s di default
del poll di `test-hardware.ps1`. Serve `-TimeoutSeconds 60` o più.

**Prossimo sviluppo:** il flush
asincrono (DMA non bloccante e `flush_ready` nell'ISR), che su 272 transazioni
da 976 byte rende molto più che sulle 8160 da 41. Poi, e solo poi, ha senso
ragionare di Quad-SPI. Restano aperti il cablaggio, le resistenze di serie e la
causa dei fallimenti a 25 MHz.

## Stato precedente: COPY, SCROLL e demo terminale

Implementati e caricati in flash FPGA/font e STM32 Release. Protocollo e API:
[BLITTER.md](BLITTER.md). BB versione 2; BC copia front → back o esegue scroll
di viewport con riempimento RGB565 automatico. PRESENT resta separato per
aggiungere il testo prima dello swap. Il resto dello schermo resta invariato.

**Banco, 16 settembre:** demo completata, una COPY a schermo intero, 32 SCROLL,
50 PRESENT e 50 fronti EXTI complessivi; zero errori SPI/LCD/HAL, IRQ finale
alto e flag azzerato. Front 0, sequenza 50 dopo avvio FPGA fresco.
COPY 480x272: **14 ms**; ultimo SCROLL 442x176 di -16 righe: **8 ms**;
ultimo PRESENT: 16 ms; clear sempre 8 ms. Tempi MCU inclusivi di invio/polling,
risoluzione 1 ms, singole misure. Risultati in
`stm32/WeAct_H743_SPI/build/Release/scroll-result.json`.

FPGA: **zero violazioni setup/hold/recovery/removal**, nessuna eccezione di
calibrazione usata. Fmax PSRAM 81.909 MHz, clock operativo 81 MHz. 5209/8640
risorse logiche (61%), 3659 registri (55%), 3 BSRAM. Build qualificata:
`.\build.ps1 -NoCompress` (PlaceOption 1, vincoli invariati).
Timing chiuso con controller one-hot, risposta PSRAM registrata, Full FIFO
anticipato e confronti separati, selezione pixel in due stadi e carry anticipati.
Il confine di frame sincronizzato è registrato un ulteriore ciclo a 81 MHz.

Nove testbench SPI/grafica/FIFO passati: 99 casi blitter, 10.000 parole FIFO,
124 linee, più regressioni precedenti. Integrazione: 12 casi COPY/SCROLL,
quattro PRESENT e otto frame completi. Risincronizzazione dopo underrun:
quattro frame successivi integri. Anche l'ultima esecuzione con FIFO reale
sulla versione caricata è PASS: 12 casi, quattro swap e otto frame completi
(1.044.480 pixel); monitor del confine allineato al ciclo registrato.
MCU Debug e Release compilate, bitstream CRC verificato, flash MCU riletta e
confrontata con ELF prima delle letture SWD.

La demo termina con “Terminale FPGA”, righe 22–32 in un viewport nero e
cornice verde. L’utente ha osservato lo scorrimento e il successivo arresto:
è il comportamento previsto dopo le 32 righe della demo. Non ha segnalato
una verifica dettagliata dei pixel o della cornice.
Nessun ciclo fisico di spegnimento/riaccensione eseguito.

```powershell
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -RequireScroll -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

Triple buffering, ROP e copie nello stesso buffer restano futuri. Il back
non viene aggiornato automaticamente fuori dal viewport: inizializzare i due
buffer con lo stesso sfondo/cornice, come nella demo, oppure ricostruire quelle
aree prima di PRESENT quando cambiano.

## Cronologia - double buffering, PRESENT e IRQ (15 settembre)

Implementati e caricati in flash FPGA (insieme ai font) e STM32 Release.
Due slot PSRAM da 256 KiB, front/back, B7/B8/B9 sul back dopo abilitazione.
PRESENT aspetta tutte le scritture e scambia al nuovo confine di frame;
FIFO drenata prima della conferma. IRQ IO28 -> PB0 basso fino ad ACK SPI.
BA controlla enable/PRESENT/ACK; BB espone versione, capacita', stato e CRC.
Sequenza a 16 bit: il duplicato dell'ultimo PRESENT non ripete lo swap.
Riferimento completo: [DOUBLE_BUFFER.md](DOUBLE_BUFFER.md).

Al banco: demo completata, **17 presentazioni e 17 fronti EXTI**, zero errori
SPI/LCD/HAL, IRQ finale alto e flag azzerato. Front 1, sequenza 17 dopo avvio
FPGA fresco. 4374 byte SPI a 12.5 MHz verificati senza mismatch.
Clear ancora 128 ms per 16 operazioni (8 ms ciascuna); ultima attesa PRESENT
12 ms, singola misura e non limite massimo. Utente: **immagine finale corretta**.

Build FPGA: zero violazioni setup/hold/recovery/removal, PSRAM 81 MHz con
Fmax riportata 84.277 MHz; 3760/8640 risorse logiche (44%), 2622 registri (39%),
3 BSRAM. Una prima versione aveva -0.224 ns sul percorso di barriera;
registrare la condizione di code svuotate ha risolto senza cambiare vincoli.
MCU Release e Debug compilate. Bitstream CRC verificato; flash STM32 confrontata
con l'ELF prima di interpretare i simboli RAM. Font validati a runtime.
Risultato: `stm32/WeAct_H743_SPI/build/Release/double-buffer-result.json`.

Verifiche: sette testbench SPI/grafica passati; integrazione TOP con PSRAM
simulata e FIFO modello/reale, tre frame interi verificati pixel per pixel.
La variante FIFO reale verifica anche B7 mascherato e B8 sul secondo target.
Regressione underrun con FIFO reale passata: recupero immediato, quattro frame
successivi integri. Log in `sim/build/`, dettagli in DOUBLE_BUFFER.md.

La demo esegue un'animazione di 16 frame e termina sul campione grafico/testuale
con la scritta `Double buffer + VSYNC + IRQ: OK`.

```powershell
# Solo lettura, controlla anche corrispondenza flash MCU / ELF:
.\stm32\WeAct_H743_SPI\test-double-buffer.ps1 -ReadOnly -SerialNumber 35FF6C064D53373238602143
```

**Prossimo sviluppo previsto allora (ora completato):** blitter COPY e scroll.
Il back non viene copiato o inizializzato automaticamente: cancellarlo o
ricostruirlo prima del primo PRESENT e gestire la coerenza per redraw parziali.
Triple buffering e ROP restano futuri. Nessuna prova fisica di spegnimento e
riaccensione eseguita in questa sessione.

## Cronologia precedente - 10 settembre 2026

Le sezioni successive descrivono lo stato storico, superato dalla sintesi sopra.

## Stato verificato a fine sessione

Sulla scheda gira tutto: `g_lcd_fpga_text_demo_state = 2`, `g_lcd_error` in
fase 0, riscontro fotografico dell'utente con testi, rettangolo `B9`, cornici,
stella a otto raggi e la scritta `CLIP` correttamente tagliata a `CLI`.

**Prima misura del guadagno di `B9`:** `g_lcd_clear_ms16` vale 128 ms, cioe'
**8 ms per un clear a schermo intero**, contro i circa 300 ms che la stessa
operazione costa passando pixel per pixel da `B7`. Il collo di bottiglia si e'
spostato dalla SPI al renderer, che costruisce i burst in serie a 27 MHz.

### Una trappola che e' costata una diagnosi sbagliata

La demo si fermava **sempre allo stesso comando** — i primi cinque testi
disegnati, dal sesto in poi niente — registrando fase 9, cioe' primo byte `00`
invece di `A5`. Quel byte e' una costante precaricata nello shift register
della FPGA, quindi sembrava un guasto elettrico, e il sospetto era caduto sul
filo appena cablato.

Non lo era: sulla scheda c'era un bitstream **anteriore all'ultima modifica
dell'RTL**, quindi firmware e logica si parlavano con due contratti diversi.
Ricostruire e riprogrammare ha risolto senza toccare altro. Due regole da
ricordare: confrontare le date di `impl/pnr/LCD.fs` e dei file sotto `src/`
prima di ogni altra ipotesi, e diffidare dell'istinto quando il guasto e'
**deterministico** — un cablaggio difettoso da' errori sparsi, non un blocco
sempre nello stesso punto.

Attenzione anche a come si legge lo stato via SWD: leggere subito dopo
`--hardRst` restituisce zeri perche' la MCU non ha ancora eseguito nulla, e
quegli zeri sembrano "demo mai partita". Serve attendere l'avvio, oppure
leggere a regime senza resettare.

## Predisposizione IRQ per PRESENT

L'utente ha collegato Tang Nano IO28 a STM32 PB0 e rigenerato da CubeMX.
Configurazione allineata in `.ioc` e `gpio.c`: `FPGA_IRQ_N`, pull-up,
EXTI0 fronte di discesa, priorità 5/subpriorità 0. Il generatore aveva lasciato
fronte di salita e priorità 0, corretti durante la verifica.
**Lato STM32 la linea e' ora consumata.** `HAL_GPIO_EXTI_Callback` e'
ridefinita e fa solo cio' che serve, alzare un flag, come previsto dal disegno;
tre variabili leggibili via SWD rendono il filo verificabile: `g_fpga_irq_count`
(fronti osservati), `g_fpga_irq_pending` e `g_fpga_irq_level` (livello campionato
all'avvio). Finche' la FPGA non pilota il pin 28 — oggi non assegnato in
`LCD.cst` — il contratto e' **conteggio 0 e livello 1**, ed e' quello misurato
sulla scheda: la linea sta alta e il pull-up tiene, quindi il cablaggio e' sano.
Qualunque altro valore direbbe che il filo raccoglie disturbi o e' sul pin
sbagliato, ed e' bene accorgersene prima di costruirci sopra un protocollo.

Restano da implementare: **uscita IRQ lato FPGA**, double buffering e PRESENT.
Il solo cablaggio non abilita lo scambio dei buffer.

## Ultima aggiunta: linee oblique FPGA

`LCD_DrawLine(x0,y0,x1,y1,color)` implementata: B9 tipo 1, pacchetto di
18 byte con CRC, Bresenham FPGA, estremi inclusi, tutte le direzioni e punto
singolo. Coordinate fuori schermo rifiutate; niente clipping o antialiasing.
Le linee H/V chiamate tramite questa API usano il fill tipo 0. I vecchi
bitstream rifiutano tipo 1 con E1; sono stati aggiornati sia FPGA sia MCU.

Sette testbench SPI/grafica superati, con 124 linee verificate pixel per pixel,
backpressure/CDC e prove negative del protocollo. MCU Debug e Release compilate.
Build FPGA finale con `build.ps1` default: zero violazioni setup/hold/recovery/removal,
vincoli invariati (SPI 12.5 MHz, PSRAM 81 MHz). Una prima versione a registri
più larghi falliva setup di 0.252 ns verso la PSRAM; ridotta la larghezza
aritmetica e ricompilato con esito positivo, senza eccezioni al gate.

Programmate Embedded Flash e User Flash FPGA tramite openFPGALoader (CRC
bitstream riuscito), poi STM32 Release con verifica flash. Controllo SWD:
eco e demo completate, nessun errore HAL/LCD; il testo completato conferma
anche la disponibilità dei font validati a runtime. La demo contiene una
stella a otto raggi colorati centrata a (350,193), sotto FILL B9.
Log: `impl/oblique-build.log`, `impl/oblique-program.log`, e
`stm32/WeAct_H743_SPI/build/Release/oblique-demo-result.json` (include hash
ELF e bitstream). Nessuna rilettura hardware dei pixel o prova di power-cycle
eseguita; la conferma visiva resta distinta dal controllo SWD.

## Aggiornamento corrente: B9, Release e linee

Il riferimento del protocollo e delle API è [GRAPHICS_COMMANDS.md](GRAPHICS_COMMANDS.md):
B7 pixel arbitrari, B8 testo FPGA, B9 riempimenti hardware. `LCD_Clear` e
`LCD_FillRect` usano B9; aggiunte `LCD_DrawHLine` e `LCD_DrawVLine`, spesse
un pixel, senza clipping. Non richiedono nuovi opcode o modifiche RTL.
Build Debug e Release delle API linea superate. Successivamente aggiunte alla
demo FPGA otto linee: bordi orizzontali bianchi e verticali ciano dello schermo,
cornice gialla/magenta attorno a FILL B9. Release caricata con verifica flash;
controllo SWD superato (eco SPI, demo completata, nessun errore HAL/LCD).
Risultati in `build/Release/lines-demo-result.json` sotto il progetto STM32;
la verifica visiva del pannello resta distinta dal controllo software.
Il confronto Debug/Release e i suoi collaudi sono in
[MCU_RELEASE_COMPARISON.md](MCU_RELEASE_COMPARISON.md). Il build predefinito
resta Debug: usare `-Preset Release` per Release.
Configurazione di avvio: un round eco, GPIO probe disabilitato,
`LCD_BOOT_TESTS=0`, `LCD_TEXT_DEMO=0`, `LCD_FPGA_TEXT_DEMO=1`.
Copie, scroll, framebuffer multipli e ROP sono solo valutazioni in
[BLITTING_ROP_STUDY.md](BLITTING_ROP_STUDY.md), non funzionalità presenti.
Le sezioni sotto conservano le verifiche e la cronologia delle tappe precedenti;
frequenze, flag e limitazioni storici non sostituiscono questo stato corrente.

## Ultimo stato: testo renderizzato dalla FPGA, font in User Flash

Il rendering del testo è passato dall'STM32 alla FPGA. Tre moduli nuovi:
`src/UserFlashReader.sv` incapsula il primitivo `FLASH608K` in una lettura a
word di sola lettura; `src/FontStore.sv` valida l'immagine (magic `LCDF`,
versione, lunghezza, CRC-32 sui 25.152 byte) e poi espone le word ai client;
`src/TextRenderer.sv` decodifica UTF-8 e disegna a cella fissa sopra
l'interfaccia di burst mascherato già esistente. Il comando SPI è l'opcode
`B8`, documentato in `SPI_TEXT.md` con pacchetto, CRC16 e byte di stato.

I font sono tre Terminus a cella fissa (8x16, 12x24, 16x32), 196 glifi
ciascuno: ASCII stampabile, Latin-1, euro e quattro frecce. Occupano 25.152 dei
77.824 byte della User Flash. `tools/generate_user_flash_fonts.py` li ricava in
modo riproducibile dai BDF sotto `third_party` (SIL OFL 1.1) ed emette il
`.bin`, il `.mem` per le simulazioni e un manifest JSON. Il `.fi` di Gowin non
e' versionato: lo trascrive `program_tang_nano_flash.ps1` quando serve, cosi'
c'e' un solo file dei font e non se ne puo' passare uno sbagliato.

Il 16x32 è stato tolto e rimesso il 10 settembre 2026: sembrava non entrare in
flash accanto al bitstream, ma la misura che lo diceva era viziata dal formato
di file sbagliato. La storia è in `SPI_TEXT.md`; la conclusione è che i tre
font ci stanno e la scheda si avvia da flash con tutti e tre a bordo.

Verifiche superate:

- sei testbench PASS, inclusi i due nuovi `tb_font_store` e `tb_text_renderer`;
  la simulazione legge `fonts/user_flash_fonts.mem` tramite il ramo `SIMULATION`
  di `UserFlashReader`, quindi quel file deve esistere prima di simulare;
- build FPGA PASS con `FLASH608K` piazzata 1/1; gate di timing senza violazioni,
  Fmax 57.92 MHz su xtal_27, 57.364 su lcd_clk_9, 81.373 su psram_clk_81.
  Attenzione a come si legge questo risultato: il vincolo `spi_clk` in `LCD.sdc`
  è stato riportato da 40 ns a 80 ns, cioè ai 12.5 MHz effettivi del master,
  mentre prima si teneva di proposito il vincolo più severo dei 25 MHz. Parte
  del margine guadagnato viene da lì, non solo dal pipeline di `Almost_Full` in
  `FramebufferController` e dalla soglia scesa a 495 in `FramebufferFifo`.
  Prima di risalire di frequenza il vincolo va rimesso a 40 ns e il gate
  rieseguito;
- collaudo hardware PASS a 12.5 MHz con `-RequireFPGAText`:
  `fpga_text_state=2`, `lcd_error.phase=0`, 1.049.760 byte di eco, zero
  mismatch, tutte le prove GPIO corrette;
- riscontro visivo dell'utente sul pannello: accenti e frecce corretti, wrap
  dentro un box stretto, sfondo trasparente, e il clipping confermato dal
  comando `CLIP` a x=430 che si ferma su `CLI`.

Lato STM32 `LCD_DrawTextFPGA()` costruisce il pacchetto, calcola il CRC16,
attende l'accettazione e ritorna solo a rendering finito. In
`spi_diag_config.h` la demo di collaudo `LCD_FPGA_TEXT_DEMO` è a 1 e la vecchia
demo CPU `LCD_TEXT_DEMO` è a 0; `LCD_BOOT_TESTS` resta 0.

Rimossa `src/framebuffer_fifo/`: era l'IP Gowin già sostituito da
`FramebufferFifo.sv` e disabilitato nel progetto. Le sue soglie di riferimento
(512 word, FWFT, almost-full 504, almost-empty 240) restano annotate in
`FramebufferFifo.sv`. Rebuild dopo la rimozione: stessi Fmax, nessuna
differenza.

### Avvio: SPI_Setup() e attesa adattiva della FPGA

La preparazione del collegamento è uscita da `SPI_SelfTest_Run()` ed è ora
`SPI_Setup()`, chiamata per prima in `main()`. Fa le tre cose che servono sempre:
deseleziona, emette i due impulsi SCK che sopprimono l'anomalia GPIO dopo il
caricamento della FPGA, e **aspetta che la FPGA risponda davvero** invece di
fidarsi di un `HAL_Delay(100)` alla cieca.

L'attesa sfrutta una proprietà del protocollo: solo `B7` e `B8` sono opcode,
quindi un primo byte qualunque, qui `00`, finisce nel percorso di eco, che
risponde `A5` seguito dall'eco del byte precedente. Una FPGA non configurata non
può produrre quella sequenza, perché i suoi pin sono ingressi con pull-up deboli
e MISO si legge `FF`. Far tornare l'eco dimostra quindi configurazione avvenuta,
PLL agganciati e slave SPI in funzione. Il ciclo ripete impulsi e sonda fino a
`SPI_SETUP_TIMEOUT_MS`, cioè 2 secondi.

Due campi nuovi in coda a `SpiTestResult`, `ready_ms` e `ready_attempts`,
registrano quanto è costata l'attesa; il runner li legge (56 byte invece di 48,
la parte iniziale è invariata). Misura sul banco: **12 ms e un solo tentativo**,
cioè la FPGA era già pronta all'arrivo della MCU.

La prova GPIO è diventata opzionale, `SPI_GPIO_PROBE`, perché costa circa 790 ms
misurati procedendo un bit alla volta con `HAL_Delay(1)`. Resta indispensabile
per diagnosticare, ed è quella che ha risolto il guasto del 10 settembre, quindi
`test-hardware.ps1` la pretende e rifiuta di partire senza.

Bilancio dell'avvio, misurato: **8.821 ms all'origine, 1.165 dopo la riduzione
dei round, 45 adesso** — 12 ms di attesa FPGA più 33 di verifica eco. Il round
di eco è rimasto di proposito: `g_spi_test.state = 2` deve restare un verdetto
dimostrato, non un'assegnazione, perché è ciò che impedisce di disegnare su un
collegamento rotto e che il 10 settembre ha reso immediata la diagnosi.

### Punti aperti

- ~~La scheda ha in Embedded Flash un bitstream più vecchio di quello su disco.~~
  Chiuso il 10 settembre 2026. Il sintomo era schermo spento dopo un reset di
  FPGA e MCU. La diagnosi via SWD ha escluso subito i font: `state=3`, quindi
  self-test fallito, `fpga_text_state=0`, quindi demo testo mai avviata, e
  `lcd_error.phase=0`, quindi nessun comando `B8` mai inviato. Il dato decisivo
  è stata la prova GPIO, che leggeva `FF` su MISO in tutte e tre le
  configurazioni, **pull-down incluso**: non una linea flottante, come nel
  guasto storico che con pull-down dava `00`, ma una linea tenuta alta. È la
  firma di una FPGA non configurata, i cui I/O restano in ingresso con i
  pull-up deboli previsti da `Unused_Pin`. Confermato dal User Code a
  `0x00000000` e dal bit di CRC error nello status `0x00031421`.
  Dopo `program_tang_nano_flash.ps1`: User Code `0x0000C765`, status
  `0x0003B020` senza CRC error, e collaudo PASS con `state=2`, zero mismatch,
  GPIO corrette in tutte e tre le prove e `fpga_text_state=2`. Riscontro visivo
  dell'utente sul pannello.
- Embedded Flash e User Flash sono lo stesso array fisico: programmare la
  embFlash senza `--fiFile` cancella i font, in silenzio. Dettagli e conseguenze
  in `PROGRAMMING.md`.
- Le demo di collaudo sono ancora attive e disegnano al boot: quando il testo
  non va più dimostrato, riportare `LCD_FPGA_TEXT_DEMO` a 0.
- Il debounce del pulsante di reset resta rinviato, come da sessioni precedenti.
- **`program_tang_nano_flash.ps1` dichiara successo anche quando la verifica
  fallisce.** Nella programmazione del 10 settembre `programmer_cli` ha stampato
  `Error: Verify Failed at 0` ed è comunque uscito con codice 0, quindi il
  controllo su `$LASTEXITCODE` non se ne è accorto e lo script ha riportato
  "programmate e verificate". Ora l'output viene ispezionato in
  `tools/Invoke-GowinProgrammer.ps1`, e il controllo si è dimostrato utile al
  primo impiego reale.
- **`Verify Failed` sulla Embedded Flash non dice se la scrittura sia riuscita.**
  Fallisce sempre, e trascina con sé `Error: Program failed` e spesso l'uscita 1.
  Una nota precedente lo dichiarava un falso allarme innocuo: **era sbagliata**.
  Il 10 settembre, dopo una di quelle programmazioni, la scheda non si è avviata
  — FPGA non configurata, e la MCU ha registrato `ready_attempts = 167` in due
  secondi senza mai una risposta. Altre volte, con lo stesso identico messaggio,
  la flash si è avviata correttamente. Non correla: va accertato ogni volta.

  L'accertamento è asimmetrico, ed è la cosa utile scoperta quel giorno. La
  **User Flash si verifica a runtime**, senza togliere corrente: si configura la
  logica da SRAM, si resetta la MCU e si guarda il testo, perché `FontStore`
  verifica il CRC-32 dei 25.152 byte prima di accettare comandi, e
  `g_lcd_error.phase = 11` segnala l'immagine non valida. Il **bitstream** invece
  richiede un ciclo di alimentazione: subito dopo la programmazione il
  dispositivo resta non configurato e leggere i codici non prova nulla.

  Non è ancora spiegato perché la verifica di `programmer_cli` fallisca sempre.
  Restano escluse con prove la compressione del bitstream, la dimensione
  dell'immagine combinata (fallisce anche il solo bitstream) e le frequenze
  JTAG più basse, che fanno crashare `programmer_cli` durante la cancellazione.

  In pratica la domanda ha perso urgenza, perché il 10 settembre i due
  programmatori sono stati messi a confronto cambiando driver apposta, e il
  verdetto è netto: da openFPGALoader la flash si programma e si avvia in modo
  riproducibile, font compresi; da `programmer_cli`, sulla stessa scheda e con
  lo stesso driver WinUSB, i font non superano il CRC (`phase = 11`). Il
  percorso Gowin resta negli script per altre macchine ma qui non va usato:
  la prova col ciclo di alimentazione dice che nemmeno il bitstream si salva,
  `User Code 0x00000000` e CRC error. Funziona invece benissimo la sola
  programmazione SRAM, che con `-UseGowinProgrammer -CableIndex 5` carica in
  4,5 s e fa partire la logica.
  Prove e numeri in `PROGRAMMING.md`, sezione "Perché su questa macchina resta
  solo openFPGALoader". Da lì viene anche il parametro `-CableIndex`: sotto
  Zadig `programmer_cli` vuole il cavo 5 (WINUSB), non l'1 (FT2CH).
- **`programmer_cli` non parte se l'ambiente definisce `PYTHONIOENCODING`.** È
  un eseguibile Python congelato e muore con `0xC0000409` e
  `LookupError: unknown encoding: utf-8:surrogateescape` prima di toccare la
  scheda. Non si vede da una PowerShell interattiva normale, ma colpisce
  qualunque automazione che esporti quella variabile. Gli script che invocano il
  programmer dovrebbero azzerarla per il processo figlio.
- La sequenza XE/YE/SE di `UserFlashReader` usa un'attesa fissa tarata sui
  27 MHz: funziona al banco, ma non è stata confrontata con i margini del
  datasheet del primitivo.

Le sezioni seguenti sono cronologia.

## Ultimo stato: avvio nero uniforme, SPI 12.5 MHz

Su richiesta dell'utente: PATTERN_SOLID in FramebufferController con parametro
BACKGROUND_COLOR=16'h0000. Nessun bordo o diagonale all'avvio/reset FPGA.
LCD_BOOT_TESTS=0 in spi_diag_config.h: demo/stress grafici sono opt-in; resta
il self-test eco lungo, che da solo non modifica lo schermo. Schede programmate,
flash verificata; eco hardware PASS 1049760 byte a 12.5 MHz, GPIO corrette.
SPI testbench PASS con controllo di tutti i 130560 pixel iniziali neri.
Gate timing PASS: sette endpoint di calibrazione ammessi, worst -1.487 ns,
nessun'altra violazione. SDC mantenuto a 40 ns, master effettivo 12.5 MHz.

Aggiunte API STM32 LCD_FillRect(x,y,w,h,color) e LCD_Clear(color), implementate
sopra LCD_WriteRect con un buffer di riga da 960 byte sullo stack. RGB565,
ritorno 1/0, nessun nuovo opcode FPGA e nessun disegno automatico aggiunto.

Prototipo font STM32 aggiunto: rendering UTF-8 opaco fixed 12x24 con 196 glifi
(ASCII, Latin-1, euro, frecce), 9408 byte bitmap in flash MCU. Generatore
riproducibile dal BDF sotto SIL OFL 1.1 in third_party. `LCD_TEXT_DEMO=1` e'
temporaneamente attivo per la prova visiva; `LCD_BOOT_TESTS` resta 0.
Firmware caricato e collaudo hardware PASS: 1200 trasferimenti, 1049760 byte,
zero mismatch a 12.5 MHz, `text_state=2`. L'utente ha confermato visivamente
il campione completo: testo regolare, simbolo di grado, vocali accentate e
quattro frecce corretti, senza corruzione apparente.

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
