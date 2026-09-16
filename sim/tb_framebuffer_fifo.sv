`timescale 1ns/1ps
module tb_framebuffer_fifo;
 reg reset=1,wclk=0,rclk=0,we=0,re=0;
 reg [31:0] data=0;
 wire [31:0] q;
 wire empty,full,ae,af;
 integer written=0,received=0,round;
 always #6 wclk=~wclk;
 always #17 rclk=~rclk;
 FramebufferFifo dut(.Reset(reset),.Data(data),.WrClk(wclk),.WrEn(we),
 .RdClk(rclk),.RdEn(re),.Q(q),.Empty(empty),.Full(full),.Almost_Empty(ae),.Almost_Full(af));
 always @(posedge wclk) if(!reset && we && !full) written=written+1;
 always @(posedge rclk) if(!reset && re && !empty) begin
   if(q!==received) $fatal(1,"FIFO data %h expected %h",q,received);
   received=received+1;
 end
 initial begin
   #101;reset=0;repeat(8) @(negedge wclk);
   // Fill completely, attempt overflow, drain, and wrap both pointers repeatedly.
   for(round=0;round<5;round=round+1) begin
     repeat(512) begin @(negedge wclk);data=written;we=1;end
     @(negedge wclk);
     if(!full || written!=(round+1)*512) $fatal(1,"Full boundary");
     repeat(12) begin data=32'hDEADBEEF;@(negedge wclk);end
     if(written!=(round+1)*512) $fatal(1,"Overflow");
     we=0;@(negedge rclk);re=1;
     wait(received==written);@(negedge rclk);
     if(!empty) $fatal(1,"Empty boundary");
     repeat(12) @(negedge rclk);
     re=0;repeat(8) @(negedge wclk);
     if(full) $fatal(1,"Full failed to release");
   end
   // Simultaneous producer and slower consumer; exercise full backpressure.
   @(negedge rclk);re=1;
   while(written<10000) begin @(negedge wclk);data=written;we=1;end
   @(negedge wclk);we=0;
   wait(received==written);@(negedge rclk);re=0;
   if(!empty) $fatal(1,"Final empty");
   $display("PASS: framebuffer_fifo %0d ordered words, full/empty, wrap and concurrent clocks",received);
   $finish;
 end
 initial begin #2000000;$fatal(1,"FIFO timeout");end
endmodule
