module VGA_Timing
(
    input                   PixelClk,
    input                   nRST,

    input           [31:0]  PixelWord,
    input                   PixelEmpty,
    input                   PixelAlmostEmpty,
    output                  PixelReadEnable,

    output                  LCD_DE,
    output                  LCD_HSYNC,
    output                  LCD_VSYNC,

	output logic    [4:0]   LCD_B,
	output logic    [5:0]   LCD_G,
	output logic    [4:0]   LCD_R
);
	
    // Horizen count to Hsync, then next Horizen line.

    parameter int unsigned H_Pixel_Valid    = 480; 
    parameter int unsigned H_FrontPorch     = 50;
    parameter int unsigned H_BackPorch      = 30;  

    parameter int unsigned PixelForHS       = H_Pixel_Valid + H_FrontPorch + H_BackPorch;

    parameter int unsigned V_Pixel_Valid    = 272; 
    parameter int unsigned V_FrontPorch     = 20;  
    parameter int unsigned V_BackPorch      = 5;    

    parameter int unsigned PixelForVS       = V_Pixel_Valid + V_FrontPorch + V_BackPorch;

    // Horizen pixel count

    logic       [15:0]  H_PixelCount;
    logic       [15:0]  V_PixelCount;

    always_ff @(  posedge PixelClk or negedge nRST  )begin
        if( !nRST ) begin
            V_PixelCount      <=  16'b0;    
            H_PixelCount      <=  16'b0;
            end
        else if(  H_PixelCount == PixelForHS ) begin
            V_PixelCount      <=  V_PixelCount + 1'b1;
            H_PixelCount      <=  16'b0;
            end
        else if(  V_PixelCount == PixelForVS ) begin
            V_PixelCount      <=  16'b0;
            H_PixelCount      <=  16'b0;
            end
        else begin
            V_PixelCount      <=  V_PixelCount ;
            H_PixelCount      <=  H_PixelCount + 1'b1;
        end
    end

    // SYNC-DE MODE
    
    assign  LCD_HSYNC = H_PixelCount <= (PixelForHS-H_FrontPorch) ? 1'b0 : 1'b1;
    
	assign  LCD_VSYNC = V_PixelCount  <= (PixelForVS-0)  ? 1'b0 : 1'b1;

    wire video_active = ( H_PixelCount >= H_BackPorch ) &&
                        ( H_PixelCount <  H_Pixel_Valid + H_BackPorch ) &&
                        ( V_PixelCount >= V_BackPorch ) &&
                        ( V_PixelCount <  V_Pixel_Valid + V_BackPorch );

    // Arm the stream one clock before the first active pixel. This keeps
    // address zero aligned with the top-left corner of the display.
    wire stream_start_window = (H_PixelCount == H_BackPorch - 1) &&
                               (V_PixelCount == V_BackPorch);

    logic stream_started;
    logic pixel_half;
    logic [15:0] pixel_rgb565;

    assign LCD_DE = video_active && PixelClk;

    // In FWFT mode PixelWord already contains the current word. Pop it while
    // its second RGB565 pixel is being consumed.
    assign PixelReadEnable = video_active && stream_started &&
                             pixel_half && !PixelEmpty;

    always_ff @(posedge PixelClk or negedge nRST) begin
        if (!nRST) begin
            stream_started <= 1'b0;
            pixel_half     <= 1'b0;
        end else if (!stream_started) begin
            pixel_half <= 1'b0;
            if (stream_start_window && !PixelAlmostEmpty)
                stream_started <= 1'b1;
        end else if (video_active && !PixelEmpty) begin
            pixel_half <= ~pixel_half;
        end else if (!video_active) begin
            pixel_half <= 1'b0;
        end
    end

    always_comb begin
        if (video_active && stream_started && !PixelEmpty) begin
            if (pixel_half)
                pixel_rgb565 = PixelWord[31:16];
            else
                pixel_rgb565 = PixelWord[15:0];
        end else begin
            pixel_rgb565 = 16'h0000;
        end

        LCD_R = pixel_rgb565[15:11];
        LCD_G = pixel_rgb565[10:5];
        LCD_B = pixel_rgb565[4:0];
    end

endmodule
