# Bring-up touch capacitivo

Il connettore touch a sei contatti usa logica a 3,3 V:

| Flat | STM32 / prototipo |
| --- | --- |
| `CTP-RST` | pull-up a 3,3 V durante il primo bring-up; un GPIO dedicato in seguito |
| `CTP-VCC` | 3,3 V |
| `CTP-GND` | GND |
| `CTP-INT` | non collegato nel primo test; futuro GPIO EXTI dedicato |
| `CTP-SDA` | `PB9`, I2C1 SDA |
| `CTP-SCL` | `PB8`, I2C1 SCL |

`I2C1` e' inizializzato a 400 kHz. Il task di servizio esegue una sola
scansione degli indirizzi I2C 7-bit da `0x08` a `0x77`, senza inviare comandi
specifici del controller. I risultati SWD sono:

- `g_touch_probe_state`: `2` quando la scansione e' conclusa;
- `g_touch_probe_found`: numero di indirizzi che hanno ACK;
- `g_touch_probe_addresses[4]`: bitmap degli indirizzi che hanno ACK;
- `g_touch_probe_bus_error`: ultimo errore di timeout/bus, `0` se assente.
- `g_touch_probe_product_id`: quattro byte ASCII letti dal registro Goodix
  read-only `0x8140` quando risponde l'indirizzo tipico `0x5D`.

Il primo indirizzo trovato identifica la famiglia di controller da cui
derivera' il driver LVGL. Non collegare `CTP-RST` alla linea di reset FPGA:
il touch deve poter essere resettato in modo indipendente.

## Driver LVGL GT911

Il Product ID rilevato e' `911`, all'indirizzo `0x5D`: il firmware registra un
input device LVGL di tipo pointer in polling ogni 10 ms. Legge lo status da
`0x814E`, il primo punto da `0x8150` e conferma ogni frame al GT911 scrivendo
zero nello status. Le coordinate native vengono scalate automaticamente alla
risoluzione del display 480 x 272; i dati SWD `g_gt911_sensor_width` e
`g_gt911_sensor_height` permettono di verificare o correggere in seguito
l'orientamento fisico.
