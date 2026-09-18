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
FPGA. LVGL puo' quindi riusare il buffer senza sovrascrivere dati ancora in
transito.

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
`g_lvgl_flush_failed` e `g_lvgl_flush_pixels`.

## Limiti intenzionali del primo stadio

- nessun touch/input device;
- framebuffer FPGA singolo: nessun `PRESENT`, quindi un aggiornamento puo'
  essere visibile mentre arriva al pannello;
- nessuna qualifica hardware LVGL ancora eseguita: il build dimostra
  integrazione e limiti di memoria, non la resa fisica;
- `COPY` e `PRESENT` saranno introdotti solo nel secondo stadio, con una
  politica di coerenza front/back definita.

Il CMake non scarica dipendenze: richiede la checkout del submodule e fallisce
con istruzioni esplicite se `third_party/lvgl` non e' inizializzato.
