// Dual-clock FIFO for the framebuffer stream.
//
// Port-compatible with the generated Gowin framebuffer_fifo it replaces, so
// TOP does not change. Two things differ inside, and both are the reason it
// exists:
//
//   - Almost_Full is pipelined. The vendor FIFO converts the synchronised read
//     pointer from Gray to binary, subtracts and compares, all combinationally
//     into the flag's flop; that chain was the critical path of the whole
//     psram_clk domain. Here the conversion and the comparison sit in separate
//     cycles.
//   - The threshold is lowered to absorb the staleness that buys. Every source
//     of lag makes the flag read fuller than reality, never emptier, so the
//     error is always on the safe side.
module FramebufferFifo
#(
    parameter int unsigned WIDTH        = 32,
    parameter int unsigned ADDR_BITS    = 9,    // 512 words
    parameter int unsigned ALMOST_EMPTY = 240,
    // 504 in the vendor part. Four cycles of pointer lag plus one more write
    // plus an eight-word burst still lands well inside 512.
    parameter int unsigned ALMOST_FULL  = 496
)
(
    input  logic             Reset,             // active high, asynchronous
    input  logic [WIDTH-1:0] Data,
    input  logic             WrClk,
    input  logic             WrEn,
    input  logic             RdClk,
    input  logic             RdEn,
    output logic [WIDTH-1:0] Q,
    output logic             Empty,
    output logic             Full,
    output logic             Almost_Empty,
    output logic             Almost_Full
);

    localparam int unsigned DEPTH = 1 << ADDR_BITS;

    function automatic logic [ADDR_BITS:0] bin2gray(input logic [ADDR_BITS:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic logic [ADDR_BITS:0] gray2bin(input logic [ADDR_BITS:0] g);
        logic [ADDR_BITS:0] b;
        b[ADDR_BITS] = g[ADDR_BITS];
        for (int i = ADDR_BITS - 1; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Reset is retimed into each domain by the same synchroniser the rest of
    // the design uses, so the two sides leave reset cleanly on their own edges.
    logic wrst_n, rrst_n;

    ResetSynchronizer write_reset_sync (
        .clk(WrClk), .async_rst_n(~Reset), .sync_rst_n(wrst_n));

    ResetSynchronizer read_reset_sync (
        .clk(RdClk), .async_rst_n(~Reset), .sync_rst_n(rrst_n));

    logic [ADDR_BITS:0] wbin, wgray, rbin, rgray;
    logic [ADDR_BITS:0] rgray_w1, rgray_w2;    // read pointer seen by the writer
    logic [ADDR_BITS:0] wgray_r1, wgray_r2;    // write pointer seen by the reader

    // ------------------------------------------------------------------
    // Storage. No reset on either port, so this infers block RAM.
    // ------------------------------------------------------------------
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    wire write_now = WrEn && !Full;
    wire read_now  = RdEn && !Empty;

    always_ff @(posedge WrClk)
        if (write_now) mem[wbin[ADDR_BITS-1:0]] <= Data;

    // First-word fall-through without a bubble: the address presented is the
    // pointer the consumer will have *after* this edge, so the one-cycle RAM
    // latency lands exactly when the new word is due.
    wire [ADDR_BITS-1:0] ram_raddr = rbin[ADDR_BITS-1:0] + (read_now ? 1'b1 : 1'b0);

    always_ff @(posedge RdClk)
        Q <= mem[ram_raddr];

    // ------------------------------------------------------------------
    // Write domain
    // ------------------------------------------------------------------
    always_ff @(posedge WrClk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= '0;
            wgray <= '0;
        end else if (write_now) begin
            wbin  <= wbin + 1'b1;
            wgray <= bin2gray(wbin + 1'b1);
        end
    end

    always_ff @(posedge WrClk or negedge wrst_n) begin
        if (!wrst_n) {rgray_w2, rgray_w1} <= '0;
        else         {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
    end

    // Full: the pointers meet with the two top Gray bits inverted.
    assign Full = (wgray == {~rgray_w2[ADDR_BITS:ADDR_BITS-1],
                              rgray_w2[ADDR_BITS-2:0]});

    // The pipelined almost-full. Stage one undoes the Gray coding, stage two
    // does the subtract and the compare.
    logic [ADDR_BITS:0] rbin_w;

    always_ff @(posedge WrClk or negedge wrst_n) begin
        if (!wrst_n) begin
            rbin_w      <= '0;
            Almost_Full <= 1'b0;
        end else begin
            rbin_w      <= gray2bin(rgray_w2);
            Almost_Full <= ((wbin - rbin_w) >= ALMOST_FULL[ADDR_BITS:0]);
        end
    end

    // ------------------------------------------------------------------
    // Read domain
    // ------------------------------------------------------------------
    always_ff @(posedge RdClk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= '0;
            rgray <= '0;
        end else if (read_now) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end

    always_ff @(posedge RdClk or negedge rrst_n) begin
        if (!rrst_n) {wgray_r2, wgray_r1} <= '0;
        else         {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
    end

    assign Empty = (rgray == wgray_r2);

    logic [ADDR_BITS:0] wbin_r;

    always_ff @(posedge RdClk or negedge rrst_n) begin
        if (!rrst_n) begin
            wbin_r       <= '0;
            Almost_Empty <= 1'b1;
        end else begin
            wbin_r       <= gray2bin(wgray_r2);
            Almost_Empty <= ((wbin_r - rbin) <= ALMOST_EMPTY[ADDR_BITS:0]);
        end
    end

endmodule
