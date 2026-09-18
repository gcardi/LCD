# Logo di avvio

Al reset la FPGA disegna il logo nella User Flash prima di accettare comandi
SPI. Non serve l'MCU: un logo visibile conferma che bitstream e immagine User
Flash sono coerenti.

![Il logo di avvio](../resources/BootLogo.png)

Il file sorgente versionato e' `resources/BootLogo.png`. Il generatore lo
converte in RGB565, lo centra sul pannello 480x272 e lo aggiunge dopo le tre
tabelle Terminus. I font non si spostano quando si cambia logo.

## Logo attuale e spazio disponibile

Il logo attuale e' **256x144**, centrato a **(112,64)**. Un bitmap RGB565
grezzo richiederebbe 73.728 byte e, insieme ai font, supererebbe i 77.824 byte
della User Flash. Per questo l'immagine versione 3 usa **RGB565-RLE**: ogni
parola da 32 bit contiene `{ colore RGB565, lunghezza della sequenza }`.
La codifica e' lossless e le sequenze possono attraversare una riga.

Con il PNG corrente, il payload del logo e' 5.444 byte (contro 73.728 non
compressi); l'immagine completa `fonts/user_flash_fonts.bin` e' 30.612 byte e
restano 47.212 byte. Uno sfondo uniforme nero si comprime molto bene. Un logo
fotografico o con rumore puo' invece non entrare: il generatore lo rifiuta
prima di produrre un'immagine programmabile.

## Procedura per sostituire il logo

Questa e' la procedura completa. Per un normale cambio del PNG, i passi 1--4 e
6 sono sufficienti: il formato resta versione 3, quindi non occorre
ricostruire la FPGA. Il passo 5 serve per una modifica del formato o dell'RTL.

### 1. Preparare il PNG

Sostituire `resources/BootLogo.png` con il nuovo file. Deve avere:

- larghezza pari;
- dimensioni entro 480x272;
- preferibilmente sfondo uniforme o aree piatte, per ottenere una buona
  compressione RLE.

La trasparenza e' ammessa: viene composta sul nero. Il logo e' opaco una volta
sul pannello; non esiste una maschera alfa nel fabric.

### 2. Verificare gli strumenti locali

Il solo requisito per rigenerare l'immagine e' Python 3 con Pillow. Il comando
seguente deve terminare con `Pillow OK`:

```powershell
python -c "from PIL import Image; print('Pillow OK')"
```

Il generatore usa inoltre le sorgenti BDF del submodule Terminus, gia' presenti
in `third_party/terminus-font-4.49.1-master`. Se il clone e' nuovo:

```powershell
git submodule update --init --recursive
```

### 3. Rigenerare la User Flash

Dalla radice del repository eseguire esattamente:

```powershell
python .\tools\generate_user_flash_fonts.py `
  .\third_party\terminus-font-4.49.1-master .\fonts `
  --logo .\resources\BootLogo.png
```

Lo script legge il PNG con Pillow e produce tre artefatti coerenti:

| File | Uso |
|---|---|
| `fonts/user_flash_fonts.bin` | immagine binaria da caricare con openFPGALoader |
| `fonts/user_flash_fonts.mem` | copia a parole esadecimali usata dalle simulazioni Verilog |
| `fonts/user_flash_fonts.json` | manifest leggibile: dimensioni, CRC, occupazione e dati RLE |

Controllare il riepilogo stampato: deve riportare dimensione, byte `encoded`,
byte `raw` e spazio libero. Il generatore fallisce esplicitamente se il PNG e'
fuori pannello, ha larghezza dispari oppure l'immagine completa supera la User
Flash. Controllo ulteriore facoltativo:

```powershell
Get-Content .\fonts\user_flash_fonts.json | ConvertFrom-Json |
  Select-Object version, image_bytes, free_bytes, logo
```

Devono comparire `version: 3`, il nuovo `width`/`height` e `format:
RGB565-RLE`.

> Non omettere `--logo`: senza di esso il generatore crea volutamente
> un'immagine valida ma senza sezione logo.

### 4. Verificare RTL e immagine insieme

```powershell
.\sim\run_spi_sim.ps1
```

La suite esegue anche `tb_boot_logo`: decodifica indipendentemente l'RLE del
file `.mem` e verifica ogni pixel scritto, il rettangolo e lo sbarramento fino
a `boot_complete`. Il risultato atteso include `PASS: boot_logo`.

### 5. Quando ricostruire il bitstream FPGA

Un normale rimpiazzo del PNG **non** richiede sintesi: il renderer legge
larghezza, altezza, posizione e formato dalla User Flash. Ricostruire la FPGA
e' necessario se si modificano `src/FontStore.sv`, `src/TextRenderer.sv` o il
formato dell'immagine. L'introduzione dell'RLE e della versione 3 e' proprio un
caso del genere; il bitstream di questo commit va quindi costruito una volta:

```powershell
.\build.ps1
```

Servono Gowin EDA (sintesi/place-and-route) e oss-cad-suite con Icarus Verilog
e openFPGALoader. `build.ps1` termina solo dopo il gate di timing e produce
`impl/pnr/LCD.fs`. I dettagli dell'ambiente sono in [README.md](../README.md)
e [VERIFICATION.md](VERIFICATION.md).

### 6. Programmare la scheda

Per rendere effettivo il nuovo logo in avvio, programmare **insieme** il
bitstream `impl/pnr/LCD.fs` e `fonts/user_flash_fonts.bin`:

```powershell
.\program_tang_nano_flash.ps1
```

Non invocare openFPGALoader o Gowin Programmer manualmente per il solo
bitstream: Embedded Flash e User Flash sono parti dello stesso array e una
scrittura del bitstream senza la User Flash cancella il logo e i font. Lo script
controlla l'header `LCDF` e passa entrambi gli artefatti. Attendere due barre di
avanzamento (bitstream e User Flash), poi togliere/ridare alimentazione o
resettare la scheda.

Su questa macchina il percorso standard e' openFPGALoader; non aggiungere
`-UseGowinProgrammer` salvo una ragione precisa. Per cablaggio, driver e
diagnostica vedere [PROGRAMMING.md](PROGRAMMING.md).

## Formato a bordo

L'header `LCDF` e' ora versione **3**. La parola 6 (offset 24, little endian)
contiene l'offset della sezione logo, oppure zero. La sezione e':

| Offset | Campo |
|---:|---|
| 0..3 | magic `LGO1` |
| 4..5 | larghezza |
| 6..7 | altezza |
| 8..11 | formato: `2` = RGB565-RLE |
| 12..13 | origine x |
| 14..15 | origine y |
| 16.. | parole little endian: run length a 16 bit, poi colore RGB565 a 16 bit |

`FontStore` verifica prima il CRC-32 dell'intera immagine, poi magic,
geometria, formato e posizione del logo. Se il descrittore logo non e' valido,
i font restano utilizzabili ma il logo viene saltato. Se versione dell'immagine
e bitstream non coincidono, invece, l'immagine viene rifiutata interamente:
questo impedisce di interpretare un layout incompatibile.

`TextRenderer` usa lo stesso percorso a burst del riempimento e decodifica un
pixel per ogni colonna del rettangolo. Alza `boot_complete` solo dopo l'ultimo
burst; fino ad allora il lato SPI resta `busy` e non puo' sovrapporre il primo
flush dell'MCU al logo.

## Riferimenti

- [PROGRAMMING.md](PROGRAMMING.md): programmazione persistente e differenza fra
  Embedded Flash e User Flash.
- [VERIFICATION.md](VERIFICATION.md): ambiente di simulazione e gate di timing.
