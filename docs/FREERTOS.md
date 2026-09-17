# FreeRTOS sullo STM32H743

## Migrazione e DMA asincrono

FreeRTOS 10.6.2 e CMSIS-RTOS v2 provengono dallo stesso pacchetto
`STM32Cube_FW_H7_V1.13.0` usato dal progetto. Le API LCD restano bloccanti per
il chiamante, ma l'attesa interna del DMA non gira più in polling: la callback
HAL sveglia direttamente `DisplayTask` con `vTaskNotifyGiveFromISR()` e la task
attende con `ulTaskNotifyTake()`.

`main()` inizializza periferiche e kernel, crea gli oggetti e chiama
`osKernelStart()`. La `defaultTask` è intenzionalmente vuota: aggiorna solo la
propria misura di stack e dorme. `DisplayTask` esegue la sequenza di boot già
esistente (`SPI_Setup`, reset/prova FPGA, autotest e demo abilitate), poi resta
bloccata su `displayQueue`.

La coda contiene `DisplayRequest`, cioè una funzione da eseguire e un puntatore
al suo contesto. `DisplayTask_Post()` copia il descrittore nella coda; non copia
il contesto, che deve quindi restare valido fino all'esecuzione. I wrapper
`SPI_Exchange_DMA`, `SPI_Transmit_DMA` e `SPI_SetBaudRatePrescaler` rifiutano un
chiamante diverso da `DisplayTask`: SPI2 e FPGA hanno un proprietario unico
anche per errore, non soltanto per convenzione.

## Tick HAL e priorità

SysTick appartiene a FreeRTOS. Il tick HAL a 1 ms è generato da TIM6 in
`stm32h7xx_hal_timebase_tim.c`; `HAL_TIM_MODULE_ENABLED` è attivo. Le attese
esplicite nel codice LCD/self-test usano `osDelay()`, quindi cedono la CPU.

EXTI0, SPI2, DMA1 Stream 0 e DMA1 Stream 1 hanno priorità NVIC 5, uguale a
`configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY`. Le callback SPI chiamano ora
l'API FreeRTOS `...FromISR` e richiedono il cambio di contesto quando la task
sbloccata ha priorità sufficiente. PendSV e SysTick sono a 15.

## Trasferimento e pipeline delle righe

`SPI_Exchange_DMA()` e `SPI_Transmit_DMA()` mantengono il contratto bloccante,
ma dormono sulla notifica invece di interrogare `completed` in un ciclo vuoto.
Per lo stream `BE`, `SPI_Transmit_DMA_Begin()` copia il pacchetto nella SRAM D2
privata e avvia il DMA; `SPI_Transmit_DMA_Wait()` attende la notifica. Lo slot di
notifica diretta di `DisplayTask` appartiene quindi al trasporto SPI.

`LCD_WriteRectStream()` usa due `StreamPacket` in DTCM. Dopo il `Begin` della
riga corrente costruisce la successiva nell'altro pacchetto, poi esegue `Wait`
e legge il risultato `BF`. Un retry conserva sia il pacchetto corrente sia il
successivo già pronto. Il DMA non vede mai questi buffer: trasmette soltanto la
copia allineata nella sezione `.spi_dma`.

## Memoria e DMA

L'heap FreeRTOS da 32 KiB, gli stack delle task e gli oggetti dinamici restano
in DTCM. È voluto: il core vi accede direttamente e il DMA non deve accedervi.
I buffer DMA restano statici nella sezione `.spi_dma`, allineati a 32 byte e
collocati in RAM D2; i wrapper copiano i dati e fanno la manutenzione cache.

Invariante: **non passare mai a una HAL DMA il buffer locale di una task, né un
puntatore proveniente dall'heap FreeRTOS**. Se in futuro l'heap viene spostato
nella RAM AXI, i dati condivisi con DMA richiederanno allineamento a cache line
e `SCB_CleanDCache_by_Addr` / `SCB_InvalidateDCache_by_Addr` nei punti corretti.

## Misura degli stack

Gli stack iniziali sono 128 parole per `defaultTask` e 1024 parole (4096 byte)
per `DisplayTask`. Non sono valori definitivi. A runtime vengono aggiornati:

- `g_display_stack_high_water_words` e `g_display_stack_high_water_bytes`;
- `g_default_stack_high_water_words` e `g_default_stack_high_water_bytes`.

`uxTaskGetStackHighWaterMark(NULL)` restituisce il minimo spazio rimasto dalla
creazione della task, espresso in `StackType_t`, quindi in parole da 4 byte su
questo Cortex-M7. La misura della `DisplayTask` viene presa dopo tutto il boot e
dopo ogni richiesta. Va letta via SWD dopo il carico peggiore; lo stack si può
poi ridurre lasciando un margine esplicito. `configCHECK_FOR_STACK_OVERFLOW=2`
e il malloc-failed hook fermano il firmware e impostano `g_freertos_failure`
(4 per overflow, 3 per heap esaurito).

## Qualifica hardware

Qualifica hardware Release superata il 17 settembre 2026 sul prototipo STM32
`35FF6C064D53373238602143`: 1200 trasferimenti, 1.049.760 byte verificati,
zero mismatch, zero errori HAL/LCD, 512 rettangoli e 354.528 pixel nello stress
grafico. La demo doppio buffer più scroll ha completato 50 `PRESENT` con 50
fronti IRQ; COPY schermo intero 14 ms, SCROLL 442x176 8 ms e attesa PRESENT
18 ms. Tre ulteriori reset consecutivi hanno ripetuto 50/50.

Il minimo stack rimasto nella qualifica asincrona è 855 parole, cioè 3420 byte,
per `DisplayTask`, e 91 parole, cioè 364 byte, per `defaultTask`.
`g_freertos_failure` è rimasto a zero. Durante la qualifica è emersa una corsa
nel percorso di conferma: il polling poteva vedere `FPGA_IRQ_N` basso e inviare
l'ACK prima che la callback EXTI avesse contato il fronte. `LCD_Present()` ora
pretende anche l'avanzamento di `g_fpga_irq_count` prima dell'ACK.

Qualifica finale del flush asincrono: 42.462 notifiche per 42.462 attese, zero timeout
e 238 righe costruite fra `Begin` e `Wait`. Il benchmark a otto righe per strip
misura 528 ms per `B7` e 172-174 ms per `BE/BF`; la precedente implementazione
sincrona `BE/BF` misurava 225 ms. Stress, 50 PRESENT/50 IRQ e reset ripetuto
restano PASS.
