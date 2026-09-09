# SPI slave per STM32

`src/SpiSlave.sv` implementa SPI mode 0 (CPOL=0, CPHA=0), full duplex,
8 bit, MSB first e CS attivo basso. Il modulo e' indipendente dal framebuffer
ed e' usato da SpiFramebuffer per la grafica e da SpiDiagnostic per le prove
separate. Il collegamento grafico passa il primo collaudo a 25 MHz MEDIUM;
vedere [SPI_FRAMEBUFFER.md](SPI_FRAMEBUFFER.md) per risultati e limiti.
Trasporta soltanto byte: non interpreta comandi, dati o flag del protocollo.
Non richiede un pin D/C; un eventuale flag comando/dato sara' codificato nei
byte dal protocollo superiore.

## Interfaccia parallela

Tutti i segnali paralleli appartengono al dominio `spi_sck`.

| Segnale | Contratto |
|---|---|
| `rx_push` | Write-enable combinazionale da campionare sul fronte di salita SCK dell'ottavo bit |
| `rx_data[7:0]` | Byte completo valido sullo stesso fronte di `rx_push` |
| `tx_data[7:0]` | Testa di una sorgente show-ahead, ad esempio FIFO asincrona |
| `tx_valid` | La sorgente dispone di un byte |
| `tx_take` | Read-enable combinazionale: consuma il byte sul primo fronte di salita SCK |
| `spi_miso` | Valore da portare sul pin MISO |
| `spi_miso_oe` | Abilitazione del driver MISO; bassa durante reset o CS alto |

Esempio concettuale del lato ricezione:

```systemverilog
always @(posedge spi_sck) begin
    if (rx_push) begin
        // Scrittura nella FIFO: dato a 8 bit rx_data.
        // La vera FIFO deve gestire anche puntatori e full.
    end
end
```

`rx_push` NON e' una notifica registrata da leggere nel clock PSRAM o al
successivo fronte SCK. Usarlo come write-enable della FIFO sullo stesso fronte
salva anche l'ultimo byte quando il master smette subito di generare clock.
Fuori dal fronte qualificato, `rx_data` non costituisce un risultato persistente.

La sorgente TX deve presentare il primo byte prima di abbassare CS e mantenerlo
fino a `tx_take`. Per i byte successivi, dato e valid devono essere stabili
dal fronte di discesa che chiude il byte precedente fino al primo fronte di
salita del nuovo byte. Non cambiare disponibilita' o dato durante questa finestra.
Dopo `tx_take` la sorgente puo' avanzare: il byte corrente e' conservato internamente.
Se `tx_valid=0`, viene trasmesso `IDLE_BYTE` (default FF) senza consumo.
Una transazione interrotta dopo il primo bit ha gia' consumato il byte TX:
non esiste rollback. Una risposta a un comando ricevuto richiede byte dummy
o una transazione successiva e una regola di disponibilita' ancora da definire.

## Primo byte fisso e uscita MISO

Il default `FIXED_FIRST_BYTE=0` conserva il contratto show-ahead generico.
Con `FIXED_FIRST_BYTE=1`, il primo byte di ogni transazione deve essere noto
prima della sintesi e corrispondere a `FIRST_BYTE` (default A5). Il wrapper
deve presentarlo anche su tx_data con tx_valid=1 al primo tx_take.
Il registro TX viene inizializzato a FIRST_BYTE e MISO e' direttamente il suo
bit 7: il selettore tx_started e la maschera active sul dato vengono eliminati
in sintesi. La disabilitazione del pin resta garantita da spi_miso_oe nel TOP.
A slave deselezionato il valore interno spi_miso non e' significativo.

SpiFramebuffer abilita questa opzione, dato che inizia sempre con A5.
SpiDiagnostic conserva il default generico e la qualifica precedente a 12.5 MHz.
Non usare il parametro per una FIFO il cui primo byte puo' variare.

## Slave Select e risincronizzazione

`spi_cs_n` e' lo Slave Select (SS, detto anche CS; NSS nello STM32).
Il suffisso `_n` indica che e' attivo basso:

- SS basso: scambio dei byte, anche consecutivi nella stessa transazione.
- SS alto: disabilita MISO e azzera il conteggio dei bit senza richiedere clock.
- Alla selezione successiva il primo fronte di salita acquisisce il bit 7
  di un nuovo byte. Un byte RX parziale viene scartato.

Il master puo' quindi riallineare la SPI portando SS alto, riportando SCK basso
prima della nuova selezione e iniziando una nuova transazione. Questo recupera
il conteggio dei bit, ma non rileva errori e non annulla byte completi gia'
consegnati. L'eventuale recupero del parser richiede regole nel protocollo:
la sola coda di byte non conserva i confini delle transazioni SS.

## Clock, reset e integrazione

- MOSI viene acquisito sui fronti di salita; MISO viene aggiornato sui fronti
  di discesa. Il primo MSB e' disponibile prima del primo clock.
- CS alto azzera asincronamente lo stato del serializzatore, scartando byte RX
  incompleti. Il reset globale `rst_n` e' attivo basso.
- SCK deve essere basso alla selezione. Rispettare setup/hold e recovery/removal
  fra rilascio reset/CS e primo clock; rilasciare il reset con CS alto.
- Non azzerare la futura FIFO ad ogni CS: i byte completi devono restare in coda.
- Per MISO ad alta impedenza usare al livello TOP:

```systemverilog
assign SPI_MISO = spi_miso_oe ? spi_miso : 1'bz;
```

- Aggiungere FIFO asincrone per attraversare il dominio SCK/PSRAM. Non collegare
  direttamente `rx_push`, `tx_take` o bus dati a logica con un altro clock.
- Il modulo non include READY, overflow o backpressure. Il livello superiore
  dovra' garantire spazio RX per il blocco autorizzato e segnalare errori.
- Le FIFO TX sincronizzate con SCK possono richiedere clock per aggiornare empty
  dopo una scrittura dall'altro dominio. Definire un handshake/precaricamento
  prima di attendersi una risposta: non presumere disponibilita' a SCK fermo.
- In integrazione aggiungere pin, clock SCK e vincoli di input/output delay,
  verificando anche i percorsi fra fronti opposti (mezzo periodo).

CubeMX: SPI master full duplex, 8 bit, MSB first, CPOL Low, CPHA 1 Edge,
NSS Software, NSS pulse e CRC disabilitati. CS e' un GPIO; non serve D/C. Partire da
1 MHz; la frequenza massima non e' ancora qualificata con place-and-route
o misure hardware. Le frequenze del testbench non sono una certificazione timing.

## Verifica

```powershell
.\sim\run_spi_sim.ps1
```

Il testbench controlla full duplex, primo MSB, avanzamento della sorgente TX,
byte consecutivi e pause con CS basso, idle TX, attivita' a CS alto,
abort dopo 1..7 bit, ultimo byte senza clock aggiuntivi, reset a meta' byte e
256 coppie di byte pseudocasuali con periodi SCK variabili. Timeout e mismatch
producono un errore; il runner richiede il marcatore PASS. Log in `sim/build`.
