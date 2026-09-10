#ifndef SPI_SELFTEST_H
#define SPI_SELFTEST_H
#include <stdint.h>
// Inspect g_spi_test in debugger. State: 1 running, 2 pass, 3 fail.
typedef struct {
    uint32_t magic, version, state, transfers, checked_bytes, mismatches;
    uint32_t first_bad_index, expected, actual, hal_error, elapsed_ms, sck_hz;
    // Appended, so the leading 48 bytes keep their layout for older readers.
    uint32_t ready_ms, ready_attempts;
} SpiTestResult;
extern volatile SpiTestResult g_spi_test;
int SPI_Exchange_DMA(const uint8_t *send, uint8_t *receive, uint16_t length);
// Bring the link up: deselect, pulse SCK, and wait for the FPGA to answer.
// Always call this before any other transfer. The wait is adaptive, so it costs
// a few milliseconds when the FPGA is already configured and gives up after
// SPI_SETUP_TIMEOUT_MS when it never answers. Returns 1 when the FPGA replied.
#define SPI_SETUP_TIMEOUT_MS 2000u
int SPI_Setup(void);
void SPI_SelfTest_Run(void);
#endif
