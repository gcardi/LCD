module FramebufferController
(
    input  logic        clk,
    input  logic        nRST,
    input  logic        init_calib,

    // One-cycle pulse, already synchronised into this domain, marking the
    // start of vertical blanking on the display side.
    input  logic        frame_restart,

    output logic [31:0] wr_data,
    input  logic [31:0] rd_data,
    input  logic        rd_data_valid,
    output logic [20:0] addr,
    output logic        cmd,
    output logic        cmd_en,
    output logic  [3:0] data_mask,

    input  logic        fifo_almost_full,
    input  logic        fifo_full,
    output logic [31:0] fifo_write_data,
    output logic        fifo_write_enable,
    output logic        fifo_flush
);

    localparam int unsigned FRAME_WIDTH     = 480;
    localparam int unsigned FRAME_HEIGHT    = 272;
    localparam int unsigned FRAME_PIXELS    = FRAME_WIDTH * FRAME_HEIGHT;
    localparam int unsigned BURST_PIXELS    = 16;
    localparam int unsigned LAST_BURST_ADDR = FRAME_PIXELS - BURST_PIXELS;

    // Flush hold, in this domain's cycles. Long enough to cover an in-flight
    // burst still draining out of the PSRAM controller, and to be seen for
    // several cycles by the FIFO's read side, which runs nine times slower.
    localparam int unsigned FLUSH_CYCLES    = 63;

    typedef enum logic [2:0] {
        WAIT_CALIBRATION,
        WRITE_COMMAND,
        WRITE_DATA,
        WRITE_GAP,
        READ_COMMAND,
        READ_DATA,
        READ_GAP,
        FRAME_FLUSH
    } state_t;

    state_t state;

    logic [20:0] memory_address;
    logic  [8:0] init_x;
    logic  [8:0] init_y;
    logic  [2:0] burst_beat;
    logic  [4:0] command_gap;
    logic  [5:0] flush_count;

    // Diagonal-walk state, kept incrementally so no divider is needed.
    // line_diag is y mod DIAG_PITCH for the current line; diag_base is
    // (x + y) mod DIAG_PITCH at the first pixel of the current burst.
    logic  [4:0] line_diag;
    logic  [4:0] diag_base;

    // Which RGB565 bit the bit-walk pattern is lighting. 272 lines divide
    // exactly into sixteen bands of DIAG_PITCH lines, so it advances on the
    // same wrap as line_diag and needs no divider of its own.
    logic  [3:0] bit_band;

    // A constant, so synthesis prunes whichever patterns are not selected.
    localparam int unsigned PATTERN_BARS     = 0;  // eight horizontal colour bars
    localparam int unsigned PATTERN_DIAGONAL = 1;  // coloured diagonals, border
    localparam int unsigned PATTERN_BITWALK  = 2;  // one RGB565 bit per band

    localparam int unsigned PATTERN = PATTERN_DIAGONAL;

    // The pitch must be odd and share no factor with the burst length, or a
    // shift of exactly one burst would slide the pattern onto itself and stay
    // invisible - the same trap the colour bars fell into.
    localparam int unsigned DIAG_PITCH = 17;

    // Eight horizontal RGB565 bars. 272 lines divide exactly into eight
    // bands of 34 lines each. Also used to colour the diagonals, so a swapped
    // bit lane still shows up as a wrong hue.
    function automatic logic [15:0] test_pixel(input logic [8:0] y);
        begin
            if      (y < 9'd34)  test_pixel = 16'hF800; // red
            else if (y < 9'd68)  test_pixel = 16'h07E0; // green
            else if (y < 9'd102) test_pixel = 16'h001F; // blue
            else if (y < 9'd136) test_pixel = 16'hFFFF; // white
            else if (y < 9'd170) test_pixel = 16'hFFE0; // yellow
            else if (y < 9'd204) test_pixel = 16'h07FF; // cyan
            else if (y < 9'd238) test_pixel = 16'hF81F; // magenta
            else                 test_pixel = 16'h0000; // black
        end
    endfunction

    // A one-pixel white frame proves the visible area really is 480x272 and
    // starts in the corner; the diagonals turn a horizontal displacement into
    // a vertical one, so the error can be read off the panel by eye.
    function automatic logic [15:0] diag_pixel(input logic [8:0] x,
                                               input logic [8:0] y,
                                               input logic [4:0] diag);
        begin
            if (x == 9'd0 || x == FRAME_WIDTH - 1 ||
                y == 9'd0 || y == FRAME_HEIGHT - 1)
                diag_pixel = 16'hFFFF;
            else if (diag == 5'd0)
                diag_pixel = test_pixel(y);
            else
                diag_pixel = 16'h0000;
        end
    endfunction

    // One RGB565 bit per band, LSB of blue at the top through MSB of red at
    // the bottom: three staircases of increasing brightness. A dead lane is a
    // black band and names its own bit; two swapped lanes put the brightness
    // steps out of order. The white border stays, as a known reference.
    function automatic logic [15:0] bitwalk_pixel(input logic [8:0] x,
                                                  input logic [8:0] y,
                                                  input logic [3:0] band);
        begin
            if (x == 9'd0 || x == FRAME_WIDTH - 1 ||
                y == 9'd0 || y == FRAME_HEIGHT - 1)
                bitwalk_pixel = 16'hFFFF;
            else
                bitwalk_pixel = 16'd1 << band;
        end
    endfunction

    // The two RGB565 pixels carried by one 32-bit beat. Low half is the
    // earlier pixel, matching how VGA_Timing unpacks the word.
    function automatic logic [31:0] write_pair(input logic [8:0] x_base,
                                               input logic [8:0] y,
                                               input logic [4:0] base,
                                               input logic [3:0] band,
                                               input logic [2:0] beat);
        logic [8:0] x_lo, x_hi;
        logic [5:0] raw_lo, raw_hi;
        logic [4:0] d_lo, d_hi;
        begin
            x_lo = x_base + {5'd0, beat, 1'b0};
            x_hi = x_lo + 9'd1;

            case (PATTERN)
                PATTERN_DIAGONAL: begin
                    // base <= 16 and 2*beat <= 14, so one conditional subtract
                    // is enough to bring both back below the pitch.
                    raw_lo = {1'b0, base} + {2'd0, beat, 1'b0};
                    raw_hi = raw_lo + 6'd1;
                    d_lo   = (raw_lo >= DIAG_PITCH) ? raw_lo[4:0] - DIAG_PITCH[4:0] : raw_lo[4:0];
                    d_hi   = (raw_hi >= DIAG_PITCH) ? raw_hi[4:0] - DIAG_PITCH[4:0] : raw_hi[4:0];
                    write_pair = {diag_pixel(x_hi, y, d_hi), diag_pixel(x_lo, y, d_lo)};
                end

                PATTERN_BITWALK:
                    write_pair = {bitwalk_pixel(x_hi, y, band),
                                  bitwalk_pixel(x_lo, y, band)};

                default:
                    write_pair = {test_pixel(y), test_pixel(y)};
            endcase
        end
    endfunction

    always_comb begin
        fifo_write_data   = rd_data;
        // Nothing is admitted while the FIFO is being flushed: beats still
        // draining from an abandoned burst belong to the previous frame.
        fifo_write_enable = rd_data_valid && !fifo_full && !fifo_flush;
    end

    always_ff @(posedge clk or negedge nRST) begin
        if (!nRST) begin
            state          <= WAIT_CALIBRATION;
            memory_address <= 21'd0;
            init_x         <= 9'd0;
            init_y         <= 9'd0;
            burst_beat     <= 3'd0;
            command_gap    <= 5'd0;
            wr_data        <= 32'd0;
            addr           <= 21'd0;
            cmd            <= 1'b0;
            cmd_en         <= 1'b0;
            data_mask      <= 4'b0000;
            fifo_flush     <= 1'b0;
            flush_count    <= 6'd0;
            line_diag      <= 5'd0;
            bit_band       <= 4'd0;
            diag_base      <= 5'd0;
        end else begin
            // Commands are single-cycle pulses. Write data is reloaded every
            // cycle so each beat of the burst carries its own pixels.
            cmd_en <= 1'b0;

            case (state)
                WAIT_CALIBRATION: begin
                    if (init_calib) begin
                        memory_address <= 21'd0;
                        init_x         <= 9'd0;
                        init_y         <= 9'd0;
                        line_diag      <= 5'd0;
                        diag_base      <= 5'd0;
                        bit_band       <= 4'd0;
                        command_gap    <= 5'd0;
                        state          <= WRITE_COMMAND;
                    end
                end

                WRITE_COMMAND: begin
                    addr       <= memory_address;
                    cmd        <= 1'b1;
                    cmd_en     <= 1'b1;
                    wr_data    <= write_pair(init_x, init_y, diag_base, bit_band, 3'd0);
                    data_mask  <= 4'b0000;
                    burst_beat <= 3'd0;
                    state      <= WRITE_DATA;
                end

                WRITE_DATA: begin
                    // Present the next beat's pair. Unlike the colour bars the
                    // diagonals change inside a burst, so beat alignment on the
                    // write side now matters.
                    wr_data <= write_pair(init_x, init_y, diag_base, bit_band,
                                          burst_beat + 3'd1);

                    if (burst_beat == 3'd7) begin
                        // The current word is Data7, the final word in the burst.
                        command_gap <= 5'd10;

                        if ((init_y == FRAME_HEIGHT - 1) &&
                            (init_x == FRAME_WIDTH - BURST_PIXELS)) begin
                            // The complete test frame is now stored in PSRAM.
                            memory_address <= 21'd0;
                            init_x         <= 9'd0;
                            init_y         <= 9'd0;
                            state          <= READ_GAP;
                        end else begin
                            memory_address <= memory_address + 21'd16;

                            if (init_x == FRAME_WIDTH - BURST_PIXELS) begin
                                init_x    <= 9'd0;
                                // New line: x returns to 0 and y advances, so
                                // (x+y) mod pitch becomes (y+1) mod pitch.
                                line_diag <= (line_diag == DIAG_PITCH - 1) ? 5'd0 : line_diag + 5'd1;
                                // Sixteen bands of DIAG_PITCH lines each fill
                                // 272 rows exactly, so the band advances on
                                // the same wrap.
                                if (line_diag == DIAG_PITCH - 1)
                                    bit_band <= bit_band + 4'd1;
                                diag_base <= (line_diag == DIAG_PITCH - 1) ? 5'd0 : line_diag + 5'd1;
                                init_y <= init_y + 9'd1;
                            end else begin
                                init_x <= init_x + 9'd16;
                                // Advancing x by 16 with pitch 17 is a step of
                                // -1 in the diagonal index.
                                diag_base <= (diag_base == 5'd0) ? DIAG_PITCH[4:0] - 5'd1 : diag_base - 5'd1;
                            end

                            state <= WRITE_GAP;
                        end
                    end else begin
                        burst_beat <= burst_beat + 3'd1;
                    end
                end

                WRITE_GAP: begin
                    if (command_gap == 5'd0)
                        state <= WRITE_COMMAND;
                    else
                        command_gap <= command_gap - 5'd1;
                end

                READ_COMMAND: begin
                    if (!fifo_almost_full && !fifo_full) begin
                        addr        <= memory_address;
                        cmd         <= 1'b0;
                        cmd_en      <= 1'b1;
                        burst_beat  <= 3'd0;
                        command_gap <= 5'd17;
                        state       <= READ_DATA;
                    end
                end

                READ_DATA: begin
                    if (command_gap != 5'd0)
                        command_gap <= command_gap - 5'd1;

                    if (rd_data_valid) begin
                        if (burst_beat == 3'd7) begin
                            if (memory_address == LAST_BURST_ADDR)
                                memory_address <= 21'd0;
                            else
                                memory_address <= memory_address + 21'd16;

                            state <= READ_GAP;
                        end else begin
                            burst_beat <= burst_beat + 3'd1;
                        end
                    end
                end

                READ_GAP: begin
                    if (command_gap == 5'd0)
                        state <= READ_COMMAND;
                    else
                        command_gap <= command_gap - 5'd1;
                end

                FRAME_FLUSH: begin
                    if (flush_count == 6'd0) begin
                        fifo_flush  <= 1'b0;
                        command_gap <= 5'd0;
                        state       <= READ_COMMAND;
                    end else begin
                        flush_count <= flush_count - 6'd1;
                    end
                end

                default: state <= WAIT_CALIBRATION;
            endcase

            // A frame restart outranks whatever the read loop was doing, so it
            // is applied last and overrides the assignments above. The initial
            // write pass is exempt: it must complete before anything is worth
            // displaying.
            if (frame_restart && (state == READ_COMMAND ||
                                  state == READ_DATA    ||
                                  state == READ_GAP)) begin
                fifo_flush     <= 1'b1;
                flush_count    <= FLUSH_CYCLES[5:0];
                memory_address <= 21'd0;
                burst_beat     <= 3'd0;
                cmd_en         <= 1'b0;
                state          <= FRAME_FLUSH;
            end
        end
    end

endmodule
