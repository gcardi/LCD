# Diagnosi SPI a 12.5 MHz — 9 settembre 2026

## Risultato

Il collegamento passa a 12.5 MHz con GPIO STM32 `MEDIUM`. Non e' stato
modificato il cablaggio. I fronti `HIGH` e `VERY_HIGH` producono errori
ripetibili. L'eco a 6.25 MHz passa, ma una successiva prova CRC ha trovato
un blocco con stato errato anche a 6.25 MHz VERY_HIGH: usare MEDIUM.

La prova eco lunga usa tre ripetizioni di 400 transazioni per impostazione,
con lunghezze 1, 2, 17, 257, 4097 e pattern deterministico variabile.

| GPIO STM32 | Errori eco a 6.25 MHz / 1049760 byte | Errori eco a 12.5 MHz / 1049760 byte |
|---|---:|---:|
| VERY_HIGH | 0 | 33664 |
| HIGH | 0 | 21970 |
| MEDIUM | 0 | 0 |

Prove separate a 12.5 MHz, tre ripetizioni per impostazione:

| Prova | VERY_HIGH | HIGH | MEDIUM |
|---|---|---|---|
| Eco MOSI -> MISO, 104976 byte | errori | errori | 0 errori |
| Sequenza FPGA autonoma, 104976 byte | errori/ripartenze | errori/ripartenze | 0 errori |
| MOSI, 24 blocchi da 4096 byte con CRC riletto lento | controllo errato | controllo errato | tutti i 24 CRC corretti |

Tutti i casi completati senza errori HAL. Il totale di byte della prova CRC
si riferisce a 98304 byte di payload; sul ritorno si confrontano 96 byte di
stato, non l'intero payload. Ogni variante FPGA supera il gate timing prima
del caricamento. La prima versione CRC a byte e' stata respinta dal gate per
una calibrazione PSRAM a -2.596 ns e non caricata; la versione bit-seriale
supera il gate senza cambiarne le soglie.

## Interpretazione e limiti

`GPIO_SPEED_FREQ_*` regola i fronti, non la frequenza SPI. Cambiare solamente
questa impostazione durante la matrice cambia drasticamente l'esito.
Il risultato sostiene l'ipotesi di un problema di integrita' dei segnali;
non dimostra quale filo o quale circuito generi il disturbo.

Nei primi errori eco archiviati, il byte ricevuto e' A5 mentre i vicini sono
corretti. La sequenza autonoma riparte da A5, EA, 75...: questo e' compatibile
con una reinizializzazione dello stato dello slave. Occorre una misura di
SCK/CS/reset per distinguere disturbi elettrici e comportamento interno RTL.
La sequenza autonoma esclude la dipendenza dai dati MOSI, ma usa ancora SCK,
CS e il reset comuni: non e' una misura isolata del solo filo MISO.

Il CRC e' CRC-16/CCITT-FALSE (polinomio 1021, iniziale FFFF, MSB first, niente
riflessione/XOR finale). La FPGA riceve 4096 byte e poi risponde C3, CRC alto,
CRC basso, 5A. Il master mantiene CS basso e passa a 781250 Hz per lo stato.
Una risposta di stato errata puo' indicare anche perdita di allineamento,
non soltanto un bit MOSI errato. Simulazioni coprono i due flussi, il cambio
di frequenza a CS basso e l'aborto di una transazione parziale.

Le modalita' richiedono bitstream distinti: i conteggi di errori fra modalita'
non misurano direttamente la stessa implementazione fisica. I confronti
fra fronti e frequenze all'interno di ciascuna matrice usano lo stesso
bitstream e firmware.

La prima transazione dopo un caricamento FPGA presenta un'anomalia separata:
prima prova GPIO D2 BC invece di A5 3C; senza prova GPIO preliminare, anche
la prima lettura della sequenza autonoma a 6.25 MHz ha ricevuto D2 invece di
A5. Il primo blocco CRC a 6.25 MHz ha anch'esso stato errato; i successivi
passano. Le prove a regime non qualificano ancora questa condizione iniziale.
Non sono state fatte misure analogiche, variazioni di temperatura o prove
oltre 12.5 MHz. Non e' una qualifica della futura scrittura framebuffer.

## Riproduzione e artefatti

Dalla radice del progetto:

```powershell
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode echo
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode miso
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode mosi
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -Mode echo -Rounds 80
# Ripristina il normale test eco, compila/carica entrambe le schede e verifica:
.\stm32\WeAct_H743_SPI\diagnose-hardware.ps1 -SerialNumber 35FF6C064D53373238602143 -RestoreSelfTest
```

Il runner imposta MODE nel TOP e nella configurazione C, abilita la matrice,
e vincola SCK a 80 ns prima della build. Lascia questa configurazione attiva
finche' non viene richiesto RestoreSelfTest. Tale opzione ripristina la
modalita' eco normale; frequenza/fronti del test normale sono in spi.c e
nella funzione probe_gpio. I mismatch sono risultati diagnostici e non
causano eccezione; timeout, dump incompleti, errori HAL e timing non ammesso
causano eccezione. Il runner normale rifiuta una configurazione matrice attiva.

Ogni archivio in `stm32/WeAct_H743_SPI/build/Debug/` contiene result.json,
matrix.bin, ELF, bitstream, report timing e hash degli artefatti:

- diagnostic-echo-20260909-105509: matrice iniziale, 8 round;
- diagnostic-miso-20260909-105616: sequenza autonoma;
- diagnostic-mosi-20260909-105832: CRC bit-seriale;
- diagnostic-echo-20260909-110023: matrice lunga, 80 round.

Questi archivi sono ignorati da Git. Ogni caso salva fino a 16 errori con
round, lunghezza, indice e byte precedente/successivo attesi e ricevuti;
il valore 256 indica un vicino non presente. I contatori totali non sono
limitati ai 16 eventi archiviati. Layout RAM verificato con static assert,
indirizzi letti dai simboli ELF, senza indirizzi SWD fissati nel runner.

## Inizializzazione dopo caricamento FPGA

Esperimenti successivi con lo stesso bitstream eco:

- caricamento FPGA + STM32, senza inizializzazione aggiunta: primo GPIO D2 BC;
- solo upload/reset STM32, FPGA gia' in funzione: tutti i GPIO corretti;
- CS basso/alto senza clock dopo caricamento FPGA: anomalia invariata;
- due impulsi SCK lenti con CS sempre alto prima della prima transazione:
  tutte e tre le prove GPIO corrette e DMA a 12.5 MHz MEDIUM senza errori.

Il firmware ora esegue questi due impulsi a slave deselezionato, dopo
l'attesa iniziale di 100 ms. Non scarta una transazione di dati: nessuno
slave e' selezionato durante i due impulsi. E' una sequenza di inizializzazione
verificata sul banco; non costituisce una spiegazione definitiva del
comportamento interno della FPGA all'avvio. Il runner normale ora richiede
anche che tutti e tre gli scambi GPIO coincidano con la sequenza attesa.

Evidenze: diagnose-final-cold.json, diagnose-final-warm.json,
diagnose-cs-init.json, diagnose-idle-clocks.json in build/Debug.

Ricontrollo con l'inizializzazione aggiunta:

- diagnostic-miso-20260909-110820: prima transazione corretta; MEDIUM senza
  errori a entrambe le frequenze, 104976 byte per frequenza;
- diagnostic-mosi-20260909-110856: primo blocco corretto; tutti i 24 blocchi
  MEDIUM corretti a ciascuna frequenza. VERY_HIGH a 6.25 MHz mostra un blocco
  con quattro byte di stato errati nella seconda ripetizione, quindi non
  tutti i difetti VERY_HIGH sono limitati al primo avvio o ai 12.5 MHz.

Il test normale finale usa 12.5 MHz, fronti MEDIUM, MODE=0, matrice disabilitata.
La verifica normale e' stata ripetuta dopo nuovo caricamento delle due schede.
