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
// Reset_Button is an asynchronous, un-debounced input that feeds the async
// reset of flops in both domains. It is deliberately NOT declared a false
// path here: that assertion only becomes true once per-domain reset
// synchronisers are in place.
//
// The LCD output bus is source-synchronous and carries ~111 ns of margin per
// pixel, so no set_output_delay is declared. Add one if the panel's setup and
// hold figures ever become the limiting factor.
//
// Known baseline with these constraints (V1.9.12.01, Slow 1.14V 85C C6/I5):
// 7 setup-violated endpoints, all of them the single calib_0 register inside
// the encrypted Gowin PSRAM IP fanning out to the CALIB pins of the eight
// IDES4 deserializers, worst slack -1.823 ns. That path is not in this
// project's RTL and cannot be fixed from here; lowering MEMORY_CLK is the
// available remedy, and there is ample bandwidth headroom to do so.
// Any violation outside psram_inst is new and belongs to us.
