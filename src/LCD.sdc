// Timing constraints for the Tang Nano 9K RGB LCD project.
//
// Two independent rPLLs derive the two clock domains from the same 27 MHz
// crystal, so the analyzer must be told they have no usable phase
// relationship: the framebuffer FIFO is what bridges them.

// -----------------------------------------------------------------------
// Primary clock
// -----------------------------------------------------------------------

// On-board crystal, 27 MHz.
create_clock -name xtal_27 -period 37.037 -waveform {0 18.518} [get_ports {XTAL_IN}]

// -----------------------------------------------------------------------
// PLL-derived clocks
// -----------------------------------------------------------------------

// Gowin_rPLL: 27 MHz * 1 / 3 = 9 MHz pixel clock.
create_clock -name lcd_clk_9 -period 111.111 -waveform {0 55.555} [get_nets {LCD_CLK}]

// Gowin_rPLL_PSRAM: 27 MHz * 6 / 1 = 162 MHz PSRAM memory clock.
create_clock -name mem_clk_162 -period 6.173 -waveform {0 3.086} [get_nets {memory_clk}]

// PSRAM_Memory_Interface_HS_Top divides memory_clk by two to produce the
// 81 MHz user-interface clock that drives FramebufferController.
create_clock -name psram_clk_81 -period 12.346 -waveform {0 6.173} [get_nets {psram_clk}]

// -----------------------------------------------------------------------
// Clock domain crossings
// -----------------------------------------------------------------------

// Three mutually asynchronous groups:
//
//   - lcd_clk_9 and the PSRAM clocks come from two different rPLLs, so they
//     have no usable phase relationship. framebuffer_fifo is the only legal
//     crossing; anything else reported here is a bug, not a path to optimise.
//
//   - xtal_27 feeds the CLKIN of both PLLs and the PSRAM IP's low-speed
//     control clock. Its edges bear no analysable relationship to the PLL
//     outputs, and the IP synchronises the crossing internally.
//
// mem_clk_162 and psram_clk_81 stay in one group on purpose: the second is
// the first divided by two inside the same PLL block, and the PSRAM serdes
// depends on that relationship being analysed.
set_clock_groups -asynchronous -group [get_clocks {lcd_clk_9}] -group [get_clocks {xtal_27}] -group [get_clocks {mem_clk_162 psram_clk_81}]

// -----------------------------------------------------------------------
// Notes
// -----------------------------------------------------------------------
//
// Reset_Button reaches flops only through the per-domain ResetSynchronizer
// instances, gated on both PLL locks. Assertion is asynchronous by design;
// release is retimed onto each domain's own clock, so it shows up in the
// removal table as an intra-domain path with positive slack rather than as an
// unconstrained crossing. No set_false_path is declared because the analyzer
// reports no path that would need one; the constraint would be inert.
//
// The button is still un-debounced. A bounce asserts reset again, which is
// harmless, but it is not a clean single-shot reset.
//
// The LCD output bus is source-synchronous and carries ~111 ns of margin per
// pixel, so no set_output_delay is declared. Add one if the panel's setup and
// hold figures ever become the limiting factor.
//
// Accepted baseline (V1.9.12.01, setup at Slow 1.14V 85C C6/I5, hold at
// Fast 1.26V 0C): this project's own RTL closes timing with positive slack at
// the worst-case corner, and there are no hold violations anywhere.
//
// Seven setup-violated endpoints remain, all of them one register: calib_0
// inside the encrypted Gowin PSRAM IP, fanning out to the CALIB pins of the
// eight IDES4 deserialisers, worst slack -1.823 ns. This is accepted, not
// outstanding work:
//
//   - it is a calibration control pulse, not a data path, and FramebufferController
//     refuses to start until the IP raises init_calib, so a failure to
//     calibrate shows up as a blank display at power-on rather than as silent
//     corruption during operation;
//   - 162 MHz is Gowin's own reference configuration for this IP on this device;
//   - the only remedy is regenerating the IP at a lower MEMORY_CLK, which
//     re-derives the frequency-dependent SHIFT_DELAY sampling window. That is a
//     GUI-only operation and it must not be approximated by editing the PLL
//     alone: the sampling window would stay tuned for 162 MHz.
//
// Any violation outside psram_inst is new and belongs to us.
