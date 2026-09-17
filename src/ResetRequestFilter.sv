// Turns the two reset sources into one clean, filtered reset request.
//
//   button_n  on-board key on IO4 (S2 on the Sipeed schematic), bank 3 at 1.8 V,
//             with its own 10 k / 100 nF RC but still able to bounce;
//   mcu_n     FPGA_RST_N from the STM32 on IO29, bank 2 at 3.3 V, open drain
//             with an external pull-up, so the MCU can reset the fabric.
//
// Either line held low for HOLD_CYCLES of the crystal clock asserts the request.
// Anything shorter is ignored: a line that resets the whole fabric must not
// react to a glitch picked up on a flying wire, and the same rule debounces the
// button, whose release bounces are too short to assert it again.
//
// The request is released on the first sample with both lines high, so the
// reset lasts as long as the source holds it plus the filter delay. Release is
// then retimed per domain by the existing ResetSynchronizer instances.
//
// No reset input on purpose, since this module generates the reset. Every
// register powers up at zero, which is a valid state: the synchronisers briefly
// read "low", but that is two cycles out of HOLD_CYCLES, and hold stays clear,
// so power-up behaves exactly as before this filter existed.
module ResetRequestFilter #(
    // 27 MHz crystal: 27000 cycles is 1 ms. The MCU pulse is 10 ms.
    parameter int unsigned HOLD_CYCLES = 27000
) (
    input  wire clk,
    input  wire button_n,
    input  wire mcu_n,
    output wire reset_request_n
);
    localparam int unsigned COUNT_WIDTH = $clog2(HOLD_CYCLES + 1);
    localparam [COUNT_WIDTH-1:0] HOLD_COUNT = HOLD_CYCLES;

    (* async_reg = "true" *) reg [1:0] button_sync = 2'b00;
    (* async_reg = "true" *) reg [1:0] mcu_sync = 2'b00;
    reg [COUNT_WIDTH-1:0] low_count = '0;
    reg hold = 1'b0;

    always @(posedge clk) begin
        button_sync <= {button_sync[0], button_n};
        mcu_sync    <= {mcu_sync[0], mcu_n};
        if (button_sync[1] && mcu_sync[1]) begin
            low_count <= '0;
            hold      <= 1'b0;
        end else if (low_count != HOLD_COUNT) begin
            low_count <= low_count + 1'b1;
        end else begin
            hold <= 1'b1;
        end
    end

    assign reset_request_n = !hold;
endmodule
