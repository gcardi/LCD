// A command issued after the boot logo. tb_boot_logo holds command_valid at
// zero for its whole run, so the handover from the logo back to the command
// path is the one sequence nothing covers: the logo could draw perfectly and
// still leave the renderer unable to accept anything afterwards, and the panel
// would show exactly that - the logo, and nothing else ever again.
//
// The fill is B9, so it needs no glyph and no second flash read: if it does not
// land, the fault is the handover and not the font path.
`timescale 1ns / 1ps

module tb_logo_command;
    localparam int FRAME_WIDTH = 480;
    localparam int FRAME_HEIGHT = 272;
    localparam int FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

    // The fill sits clear of the centred logo, so the two never overlap and a
    // pixel's provenance is never in doubt.
    localparam int FILL_X = 16;
    localparam int FILL_Y = 8;
    localparam int FILL_W = 32;
    localparam int FILL_H = 16;
    localparam [15:0] FILL_COLOUR = 16'hF800;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #18.518 clk = ~clk;

    wire fonts_ready, fonts_error;
    wire logo_valid;
    wire [8:0] logo_width, logo_height, logo_x, logo_y;
    wire [14:0] logo_base;
    wire flash_request, flash_ready, flash_valid;
    wire [14:0] flash_address;
    wire [31:0] flash_data;

    FontStore store (
        .clk(clk), .rst_n(rst_n),
        .fonts_ready(fonts_ready), .fonts_error(fonts_error),
        .read_request(flash_request), .read_address(flash_address),
        .read_ready(flash_ready), .read_valid(flash_valid), .read_data(flash_data),
        .logo_valid(logo_valid), .logo_width(logo_width), .logo_height(logo_height),
        .logo_x(logo_x), .logo_y(logo_y), .logo_base(logo_base)
    );

    reg command_valid = 1'b0;
    wire command_take;
    wire update_valid;
    wire [20:0] update_address;
    wire [255:0] update_data;
    wire [15:0] update_mask;
    wire update_take = update_valid;

    TextRenderer renderer (
        .clk(clk), .rst_n(rst_n), .fonts_ready(fonts_ready),
        .logo_valid(logo_valid), .logo_width(logo_width), .logo_height(logo_height),
        .logo_x(logo_x), .logo_y(logo_y), .logo_base(logo_base),
        .command_valid(command_valid), .command_take(command_take),
        .command_kind(1'b1), .command_font_id(2'd0), .command_flags(8'd0),
        .command_x(FILL_X[8:0]), .command_y(FILL_Y[8:0]),
        .command_box_width(FILL_W[9:0]), .command_box_height(FILL_H[8:0]),
        .command_foreground(FILL_COLOUR), .command_background(16'd0),
        .command_length(7'd0),
        .text_read_address(), .text_read_data(8'd0),
        .flash_request(flash_request), .flash_address(flash_address),
        .flash_ready(flash_ready), .flash_valid(flash_valid), .flash_data(flash_data),
        .update_valid(update_valid), .update_take(update_take),
        .update_address(update_address), .update_data(update_data),
        .update_mask(update_mask)
    );

    reg [15:0] frame [0:FRAME_PIXELS-1];
    reg written [0:FRAME_PIXELS-1];

    integer errors = 0;
    integer writes = 0;
    integer fill_writes = 0;
    integer i, index;
    integer pixel_x, pixel_y;
    reg counting_fill = 1'b0;

    task fail(input [1023:0] message);
        begin
            $display("FAIL: %0s", message);
            errors = errors + 1;
        end
    endtask

    initial begin
        for (i = 0; i < FRAME_PIXELS; i = i + 1) begin
            frame[i] = 16'hDEAD;
            written[i] = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && update_valid && update_take) begin
            for (i = 0; i < 16; i = i + 1) begin
                if (update_mask[i]) begin
                    index = update_address + i;
                    if (index < FRAME_PIXELS) begin
                        written[index] = 1'b1;
                        frame[index] = update_data[16*i +: 16];
                        writes = writes + 1;
                        if (counting_fill) fill_writes = fill_writes + 1;
                    end
                end
            end
        end
    end

    integer logo_pixels;

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;

        fork : boot
            begin
                wait (fonts_ready || fonts_error);
                disable boot;
            end
            begin
                #40_000_000;
                fail("FontStore never finished validating the image");
                disable boot;
            end
        join

        if (fonts_error) fail("the image did not pass its CRC");
        if (!logo_valid) fail("no logo descriptor was accepted");

        logo_pixels = logo_width * logo_height;

        fork : draw
            begin
                wait (writes == logo_pixels);
                repeat (200) @(posedge clk);
                disable draw;
            end
            begin
                #40_000_000;
                fail("the logo never finished drawing");
                disable draw;
            end
        join

        $display("logo drawn: %0d pixels at %0t", writes, $time);

        // Now the part nothing else covers: a command, after the logo.
        counting_fill = 1'b1;
        command_valid <= 1'b1;

        fork : accept
            begin
                @(posedge clk);
                wait (command_take);
                disable accept;
            end
            begin
                // Generous: the fill is a few hundred cycles of work at most.
                repeat (200_000) @(posedge clk);
                fail("the renderer never took the command after the logo");
                disable accept;
            end
        join

        @(posedge clk);
        command_valid <= 1'b0;

        repeat (2000) @(posedge clk);

        if (fill_writes != FILL_W * FILL_H)
            fail("the fill wrote the wrong number of pixels");

        for (pixel_y = FILL_Y; pixel_y < FILL_Y + FILL_H; pixel_y = pixel_y + 1)
            for (pixel_x = FILL_X; pixel_x < FILL_X + FILL_W; pixel_x = pixel_x + 1) begin
                index = pixel_y * FRAME_WIDTH + pixel_x;
                if (!written[index]) fail("a fill pixel was never written");
                else if (frame[index] !== FILL_COLOUR)
                    fail("a fill pixel has the wrong colour");
            end

        if (errors == 0)
            $display("PASS: logo_command logo then fill, %0d fill pixels", fill_writes);
        else
            $display("FAILED with %0d error(s)", errors);
        $finish;
    end
endmodule
