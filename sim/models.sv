`timescale 1ns/1ps

// Behavioural stand-in for PSRAM_Memory_Interface_HS_Top.
//
// It deliberately ignores what the controller writes and answers every read
// with data derived from the address: word i of a burst based at A carries
// pixels A+2i and A+2i+1. Colour bars cannot reveal a misalignment, which is
// exactly why the original bug stayed invisible; an address-derived ramp makes
// any shift a hard mismatch.
module psram_model
(
    input               clk,
    input               rst_n,
    input        [20:0] addr,
    input               cmd,
    input               cmd_en,
    output logic [31:0] rd_data,
    output logic        rd_data_valid,
    output logic        init_calib,
    input               starve          // fault injection: withhold read data
);
    localparam int LATENCY = 6;

    integer      calib_cnt;
    logic [20:0] base;
    integer      beat, lat;
    logic        busy;
    logic [20:0] pix0, pix1;

    assign pix0 = base + beat*2;
    assign pix1 = base + beat*2 + 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calib_cnt  <= 0;
            init_calib <= 1'b0;
        end else if (calib_cnt < 100) begin
            calib_cnt <= calib_cnt + 1;
        end else begin
            init_calib <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; beat <= 0; lat <= 0; rd_data_valid <= 1'b0;
        end else begin
            rd_data_valid <= 1'b0;
            if (!busy) begin
                if (cmd_en && !cmd) begin
                    busy <= 1'b1; base <= addr; lat <= LATENCY; beat <= 0;
                end
            end else if (lat != 0) begin
                lat <= lat - 1;
            end else if (!starve) begin
                rd_data       <= {pix1[15:0], pix0[15:0]};
                rd_data_valid <= 1'b1;
                if (beat == 7) busy <= 1'b0;
                else           beat <= beat + 1;
            end
        end
    end
endmodule


// Behavioural stand-in for the generated Gowin dual-clock FIFO: 512 words,
// first-word-fall-through, the same almost-full / almost-empty thresholds as
// framebuffer_fifo.ipc. The fill level is shared combinationally instead of
// being resynchronised into each domain, which is idealised but conservative
// for what this bench checks.
module fifo_model
(
    input               Reset,
    input        [31:0] Data,
    input               WrClk,
    input               WrEn,
    input               RdClk,
    input               RdEn,
    output       [31:0] Q,
    output              Empty,
    output              Full,
    output              Almost_Empty,
    output              Almost_Full
);
    localparam int DEPTH      = 512;
    localparam int ALEMPTY    = 240;
    localparam int ALFULL     = 504;

    logic [31:0] mem [0:DEPTH-1];
    integer      wptr, rptr;

    wire integer count = wptr - rptr;

    assign Empty        = (count == 0);
    assign Full         = (count >= DEPTH);
    assign Almost_Empty = (count <= ALEMPTY);
    assign Almost_Full  = (count >= ALFULL);
    assign Q            = mem[rptr % DEPTH];

    initial begin wptr = 0; rptr = 0; end

    always @(posedge WrClk) begin
        if (Reset) wptr <= 0;
        else if (WrEn && !Full) begin
            mem[wptr % DEPTH] <= Data;
            wptr <= wptr + 1;
        end
    end

    always @(posedge RdClk) begin
        if (Reset) rptr <= 0;
        else if (RdEn && !Empty) rptr <= rptr + 1;
    end
endmodule
