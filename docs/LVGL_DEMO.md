# Demo LVGL 9 sullo STM32H743

Il firmware include LVGL `v9.6.0` come submodule in `third_party/lvgl` e un
primo display port RGB565 per il framebuffer nella PSRAM della Tang Nano.
LVGL resta interamente sullo STM32; la FPGA riceve rettangoli di pixel tramite
il protocollo streaming `BE/BF` gia' esistente.

## Architettura

`GuiTask` e' il solo contesto che crea widget ed esegue
`lv_timer_handler()` ogni 5 ms. La callback LVGL di flush non usa SPI: copia
coordinate e puntatore del draw buffer in una richiesta persistente e la posta
a `DisplayTask`. Quest'ultima resta l'unica proprietaria di SPI2, esegue
`LCD_WriteRectStream()` e chiama `lv_display_flush_ready()` solo dopo il fence
FPGA. All'ultimo flush del frame esegue inoltre `PRESENT`, attende l'IRQ di
vertical blanking e copia il nuovo front buffer nel nuovo draw buffer con
`COPY`. LVGL puo' quindi riusare il buffer senza sovrascrivere dati ancora in
transito, e il prossimo aggiornamento parziale parte da un'immagine coerente.

I due draw buffer sono 480 x 20 pixel RGB565 (19.200 byte ciascuno) nella
sezione `.lvgl_draw` in RAM D2. Non sono nello stack, nell'heap FreeRTOS o in
DTCM. LVGL usa un pool statico indipendente da 32 KiB; la `GuiTask` ha stack di
8 KiB e priorita' sotto `DisplayTask`.

## Demo

All'avvio, dopo l'autotest SPI/FPGA, viene mostrata una schermata con titolo,
descrizione del trasporto e barra di avanzamento aggiornata ogni 100 ms. Le
demo grafiche di boot esistenti sono disabilitate in `spi_diag_config.h` perche'
non devono disegnare contemporaneamente a LVGL.

Per compilare e caricare il firmware:

```powershell
cd stm32\WeAct_H743_SPI
.\build.ps1 -Preset Debug -Program -SerialNumber <seriale-ST-LINK>
```

Via SWD si possono osservare `g_lvgl_demo_state` (2 = UI creata),
`g_lvgl_port_state` (2 = display LVGL pronto), `g_lvgl_flush_count`,
`g_lvgl_flush_failed`, `g_lvgl_flush_pixels`, `g_lvgl_present_count`,
`g_lvgl_present_failed`, `g_lvgl_frame_count` e `g_lvgl_frame_ms`.

## Limiti intenzionali del primo stadio

- nessun touch/input device;
- la COPY e' volutamente full-screen: e' la politica piu' semplice e robusta
  per i flush parziali, ma aggiunge il suo tempo a ogni frame; una futura
  ottimizzazione potra' copiare solo le aree danneggiate quando la semantica
  LVGL sara' misurata con il touch reale;
- la qualifica visiva del tearing richiede il pannello e un'animazione rapida.

Il CMake non scarica dipendenze: richiede la checkout del submodule e fallisce
con istruzioni esplicite se `third_party/lvgl` non e' inizializzato.
