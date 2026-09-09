#ifndef SPI_SELFTEST_H
#define SPI_SELFTEST_H
#include <stdint.h>
// Inspect g_spi_test in debugger. State: 1 running, 2 pass, 3 fail.
typedef struct {
    uint32_t magic, version, state, transfers, checked_bytes, mismatches;
    uint32_t first_bad_index, expected, actual, hal_error, elapsed_ms, sck_hz;
} SpiTestResult;
extern volatile SpiTestResult g_spi_test;
void SPI_SelfTest_Run(void);
#endif
