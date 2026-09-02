module TOP
(
	input			Reset_Button,
    //input           User_Button,
    input           XTAL_IN,

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
	logic psram_clk;       // clk_out = 81 MHz
	logic init_calib;

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

    Gowin_rPLL Gowin_rPLL_9Mhz(
        .clkout(LCD_CLK), // 9MHz
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

	FramebufferController framebuffer_controller_inst (
		.clk              (psram_clk),
		.nRST             (Reset_Button),
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
		.fifo_write_enable(fifo_write_enable)
	);

	framebuffer_fifo framebuffer_fifo_inst (
		.Data         (fifo_write_data),
		.Reset        (~Reset_Button),
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
		.nRST		(	Reset_Button),
		.PixelWord     (	fifo_read_data),
		.PixelEmpty    (	fifo_empty),
		.PixelAlmostEmpty(	fifo_almost_empty),
		.PixelReadEnable(	fifo_read_enable),

		.LCD_DE		(	LCD_DEN	 	),
		.LCD_HSYNC	(	LCD_HYNC 	),
    	.LCD_VSYNC	(	LCD_SYNC 	),

		.LCD_B		(	LCD_B		),
		.LCD_G		(	LCD_G		),
		.LCD_R		(	LCD_R		)
	);

endmodule
