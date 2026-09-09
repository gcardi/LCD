module TOP
(
	input			Reset_Button,
    //input           User_Button,
    input           XTAL_IN,
    input wire      SPI_SCK,
    input wire      SPI_CS_N,
    input wire      SPI_MOSI,
    output wire     SPI_MISO,

	output			LCD_CLK,
	output			LCD_HYNC,
	output			LCD_SYNC,
	output			LCD_DEN,
	output	[4:0]	LCD_R,
	output	[5:0]	LCD_G,
	output	[4:0]	LCD_B,

	// Internal SiP connections between the FPGA fabric and PSRAM.
	output wire [0:0] O_psram_ck,
	output wire [0:0] O_psram_ck_n,
	inout  wire [7:0] IO_psram_dq,
	inout  wire [0:0] IO_psram_rwds,
	output wire [0:0] O_psram_cs_n,
	output wire [0:0] O_psram_reset_n

);

	logic memory_clk;
	logic psram_pll_lock;
	logic lcd_pll_lock;
	logic psram_clk;       // clk_out = 81 MHz
	logic init_calib;

	// Reset tree. Reset_Button is asynchronous to every clock here, and both
	// PLL outputs are meaningless until they lock, so the release is gated on
	// both locks and then retimed separately into each domain.
	wire global_rst_n = Reset_Button & psram_pll_lock & lcd_pll_lock;
    wire psram_rst_n;
    wire font_rst_n;
    wire spi_miso_data, spi_miso_enable;
    wire update_valid, update_take;
    wire [20:0] update_addr;
    wire [255:0] update_data;
    wire [15:0] update_mask;
    localparam SPI_FRAMEBUFFER = 1;
    generate if (SPI_FRAMEBUFFER) begin : graphics
    wire direct_valid,direct_take,text_command_valid,text_command_take;
    wire [20:0] direct_addr,text_update_addr;
    wire [255:0] direct_data,text_update_data;
    wire [15:0] direct_mask,text_update_mask;
    wire [1:0] text_font_id;
    wire [7:0] text_flags;
    wire [8:0] text_x,text_y,text_box_height;
    wire [9:0] text_box_width;
    wire [15:0] text_foreground,text_background;
    wire [6:0] text_length;
    wire [5:0] text_read_address;
    wire [7:0] text_read_data;
    wire fonts_ready,fonts_error,flash_request,flash_ready,flash_valid;
    wire [14:0] flash_address;
    wire [31:0] flash_data;
    wire text_update_valid_slow,text_update_valid_fast,text_update_take_slow;
    reg text_update_valid_fast1,text_update_valid_fast2,text_update_ack_fast;
    (* async_reg = "true" *) reg text_update_ack_slow1,text_update_ack_slow2;
    SpiFramebuffer spi_framebuffer (
        .rst_n(global_rst_n), .sck(SPI_SCK), .cs_n(SPI_CS_N),
        .mosi(SPI_MOSI), .miso(spi_miso_data), .miso_oe(spi_miso_enable),
        .clk(psram_clk), .mem_rst_n(psram_rst_n),
        .valid(direct_valid), .take(direct_take), .address(direct_addr),
        .pixels(direct_data), .mask(direct_mask),.text_clk(XTAL_IN),
        .text_rst_n(font_rst_n),.text_enabled(fonts_ready),
        .text_valid(text_command_valid),.text_take(text_command_take),
        .text_font_id(text_font_id),.text_flags(text_flags),.text_x(text_x),.text_y(text_y),
        .text_box_width(text_box_width),.text_box_height(text_box_height),
        .text_foreground(text_foreground),.text_background(text_background),
        .text_length(text_length),.text_read_address(text_read_address),
        .text_read_data(text_read_data)
    );
    FontStore font_store(
        .clk(XTAL_IN),.rst_n(font_rst_n),.fonts_ready(fonts_ready),
        .fonts_error(fonts_error),.read_request(flash_request),
        .read_address(flash_address),.read_ready(flash_ready),
        .read_valid(flash_valid),.read_data(flash_data));
    TextRenderer text_renderer(
        .clk(XTAL_IN),.rst_n(font_rst_n),.fonts_ready(fonts_ready),
        .command_valid(text_command_valid),.command_take(text_command_take),
        .command_font_id(text_font_id),.command_flags(text_flags),
        .command_x(text_x),.command_y(text_y),.command_box_width(text_box_width),
        .command_box_height(text_box_height),.command_foreground(text_foreground),
        .command_background(text_background),.command_length(text_length),
        .text_read_address(text_read_address),.text_read_data(text_read_data),
        .flash_request(flash_request),
        .flash_address(flash_address),.flash_ready(flash_ready),
        .flash_valid(flash_valid),.flash_data(flash_data),
        .update_valid(text_update_valid_slow),.update_take(text_update_take_slow),
        .update_address(text_update_addr),.update_data(text_update_data),
        .update_mask(text_update_mask));
    always @(posedge psram_clk or negedge psram_rst_n) begin
      if(!psram_rst_n) begin
        text_update_valid_fast1<=0;text_update_valid_fast2<=0;text_update_ack_fast<=0;
      end else begin
        text_update_valid_fast1<=text_update_valid_slow;
        text_update_valid_fast2<=text_update_valid_fast1;
        if(!text_update_ack_fast && text_update_valid_fast2 && update_take && !direct_valid)
          text_update_ack_fast<=1;
        else if(text_update_ack_fast && !text_update_valid_fast2)
          text_update_ack_fast<=0;
      end
    end
    always @(posedge XTAL_IN or negedge font_rst_n) begin
      if(!font_rst_n) begin text_update_ack_slow1<=0;text_update_ack_slow2<=0;end
      else begin
        text_update_ack_slow1<=text_update_ack_fast;
        text_update_ack_slow2<=text_update_ack_slow1;
      end
    end
    assign text_update_valid_fast=text_update_valid_fast2 && !text_update_ack_fast;
    assign text_update_take_slow=text_update_ack_slow2;
    assign update_valid=direct_valid || text_update_valid_fast;
    assign update_addr=direct_valid?direct_addr:text_update_addr;
    assign update_data=direct_valid?direct_data:text_update_data;
    assign update_mask=direct_valid?direct_mask:text_update_mask;
    assign direct_take=update_take && direct_valid;
    end else begin : diagnostic
    assign update_valid = 0;
    assign update_addr = 0;
    assign update_data = 0;
    assign update_mask = 0;
    SpiDiagnostic #(.MODE(0)) spi_diagnostic (
        .rst_n(global_rst_n), .sck(SPI_SCK), .cs_n(SPI_CS_N),
        .mosi(SPI_MOSI), .miso(spi_miso_data), .miso_oe(spi_miso_enable)
    );
    end endgenerate
    assign SPI_MISO = spi_miso_enable ? spi_miso_data : 1'bz;


	wire lcd_rst_n;

	// PSRAM user interface.
	logic [31:0] wr_data;
	wire [31:0] rd_data;
	wire        rd_data_valid;
	logic [20:0] addr;
	logic        cmd;
	logic        cmd_en;
	logic  [3:0] data_mask;

	// Dual-clock framebuffer FIFO.
	wire [31:0] fifo_write_data;
	wire        fifo_write_enable;
	wire [31:0] fifo_read_data;
	wire        fifo_read_enable;
	wire        fifo_almost_empty;
	wire        fifo_almost_full;
	wire        fifo_empty;
	wire        fifo_full;

	// Per-frame resynchronisation between the raster and the read pointer.
	wire fifo_flush;
	wire frame_restart_lcd;
	wire frame_restart_psram;

    Gowin_rPLL Gowin_rPLL_9Mhz(
        .clkout(LCD_CLK), // 9MHz
        .lock(lcd_pll_lock),
        .clkin(XTAL_IN)   //27MHz
    );


	Gowin_rPLL_PSRAM psram_pll_inst (
		.clkout (memory_clk),
		.lock   (psram_pll_lock),
		.clkin  (XTAL_IN)
	);

	PSRAM_Memory_Interface_HS_Top psram_inst (
		.clk            (XTAL_IN),
		.memory_clk     (memory_clk),
		.pll_lock       (psram_pll_lock),
		// Left on the raw button on purpose: the IP takes pll_lock separately
		// and synchronises rst_n internally, so it is characterised this way.
		.rst_n          (Reset_Button),

		// Porte interne SiP
		.O_psram_ck      (O_psram_ck),
		.O_psram_ck_n    (O_psram_ck_n),
		.IO_psram_dq     (IO_psram_dq),
		.IO_psram_rwds   (IO_psram_rwds),
		.O_psram_cs_n    (O_psram_cs_n),
		.O_psram_reset_n (O_psram_reset_n),

		// Interfaccia utente
		.wr_data         (wr_data),
		.rd_data         (rd_data),
		.rd_data_valid   (rd_data_valid),
		.addr            (addr),
		.cmd             (cmd),
		.cmd_en          (cmd_en),
		.data_mask       (data_mask),

		.init_calib      (init_calib),
		.clk_out         (psram_clk)
	);

	ResetSynchronizer psram_reset_sync (
		.clk         (psram_clk),
		.async_rst_n (global_rst_n),
		.sync_rst_n  (psram_rst_n)
	);

	ResetSynchronizer font_reset_sync (
		.clk         (XTAL_IN),
		.async_rst_n (global_rst_n),
		.sync_rst_n  (font_rst_n)
	);

	ResetSynchronizer lcd_reset_sync (
		.clk         (LCD_CLK),
		.async_rst_n (global_rst_n),
		.sync_rst_n  (lcd_rst_n)
	);

	// The vertical blanking pulse is born on LCD_CLK and consumed on psram_clk.
	PulseSynchronizer frame_restart_sync (
		.src_clk   (LCD_CLK),
		.src_rst_n (lcd_rst_n),
		.src_pulse (frame_restart_lcd),
		.dst_clk   (psram_clk),
		.dst_rst_n (psram_rst_n),
		.dst_pulse (frame_restart_psram)
	);

	FramebufferController framebuffer_controller_inst (
		.clk              (psram_clk),
		.nRST             (psram_rst_n),
		.init_calib       (init_calib),

		.wr_data          (wr_data),
		.rd_data          (rd_data),
		.rd_data_valid    (rd_data_valid),
		.addr             (addr),
		.cmd              (cmd),
		.cmd_en           (cmd_en),
		.data_mask        (data_mask),

		.fifo_almost_full(fifo_almost_full),
		.fifo_full       (fifo_full),
		.fifo_write_data (fifo_write_data),
		.fifo_write_enable(fifo_write_enable),
		.frame_restart    (frame_restart_psram),
		.fifo_flush       (fifo_flush),
        .update_valid(update_valid), .update_take(update_take),
        .update_addr(update_addr), .update_data(update_data), .update_mask(update_mask)
	);

	FramebufferFifo framebuffer_fifo_inst (
		.Data         (fifo_write_data),
		// RESET_SYNC is enabled on this IP, so it retimes the release into
		// each of its own clock domains.
		.Reset        (~global_rst_n | fifo_flush),
		.WrClk        (psram_clk),
		.RdClk        (LCD_CLK),
		.WrEn         (fifo_write_enable),
		.RdEn         (fifo_read_enable),
		.Almost_Empty (fifo_almost_empty),
		.Almost_Full  (fifo_almost_full),
		.Q            (fifo_read_data),
		.Empty        (fifo_empty),
		.Full         (fifo_full)
	);

	VGA_Timing	VGA_timing_inst(
		.PixelClk	(	LCD_CLK		),
		.nRST		(	lcd_rst_n	),
		.PixelWord     (	fifo_read_data),
		.PixelEmpty    (	fifo_empty),
		.PixelAlmostEmpty(	fifo_almost_empty),
		.PixelReadEnable(	fifo_read_enable),
		.FrameRestart	(	frame_restart_lcd),

		.LCD_DE		(	LCD_DEN	 	),
		.LCD_HSYNC	(	LCD_HYNC 	),
    	.LCD_VSYNC	(	LCD_SYNC 	),

		.LCD_B		(	LCD_B		),
		.LCD_G		(	LCD_G		),
		.LCD_R		(	LCD_R		)
	);

endmodule
