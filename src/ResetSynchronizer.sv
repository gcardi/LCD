// Asynchronous-assert, synchronous-release reset synchroniser.
//
// Assertion is asynchronous so that logic stops the instant the reset source
// falls, even if its clock is absent or unstable. Release is retimed onto clk,
// so every flop in the domain leaves reset on the same edge instead of each
// resolving the metastability of an unrelated signal on its own.
module ResetSynchronizer
#(
    // Two stages resolve metastability; the third is margin. It also keeps
    // this domain's release strictly behind framebuffer_fifo, whose generated
    // reset synchronisers are two stages deep.
    parameter int unsigned STAGES = 3
)
(
    input  logic clk,
    input  logic async_rst_n,
    output logic sync_rst_n
);

    // Keep the chain intact: it exists to burn clock edges, so an optimiser
    // that collapses it would remove the entire point of the module.
    (* syn_preserve = 1 *) logic [STAGES-1:0] stage;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            stage <= '0;
        else
            stage <= {stage[STAGES-2:0], 1'b1};
    end

    assign sync_rst_n = stage[STAGES-1];

endmodule
