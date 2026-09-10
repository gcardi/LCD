`timescale 1ns/1ps
module tb_line_renderer;
 reg clk=0,rst=0,valid=0,take=0;always #18.5 clk=~clk;
 reg [8:0] x=0,y=0,y1=0;reg [9:0] x1=0;
 wire done,uv;wire [20:0] address;wire [255:0] data;wire [15:0] mask;
 TextRenderer dut(.clk(clk),.rst_n(rst),.fonts_ready(1'b0),
  .command_valid(valid),.command_take(done),.command_kind(1'b1),
  .command_font_id(2'd1),.command_flags(8'd0),.command_x(x),.command_y(y),
  .command_box_width(x1),.command_box_height(y1),.command_foreground(16'hBEEF),
  .command_background(16'd0),.command_length(7'd0),.text_read_address(),
  .text_read_data(8'd0),.flash_request(),.flash_address(),.flash_ready(1'b0),
  .flash_valid(1'b0),.flash_data(32'd0),.update_valid(uv),.update_take(take),
  .update_address(address),.update_data(data),.update_mask(mask));
 reg expected[0:130559];reg seen[0:130559];
 integer phase=0,delay_count=0,bursts=0,j;
 reg [20:0] saved_address;reg [255:0] saved_data;reg [15:0] saved_mask;
 // Delayed acceptance AND delayed acknowledge release model the TOP CDC.
 always @(negedge clk) if(!rst) begin phase=0;take=0;end else case(phase)
  0:if(uv)begin
    saved_address=address;saved_data=data;saved_mask=mask;
    delay_count=7;phase=1;
  end
  1:begin
    if(!uv || address!==saved_address || data!==saved_data || mask!==saved_mask)
      $fatal(1,"payload changed under backpressure");
    if(delay_count>0)delay_count=delay_count-1;
    else begin
      if(address>=130560 || address[3:0]!=0 || mask==0)$fatal(1,"invalid burst");
      for(j=0;j<16;j=j+1)if(mask[j])begin
        if(!expected[address+j] || seen[address+j] || data[j*16+:16]!==16'hBEEF)
          $fatal(1,"unexpected/duplicate pixel at %0d",address+j);
        seen[address+j]=1;
      end
      bursts=bursts+1;take=1;phase=2;
    end
  end
  2:if(!uv)begin delay_count=5;phase=3;end
  3:begin
    if(uv)$fatal(1,"new request before acknowledge released");
    if(delay_count>0)delay_count=delay_count-1;
    else begin take=0;phase=0;end
  end
 endcase
 integer cases=0;
 task check_line(input integer ax,ay,bx,by);
  integer dx,dy,sx,sy,n,k,px,py,i;
  begin
    for(i=0;i<130560;i=i+1)begin expected[i]=0;seen[i]=0;end
    dx=bx-ax;dy=by-ay;sx=dx<0?-1:1;sy=dy<0?-1:1;
    if(dx<0)dx=-dx;if(dy<0)dy=-dy;n=dx>dy?dx:dy;
    // Independent reference: nearest pixel via integer rational rounding,
    // not a second copy of the incremental hardware error accumulator.
    for(k=0;k<=n;k=k+1)begin
      if(n==0)begin px=ax;py=ay;end
      else if(dx>=dy)begin px=ax+sx*k;py=ay+sy*((2*k*dy+dx)/(2*dx));end
      else begin py=ay+sy*k;px=ax+sx*((2*k*dx+dy)/(2*dy));end
      expected[py*480+px]=1;
    end
    @(negedge clk);x=ax;y=ay;x1=bx;y1=by;valid=1;bursts=0;
    wait(done);@(negedge clk);valid=0;repeat(4)@(posedge clk);
    for(i=0;i<130560;i=i+1)if(expected[i]!==seen[i])$fatal(1,"missing pixel %0d",i);
    if(ay==by && bursts!=((ax>bx?ax:bx)/16-(ax<bx?ax:bx)/16+1))
      $fatal(1,"horizontal pixels not merged into bursts");
    cases=cases+1;
  end
 endtask
 integer a,b;reg [31:0] seed=32'h12345678;
 initial begin
  #80;rst=1;
  check_line(0,0,479,271);check_line(479,271,0,0);
  check_line(479,0,0,271);check_line(0,271,479,0);
  check_line(0,0,479,0);check_line(479,271,0,271);
  check_line(0,0,0,271);check_line(479,271,479,0);
  check_line(479,271,479,271);check_line(0,0,0,0);
  for(a=-2;a<=2;a=a+1)for(b=-2;b<=2;b=b+1)begin
    check_line(31,31,31+a,31+b);check_line(31+a,31+b,31,31);
  end
  for(a=0;a<64;a=a+1)begin
    seed=seed*1664525+1013904223;
    check_line(seed[8:0]%480,seed[17:9]%272,seed[26:18]%480,seed[31:23]%272);
  end
  $display("PASS: line_renderer %0d lines, all octants, edges, ties, point, masks and CDC stalls",cases);
  $finish;
 end
 initial begin #100000000;$fatal(1,"line timeout");end
endmodule
