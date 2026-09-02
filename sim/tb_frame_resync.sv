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
    wire [31:0] wr_data;

    psram_model psram (
        .clk(psram_clk), .rst_n(psram_rst_n), .addr(addr), .cmd(cmd),
        .cmd_en(cmd_en), .wr_data(wr_data), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
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
        .wr_data(wr_data), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .addr(addr), .cmd(cmd), .cmd_en(cmd_en), .data_mask(),
        .fifo_almost_full(fifo_afull), .fifo_full(fifo_full),
        .fifo_write_data(fifo_wdata), .fifo_write_enable(fifo_wren));

    wire [4:0] lcd_r, lcd_b;
    wire [5:0] lcd_g;
    wire       lcd_de, lcd_hsync, lcd_vsync;

    VGA_Timing vga (
        .PixelClk(lcd_clk), .nRST(lcd_rst_n),
        .PixelWord(fifo_rdata), .PixelEmpty(fifo_empty),
        .PixelAlmostEmpty(fifo_aempty), .PixelReadEnable(fifo_rden),
`ifndef LEGACY
        .FrameRestart(frame_restart_lcd),
`endif
        .LCD_DE(lcd_de), .LCD_HSYNC(lcd_hsync), .LCD_VSYNC(lcd_vsync),
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

    // VSYNC measured as a host interrupt source: width and one pulse per frame.
    integer vs_high = 0, vs_width = 0, vs_pulses = 0;
    reg     vs_d = 1'b0;

    always @(posedge lcd_clk) begin
        vs_d <= lcd_vsync;
        if (lcd_vsync)          vs_high <= vs_high + 1;
        else if (vs_d) begin
            vs_width  <= vs_high;
            vs_pulses <= vs_pulses + 1;
            vs_high   <= 0;
        end
    end

    reg started_d;
    always @(posedge lcd_clk) started_d <= vga.stream_started;

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
        end else if (lcd_de) begin
            // Scored on the registered outputs, i.e. what actually leaves the
            // pins. stream_started is delayed to match that register stage.
            if (!started_d)                         blanked    <= blanked + 1;
            else if (pixel_out !== pix_index[15:0]) mismatches <= mismatches + 1;
            pix_index <= pix_index + 1;
        end
    end


    // ------------------------------------------------------------------
    // Audit of what the controller actually wrote into PSRAM.
    //
    // The reference is recomputed here with plain modulo arithmetic, on
    // purpose: the RTL walks the diagonals with incremental counters, so an
    // independent formulation is what makes this a check rather than a
    // restatement. It also catches beat misalignment inside a burst, which
    // could not exist while every beat of a burst carried the same word.
    // ------------------------------------------------------------------
    localparam int W = 480, H = 272, PITCH = 17;

    function [15:0] ref_bar(input integer y);
        begin
            if      (y <  34) ref_bar = 16'hF800;
            else if (y <  68) ref_bar = 16'h07E0;
            else if (y < 102) ref_bar = 16'h001F;
            else if (y < 136) ref_bar = 16'hFFFF;
            else if (y < 170) ref_bar = 16'hFFE0;
            else if (y < 204) ref_bar = 16'h07FF;
            else if (y < 238) ref_bar = 16'hF81F;
            else              ref_bar = 16'h0000;
        end
    endfunction

    // Follows whichever pattern the RTL selected, read from the DUT so the two
    // cannot drift apart.
    function [15:0] ref_pixel(input integer x, input integer y);
        reg border;
        begin
            border = (x == 0 || x == W-1 || y == 0 || y == H-1);
            case (ctrl.PATTERN)
                2:       ref_pixel = border ? 16'hFFFF : (16'd1 << (y / PITCH));
                1:       ref_pixel = border ? 16'hFFFF :
                                     ((((x + y) % PITCH) == 0) ? ref_bar(y) : 16'h0000);
                default: ref_pixel = ref_bar(y);
            endcase
        end
    endfunction

    task audit_framebuffer;
        integer x, y, idx, bad, first_x, first_y;
        begin
            bad = 0; first_x = -1; first_y = -1;
            for (y = 0; y < H; y = y + 1)
                for (x = 0; x < W; x = x + 1) begin
                    idx = y * W + x;
                    if (psram.fb[idx] !== ref_pixel(x, y)) begin
                        if (bad == 0) begin first_x = x; first_y = y; end
                        bad = bad + 1;
                    end
                end
            if (bad == 0)
                $display("[audit] frame buffer scritto: %0d pixel, tutti corretti", W*H);
            else
                $display("[audit] FALLITO: %0d pixel errati su %0d, primo a (x=%0d,y=%0d) atteso %04h letto %04h",
                         bad, W*H, first_x, first_y,
                         ref_pixel(first_x, first_y), psram.fb[first_y*W + first_x]);
        end
    endtask
    initial begin
`ifdef LEGACY
        $display("=== RTL PRE-FIX (senza risincronizzazione) ===");
`else
        $display("=== RTL CON RISINCRONIZZAZIONE AL VBLANK ===");
`endif
        global_rst_n = 1'b0;
        repeat (20) @(posedge psram_clk);
        global_rst_n = 1'b1;

        wait (frame_no >= 1);
        audit_framebuffer;

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
        $display("[vsync] %0d impulsi in %0d frame, larghezza %0d clock = %.0f us",
                 vs_pulses, frame_no, vs_width, vs_width / 9.0);
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
