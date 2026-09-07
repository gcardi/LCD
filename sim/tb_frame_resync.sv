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

    logic global_rst_n = 1'b1;
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

    // Independent, clock-counted reference for the EXISTING raster. The RTL
    // has 561 clocks/line and 297 lines plus one final clock (V=297,H=0).
    // Freeze this explicitly; a future raster correction must update this
    // contract deliberately, not silently inherit new DUT counter values.
    localparam int LINE_CLOCKS = 561;
    localparam int FRAME_CLOCKS = 166618;
    localparam int FRAME_MARK = 277 * LINE_CLOCKS;
    localparam int W = 480, H = 272, PITCH = 17;
    wire [15:0] pixel_out = {lcd_r, lcd_g, lcd_b};

    integer frame_no   = -1;
    integer pix_index  = 0;
    integer mismatches = 0;
    integer blanked    = 0;
    integer fault_frame = -1;
    integer bad_after_fault = 0;
    integer frames_after_fault = 0;
    integer clean_before_fault = 0;
    integer underrun_pixels = 0;
    integer fault_errors = 0;
    integer phase = 0;
    integer sample_phase, ref_x, ref_y;
    integer vs_high = 0, vs_width = 0, vs_pulses = 0;
    reg vs_d = 1'b0;
    reg expected_de, expected_hs, expected_vs;
    reg sampled_started, sampled_empty;

    // Sample after NBA/continuous assignments settle. Legacy has combinational
    // outputs (and half-period DE), current has a one-clock output register.
    // The old output must be sampled during the HIGH half-cycle, never on the
    // DE/clock transition as the previous checker did.
    always @(posedge lcd_clk) begin
        if (!lcd_rst_n) begin
            phase = 0;
        end else begin
            sampled_started = vga.stream_started;
            sampled_empty = fifo_empty;
`ifdef LEGACY
            sample_phase = (phase + 1) % FRAME_CLOCKS;
`else
            sample_phase = phase;
`endif
            #1;
`ifdef LEGACY
            sampled_started = vga.stream_started;
            sampled_empty = fifo_empty;
`endif
            ref_x = sample_phase % LINE_CLOCKS;
            ref_y = sample_phase / LINE_CLOCKS;
            expected_de = ref_x >= 30 && ref_x < 510 && ref_y >= 5 && ref_y < 277;
            expected_hs = ref_x > 510;
`ifdef LEGACY
            expected_vs = 1'b0; // historical defect, not a current requirement
`else
            expected_vs = ref_y > 277;
`endif
            if ({lcd_de, lcd_hsync, lcd_vsync} !== {expected_de, expected_hs, expected_vs})
                $fatal(1, "Timing: phase=%0d atteso DE/HS/VS=%b%b%b letto=%b%b%b",
                       sample_phase, expected_de, expected_hs, expected_vs,
                       lcd_de, lcd_hsync, lcd_vsync);
            if (!expected_de && pixel_out !== 16'd0)
                $fatal(1, "RGB non nero durante blanking, phase=%0d", sample_phase);

            if (lcd_vsync) vs_high = vs_high + 1;
            else if (vs_d) begin
                vs_width = vs_high;
                vs_pulses = vs_pulses + 1;
                vs_high = 0;
                if (vs_width != 10660) $fatal(1, "Larghezza VSYNC: %0d", vs_width);
            end
            vs_d = lcd_vsync;

            if (sample_phase == FRAME_MARK) begin
                if (frame_no >= 0) begin
                    $display("[frame %0d] %0d pixel, %0d errati, %0d oscurati (t=%0t)",
                             frame_no, pix_index, mismatches, blanked, $time);
                    if (pix_index != W*H) $fatal(1, "Numero pixel/frame: %0d", pix_index);
                    if (fault_frame < 0) begin
                        if (mismatches != 0 || blanked != 0)
                            $fatal(1, "Frame corrotto prima del guasto");
                        clean_before_fault = clean_before_fault + 1;
                    end else if (frame_no == fault_frame) begin
                        fault_errors = mismatches + blanked;
                        if (fault_errors == 0 || underrun_pixels == 0)
                            $fatal(1, "Iniezione inefficace: nessun underrun/danno osservato");
                    end else if (frame_no > fault_frame) begin
                        if (mismatches != 0 || blanked != 0)
                            bad_after_fault = bad_after_fault + 1;
                        frames_after_fault = frames_after_fault + 1;
                    end
                end
                frame_no = frame_no + 1;
                pix_index = 0;
                mismatches = 0;
                blanked = 0;
            end else if (expected_de) begin
                if (!sampled_started) blanked = blanked + 1;
                else if (pixel_out !== pix_index[15:0]) mismatches = mismatches + 1;
                if (frame_no == fault_frame && sampled_started && sampled_empty)
                    underrun_pixels = underrun_pixels + 1;
                pix_index = pix_index + 1;
            end
            phase = (phase + 1) % FRAME_CLOCKS;
        end
    end

    // Output registers must hold their value through the falling edge.
`ifndef LEGACY
    reg [18:0] held_outputs;
    always @(negedge lcd_clk) begin
        held_outputs = {lcd_de, lcd_hsync, lcd_vsync, pixel_out};
        #1;
        if (lcd_rst_n && {lcd_de, lcd_hsync, lcd_vsync, pixel_out} !== held_outputs)
            $fatal(1, "Uscite LCD cambiate sul fronte di discesa");
    end
`endif

    always @(posedge psram_clk) begin
        if (psram_rst_n && rd_data_valid && fifo_full && !fifo_flush)
            $fatal(1, "Overflow: beat PSRAM scartato dalla FIFO piena");
    end

    initial begin
        #1000000;
        $display("[progress] 1 ms simulato, calibrazione=%b", init_calib);
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
`ifdef LEGACY
            ref_pixel = ref_bar(y);
`else
            case (ctrl.PATTERN)
                2:       ref_pixel = border ? 16'hFFFF : (16'd1 << (y / PITCH));
                1:       ref_pixel = border ? 16'hFFFF :
                                     ((((x + y) % PITCH) == 0) ? ref_bar(y) : 16'h0000);
                default: ref_pixel = ref_bar(y);
            endcase
`endif
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
                $fatal(1, "[audit] FALLITO: %0d pixel errati su %0d, primo a (x=%0d,y=%0d) atteso %04h letto %04h",
                         bad, W*H, first_x, first_y,
                         ref_pixel(first_x, first_y), psram.fb[first_y*W + first_x]);
        end
    endtask
    integer fault_us = 150;
    integer timeout_ns = 200000000;
    initial begin
        if ($value$plusargs("FAULT_US=%d", fault_us)) begin end
`ifdef LEGACY
        $display("=== RTL PRE-FIX (senza risincronizzazione) ===");
`else
        $display("=== RTL CON RISINCRONIZZAZIONE AL VBLANK ===");
`endif
        global_rst_n = 1'b0;
        repeat (20) @(negedge psram_clk);
        global_rst_n = 1'b1;

        wait (cmd_en && !cmd);
        #1;
        audit_framebuffer;

        wait (frame_no >= 2);

        // Strike in the middle of the visible area, where starving the FIFO
        // actually costs the raster pixels it can never get back.
        wait (phase == 100 * LINE_CLOCKS);
        @(negedge psram_clk);
        fault_frame = frame_no;
        $display("[tb] underrun nel frame %0d, a meta' area visibile", fault_frame);
        starve = 1'b1;
        #(fault_us * 1000);      // default 150 us > 114 us of FIFO coverage
        @(negedge psram_clk);
        starve = 1'b0;

        wait (frames_after_fault >= 4);
        @(negedge lcd_clk);      // scoreboard has completed all frame checks

        $display("");
        $display("[vsync] %0d impulsi in %0d frame, larghezza %0d clock = %.0f us",
                 vs_pulses, frame_no, vs_width, vs_width / 9.0);
        $display("");
        $display("--- esito: %0d frame danneggiati su %0d dopo il guasto ---",
                 bad_after_fault, frames_after_fault);
        if (clean_before_fault < 2 || fault_errors == 0 || underrun_pixels == 0)
            $fatal(1, "Copertura insufficiente: baseline o guasto non verificati");
`ifdef LEGACY
        if (bad_after_fault != 4 || vs_pulses != 0)
            $fatal(1, "Legacy non riproduce il danno persistente atteso");
        $display("PASS: frame_resync legacy (danno persistente atteso: 4/4)");
`else
        if (bad_after_fault != 0 || vs_pulses != frame_no)
            $fatal(1, "Recupero/VSYNC fallito: bad=%0d vs=%0d frame=%0d",
                   bad_after_fault, vs_pulses, frame_no);
        $display("PASS: frame_resync current/model (recupero al frame seguente: 0/4)");
`endif
        $finish;
    end

    initial begin
        if ($value$plusargs("TIMEOUT_NS=%d", timeout_ns)) begin end
        #(timeout_ns);
        $fatal(1, "TIMEOUT simulato: frame=%0d phase=%0d calib=%b", frame_no, phase, init_calib);
    end

endmodule
