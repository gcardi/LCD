/* Supplement generated linker script without editing CubeMX-owned sections.
 * Explicitly initialized by self-test after enabling SRAM1 clock. */
SECTIONS
{
  .spi_dma (NOLOAD) : ALIGN(32)
  {
    *(.spi_dma)
    . = ALIGN(32);
  } > RAM_D2
}
