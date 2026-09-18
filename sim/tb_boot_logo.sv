// Boot logo: descriptor, pixel stream and burst addresses, checked against the
// same User Flash image the fabric reads. The renderer is driven with no SPI
// command at all, so everything observed here is what a bare reset produces.
//
// What this proves: every pixel of the rectangle is written exactly once, with
// the colour stored in flash, at the address the framebuffer expects; nothing
// outside the rectangle is touched; and the logo does not consume a command.
// What it does not prove: the CDC handshake in TOP, or PSRAM arbitration.
//
// With +nologo the expectation inverts: the image is one generated without a
// logo, and the fonts must still come up while nothing at all is drawn. That
// is the regression to fear, because dropping --logo from the generator is a
// one-word mistake that would otherwise surface only on the panel.
`timescale 1ns / 1ps

module tb_boot_logo;
    localparam int FRAME_WIDTH = 480;
    localparam int FRAME_HEIGHT = 272;
    localparam int FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #18.518 clk = ~clk;  // 27 MHz, the crystal the font domain runs on

    wire fonts_ready, fonts_error;
    wire logo_valid;
    wire [8:0] logo_width, logo_height, logo_x, logo_y;
    wire [1:0] logo_format;
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
        .logo_x(logo_x), .logo_y(logo_y), .logo_format(logo_format), .logo_base(logo_base)
    );

    wire update_valid;
    wire [20:0] update_address;
    wire [255:0] update_data;
    wire [15:0] update_mask;
    // The real consumer acknowledges through a CDC handshake; taking on the
    // spot is the fastest a burst can be accepted and exercises the renderer's
    // own sequencing rather than the handshake's.
    wire update_take = update_valid;
    wire command_take;
    wire boot_complete;

    TextRenderer renderer (
        .clk(clk), .rst_n(rst_n), .fonts_ready(fonts_ready),
        .logo_valid(logo_valid), .logo_width(logo_width), .logo_height(logo_height),
        .logo_x(logo_x), .logo_y(logo_y), .logo_format(logo_format), .logo_base(logo_base),
        .boot_complete(boot_complete),
        .command_valid(1'b0), .command_take(command_take),
        .command_kind(1'b0), .command_font_id(2'd0), .command_flags(8'd0),
        .command_x(9'd0), .command_y(9'd0),
        .command_box_width(10'd0), .command_box_height(9'd0),
        .command_foreground(16'd0), .command_background(16'd0),
        .command_length(7'd0),
        .text_read_address(), .text_read_data(8'd0),
        .flash_request(flash_request), .flash_address(flash_address),
        .flash_ready(flash_ready), .flash_valid(flash_valid), .flash_data(flash_data),
        .update_valid(update_valid), .update_take(update_take),
        .update_address(update_address), .update_data(update_data),
        .update_mask(update_mask)
    );

    // An independent copy of the image, so the expected colour comes from the
    // file and not from the module under test.
    reg [31:0] expected_flash [0:19455];
    reg [15:0] frame [0:FRAME_PIXELS-1];
    reg written [0:FRAME_PIXELS-1];

    integer errors = 0;
    integer writes = 0;
    integer i;
    integer index;
    integer pixel_x, pixel_y;

    task fail(input [1023:0] message);
        begin
            $display("FAIL: %0s", message);
            errors = errors + 1;
        end
    endtask

    initial begin
        $readmemh("fonts/user_flash_fonts.mem", expected_flash);
        for (i = 0; i < FRAME_PIXELS; i = i + 1) begin
            frame[i] = 16'hDEAD;
            written[i] = 1'b0;
        end
    end

    // Capture every accepted burst, one pixel per set mask bit.
    always @(posedge clk) begin
        if (rst_n && update_valid && update_take) begin
            for (i = 0; i < 16; i = i + 1) begin
                if (update_mask[i]) begin
                    index = update_address + i;
                    if (index >= FRAME_PIXELS) fail("burst addresses past the frame");
                    else begin
                        if (written[index]) fail("a pixel was written twice");
                        written[index] = 1'b1;
                        frame[index] = update_data[16*i +: 16];
                        writes = writes + 1;
                    end
                end
            end
        end
    end

    // The logo must not look like a command being consumed.
    always @(posedge clk) if (rst_n && command_take) fail("the logo took a command");

    integer expected_pixels;
    integer stream_index;
    integer word_index;
    integer rle_word_index;
    integer rle_run_left;
    reg [15:0] expected_pixel;

    reg expect_logo;

    initial begin
        expect_logo = !$test$plusargs("nologo");
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;

        // The CRC walk over the whole image dominates this wait.
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

        if (!expect_logo) begin
            if (logo_valid) fail("a logo appeared in an image built without one");
            // Long enough for the renderer to have drawn one had it tried.
            repeat (200_000) @(posedge clk);
            if (writes != 0) fail("something was drawn without a logo");
            if (!boot_complete) fail("boot did not complete without a logo");
            if (errors == 0)
                $display("PASS: boot_logo fonts came up with no logo and nothing was drawn");
            else
                $display("FAILED with %0d error(s)", errors);
            $finish;
        end

        if (!logo_valid) fail("no logo descriptor was accepted");
        $display("fonts_ready at %0t, logo %0dx%0d at (%0d,%0d), base word %0d",
                 $time, logo_width, logo_height, logo_x, logo_y, logo_base);

        expected_pixels = logo_width * logo_height;

        if (boot_complete) fail("boot completed before the logo was drawn");

        // Drawing is bounded by one flash word per two pixels; give it room.
        fork : draw
            begin
                wait (writes == expected_pixels);
                // Settle, so a stray extra burst still shows up below.
                repeat (200) @(posedge clk);
                disable draw;
            end
            begin
                #40_000_000;
                fail("the logo was still being drawn when time ran out");
                disable draw;
            end
        join

        if (writes != expected_pixels)
            fail("wrong number of pixels written");
        if (!boot_complete) fail("boot did not complete after the logo");

        // Every stored pixel, in the order the section holds them, must have
        // landed on its own square of the panel.
        stream_index = 0;
        rle_word_index = 0;
        rle_run_left = 0;
        for (pixel_y = 0; pixel_y < logo_height; pixel_y = pixel_y + 1) begin
            for (pixel_x = 0; pixel_x < logo_width; pixel_x = pixel_x + 1) begin
                if(logo_format==2) begin
                    if(rle_run_left==0) begin
                        word_index = logo_base + rle_word_index;
                        rle_run_left = expected_flash[word_index][15:0];
                        expected_pixel = expected_flash[word_index][31:16];
                        rle_word_index = rle_word_index + 1;
                        if(rle_run_left==0) fail("zero-length RLE run in User Flash");
                    end
                    rle_run_left = rle_run_left - 1;
                end else begin
                    word_index = logo_base + (stream_index >> 1);
                    expected_pixel = stream_index[0] ? expected_flash[word_index][31:16]
                                                     : expected_flash[word_index][15:0];
                end
                index = (logo_y + pixel_y) * FRAME_WIDTH + logo_x + pixel_x;
                if (!written[index]) fail("a logo pixel was never written");
                else if (frame[index] !== expected_pixel) begin
                    $display("  at (%0d,%0d): got %04h, want %04h",
                             logo_x + pixel_x, logo_y + pixel_y,
                             frame[index], expected_pixel);
                    fail("a logo pixel has the wrong colour");
                end
                stream_index = stream_index + 1;
            end
        end

        // Nothing outside the rectangle may have been touched.
        for (index = 0; index < FRAME_PIXELS; index = index + 1) begin
            pixel_x = index % FRAME_WIDTH;
            pixel_y = index / FRAME_WIDTH;
            if (written[index] &&
                (pixel_x < logo_x || pixel_x >= logo_x + logo_width ||
                 pixel_y < logo_y || pixel_y >= logo_y + logo_height))
                fail("a pixel outside the logo was written");
        end

        if (errors == 0)
            $display("PASS: boot_logo %0d pixels, all matching the User Flash image", writes);
        else
            $display("FAILED with %0d error(s)", errors);
        $finish;
    end
endmodule
