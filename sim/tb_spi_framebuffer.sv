`timescale 1ns/1ps
module tb_spi_framebuffer;
 reg clk=0,rst=1,sck=0,cs=1,mosi=0,allow=0,restart=0;
 always #6 clk=~clk;
 wire miso,oe,valid,take; wire [20:0] address,addr;
 wire [255:0] pixels; wire [15:0] mask;
 wire [31:0] wd; wire cmd,en;wire [3:0] dm;
 SpiFramebuffer endpoint(rst,sck,cs,mosi,miso,oe,clk,rst,valid,take,address,pixels,mask);
 FramebufferController controller(.clk(clk),.nRST(rst),.init_calib(1'b1),
 .frame_restart(restart),.wr_data(wd),.rd_data(32'd0),.rd_data_valid(1'b0),
 .addr(addr),.cmd(cmd),.cmd_en(en),.data_mask(dm),.fifo_almost_full(1'b1),
 .fifo_full(1'b0),.fifo_write_data(),.fifo_write_enable(),.fifo_flush(),
 .update_valid(valid && allow),.update_take(take),.update_addr(address),
 .update_data(pixels),.update_mask(mask));
 reg [15:0] memory[0:130559];
 integer beat=0,base=0,writes=0;reg writing=0;
 always @(posedge clk) if(rst) begin
   if(en && cmd) begin
      if(writing) $fatal(1,"overlapping write");
      base=addr;beat=0;writing=1;writes=writes+1;
   end
   if(writing) begin
      if(!dm[0] && !dm[1]) memory[base+beat*2]=wd[15:0];
      if(!dm[2] && !dm[3]) memory[base+beat*2+1]=wd[31:16];
      if(beat==7) writing=0;else beat=beat+1;
   end
 end
 task byte_io(input [7:0] value,output [7:0] reply);
   integer b;begin
     for(b=7;b>=0;b=b-1) begin
       mosi=value[b];#40;sck=1;reply[b]=miso;#40;sck=0;
     end
   end
 endtask
 reg [7:0] r;integer i;reg [15:0] before0,before15;
 task packet(input [23:0] a,input integer count,input [7:0] status);
 begin
   cs=0;#100;byte_io(8'hB7,r);if(r!=8'hA5)$fatal(1,"identity");
   byte_io(0,r);if(r!=status)$fatal(1,"status %h expected %h",r,status);
   byte_io(a[23:16],r);byte_io(a[15:8],r);byte_io(a[7:0],r);
   byte_io(8'h7F,r);byte_io(8'hFE,r);
   for(integer j=0;j<count;j=j+1) byte_io(j+1,r);
   if(count==32) begin byte_io(8'h5A,r);byte_io(0,r);
     if(r != ((status==8'hC3 && a<130560 && a[3:0]==0)?8'hAC:8'hE1)) $fatal(1,"commit %h",r);
   end
   #100;cs=1;#100;
 end endtask
 initial begin
   #1;rst=0;#100;rst=1;#100;sck=1;#40;sck=0;#40;sck=1;#40;sck=0;
   wait(writes==8160 && !writing);#1000;
   before0=memory[496];before15=memory[511];
   packet(496,5,8'hC3);#200;if(valid)$fatal(1,"partial committed");
   packet(497,32,8'hC3);#200;if(valid)$fatal(1,"unaligned committed");
   packet(130560,32,8'hC3);#200;if(valid)$fatal(1,"out of bounds");
   packet(496,32,8'hC3);#200;if(!valid)$fatal(1,"missing request");
   packet(512,32,0);if(address!=496)$fatal(1,"busy overwrote packet");
   allow=1;wait(take);@(negedge clk);restart=1;
   @(negedge clk);restart=0;#2000;
   if(writes!=8161)$fatal(1,"write count %d",writes);
   if(memory[496]!=before0 || memory[511]!=before15)$fatal(1,"masked edges changed");
   for(i=1;i<15;i=i+1) if(memory[496+i] != ((2*i+2)*256+2*i+1))$fatal(1,"pixel %d = %h",i,memory[496+i]);
   packet(512,32,8'hC3);#2000;if(writes!=8162)$fatal(1,"queue failed reuse");
   // Partial byte abort must leave the next command aligned.
   cs=0;#100;mosi=1;#40;sck=1;#40;sck=0;cs=1;#100;
   packet(528,32,8'hC3);#2000;if(writes!=8163)$fatal(1,"abort recovery");
   $display("PASS: spi_framebuffer masks, bounds, busy, abort, CDC, restart and PSRAM beats");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule


