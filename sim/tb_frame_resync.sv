`timescale 1ns/1ps

// Drives the display pipeline with an address-derived pattern, forces an
// underrun in the middle of a visible frame, and reports how many frames stay
// damaged afterwards. Compile with -DLEGACY to run the same experiment against
// the pre-resynchronisation RTL.
module tb_frame_resync;

    logic lcd_clk = 1'b0;
    logic psram_clk = 1'b0;
    always #55.5555 lcd_clk   = ~lcd_clk;
    always #6.1728  psram_clk = ~psram_clk;

    logic global_rst_n = 1'b0;
    logic lcd_rst_n, psram_rst_n;

    ResetSynchronizer psram_reset_sync (
        .clk(psram_clk), .async_rst_n(global_rst_n), .sync_rst_n(psram_rst_n));
    ResetSynchronizer lcd_reset_sync (
        .clk(lcd_clk),   .async_rst_n(global_rst_n), .sync_rst_n(lcd_rst_n));

    wire [31:0] rd_data;
    wire        rd_data_valid;
    wire [20:0] addr;
    wire        cmd, cmd_en;
    wire        init_calib;
    logic       starve = 1'b0;

    psram_model psram (
        .clk(psram_clk), .rst_n(psram_rst_n), .addr(addr), .cmd(cmd),
        .cmd_en(cmd_en), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .init_calib(init_calib), .starve(starve));

    wire [31:0] fifo_wdata, fifo_rdata;
    wire        fifo_wren, fifo_rden;
    wire        fifo_empty, fifo_full, fifo_aempty, fifo_afull;

`ifdef LEGACY
    wire fifo_flush = 1'b0;
`else
    wire fifo_flush;
    wire frame_restart_lcd, frame_restart_psram;

    PulseSynchronizer frame_restart_sync (
        .src_clk(lcd_clk),   .src_rst_n(lcd_rst_n),   .src_pulse(frame_restart_lcd),
        .dst_clk(psram_clk), .dst_rst_n(psram_rst_n), .dst_pulse(frame_restart_psram));
`endif

`ifdef REAL_FIFO
    FramebufferFifo fifo (
`else
    fifo_model fifo (
`endif
        .Reset(~global_rst_n | fifo_flush),
        .Data(fifo_wdata), .WrClk(psram_clk), .WrEn(fifo_wren),
        .RdClk(lcd_clk),   .RdEn(fifo_rden),  .Q(fifo_rdata),
        .Empty(fifo_empty), .Full(fifo_full),
        .Almost_Empty(fifo_aempty), .Almost_Full(fifo_afull));

    FramebufferController ctrl (
        .clk(psram_clk), .nRST(psram_rst_n), .init_calib(init_calib),
`ifndef LEGACY
        .frame_restart(frame_restart_psram),
        .fifo_flush(fifo_flush),
`endif
        .wr_data(), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .addr(addr), .cmd(cmd), .cmd_en(cmd_en), .data_mask(),
        .fifo_almost_full(fifo_afull), .fifo_full(fifo_full),
        .fifo_write_data(fifo_wdata), .fifo_write_enable(fifo_wren));

    wire [4:0] lcd_r, lcd_b;
    wire [5:0] lcd_g;

    VGA_Timing vga (
        .PixelClk(lcd_clk), .nRST(lcd_rst_n),
        .PixelWord(fifo_rdata), .PixelEmpty(fifo_empty),
        .PixelAlmostEmpty(fifo_aempty), .PixelReadEnable(fifo_rden),
`ifndef LEGACY
        .FrameRestart(frame_restart_lcd),
`endif
        .LCD_DE(), .LCD_HSYNC(), .LCD_VSYNC(),
        .LCD_R(lcd_r), .LCD_G(lcd_g), .LCD_B(lcd_b));

    // ------------------------------------------------------------------
    // Frame boundary derived from the counters, so both variants are scored
    // by the same yardstick.
    // ------------------------------------------------------------------
    wire frame_mark = (vga.V_PixelCount == 16'd277) && (vga.H_PixelCount == 16'd0);
    wire [15:0] pixel_out = {lcd_r, lcd_g, lcd_b};

    integer frame_no   = -1;
    integer pix_index  = 0;
    integer mismatches = 0;
    integer blanked    = 0;
    integer fault_frame = -1;
    integer bad_after_fault = 0;
    integer frames_after_fault = 0;

    always @(posedge lcd_clk) begin
        if (frame_mark) begin
            if (frame_no >= 0) begin
                $display("  frame %2d: %6d attivi | %6d errati | %6d oscurati%s",
                         frame_no, pix_index, mismatches, blanked,
                         (fault_frame == frame_no) ? "   <-- underrun iniettato" : "");
                if (fault_frame >= 0 && frame_no > fault_frame) begin
                    frames_after_fault = frames_after_fault + 1;
                    if (mismatches != 0 || blanked != 0)
                        bad_after_fault = bad_after_fault + 1;
                end
            end
            frame_no   <= frame_no + 1;
            pix_index  <= 0;
            mismatches <= 0;
            blanked    <= 0;
        end else if (vga.video_active) begin
            if (!vga.stream_started)          blanked    <= blanked + 1;
            else if (pixel_out !== pix_index[15:0]) mismatches <= mismatches + 1;
            pix_index <= pix_index + 1;
        end
    end

    initial begin
`ifdef LEGACY
        $display("=== RTL PRE-FIX (senza risincronizzazione) ===");
`else
        $display("=== RTL CON RISINCRONIZZAZIONE AL VBLANK ===");
`endif
        global_rst_n = 1'b0;
        repeat (20) @(posedge psram_clk);
        global_rst_n = 1'b1;

        wait (frame_no >= 3);

        // Strike in the middle of the visible area, where starving the FIFO
        // actually costs the raster pixels it can never get back.
        wait (vga.V_PixelCount == 16'd100);
        fault_frame = frame_no;
        $display("[tb] underrun nel frame %0d, a meta' area visibile", fault_frame);
        starve = 1'b1;
        #150000;                 // 150 us > i 114 us che la FIFO puo' coprire
        starve = 1'b0;

        wait (frames_after_fault >= 4);

        $display("");
        $display("--- esito: %0d frame danneggiati su %0d dopo il guasto ---",
                 bad_after_fault, frames_after_fault);
        if (bad_after_fault == 0)
            $display("RISULTATO: recupero immediato, nessun frame successivo danneggiato");
        else if (bad_after_fault < frames_after_fault)
            $display("RISULTATO: recupero dopo %0d frame", bad_after_fault);
        else
            $display("RISULTATO: DANNO PERMANENTE, ogni frame successivo resta corrotto");
        $finish;
    end

    initial begin
        #400000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
