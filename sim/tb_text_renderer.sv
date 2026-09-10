`timescale 1ns/1ps
module tb_text_renderer;
 reg clk=0,rst=0,command_valid=0,kind=0;always #6 clk=~clk;
 reg [1:0] font_id=1;reg [7:0] flags=0;reg [8:0] x=5,y=7;
 reg [9:0] box_width=12;reg [8:0] box_height=24;
 reg [15:0] foreground=16'hF800,background=16'h001F;
 reg [6:0] length=1;wire [5:0] text_read_address;reg [7:0] text_read_data=0;
 always @(posedge clk)text_read_data<=text_read_address==0?8'h41:8'h00;
 wire fonts_ready,fonts_error,flash_request,flash_ready,flash_valid;
 wire [14:0] flash_address;wire [31:0] flash_data;
 wire command_take,update_valid;wire [20:0] update_address;
 wire [255:0] update_data;wire [15:0] update_mask;
 FontStore store(.clk(clk),.rst_n(rst),.fonts_ready(fonts_ready),.fonts_error(fonts_error),
  .read_request(flash_request),.read_address(flash_address),.read_ready(flash_ready),
  .read_valid(flash_valid),.read_data(flash_data));
 TextRenderer renderer(.clk(clk),.rst_n(rst),.fonts_ready(fonts_ready),
  .command_valid(command_valid),.command_take(command_take),.command_kind(kind),
  .command_font_id(font_id),
  .command_flags(flags),.command_x(x),.command_y(y),.command_box_width(box_width),
  .command_box_height(box_height),.command_foreground(foreground),
  .command_background(background),.command_length(length),
  .text_read_address(text_read_address),.text_read_data(text_read_data),
  .flash_request(flash_request),.flash_address(flash_address),.flash_ready(flash_ready),
  .flash_valid(flash_valid),.flash_data(flash_data),.update_valid(update_valid),
  .update_take(update_valid),.update_address(update_address),.update_data(update_data),
  .update_mask(update_mask));
 reg [15:0] framebuffer[0:130559];integer i,row,column;
 always @(posedge clk) if(update_valid)
   for(i=0;i<16;i=i+1) if(update_mask[i])
     framebuffer[update_address+i]<=update_data[i*16 +: 16];
 function automatic [15:0] a_row(input integer r);
   begin case(r)
     4:a_row=16'h1F00;5:a_row=16'h2080;
     6,7,8,9,10,11:a_row=16'h4040;12:a_row=16'h7FC0;
     13,14,15,16,17,18:a_row=16'h4040;default:a_row=0;
   endcase end
 endfunction
 initial begin
   for(i=0;i<130560;i=i+1) framebuffer[i]=16'hDEAD;
   #50;rst=1;wait(fonts_ready || fonts_error);if(fonts_error)$fatal(1,"font CRC");
   @(negedge clk);command_valid=1;wait(command_take);@(negedge clk);command_valid=0;
   repeat(4)@(posedge clk);
   for(row=0;row<24;row=row+1) for(column=0;column<12;column=column+1)
     if(framebuffer[(7+row)*480+5+column] !==
        ((a_row(row)&(16'h8000>>column))?16'hF800:16'h001F))
       $fatal(1,"pixel row=%d col=%d value=%h",row,column,
              framebuffer[(7+row)*480+5+column]);
   for(row=0;row<24;row=row+1)
     if(framebuffer[(7+row)*480+4]!==16'hDEAD ||
        framebuffer[(7+row)*480+17]!==16'hDEAD)$fatal(1,"clip/mask edge");

   // --- Riempimento B9: rettangolo disallineato rispetto ai gruppi da 16 ---
   for(i=0;i<130560;i=i+1) framebuffer[i]=16'hDEAD;
   kind=1;font_id=0;x=5;y=7;box_width=30;box_height=5;foreground=16'h07E0;
   @(negedge clk);command_valid=1;wait(command_take);@(negedge clk);command_valid=0;
   repeat(4)@(posedge clk);
   for(row=0;row<5;row=row+1) for(column=0;column<30;column=column+1)
     if(framebuffer[(7+row)*480+5+column]!==16'h07E0)
       $fatal(1,"fill row=%0d col=%0d value=%h",row,column,
              framebuffer[(7+row)*480+5+column]);
   for(row=0;row<5;row=row+1)
     if(framebuffer[(7+row)*480+4]!==16'hDEAD ||
        framebuffer[(7+row)*480+35]!==16'hDEAD)$fatal(1,"fill bordo orizzontale");
   if(framebuffer[6*480+5]!==16'hDEAD || framebuffer[12*480+5]!==16'hDEAD)
     $fatal(1,"fill bordo verticale");

   // --- Clipping: il rettangolo sborda a destra e in basso ---
   for(i=0;i<130560;i=i+1) framebuffer[i]=16'hDEAD;
   kind=1;x=470;y=268;box_width=30;box_height=10;foreground=16'hF81F;
   @(negedge clk);command_valid=1;wait(command_take);@(negedge clk);command_valid=0;
   repeat(4)@(posedge clk);
   for(row=0;row<4;row=row+1) for(column=470;column<480;column=column+1)
     if(framebuffer[(268+row)*480+column]!==16'hF81F)
       $fatal(1,"clip row=%0d col=%0d value=%h",row,column,
              framebuffer[(268+row)*480+column]);
   // Sbordare a destra si vedrebbe come inizio della riga successiva sporcato.
   for(row=269;row<272;row=row+1)
     if(framebuffer[row*480]!==16'hDEAD)$fatal(1,"clip: sbordo a destra");
   if(framebuffer[267*480+470]!==16'hDEAD)$fatal(1,"clip: sbordo in alto");

   // --- Schermo intero, cioe' il caso LCD_Clear: 0 significa fino al bordo ---
   for(i=0;i<130560;i=i+1) framebuffer[i]=16'hDEAD;
   kind=1;x=0;y=0;box_width=0;box_height=0;foreground=16'h1234;
   @(negedge clk);command_valid=1;wait(command_take);@(negedge clk);command_valid=0;
   repeat(4)@(posedge clk);
   for(i=0;i<130560;i=i+1)
     if(framebuffer[i]!==16'h1234)$fatal(1,"clear: pixel %0d vale %h",i,framebuffer[i]);

   $display("PASS: text_renderer glyph, and B9 fill unaligned, clipped and full screen");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
