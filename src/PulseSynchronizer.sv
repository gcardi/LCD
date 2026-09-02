// Carries a single-cycle pulse from one clock domain to another.
//
// The pulse is turned into a level change in the source domain, and the
// receiver recovers it by detecting that change after two synchronising
// flops. Sampling a level this way works in either frequency direction,
// unlike synchronising the pulse itself, which a faster source could push
// through in less than one destination clock period.
//
// Valid as long as consecutive source pulses are more than about three
// destination clocks apart. Here they are one frame apart.
module PulseSynchronizer
(
    input  logic src_clk,
    input  logic src_rst_n,
    input  logic src_pulse,

    input  logic dst_clk,
    input  logic dst_rst_n,
    output logic dst_pulse
);

    logic toggle;

    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            toggle <= 1'b0;
        else if (src_pulse)
            toggle <= ~toggle;
    end

    (* syn_preserve = 1 *) logic [2:0] sync;

    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n)
            sync <= 3'b000;
        else
            sync <= {sync[1:0], toggle};
    end

    // The two domains leave reset independently, so the toggle and the
    // synchroniser can disagree by one edge across a reset. That yields at
    // most one spurious or missing pulse, which costs a single frame.
    assign dst_pulse = sync[2] ^ sync[1];

endmodule
