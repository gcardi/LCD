# Firmware WeAct H743 / Tang Nano 9K

## Build e upload

Aprire questa cartella in VS Code. Servono CMake, Ninja, arm-none-eabi-gcc
nel PATH e STM32CubeProgrammer CLI (gia' incluso nel CubeCLT installato).

```powershell
.\build.ps1                  # configura e compila Debug
.\build.ps1 -ListProbes      # elenca le sonde, senza collegarsi al target
.\build.ps1 -Program -SerialNumber <seriale>
```

Il comando -Program compila, scrive l'ELF agli indirizzi in esso contenuti,
verifica la flash e resetta il micro. Si ferma se un comando fallisce; nessuna
cancellazione globale o modifica degli option byte. Richiede il seriale per
selezionare esplicitamente il target quando sono presenti piu' sonde.
La programmazione sostituisce il firmware nelle aree interessate.

Opzioni: `-Preset Release`, `-SwdFrequencyKHz 1000`,
`-ProgrammerPath <percorso>`, `-UnderReset` (richiede NRST collegato).
Chiudere una sessione debug che occupa la sonda prima dell'upload.
Log e artefatti in `build/<preset>/`, esclusi da Git.

In VS Code: Terminal > Run Task > STM32: Build and upload Debug.
La task chiede il seriale. Ctrl+Shift+B esegue soltanto la build.

## Cablaggio implementato

Questi numeri TangNano sono IO FPGA, non posizioni contate sul connettore.
Il cablaggio e' implementato nel TOP e nei vincoli del progetto LCD.

| WeAct | TangNano IO | Segnale |
|---|---:|---|
| GND | GND | Massa comune |
| PB13 | 36 | SCK |
| PB15 | 25 | MOSI |
| PB14 | 26 | MISO |
| PB12 / FPGA_CS | 27 | CS attivo basso |

Nessun D/C. READY non e' ancora implementato e non serve al primo test breve.
Slot microSD TangNano vuoto (SCK IO36 condiviso). Alimentazione dalle rispettive USB,
solo masse e segnali fra schede, senza unire 5 V o 3.3 V. Logica 3.3 V,
cavi corti, pull-up 10 kohm su CS verso 3.3 V TangNano.
Non pilotare i pulsanti/reset a 1.8 V della TangNano con il micro.

ST-LINK: SWDIO -> PA13, SWCLK -> PA14, GND -> GND, NRST -> NRST consigliato.
Su sonde con ingresso VTref collegarlo al 3.3 V target. Non confondere VTref
con l'uscita di alimentazione 3.3 V di alcune sonde/cloni; WeAct alimentata USB.

## Test hardware automatico

Dalla radice del repository:

```powershell
.\stm32\WeAct_H743_SPI\test-hardware.ps1 -SerialNumber 35FF6C064D53373238602143
```

Esegue simulazioni SPI, build e caricamento SRAM FPGA, build e upload STM32,
quindi legge il risultato via ST-LINK. Disponibile anche come task VS Code
`STM32 + FPGA: Build, upload and test SPI`. Il bitstream SRAM si perde allo
spegnimento della Tang: ripetere il comando dopo un ciclo di alimentazione.

`-ReadOnly` legge soltanto i risultati usando i simboli dell'ELF locale: usarlo
solo se quell'ELF e' quello caricato. L'hash registrato identifica il file locale,
non costituisce una verifica della flash in questa modalita'.

`SpiDiagnostic` restituisce A5 al primo byte dopo CS basso, poi il precedente
byte MOSI. Non modifica il framebuffer. Prima del DMA, una prova GPIO lenta
invia otto byte con tre configurazioni MISO (nessun pull, up, down). Le risposte
attese sono `A5 3C 4D 5E 6F 80 91 A2` in tutti e tre i casi.

Il firmware esegue poi 40 trasferimenti DMA a 12.5 Mbit/s, GPIO MEDIUM (lunghezze
1, 2, 17, 257, 4097 ripetute otto volte), verificando 34992 byte. I buffer sono
in SRAM D2, allineati a 32 byte, con gestione cache se abilitata. CS viene
rialzato dopo il completamento SPI. Il risultato e' in `g_spi_test`; il runner
salva `build/Debug/hardware-result.json` e fallisce su timeout o mismatch.
La sezione RAM aggiuntiva e il sorgente del test sono collegati dal CMake
utente, senza modificare il linker generato da CubeMX.

## Esito del primo collaudo (2026-09-08)

Simulazioni superate (525 byte RX / 515 TX generici, 32777 byte diagnostici),
build FPGA con gate timing superato, upload FPGA e STM32 verificati.
ST-LINK V2 rileva STM32 rev. V, alimentazione 3.27 V.

**Test hardware non superato:** 40 trasferimenti completati, nessun errore HAL,
34853 mismatch su 34992 byte. La prova GPIO legge FF con pull-up e 00 con
pull-down: MISO appare non pilotato lato STM32 anche con CS comandato basso.
Verificare la corrispondenza dei quattro segnali e la selezione dello slave;
questo risultato non qualifica ancora il collegamento ne' la velocita' massima.

Aggiornamento 2026-09-09: corretto un connettore invertito, il DMA passa a
0.78125, 1.5625, 3.125 e 6.25 MHz. A 12.5 MHz compaiono 32 mismatch su
34992 byte nonostante il PASS timing. Configurazione corrente: 6.25 MHz,
prescaler 32, vincolo SPI 160 ns; CubeMX allineato. Non salire ulteriormente
prima di diagnosticare gli errori. Resta un'anomalia nei primi due byte del
primo scambio GPIO senza pull; gli scambi con pull-up/down sono corretti.
Il runner determina il PASS dal DMA e riporta separatamente i byte GPIO.
Risultati e limiti: ../../docs/SPI_PERFORMANCE.md.

Diagnosi successiva: a 12.5 MHz i fronti MEDIUM eliminano gli errori nelle
prove eseguite (eco lungo: 1049760 byte, sequenza autonoma: 104976 byte,
MOSI: 24 blocchi da 4096 byte con CRC corretto). Configurazione corrente
prescaler 16, GPIO MEDIUM, SDC 80 ns; CubeMX allineato. Il test normale e'
stato ricaricato e supera il confronto DMA. L'anomalia della prima prova
GPIO dopo caricamento FPGA non ricompare riavviando il solo STM32.

Il nuovo `diagnose-hardware.ps1 -SerialNumber <seriale> -Mode echo|miso|mosi`
esegue tre ripetizioni a 6.25/12.5 MHz e fronti VERY_HIGH/HIGH/MEDIUM;
`-Rounds 80` estende la prova. Salva fino a 16 eventi per caso con byte
vicini, contatori totali e artefatti identificati da hash. I mismatch sono
evidenze diagnostiche e non fanno fallire questo runner; controllare i
risultati. `-RestoreSelfTest` disabilita la matrice e ricarica il test normale.
Procedura e risultati: ../../docs/SPI_DIAGNOSTIC_RESULTS.md.

Il firmware inizializza ora lo slave con due impulsi SCK a CS alto prima
 della prima transazione. Dopo nuovo caricamento FPGA le tre prove GPIO
passano; il runner normale le verifica oltre al DMA. La sola commutazione
CS senza clock non era sufficiente. Vedere il report diagnostico per i
limiti di questa sequenza di inizializzazione e le prove successive.
