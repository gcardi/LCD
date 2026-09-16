`timescale 1ns/1ps
module tb_blit_renderer;
 reg clk=0,rst=0,start=0,scroll=0,source=0;
 always #6 clk=~clk;
 reg [15:0] x,y,w,h,ax,ay,color;
 wire done,error,rv,rt,uv,ut;wire [20:0] ra,ua;wire [255:0] up;
 wire [15:0] mask;reg rd=0;reg [255:0] rp=0;
 BlitRenderer dut(.clk(clk),.rst_n(rst),.start(start),.scroll(scroll),.source_buffer(source),
 .x(x),.y(y),.width(w),.height(h),.arg_x(ax),.arg_y(ay),.fill_color(color),
 .done(done),.error(error),.read_valid(rv),.read_take(rt),.read_address(ra),
 .read_done(rd),.read_pixels(rp),.update_valid(uv),.update_take(ut),
 .update_address(ua),.update_pixels(up),.update_mask(mask));
 reg [15:0] memory[0:262143],expected[0:262143];
 integer cycle=0,delay_left=0,saved_read,reads=0,writes=0,cases=0;
 reg reading=0;
 assign rt=rv && !reading && cycle%3==0;
 assign ut=uv && cycle%5!=0;
 always @(posedge clk)begin
   cycle<=cycle+1;rd<=0;
   if(rt)begin
     if(ra>=262144 || ra[3:0]!=0 || ra[17]!=source || ra[16:0]>=130560)
       $fatal(1,"read address %h",ra);
     saved_read=ra;delay_left=2+cycle%9;reading=1;reads=reads+1;
   end else if(reading)begin
     if(delay_left!=0)delay_left=delay_left-1;
     else begin
       for(integer i=0;i<16;i=i+1)rp[i*16+:16]<=memory[saved_read+i];
       rd<=1;reading=0;
     end
   end
   if(ut)begin
     if(ua>=130560 || ua[3:0]!=0)$fatal(1,"write address %h",ua);
     for(integer i=0;i<16;i=i+1)if(mask[i])memory[(source?0:131072)+ua+i]=up[16*i+:16];
     writes=writes+1;
   end
 end
 task run_case(input bit mode,input integer sx,sy,width,height,argx,argy);
   integer dx,dy,ex,ey,ix,iy,old_reads,old_writes;reg valid_case;begin
     source=cases%2;scroll=mode;x=sx;y=sy;w=width;h=height;ax=argx;ay=argy;color=16'hA35C;
     for(integer i=0;i<262144;i=i+1)begin
       memory[i]=(i*73)^(i>>5)^16'h96B4;expected[i]=memory[i];
     end
     valid_case=sx>=0 && sy>=0 && sx<480 && sy<272 && width>0 && height>0 &&
                sx+width<=480 && sy+height<=272 &&
                (mode || (argx>=0 && argy>=0 && argx+width<=480 && argy+height<=272));
     if(valid_case)begin
       dx=mode?sx:argx;dy=mode?sy:argy;
       for(integer j=0;j<height;j=j+1)for(integer i=0;i<width;i=i+1)begin
         ix=mode?sx+i-argx:sx+i;iy=mode?sy+j-argy:sy+j;
         expected[(source?0:131072)+(dy+j)*480+dx+i]=
           (ix>=sx && ix<sx+width && iy>=sy && iy<sy+height)?
           memory[(source?131072:0)+iy*480+ix]:16'hA35C;
       end
     end
     old_reads=reads;old_writes=writes;
     @(negedge clk);start=1;@(negedge clk);start=0;
     wait(done);@(negedge clk);
     if(error==valid_case)$fatal(1,"validation case %d",cases);
     if(!valid_case && (reads!=old_reads || writes!=old_writes))$fatal(1,"invalid mutated memory");
     if(mode && valid_case && (argx>=width || argx<=-width || argy>=height || argy<=-height) && reads!=old_reads)
       $fatal(1,"fully exposed scroll read outside viewport");
     for(integer i=0;i<262144;i=i+1)if(memory[i]!==expected[i])
       $fatal(1,"case %d mode %d rect %d,%d %dx%d arg %d,%d memory[%d]=%h expected=%h",
         cases,mode,sx,sy,width,height,argx,argy,i,memory[i],expected[i]);
     cases=cases+1;
   end endtask
 integer seed=32'hCAFE1234,rx,ry,rw,rh,dx,dy;
 initial begin
   #1;rst=0;#100;rst=1;
   run_case(0,0,0,480,272,0,0);
   run_case(1,19,60,442,176,0,-16);
   run_case(1,19,60,442,176,0,16);
   run_case(1,0,0,480,272,0,0);
   run_case(1,1,1,31,17,32767,-32768);
   run_case(1,479,271,1,1,0,0);
   run_case(1,479,271,1,1,-1,0);
   run_case(0,479,271,1,1,0,0);
   run_case(0,0,0,1,1,479,271);
   for(integer i=0;i<80;i=i+1)begin
     rx=$unsigned($random(seed))%440;ry=$unsigned($random(seed))%240;
     rw=1+$unsigned($random(seed))%40;rh=1+$unsigned($random(seed))%32;
     if(i%2==0)begin
       dx=$unsigned($random(seed))%(481-rw);dy=$unsigned($random(seed))%(273-rh);
     end else begin dx=($unsigned($random(seed))%101)-50;dy=($unsigned($random(seed))%81)-40;end
     run_case(i%2,rx,ry,rw,rh,dx,dy);
   end
   run_case(0,480,0,1,1,0,0);run_case(0,0,272,1,1,0,0);
   run_case(0,0,0,0,1,0,0);run_case(1,0,0,1,0,0,0);
   run_case(0,479,0,2,1,0,0);run_case(0,0,0,1,1,480,0);
   run_case(0,0,0,1,1,0,272);run_case(1,65535,0,1,1,0,0);
   run_case(1,0,0,65535,1,0,0);run_case(0,0,0,1,65535,0,0);
   $display("PASS: blit_renderer %0d cases, all pixels and padding, both buffers, signed scroll, fill, bounds and stalls",cases);$finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule
