module FramebufferController
(
    input  logic        clk,
    input  logic        nRST,
    input  logic        init_calib,

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
    output logic        fifo_write_enable
);

    localparam int unsigned FRAME_WIDTH     = 480;
    localparam int unsigned FRAME_HEIGHT    = 272;
    localparam int unsigned FRAME_PIXELS    = FRAME_WIDTH * FRAME_HEIGHT;
    localparam int unsigned BURST_PIXELS    = 16;
    localparam int unsigned LAST_BURST_ADDR = FRAME_PIXELS - BURST_PIXELS;

    typedef enum logic [2:0] {
        WAIT_CALIBRATION,
        WRITE_COMMAND,
        WRITE_DATA,
        WRITE_GAP,
        READ_COMMAND,
        READ_DATA,
        READ_GAP
    } state_t;

    state_t state;

    logic [20:0] memory_address;
    logic  [8:0] init_x;
    logic  [8:0] init_y;
    logic  [2:0] burst_beat;
    logic  [4:0] command_gap;

    function automatic logic [15:0] test_pixel(input logic [8:0] x);
        begin
            if      (x < 9'd60)  test_pixel = 16'hF800; // red
            else if (x < 9'd120) test_pixel = 16'h07E0; // green
            else if (x < 9'd180) test_pixel = 16'h001F; // blue
            else if (x < 9'd240) test_pixel = 16'hFFFF; // white
            else if (x < 9'd300) test_pixel = 16'hFFE0; // yellow
            else if (x < 9'd360) test_pixel = 16'h07FF; // cyan
            else if (x < 9'd420) test_pixel = 16'hF81F; // magenta
            else                 test_pixel = 16'h0000; // black
        end
    endfunction

    function automatic logic [31:0] test_pixel_pair(input logic [8:0] x);
        begin
            test_pixel_pair = {test_pixel(x + 9'd1), test_pixel(x)};
        end
    endfunction

    always_comb begin
        fifo_write_data   = rd_data;
        fifo_write_enable = rd_data_valid && !fifo_full;
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
        end else begin
            // Commands are single-cycle pulses. Write data remains valid for
            // all eight cycles of a 32-byte burst.
            cmd_en <= 1'b0;

            case (state)
                WAIT_CALIBRATION: begin
                    if (init_calib) begin
                        memory_address <= 21'd0;
                        init_x         <= 9'd0;
                        init_y         <= 9'd0;
                        command_gap    <= 5'd0;
                        state          <= WRITE_COMMAND;
                    end
                end

                WRITE_COMMAND: begin
                    addr       <= memory_address;
                    cmd        <= 1'b1;
                    cmd_en     <= 1'b1;
                    wr_data    <= test_pixel_pair(init_x);
                    data_mask  <= 4'b0000;
                    burst_beat <= 3'd0;
                    state      <= WRITE_DATA;
                end

                WRITE_DATA: begin
                    if (burst_beat == 3'd7) begin
                        // The current word is Data7, the final word in the burst.
                        command_gap <= 5'd10;

                        if ((init_y == FRAME_HEIGHT - 1) &&
                            (init_x == FRAME_WIDTH - 2)) begin
                            // The complete test frame is now stored in PSRAM.
                            memory_address <= 21'd0;
                            init_x         <= 9'd0;
                            init_y         <= 9'd0;
                            state          <= READ_GAP;
                        end else begin
                            memory_address <= memory_address + 21'd16;

                            if (init_x == FRAME_WIDTH - 2) begin
                                init_x <= 9'd0;
                                init_y <= init_y + 9'd1;
                            end else begin
                                init_x <= init_x + 9'd2;
                            end

                            state <= WRITE_GAP;
                        end
                    end else begin
                        burst_beat <= burst_beat + 3'd1;
                        wr_data    <= test_pixel_pair(init_x + 9'd2);
                        init_x     <= init_x + 9'd2;
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

                default: state <= WAIT_CALIBRATION;
            endcase
        end
    end

endmodule
