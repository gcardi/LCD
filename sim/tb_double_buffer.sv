`timescale 1ns/1ps
module tb_double_buffer;
 reg xtal=0,rst=1,mcu_rst=1,sck=0,cs=1,mosi=0;
 always #18.5185 xtal=~xtal;
 wire miso,irq,lcd_clk,de,hs,vs;wire [4:0] r,b;wire [5:0] g;
 TOP dut(.Reset_Button(rst),.FPGA_RST_N(mcu_rst),.XTAL_IN(xtal),.SPI_SCK(sck),.SPI_CS_N(cs),
   .SPI_MOSI(mosi),.SPI_MISO(miso),.FPGA_IRQ_N(irq),.LCD_CLK(lcd_clk),
   .LCD_DEN(de),.LCD_HYNC(hs),.LCD_SYNC(vs),.LCD_R(r),.LCD_G(g),.LCD_B(b));
 reg [7:0] reply,st[0:10];integer irq_edges=0,checked_frames=0,pixel_count=0;
 integer raster_phase=0,reference_phase,px,py,front_at_start=0;
 reg [15:0] expected_frame[0:130559];
 reg [15:0] boot_frame[0:130559];
 reg check_frame=0;integer restarts=0;
 always @(negedge irq) if(rst) irq_edges=irq_edges+1;
 // Independent raster coordinates, with one-cycle registered video outputs.
 always @(posedge lcd_clk) begin
   // restarts too: the first frame after any reset, not only power-on, is
   // skipped, because the controller is still redoing the initial fill.
   if(!dut.lcd_rst_n) begin raster_phase=0;check_frame=0;pixel_count=0;restarts=0;end
   else begin
     reference_phase=raster_phase;
     raster_phase=(raster_phase==166617)?0:raster_phase+1;
     px=reference_phase%561;py=reference_phase/561;
     if(reference_phase==277*561) begin
       restarts=restarts+1;
       if(check_frame) begin
         if(pixel_count!=130560)$fatal(1,"pixel count %d",pixel_count);
         checked_frames=checked_frames+1;
         $display("double_buffer frame %0d verified, front=%0d",checked_frames,front_at_start);
       end
       pixel_count=0;check_frame=0;
     end
     if(px==30 && py==5 && restarts>0) begin
       front_at_start=dut.framebuffer_controller_inst.front_buffer;
       for(integer i=0;i<130560;i=i+1)
         expected_frame[i]=dut.psram_inst.fb[front_at_start*131072+i];
       check_frame=1;
     end
     #1;
     if(check_frame && px>=30 && px<510 && py>=5 && py<277) begin
       if(!de || {r,g,b}!==expected_frame[(py-5)*480+px-30])
         $fatal(1,"scanout mismatch frame=%0d xy=%0d,%0d actual=%h expected=%h",
           checked_frames,px-30,py-5,{r,g,b},expected_frame[(py-5)*480+px-30]);
       pixel_count=pixel_count+1;
     end
   end
 end
 reg old_front=0,boundary,boundary_delayed=0;
 always @(posedge dut.psram_clk) if(!dut.psram_rst_n) old_front=0; else begin
   // The controller registers the synchronized pulse once before arbitration.
   // Track that one-cycle latency independently of the controller register.
   boundary=boundary_delayed;
   boundary_delayed=dut.frame_restart_psram;
   #1;
   if(old_front!=dut.framebuffer_controller_inst.front_buffer && !boundary)
     $fatal(1,"swap outside a fresh frame boundary");
   old_front=dut.framebuffer_controller_inst.front_buffer;
   if(dut.cmd_en && dut.cmd && dut.framebuffer_controller_inst.double_enabled &&
      dut.addr[17]==old_front)$fatal(1,"write into visible front buffer");
   if(!irq && (dut.psram_inst.wbusy || dut.fifo_flush))$fatal(1,"IRQ before write/flush completion");
 end
 function automatic [15:0] crc_byte(input [15:0] crc,input [7:0] value);
   reg [15:0] c;begin c=crc^{value,8'd0};
     for(integer i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1;
     crc_byte=c;end
 endfunction
 task byte_io(input [7:0] value,output [7:0] received);
   begin received=0;
     for(integer i=7;i>=0;i=i-1)begin
       mosi=value[i];#40;sck=1;#1;received[i]=miso;#39;sck=0;
     end
   end
 endtask
 task status;
   reg [15:0] crc;begin
     cs=0;#1000;byte_io(8'hBB,st[0]);
     for(integer i=1;i<11;i=i+1)byte_io(0,st[i]);
     #1000;cs=1;#1000;
     if(st[0]!=8'hA5 || st[1]!=8'hD2 || st[2]!=3 || st[3]!=2)$fatal(1,"status identity");
     crc=16'hFFFF;for(integer i=1;i<=8;i=i+1)crc=crc_byte(crc,st[i]);
     if({st[9],st[10]}!=crc)$fatal(1,"status CRC");
   end
 endtask
 task idle(input [7:0] result);
   begin
     status();while(st[4][3])begin #100000;status();end
     if(st[8]!=result)$fatal(1,"control result %h expected %h",st[8],result);
   end
 endtask
 task control(input [7:0] op,buffer,input [15:0] seq,
              input bit corrupt,input integer length,input [7:0] ready_value,commit_value);
   reg [7:0] bytes[0:9];reg [15:0] crc;begin
     bytes[0]=8'hBA;bytes[1]=0;bytes[2]=op;bytes[3]=buffer;
     bytes[4]=seq[15:8];bytes[5]=seq[7:0];crc=16'hFFFF;
     for(integer i=2;i<=5;i=i+1)crc=crc_byte(crc,bytes[i]);
     bytes[6]=crc[15:8]^{7'd0,corrupt};bytes[7]=crc[7:0];bytes[8]=8'hA6;bytes[9]=0;
     cs=0;#1000;
     for(integer i=0;i<length;i=i+1)begin byte_io(bytes[i],reply);
       if(i==0 && reply!=8'hA5)$fatal(1,"control identity");
       if(i==1 && reply!=ready_value)$fatal(1,"control ready %h",reply);
       if(i==9 && reply!=commit_value)$fatal(1,"control commit %h expected %h",reply,commit_value);
     end
     #1000;cs=1;#1000;
   end
 endtask
 task poll(input [7:0] opcode,input [7:0] expected);
   begin cs=0;#1000;byte_io(opcode,reply);byte_io(0,reply);#1000;cs=1;#1000;
     if(reply!=expected)$fatal(1,"poll %h returned %h expected %h",opcode,reply,expected);
   end
 endtask
 task fill(input [15:0] color,input [7:0] expected_ready,expected_commit);
   reg [7:0] bytes[0:17];reg [15:0] crc;begin
     for(integer i=0;i<18;i=i+1)bytes[i]=0;
     bytes[0]=8'hB9;bytes[8]=1;bytes[9]=8'hE0;bytes[10]=1;bytes[11]=8'h10;
     bytes[12]=color[15:8];bytes[13]=color[7:0];crc=16'hFFFF;
     for(integer i=2;i<=13;i=i+1)crc=crc_byte(crc,bytes[i]);
     bytes[14]=crc[15:8];bytes[15]=crc[7:0];bytes[16]=8'hA6;
     cs=0;#1000;
     for(integer i=0;i<18;i=i+1)begin byte_io(bytes[i],reply);
       if(i==1 && reply!=expected_ready)$fatal(1,"fill ready");
       if(i==17 && reply!=expected_commit)$fatal(1,"fill commit %h",reply);
     end
     #1000;cs=1;#1000;
   end
 endtask
 task audit(input integer slot,input [15:0] color);
   begin for(integer i=0;i<130560;i=i+1)
     if(dut.psram_inst.fb[slot*131072+i]!==color)$fatal(1,"memory slot %0d pixel %0d",slot,i);
   end
 endtask
 task capture_boot;
   integer changed;begin changed=0;
     for(integer i=0;i<130560;i=i+1)begin
       boot_frame[i]=dut.psram_inst.fb[i];
       if(boot_frame[i]!==16'h0000)changed=changed+1;
     end
     if(changed==0)$fatal(1,"boot logo did not change the cleared frame");
   end
 endtask
 task audit_boot(input integer slot);
   begin for(integer i=0;i<130560;i=i+1)
     if(dut.psram_inst.fb[slot*131072+i]!==boot_frame[i])
       $fatal(1,"boot frame slot %0d pixel %0d",slot,i);
   end
 endtask
 task wait_shape;
   begin
     do begin cs=0;#1000;byte_io(8'hB9,reply);byte_io(0,reply);
       #1000;cs=1;#1000;
     end while(reply==0);
     if(reply!=8'hC3)$fatal(1,"shape ready failed");
   end
 endtask
 task last_pixel;
   begin
     cs=0;#1000;byte_io(8'hB7,reply);byte_io(0,reply);
     if(reply!=8'hC3)$fatal(1,"B7 unavailable");
     byte_io(1,reply);byte_io(8'hFD,reply);byte_io(8'hF0,reply); // 130544
     byte_io(8'h80,reply);byte_io(0,reply); // only pixel 15
     for(integer i=0;i<16;i=i+1)begin byte_io(8'h1F,reply);byte_io(0,reply);end
     byte_io(8'h5A,reply);byte_io(0,reply);
     if(reply!=8'hAC)$fatal(1,"B7 commit");
     #1000;cs=1;#1000;
   end
 endtask
 task text_a;
   reg [7:0] bytes[0:21];reg [15:0] crc;begin
     for(integer i=0;i<22;i=i+1)bytes[i]=0;
     bytes[0]=8'hB8;bytes[5]=7;bytes[7]=5;bytes[9]=8;bytes[11]=16;
     bytes[12]=8'hFF;bytes[13]=8'hFF;bytes[14]=0;bytes[15]=8'h1F;
     bytes[16]=1;bytes[17]=8'h41;crc=16'hFFFF;
     for(integer i=2;i<=17;i=i+1)crc=crc_byte(crc,bytes[i]);
     bytes[18]=crc[15:8];bytes[19]=crc[7:0];bytes[20]=8'hA6;
     cs=0;#1000;
     for(integer i=0;i<22;i=i+1)begin byte_io(bytes[i],reply);
       if(i==1 && reply!=8'hC3)$fatal(1,"text ready");
       if(i==21 && reply!=8'hAC)$fatal(1,"text commit");
     end
     #1000;cs=1;#1000;
   end
 endtask
`ifdef BLIT_TEST
 `include "sim/blit_cases.svh"
`endif
 initial begin
   // The reset request filter ignores anything shorter than 1 ms, so the
   // power-on press has to last longer than that: 2 ms, like a real key.
   #1;rst=0;#2000000;rst=1;
   // SCK resynchronizer startup, as on STM32.
   repeat(3)begin #40;sck=1;#40;sck=0;end
   wait(dut.graphics.fonts_ready);wait(dut.framebuffer_controller_inst.state==4);
   // Font validation precedes the logo.  BB must expose that interval as busy
   // and direct graphics must remain unavailable, otherwise an MCU flush can
   // race the boot painter and be overwritten afterwards.
   status();if(st[4]!=8'h18 || st[5]!=0)$fatal(1,"logo boot barrier expected");
   poll(8'hB7,0);poll(8'hB9,0);
   wait(dut.graphics.boot_complete);
   repeat(3)begin #40;sck=1;#40;sck=0;end
   capture_boot();status();if(st[4]!=8'h10 || st[5]!=0)$fatal(1,"reset state, reset_seen expected");
   control(6,1,0,0,10,8'hC3,8'hE1); // ACK_RESET: reserved buffer
   control(6,0,1,0,10,8'hC3,8'hE1); // ACK_RESET: reserved sequence
   control(6,0,0,0,10,8'hC3,8'hAC);idle(0);
   if(st[4]!=0)$fatal(1,"ACK_RESET did not clear reset_seen");
   control(1,0,0,1,10,8'hC3,8'hE1); // corrupt CRC
   control(4,0,0,0,10,8'hC3,8'hE1); // unknown op
   control(1,1,0,0,10,8'hC3,8'hE1); // reserved field
   control(1,0,1,0,10,8'hC3,8'hE1); // reserved sequence
   for(integer n=2;n<=8;n=n+1)control(1,0,0,0,n,8'hC3,0);
   status();if(st[4]!=0)$fatal(1,"aborted packet executed");
   control(2,1,1,0,10,8'hC3,8'hAC);idle(8'hE1); // not enabled
   control(1,0,0,0,10,8'hC3,8'hAC);idle(0);
   if(st[4]!=1 || st[5]!=1)$fatal(1,"enable state");
   fill(16'hF800,8'hC3,8'hAC);
   control(2,1,1,0,10,8'hC3,8'hAC); // renderer still working
   status();if(!st[4][3] || !irq)$fatal(1,"PRESENT failed to wait for renderer");
   poll(8'hB7,0);poll(8'hB8,0);poll(8'hB9,0);
   fill(16'hFFFF,0,8'hE1); // blocked command cannot mutate pending renderer
   control(3,0,0,0,10,0,8'hE1); // occupied control mailbox
   idle(0);if(irq || st[4]!=7 || {st[6],st[7]}!=1 || st[5]!=0)$fatal(1,"first PRESENT");
   audit(1,16'hF800);audit_boot(0);
   if(irq_edges!=1)$fatal(1,"IRQ edge count");
   control(2,1,1,0,10,8'hC3,8'hAC);idle(0); // duplicate while IRQ pending
   control(3,0,9,0,10,8'hC3,8'hAC);idle(8'hE1);
   if(irq)$fatal(1,"wrong ACK cleared IRQ");
   control(2,0,2,0,10,8'hC3,8'hAC);idle(8'hE1); // cannot overwrite pending event
   control(3,0,1,0,10,8'hC3,8'hAC);idle(0);if(!irq)$fatal(1,"ACK failed");
   control(2,1,1,0,10,8'hC3,8'hAC);idle(0); // duplicate after ACK
   if(!irq || irq_edges!=1 || st[4][1]!=1)$fatal(1,"duplicate re-presented");
   wait(checked_frames>=1);
   fill(16'h07E0,8'hC3,8'hAC);
   wait_shape();last_pixel();text_a();
   control(2,0,2,0,10,8'hC3,8'hAC);idle(0);
   audit(1,16'hF800);
   for(integer i=0;i<130560;i=i+1)begin
     if(i==130559)begin
       if(dut.psram_inst.fb[i]!==16'h001F)$fatal(1,"B7 target/mask");
     end else if(i/480>=5 && i/480<21 && i%480>=7 && i%480<15)begin
       if(dut.psram_inst.fb[i]!==16'h001F && dut.psram_inst.fb[i]!==16'hFFFF)
         $fatal(1,"B8 target/clipping");
     end else if(dut.psram_inst.fb[i]!==16'h07E0)$fatal(1,"back isolation pixel %d",i);
   end
   if(irq_edges!=2 || st[4]!=5 || {st[6],st[7]}!=2)$fatal(1,"second PRESENT");
   control(3,0,2,0,10,8'hC3,8'hAC);idle(0);
   wait(checked_frames>=3);
   // No silent aliasing of the padding between the two fixed slots.
   if(dut.psram_inst.fb[130560]!==16'hxxxx)$fatal(1,"slot padding was written");
   if(irq_edges!=2 || !irq)$fatal(1,"spurious IRQ");
`ifdef BLIT_TEST
   blit_scenario();
`endif
   // --- Reset from the MCU (FPGA_RST_N) ---
   // A short glitch must not reset: reset_seen, cleared above, stays clear.
   mcu_rst=0;#500000;mcu_rst=1;#300000;
   status();if(st[4][4])$fatal(1,"0.5 ms glitch reset the fabric");
   // A real 10 ms pulse, as the firmware sends it.
   mcu_rst=0;#3000000;
   if(dut.global_rst_n)$fatal(1,"reset request not asserted after 3 ms low");
   if(!irq)$fatal(1,"IRQ active during reset");
   #7000000;mcu_rst=1;
   wait(dut.graphics.fonts_ready);wait(dut.graphics.boot_complete);
   wait(dut.framebuffer_controller_inst.state==4);
   repeat(3)begin #40;sck=1;#40;sck=0;end
   status();if(st[4]!=8'h10 || st[5]!=0)$fatal(1,"reset proof missing after MCU reset: %h",st[4]);
   audit_boot(0); // initial fill and logo both ran again
   control(6,0,0,0,10,8'hC3,8'hAC);idle(0);
   if(st[4]!=0)$fatal(1,"ACK_RESET after MCU reset");
   if(!irq)$fatal(1,"IRQ left active after reset");
   $display("PASS: double_buffer CRC, abort, barrier, back-only writes, duplicate, ACK, full raster frames and MCU reset proof");
   $finish;
 end
 initial begin #300000000;$fatal(1,"double buffer timeout");end
endmodule

module Gowin_rPLL(input clkin,output reg clkout=0,output wire lock);
 always #55.5555 clkout=~clkout;
 assign lock=1'b1;
endmodule
module Gowin_rPLL_PSRAM(input clkin,output reg clkout=0,output wire lock);
 always #3.0864 clkout=~clkout;
 assign lock=1'b1;
endmodule
`ifndef REAL_FIFO
module FramebufferFifo(input Reset,input [31:0] Data,input WrClk,WrEn,RdClk,RdEn,
 output [31:0] Q,output Empty,Full,Almost_Empty,Almost_Full);
 fifo_model f(.*);
endmodule
`endif
// Real reads from captured PSRAM, with burst latency, write masks and recovery.
module PSRAM_Memory_Interface_HS_Top(input clk,memory_clk,pll_lock,rst_n,
 output O_psram_ck,O_psram_ck_n,O_psram_cs_n,O_psram_reset_n,
 inout [7:0] IO_psram_dq,inout IO_psram_rwds,
 input [31:0] wr_data,output reg [31:0] rd_data=0,output reg rd_data_valid=0,
 input [20:0] addr,input cmd,cmd_en,input [3:0] data_mask,
 output wire init_calib,output reg clk_out=0);
 always #6.1728 clk_out=~clk_out;
 assign init_calib=rst_n;
 reg [15:0] fb[0:262143];
 integer wbeat=0,rbeat=0,wbase=0,rbase=0,lat=0;
 reg wbusy=0,rbusy=0;
 always @(posedge clk_out) begin
   rd_data_valid<=0;
   if(!rst_n)begin wbusy=0;rbusy=0;end
   else begin
     if(cmd_en)begin
       if(wbusy || rbusy)$fatal(1,"overlapping PSRAM commands");
       if(addr[3:0]!=0 || addr>=262144)$fatal(1,"PSRAM address invalid");
       if(cmd)begin wbase=addr;wbeat=0;wbusy=1;end
       else begin rbase=addr;rbeat=0;lat=6;rbusy=1;end
     end
     if(wbusy)begin
       if(!data_mask[0])fb[wbase+2*wbeat][7:0]=wr_data[7:0];
       if(!data_mask[1])fb[wbase+2*wbeat][15:8]=wr_data[15:8];
       if(!data_mask[2])fb[wbase+2*wbeat+1][7:0]=wr_data[23:16];
       if(!data_mask[3])fb[wbase+2*wbeat+1][15:8]=wr_data[31:24];
       if(wbeat==7)wbusy=0;else wbeat=wbeat+1;
     end
     if(rbusy)begin
       if(lat!=0)lat=lat-1;
       else begin
         rd_data<={fb[rbase+2*rbeat+1],fb[rbase+2*rbeat]};rd_data_valid<=1;
         if(rbeat==7)rbusy=0;else rbeat=rbeat+1;
       end
     end
   end
 end
endmodule
