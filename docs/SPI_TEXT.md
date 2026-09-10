# Comando testo SPI B8

Il renderer FPGA usa tre font Terminus a cella fissa memorizzati nella User
Flash del GW1NR-9C. L'immagine occupa 25.152 dei 77.824 byte disponibili e
contiene 196 glifi per ciascuna dimensione:

| font_id | Cella | Byte/glifo |
|---:|---:|---:|
| 0 | 8x16 | 16 |
| 1 | 12x24 | 48 |
| 2 | 16x32 | 64 |

Il 10 settembre 2026 questi tre font sono stati tolti e rimessi nel giro di
poche ore, e la storia vale la pena di essere raccontata perché il primo
verdetto era sbagliato. Una bisezione sembrava mostrare che bitstream e User
Flash, condividendo l'array fisico, non ci stessero insieme oltre i 18.432 byte
di font. In realtà quella bisezione passava a openFPGALoader dei file `.fi`, che
è testo ASCII e occupa circa quattro volte il payload: la soglia misurata cade
esattamente dove il testo del `.fi` supera i 77.824 byte della User Flash
(18.432 → 76.173 byte, 19.456 → 80.461). Non era un conflitto di capacità, era
il formato di file sbagliato — lo stesso problema che faceva fallire il CRC dei
font. Passando l'immagine binaria grezza, i 25.152 byte si programmano e la
FPGA si avvia da flash senza obiezioni. Vedi `PROGRAMMING.md`.

Il subset comprende ASCII stampabile, Latin-1, euro e le quattro frecce. Un
codepoint non presente viene sostituito da `?`. Le sorgenti BDF Terminus sono
distribuite secondo SIL Open Font License 1.1, inclusa in `third_party`.

## Pacchetto

Tutti i campi multibyte sono big endian. La lunghezza indica byte UTF-8, da 0
a 64; il terminatore zero della stringa C non viene trasmesso.

| Offset | Campo |
|---:|---|
| 0 | opcode `B8` |
| 1 | dummy/status |
| 2 | font_id |
| 3 | flags: bit 0 trasparente, bit 1 wrap |
| 4..5 | x |
| 6..7 | y |
| 8..9 | larghezza box; zero = fino al bordo destro |
| 10..11 | altezza box; zero = fino al bordo inferiore |
| 12..13 | foreground RGB565 |
| 14..15 | background RGB565 |
| 16 | lunghezza UTF-8 |
| 17.. | testo |
| 17+N..18+N | CRC16-CCITT, init `FFFF`, polinomio `1021` |
| 19+N | commit `A6` |
| 20+N | dummy per leggere l'esito |

Il secondo byte ricevuto vale `C3` quando la coda è libera, `00` durante il
rendering ed `E2` finché l’immagine font non è disponibile o non supera il
CRC32. Il byte ricevuto dopo il commit vale `AC` se il comando è accettato,
`E1` in caso contrario.

Il clipping al box e allo schermo è sempre attivo. Il ritorno a capo avviene
solo su `\n`, oppure automaticamente quando è impostato il flag wrap. Senza
wrap, la parte a destra del box viene scartata.

## Generazione e programmazione

```powershell
python tools\generate_user_flash_fonts.py third_party\terminus-font-4.49.1-master fonts
.\build.ps1
.\program_tang_nano_flash.ps1
```

L’ultima operazione programma e verifica sia la configurazione FPGA nella
Embedded Flash sia i font nella User Flash. Per i normali aggiornamenti
volatili del solo bitstream resta disponibile `program_tang_nano_sram.ps1`.

Il test hardware completo, incluso lo stato finale del renderer FPGA, è:

```powershell
.\stm32\WeAct_H743_SPI\test-hardware.ps1 `
  -SerialNumber <seriale-ST-LINK> -RequireFPGAText
```

Sul firmware STM32, `LCD_DrawTextFPGA()` costruisce il pacchetto, calcola il
CRC, attende l’accettazione e ritorna soltanto dopo il completamento del
rendering.
