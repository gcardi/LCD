`timescale 1ns/1ps
module tb_spi_framebuffer;
 reg clk=0,rst=1,sck=0,cs=1,mosi=0,allow=0,restart=0,text_take=0,text_enabled=1;
 wire text_kind;
 always #6 clk=~clk;
 wire miso,oe,valid,take,text_valid; wire [20:0] address,addr;
 wire [255:0] pixels; wire [15:0] mask;
 wire [31:0] wd; wire cmd,en;wire [3:0] dm;
 wire [1:0] text_font;wire [7:0] text_flags;wire [8:0] text_x,text_y,text_bh;
 wire [9:0] text_bw;wire [15:0] text_fg,text_bg;wire [6:0] text_length;
 reg [5:0] text_read_address=0;wire [7:0] text_read_data;
 SpiFramebuffer endpoint(.rst_n(rst),.sck(sck),.cs_n(cs),.mosi(mosi),
 .miso(miso),.miso_oe(oe),.clk(clk),.mem_rst_n(rst),.valid(valid),.take(take),
 .address(address),.pixels(pixels),.mask(mask),.text_clk(clk),.text_rst_n(rst),
 .text_enabled(text_enabled),.text_kind(text_kind),
 .text_valid(text_valid),.text_take(text_take),.text_font_id(text_font),
 .text_flags(text_flags),.text_x(text_x),.text_y(text_y),.text_box_width(text_bw),
 .text_box_height(text_bh),.text_foreground(text_fg),.text_background(text_bg),
 .text_length(text_length),.text_read_address(text_read_address),
 .text_read_data(text_read_data));
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
       mosi=value[b];#20;sck=1;reply[b]=miso;#20;sck=0;
     end
   end
 endtask
 reg [7:0] r;integer i;reg [15:0] before0,before15;
 function automatic [15:0] crc_byte(input [15:0] current,input [7:0] value);
   integer bit_index;reg [15:0] next;begin next=current^{value,8'd0};
     for(bit_index=0;bit_index<8;bit_index=bit_index+1)
       next=next[15]?(next<<1)^16'h1021:(next<<1);
     crc_byte=next;end
 endfunction
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
 task text_packet(input wrong_crc,input [7:0] expected_reply);
   reg [15:0] crc;reg [7:0] value;integer n;begin
     crc=16'hFFFF;cs=0;#100;byte_io(8'hB8,r);if(r!=8'hA5)$fatal(1,"text identity");
     byte_io(0,r);if(r!=8'hC3)$fatal(1,"text status %h",r);
     for(n=2;n<=17;n=n+1) begin
       case(n)
         2:value=1;3:value=2;4:value=0;5:value=5;6:value=0;7:value=7;
         8:value=0;9:value=12;10:value=0;11:value=24;
         12:value=8'hF8;13:value=0;14:value=0;15:value=8'h1F;
         16:value=1;default:value=8'h41;
       endcase
       crc=crc_byte(crc,value);byte_io(value,r);
     end
     byte_io(crc[15:8]^(wrong_crc?8'h01:8'h00),r);byte_io(crc[7:0],r);
     byte_io(8'hA6,r);byte_io(0,r);if(r!=expected_reply)
       $fatal(1,"text commit %h crc=%h expected=%h invalid=%b len=%d",
              r,endpoint.text_crc,endpoint.text_expected_crc,endpoint.text_invalid,text_length);
     cs=1;#100;
   end endtask
 task shape_packet(input integer shape,ax,ay,bx,by,flags_value,
                   input bit bad_crc,abort_packet,input [7:0] expected_status,expected_commit);
   reg [7:0] bytes[0:17];reg [7:0] reply;reg [15:0] crc;integer k;
   begin
     bytes[0]=8'hB9;bytes[1]=0;bytes[2]=shape;bytes[3]=flags_value;
     bytes[4]=ax>>8;bytes[5]=ax;bytes[6]=ay>>8;bytes[7]=ay;
     bytes[8]=bx>>8;bytes[9]=bx;bytes[10]=by>>8;bytes[11]=by;
     bytes[12]=8'hAB;bytes[13]=8'hCD;crc=16'hFFFF;
     for(k=2;k<=13;k=k+1)crc=crc_byte(crc,bytes[k]);
     bytes[14]=crc[15:8]^(bad_crc?8'h01:0);bytes[15]=crc[7:0];
     bytes[16]=8'hA6;bytes[17]=0;
     cs=0;#100;
     for(k=0;k<(abort_packet?16:18);k=k+1)begin
       byte_io(bytes[k],reply);
       if(k==0 && reply!=8'hA5)$fatal(1,"shape first byte");
       if(k==1 && reply!=expected_status)$fatal(1,"shape busy %h",reply);
       if(k>=2 && k<=16 && reply!=bytes[k-1])$fatal(1,"shape echo");
       if(k==17 && reply!=expected_commit)$fatal(1,"shape commit %h expected %h",reply,expected_commit);
     end
     cs=1;#300;
   end
 endtask
 initial begin
   #1;rst=0;#100;rst=1;#100;sck=1;#20;sck=0;#20;sck=1;#20;sck=0;
   wait(writes==8160 && !writing);#1000;
   for(i=0;i<130560;i=i+1)
     if(memory[i] !== 16'h0000) $fatal(1,"startup pixel %d is not black",i);
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
   cs=0;#100;mosi=1;#20;sck=1;#20;sck=0;cs=1;#100;
   packet(528,32,8'hC3);#2000;if(writes!=8163)$fatal(1,"abort recovery");
   text_packet(0,8'hAC);#300;if(!text_valid)$fatal(1,"missing text command");
   if(text_font!=1 || text_flags!=2 || text_x!=5 || text_y!=7 ||
      text_bw!=12 || text_bh!=24 || text_fg!=16'hF800 || text_bg!=16'h001F ||
      text_length!=1)$fatal(1,"text fields");
   text_read_address=0;repeat(2)@(posedge clk);
   if(text_read_data!=8'h41)$fatal(1,"text payload");
   cs=0;#100;byte_io(8'hB8,r);byte_io(0,r);cs=1;#100;
   if(r!=0)$fatal(1,"text queue did not report busy");
   @(negedge clk);text_take=1;@(negedge clk);text_take=0;wait(!text_valid);#200;
   text_packet(1,8'hE1);#300;if(text_valid)$fatal(1,"bad CRC committed");
   // B9 line packet validation, including high bits before field truncation.
   shape_packet(1,0,0,479,271,0,1,0,8'hC3,8'hE1);
   if(text_valid)$fatal(1,"shape CRC committed");
   shape_packet(1,0,0,480,271,0,0,0,8'hC3,8'hE1);
   shape_packet(1,0,0,479,272,0,0,0,8'hC3,8'hE1);
   shape_packet(1,512,0,479,271,0,0,0,8'hC3,8'hE1);
   shape_packet(1,0,0,1024,0,0,0,0,8'hC3,8'hE1);
   shape_packet(2,0,0,10,10,0,0,0,8'hC3,8'hE1);
   shape_packet(1,0,0,10,10,1,0,0,8'hC3,8'hE1);
   shape_packet(1,0,0,479,271,0,0,1,8'hC3,0);
   if(text_valid)$fatal(1,"invalid/aborted line committed");
   text_enabled=0;
   shape_packet(1,479,271,0,0,0,0,0,8'hC3,8'hAC);
   if(!text_valid || !text_kind || text_font!=1 || text_x!=479 || text_y!=271 ||
      text_bw!=0 || text_bh!=0 || text_fg!=16'hABCD)$fatal(1,"line fields");
   // A busy text poll must not change the pending shape's kind or fields.
   text_enabled=1;
   cs=0;#100;byte_io(8'hB8,r);byte_io(0,r);cs=1;#100;
   if(r!=0 || !text_kind)$fatal(1,"busy poll changed pending kind");
   shape_packet(0,5,7,12,24,0,0,0,0,8'hE1);
   if(text_font!=1 || text_x!=479 || text_y!=271)$fatal(1,"busy shape overwritten");
   @(negedge clk);text_take=1;@(negedge clk);text_take=0;wait(!text_valid);#200;
   shape_packet(0,5,7,12,24,0,0,0,8'hC3,8'hAC);
   if(!text_valid || text_font!=0 || !text_kind)$fatal(1,"fill regression");
   $display("PASS: spi_framebuffer masks, bounds, busy, abort, CDC, B9 line/fill CRC and PSRAM beats");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule


