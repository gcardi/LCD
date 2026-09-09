`timescale 1ns/1ps
module tb_font_store;
 reg clk=0,rst=0,request=0;reg [14:0] address=0;
 always #6 clk=~clk;
 wire ready,error,read_ready,read_valid;wire [31:0] data;
 FontStore dut(.clk(clk),.rst_n(rst),.fonts_ready(ready),.fonts_error(error),
   .read_request(request),.read_address(address),.read_ready(read_ready),
   .read_valid(read_valid),.read_data(data));
 initial begin
   #50;rst=1;
   wait(ready || error);
   if(error)$fatal(1,"font image validation failed");
   @(posedge clk);address=15'd800;request=1;
   wait(read_ready);@(posedge clk);request=0;
   wait(read_valid);
   // First word at font 1 offset 3200: four blank rows of the space glyph.
   if(data!==32'd0)$fatal(1,"font read mismatch %h",data);
   $display("PASS: font_store header, CRC32 and client read");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
