module FramebufferController #(
    parameter [15:0] BACKGROUND_COLOR = 16'h0000
)
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
    output logic        fifo_flush,
    input wire update_valid,
    input wire [20:0] update_addr,
    input wire [255:0] update_data,
    input wire [15:0] update_mask,
    output wire update_take,
    input wire control_valid,
    input wire [7:0] control_op,
    input wire control_buffer,
    input wire [15:0] control_sequence,
    output logic control_take,
    output wire [27:0] control_status,
    output wire irq_n,
    output logic blit_start,input wire blit_done,blit_error,
    input wire blit_read_valid,output wire blit_read_take,
    input wire [20:0] blit_read_address,
    output logic blit_read_done,output logic [255:0] blit_read_pixels
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

    typedef enum logic [3:0] {
        WAIT_CALIBRATION,
        WRITE_COMMAND,
        WRITE_DATA,
        WRITE_GAP,
        READ_COMMAND,
        READ_DATA,
        READ_GAP,
        FRAME_FLUSH, UPDATE_COMMAND, UPDATE_DATA, UPDATE_GAP,
        BLIT_READ_COMMAND, BLIT_READ_DATA, BLIT_READ_GAP
    } state_t;

      // One-hot encoding avoids a long shared clock-enable decoder as the
      // read/write/blit arbitration grows. Simulation keeps the enum values.
      (* syn_encoding = "onehot" *) state_t state;
      logic restart_pending;
      logic frame_restart_q;
      always_ff @(posedge clk or negedge nRST) begin
          if(!nRST) frame_restart_q<=0;
          else frame_restart_q<=frame_restart;
      end
      logic fifo_almost_full_q,init_calib_q;
      logic rd_valid_q;
      logic [31:0] rd_data_q;
      // Capture the IP response as a pair before FIFO/blitter arbitration.
      // This cuts the IP's combinational valid gating out of those paths.
      always_ff @(posedge clk or negedge nRST) begin
          if(!nRST) begin rd_valid_q<=0;rd_data_q<=0;end
          else begin rd_valid_q<=rd_data_valid;rd_data_q<=rd_data;end
      end
      logic update_pending_q,blit_read_pending_q;
    logic [255:0] update_words;
    logic [15:0] update_masks;
    // Pixel addresses: two disjoint 128K-pixel slots (256 KiB each).
    // The first 130560 pixels of each slot are the 480x272 image.
    logic double_enabled,front_buffer,irq_pending,present_pending,present_flushing;
    // Proof of reset for the MCU. Set by every reset of this domain, cleared
    // only by ACK_RESET. The MCU clears it, pulses FPGA_RST_N and reads it
    // back: set again means the pulse really reset the fabric, still clear
    // means it did not arrive. ACK_RESET is served here in READ_COMMAND, after
    // PSRAM calibration and the initial fill, so its completion also says the
    // memory side is ready to draw.
    logic reset_seen;
    logic [15:0] completed_sequence;
    logic [7:0] control_result;
    logic blit_active,blit_read_active;
    logic sequence_same_q,sequence_next_q;
    // Payload is stable before control_valid crosses the mailbox barrier.
    always_ff @(posedge clk or negedge nRST) begin
        if(!nRST) begin sequence_same_q<=0;sequence_next_q<=0;end
        else begin
            sequence_same_q<=control_sequence==completed_sequence;
            sequence_next_q<=control_sequence==completed_sequence+16'd1;
        end
    end
    assign blit_read_take = state==BLIT_READ_COMMAND;
    wire draw_buffer = double_enabled && !front_buffer;
    assign irq_n = !irq_pending;
    assign control_status = {reset_seen,completed_sequence,control_result,irq_pending,front_buffer,double_enabled};
      assign update_take = state == UPDATE_COMMAND;
      // Break the FIFO pointer/threshold path before it reaches the controller
      // state decoder. The FIFO threshold already reserves a full burst.
      always_ff @(posedge clk or negedge nRST) begin
          if (!nRST) begin
              fifo_almost_full_q <= 1'b0;init_calib_q<=0;update_pending_q<=0;blit_read_pending_q<=0;
          end else begin
              fifo_almost_full_q <= fifo_almost_full;
              init_calib_q<=init_calib;
              update_pending_q<=update_valid;blit_read_pending_q<=blit_read_valid;
          end
      end
    function automatic [3:0] pixel_mask(input [1:0] enabled);
        pixel_mask = {{2{!enabled[1]}}, {2{!enabled[0]}}};
    endfunction

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

    localparam int unsigned PATTERN_SOLID = 3;
    localparam int unsigned PATTERN = PATTERN_SOLID;

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
                PATTERN_SOLID: write_pair = {BACKGROUND_COLOR, BACKGROUND_COLOR};
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
        fifo_write_data   = rd_data_q;
        // Nothing is admitted while the FIFO is being flushed: beats still
        // draining from an abandoned burst belong to the previous frame.
        fifo_write_enable = rd_valid_q && !fifo_full && !fifo_flush && !blit_read_active;
    end

    always_ff @(posedge clk or negedge nRST) begin
        if (!nRST) begin
            restart_pending <= 0;
            double_enabled<=0;front_buffer<=0;irq_pending<=0;reset_seen<=1;
            present_pending<=0;present_flushing<=0;
            completed_sequence<=0;control_result<=0;control_take<=0;
            blit_start<=0;blit_active<=0;blit_read_active<=0;
            blit_read_done<=0;blit_read_pixels<=0;
            update_words <= 0;
            update_masks <= 0;
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
            control_take <= 1'b0;
            blit_start<=0;blit_read_done<=0;
            if (frame_restart_q) restart_pending <= 1;

            case (state)
                WAIT_CALIBRATION: begin
                    if (init_calib_q) begin
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

                UPDATE_DATA: begin
                    update_words <= update_words >> 32;
                    update_masks <= update_masks >> 2;
                    wr_data <= update_words[63:32];
                    data_mask <= pixel_mask(update_masks[3:2]);
                    if (burst_beat == 7) begin
                        command_gap <= 10;
                        state <= UPDATE_GAP;
                    end else burst_beat <= burst_beat + 1'b1;
                end
                UPDATE_GAP: begin
                    if (command_gap == 0) state <= READ_COMMAND;
                    else command_gap <= command_gap - 1'b1;
                end
                UPDATE_COMMAND: begin
                        addr <= {3'd0,draw_buffer,update_addr[16:0]};
                        cmd <= 1;
                        cmd_en <= 1;
                        wr_data <= update_data[31:0];
                        data_mask <= pixel_mask(update_mask[1:0]);
                        update_words <= update_data;
                        update_masks <= update_mask;
                        burst_beat <= 0;
                        state <= UPDATE_DATA;
                end
                READ_COMMAND: begin
                    // This state is reached after the final write's recovery
                    // gap. The endpoint barrier has also drained both queues.
                    if(blit_active) begin
                        if(blit_done && !blit_start) begin
                            blit_active<=0;control_take<=1;
                            control_result<=blit_error?8'hE1:8'h00;
                        end
                    end else if(control_valid && !control_take && !present_pending && !present_flushing) begin
                        control_result<=0;
                        case(control_op)
                          1:begin double_enabled<=1;control_take<=1;end
                          2:begin
                            // Exact duplicate of the last completed presentation
                            // is idempotent, including after its IRQ was ACKed.
                            if(double_enabled && sequence_same_q &&
                               control_buffer==front_buffer) control_take<=1;
                            else if(double_enabled && !irq_pending && control_buffer!=front_buffer &&
                                    sequence_next_q)
                              present_pending<=1;
                            else begin control_result<=8'hE1;control_take<=1;end
                          end
                          3:begin
                            if(sequence_same_q) irq_pending<=0;
                            else control_result<=8'hE1;
                            control_take<=1;
                          end
                          6:begin reset_seen<=0;control_take<=1;end // ACK_RESET
                          4,5:begin
                            if(double_enabled && control_buffer!=front_buffer)begin
                              blit_start<=1;blit_active<=1;
                            end else begin control_result<=8'hE1;control_take<=1;end
                          end
                          default:begin control_result<=8'hE1;control_take<=1;end
                        endcase
                    end
                    if (fifo_almost_full_q && update_pending_q) begin
                        state <= UPDATE_COMMAND;
                    end else if(fifo_almost_full_q && blit_read_pending_q)begin
                        state<=BLIT_READ_COMMAND;
                    // ALMOST_FULL is asserted early enough to reserve the
                    // complete eight-word read burst, so a second FULL test
                    // here is redundant and would reintroduce the raw Gray
                    // pointer into this timing-critical state decoder.
                    end else if (!fifo_almost_full_q) begin
                        addr        <= {3'd0,front_buffer,memory_address[16:0]};
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

                    if (rd_valid_q) begin
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

                BLIT_READ_COMMAND:begin
                    addr<=blit_read_address;cmd<=0;cmd_en<=1;
                    burst_beat<=0;command_gap<=17;blit_read_active<=1;
                    state<=BLIT_READ_DATA;
                end
                BLIT_READ_DATA:begin
                    if(command_gap!=0)command_gap<=command_gap-1'b1;
                    if(rd_valid_q)begin
                        blit_read_pixels<={rd_data_q,blit_read_pixels[255:32]};
                        if(burst_beat==7)state<=BLIT_READ_GAP;
                        else burst_beat<=burst_beat+1'b1;
                    end
                end
                BLIT_READ_GAP:begin
                    if(command_gap==0)begin
                        blit_read_done<=1;blit_read_active<=0;state<=READ_COMMAND;
                    end else command_gap<=command_gap-1'b1;
                end

                FRAME_FLUSH: begin
                    if (flush_count == 6'd0) begin
                        if(present_flushing) begin
                            present_flushing<=0;present_pending<=0;
                            completed_sequence<=control_sequence;
                            irq_pending<=1;control_take<=1;
                        end
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
            if ((frame_restart_q || restart_pending) && (state == READ_COMMAND ||
                                  state == READ_DATA    ||
                                  state == READ_GAP)) begin
                restart_pending <= 0;
                fifo_flush     <= 1'b1;
                flush_count    <= FLUSH_CYCLES[5:0];
                memory_address <= 21'd0;
                burst_beat     <= 3'd0;
                cmd_en         <= 1'b0;
                state          <= FRAME_FLUSH;
                // Arm only after the write barrier, and use a NEW raster
                // boundary (never a stale restart_pending from an old frame).
                if(frame_restart_q && present_pending) begin
                    front_buffer<=control_buffer;
                    present_flushing<=1;
                end
            end
        end
    end

endmodule
