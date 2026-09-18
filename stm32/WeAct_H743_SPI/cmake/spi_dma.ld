/* Supplement generated linker script without editing CubeMX-owned sections.
 * Explicitly initialized by self-test after enabling SRAM1 clock. */
SECTIONS
{
  .spi_dma (NOLOAD) : ALIGN(32)
  {
    *(.spi_dma)
    . = ALIGN(32);
  } > RAM_D2

  /* LVGL partial draw buffers are too large for task stacks/DTCM.  SPI DMA
   * never sees them directly: lvgl_port copies each row to .spi_dma. */
  .lvgl_draw (NOLOAD) : ALIGN(32)
  {
    *(.lvgl_draw)
    . = ALIGN(32);
  } > RAM_D2
}
