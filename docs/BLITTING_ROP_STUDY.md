# Studio: copie, scroll, framebuffer multipli e ROP

10 settembre 2026. **Solo valutazione: nessuna delle estensioni di questo
documento è implementata, nessun opcode nuovo è assegnato.** La memoria
attuale è PSRAM integrata, non un controller SDRAM esterno. Le considerazioni
derivano dai sorgenti locali `FramebufferController.sv`, `TOP.sv`,
`SpiFramebuffer.sv` e `TextRenderer.sv`; i costi sono stime, non benchmark.

## Punto di partenza

Un framebuffer RGB565 480×272 occupa 261120 byte (255 KiB). Due occupano
522240 byte, tre 783360 byte. Occorre comunque verificare capacità fisica,
spazio indirizzabile dell'IP e aree riservate prima di scegliere il numero.
Un passo fra buffer di 130560 pixel conserva l'allineamento a 16 pixel.
Oggi scan-out e disegno usano un unico framebuffer con origine zero.

Il controller privilegia il video e accetta aggiornamenti quando la FIFO è
quasi piena. Ogni `rd_data_valid` viene attualmente inoltrato alla FIFO video:
aggiungere letture per copie o ROP richiede distinguere la destinazione di
ciascuna transazione. Non basta aggiungere un opcode al parser.

Le linee H/V ora sono rettangoli B9 spessi un pixel. B7 scrive pixel, B8
genera testo, B9 genera colore uniforme; tutti arrivano al controller come
burst mascherati di 16 pixel. Questo è il punto comune candidato per le ROP.

## Copiare soltanto fra buffer distinti

È una prima versione sensata: buffer fisicamente disgiunti eliminano la
dipendenza fra direzione di lettura e scrittura delle aree sovrapposte.
Si può avanzare per righe, dall'alto verso il basso, senza una semantica
equivalente a `memmove`. Due identificativi diversi devono però riferirsi
davvero ad aree fisiche disgiunte; conviene usare una tabella interna di buffer
con dimensioni fisse invece di esporre indirizzi arbitrari.

Restano necessari:

- identificativi sorgente/destinazione, coordinate, dimensioni e validazione
  completa prima di iniziare; proporrei inizialmente errore sulle aree fuori
  campo, senza clipping implicito;
- letture sorgente indirizzate a un piccolo buffer locale, poi scritture
  destinazione, arbitrate con lo scan-out;
- riallineamento e maschere: x sorgente e x destinazione possono avere offset
  diversi modulo 16. Un gruppo destinazione può richiedere due burst sorgente;
  32 pixel di staging sono una possibile base, non una stima finale di risorse;
- ordinamento fra copia e altre primitive: la sorgente deve restare stabile
  e la destinazione non deve ricevere scritture concorrenti;
- segnalazione distinta di comando accettato e operazione completata.

Per una prima realizzazione limiterei la destinazione a un buffer non
visualizzato. La lettura dal front buffer resta possibile: è già stabile
perché l'applicazione non deve disegnarci durante la scansione.

## Double buffering e scrolling

Il cambio di buffer è uno scambio di indirizzi base: **non richiede una copia**.
Servono una base per lo scan-out, un target per il disegno e un comando di
presentazione. B7/B8/B9 devono usare il target catturato all'accettazione del
comando; cambiare un registro globale a metà rendering sarebbe scorretto.
Per mantenere compatibilità, il target iniziale può restare buffer 0.

La presentazione deve attendere tutte le scritture, poi cambiare base al
confine di frame. Il `frame_restart` esistente è un possibile punto di
aggancio: occorre drenare letture precedenti, svuotare la FIFO e ripartire
dalla nuova base senza introdurre un frame vuoto o mescolare due buffer.
Il master deve ricevere conferma dello scambio prima di riutilizzare il vecchio
front buffer. Un semplice `C3` di coda libera non è questo contratto.

Esempio: scroll verso l'alto di 16 righe su tutta l'area.

1. Copiare front `(0,16,480,256)` in back `(0,0)`.
2. Riempire o ridisegnare le ultime 16 righe nel back.
3. Presentare il back al prossimo confine di frame; il vecchio front diventa back.

Per uno scroll limitato a un riquadro vanno preservati anche i pixel esterni:
il back deve essere una copia coerente del front, oppure quelle aree devono
essere aggiornate esplicitamente. Alternare due buffer con soli aggiornamenti
parziali lascia altrimenti visibili contenuti di due frame prima. Copiare
sempre tutto il front nel back è semplice ma può annullare il risparmio di banda.
Tre buffer possono ridurre alcune attese fra produttore e display, ma non
eliminano né la coerenza dei contenuti né il costo delle copie.

Nel singolo framebuffer lo scroll in-place resta escluso dalla prima versione:
richiederebbe percorso inverso per certe sovrapposizioni o staging aggiuntivo.

## Traffico minimo, prima delle latenze e dello scan-out

Per N pixel, trascurando padding e burst parziali:

| Operazione | Traffico PSRAM minimo |
|---|---:|
| Scrittura/fill COPY | 2N byte |
| Copia da un altro buffer | 4N byte: lettura sorgente + scrittura destinazione |
| XOR con colore o pixel appena generati | 4N byte: lettura destinazione + scrittura |
| Blit XOR sorgente/destinazione in memoria | 6N byte: due letture + scrittura |

Copiare un frame intero muove almeno 522240 byte. A 30 copie/s sono
15.67 MB/s aggiuntivi; a 60 sono 31.33 MB/s, oltre al video e alle altre
primitive. Non sono prestazioni promesse: burst, recuperi, allineamento e
priorità della FIFO incidono sulla banda effettiva. Per lo scroll dell'esempio,
la sola copia muove 491520 byte, a cui si aggiunge il disegno delle righe nuove.

Il vantaggio è evitare che i pixel attraversino SPI: a 12.5 Mbit/s un frame
richiede idealmente 167.1 ms sul filo, prima dell'overhead B7. Il vantaggio
reale del blitter va misurato sul controller integrato, non dedotto dal solo
clock della PSRAM. Riempimenti e testo già accelerati possono rendere più
economico ridisegnare contenuti semplici invece di copiarli.

## ROP: partire da poche operazioni binarie

Definire S come pixel sorgente generato da B7/B8/B9 e D come pixel già presente
nella destinazione. Applicare la funzione ai 16 bit RGB565, senza conversione:

| ROP candidata | Risultato | Lettura D necessaria |
|---|---|---|
| COPY (attuale) | S | no |
| XOR | S XOR D | sì |
| AND | S AND D | sì |
| OR | S OR D | sì |
| INVERT | NOT D, su 16 bit | sì |

XOR/AND/OR non sono alpha blending né compositing a colori: modificano i bit
dei canali. XOR con `FFFF` inverte i bit del pixel. Disegnare due volte la
stessa figura XOR ripristina D **solo se nessun'altra scrittura interviene**.
Per cursori temporanei o selezioni può essere utile; per una UI con redraw
asincroni e buffer alternati spesso è più robusto ridisegnare lo sfondo.

Proporrei un campo ROP catturato per comando, con COPY come default, invece
di uno stato globale persistente. Non riutilizzare in silenzio i flags di B8
(trasparenza/wrap) o quelli riservati B9: servono versione/capacità negoziabili
e un'estensione del formato con CRC. Per B7, oggi privo di CRC preventivo,
preferire un formato nuovo protetto prima di ammettere operazioni non idempotenti.

Nel controller: per COPY conservare il percorso attuale senza letture; per
le altre ROP leggere D, combinare con S e scrivere con la maschera originale.
I pixel mascherati devono restare invariati. Nel testo trasparente la maschera
esclude lo sfondo: la ROP si applica solo ai pixel effettivamente disegnati.
L'arbitro deve impedire scritture concorrenti fra lettura D e relativo commit;
può continuare a servire letture video secondo una pianificazione verificata.

Le porte XOR sono la parte economica: il costo principale è lo staging dei
burst, la lettura aggiuntiva, il controllo e la verifica del timing. Un sistema
ROP ternario con sorgente/destinazione/pattern allargherebbe molto lo scopo;
non emerge ancora un caso d'uso che lo giustifichi.

**Retry:** dopo una risposta persa un XOR accettato non va reinviato alla
cieca, altrimenti annulla il primo disegno. Occorrono ID di comando e stato di
completamento/deduplicazione, oppure un contratto che vieti il retry ambiguo
e richieda il ridisegno da uno stato noto. Il CRC da solo non risolve il problema.

## Raccomandazione e prove prima di procedere

Conviene valutare un blitter COPY tra buffer distinti se lo scroll di immagini
o aree complesse diventa frequente. Non è necessario per il semplice page flip.
Prima implementerei identificazione/capacità, target di disegno e presentazione
con conferma; poi misurerei se il costo di ricostruire il back giustifica COPY.
Le ROP possono riusare il futuro percorso di lettura della destinazione, ma
le terrei opzionali e successive: oggi B9 e testo coprono già molti casi UI.

Prima di qualsiasi implementazione: stimare risorse da sintesi del prototipo e
misurare banda/latency con scan-out attivo. Per la qualifica futura servono
scoreboard PSRAM con copie allineate/disallineate, bordi, sorgente immutata,
buffer distinti, XOR doppio, pixel mascherati e retry; poi prove di presentazione
durante operazioni pendenti, stress FIFO/underrun, timing e verifica al banco.
Queste prove non sono state eseguite: descrivono i criteri della futura estensione.
