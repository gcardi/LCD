// Included inside tb_double_buffer for integrated SPI -> PSRAM -> LCD tests.
reg [15:0] blit_expected[0:262143];
integer blit_cases=0;
task bc(input integer op,src,dst,sx,sy,w,h,dx,dy,color,flags,length,
        input bit corrupt,input [7:0] ready_reply,commit_reply);
 reg [7:0] bytes[0:23];reg [15:0] crc;begin
  bytes[0]=8'hBC;bytes[1]=0;bytes[2]=op;bytes[3]=src;bytes[4]=dst;bytes[5]=flags;
  bytes[6]=sx>>8;bytes[7]=sx;bytes[8]=sy>>8;bytes[9]=sy;
  bytes[10]=w>>8;bytes[11]=w;bytes[12]=h>>8;bytes[13]=h;
  bytes[14]=dx>>8;bytes[15]=dx;bytes[16]=dy>>8;bytes[17]=dy;
  bytes[18]=color>>8;bytes[19]=color;crc=16'hFFFF;
  for(integer i=2;i<=19;i=i+1)crc=crc_byte(crc,bytes[i]);
  bytes[20]=crc[15:8]^{7'd0,corrupt};bytes[21]=crc[7:0];bytes[22]=8'hA6;bytes[23]=0;
  cs=0;#1000;
  for(integer i=0;i<length;i=i+1)begin byte_io(bytes[i],reply);
   if(i==0 && reply!=8'hA5)$fatal(1,"BC identity");
   if(i==1 && reply!=ready_reply)$fatal(1,"BC ready %h",reply);
   if(i>=2 && i<=22 && reply!=bytes[i-1])$fatal(1,"BC echo %d",i);
   if(i==23 && reply!=commit_reply)$fatal(1,"BC commit %h",reply);
  end
  #1000;cs=1;#1000;
 end
endtask
task blit_case(input integer op,src,dst,sx,sy,w,h,dx,dy,color,input bit valid_case,exercise_busy);
 integer ox,oy,ix,iy;begin
  for(integer i=0;i<262144;i=i+1)blit_expected[i]=dut.psram_inst.fb[i];
  if(valid_case)begin
   ox=op?sx:dx;oy=op?sy:dy;
   for(integer j=0;j<h;j=j+1)for(integer i=0;i<w;i=i+1)begin
    ix=op?sx+i-dx:sx+i;iy=op?sy+j-dy:sy+j;
    blit_expected[dst*131072+(oy+j)*480+ox+i]=
     (ix>=sx && ix<sx+w && iy>=sy && iy<sy+h)?dut.psram_inst.fb[src*131072+iy*480+ix]:color;
   end
  end
  bc(op,src,dst,sx,sy,w,h,dx,dy,color,0,24,0,8'hC3,8'hAC);
  if(exercise_busy)begin
   status();if(!st[4][3])$fatal(1,"BC premature completion");
   poll(8'hB7,0);poll(8'hB8,0);poll(8'hB9,0);poll(8'hBC,0);
   control(2,1,3,0,10,0,8'hE1);
   fill(16'hFFFF,0,8'hE1);
   bc(1,0,1,0,0,16,16,0,-1,0,0,24,0,0,8'hE1);
  end
  idle(valid_case?0:8'hE1);
  if(dut.psram_inst.wbusy || dut.psram_inst.rbusy && dut.framebuffer_controller_inst.blit_read_active)
   $fatal(1,"BC completion before memory finished");
  for(integer i=0;i<262144;i=i+1)if(dut.psram_inst.fb[i]!==blit_expected[i])
   $fatal(1,"BC case %d memory[%d]=%h expected %h",blit_cases,i,dut.psram_inst.fb[i],blit_expected[i]);
  blit_cases=blit_cases+1;
  $display("blit integration case %0d complete",blit_cases);
 end
endtask
task blit_scenario;
 integer frames_before;begin
  bc(2,0,1,0,0,16,16,0,0,0,0,24,0,8'hC3,8'hE1); // unknown op
  bc(0,0,0,0,0,16,16,0,0,0,0,24,0,8'hC3,8'hE1); // same buffer
  bc(0,2,1,0,0,16,16,0,0,0,0,24,0,8'hC3,8'hE1); // invalid source
  bc(0,0,2,0,0,16,16,0,0,0,0,24,0,8'hC3,8'hE1); // invalid target
  bc(0,0,1,0,0,16,16,0,0,1,0,24,0,8'hC3,8'hE1); // COPY reserved color
  bc(1,0,1,0,0,16,16,0,0,0,1,24,0,8'hC3,8'hE1); // reserved flag
  bc(1,0,1,0,0,16,16,0,0,0,0,24,1,8'hC3,8'hE1); // bad CRC
  for(integer i=2;i<=22;i=i+1)bc(1,0,1,0,0,16,16,0,-1,0,0,i,0,8'hC3,0);
  idle(0);audit(1,16'hF800);
  // COPY must wait for this already accepted renderer command to finish.
  fill(16'h0123,8'hC3,8'hAC);
  blit_case(0,0,1,0,0,480,272,0,0,0,1,1);
  blit_case(0,0,1,7,5,47,37,29,60,0,1,0);
  blit_case(1,0,1,19,60,442,176,0,-16,16'h1234,1,1);
  blit_case(1,0,1,19,60,442,176,3,5,16'hABCD,1,0);
  blit_case(1,0,1,19,60,442,176,-442,0,16'h039F,1,0);
  blit_case(1,0,1,19,60,23,17,-32768,32767,16'hF81F,1,0);
  blit_case(0,0,1,0,0,1,1,479,271,0,1,0);
  blit_case(0,0,1,479,271,2,1,0,0,0,0,0);
  blit_case(0,0,1,0,0,1,1,480,0,0,0,0);
  blit_case(1,0,1,0,0,0,1,0,0,0,0,0);
  blit_case(0,1,0,0,0,16,16,0,0,0,0,0); // never write front
  control(2,1,3,0,10,8'hC3,8'hAC);idle(0);
  control(3,0,3,0,10,8'hC3,8'hAC);idle(0);
  blit_case(0,1,0,13,61,37,29,5,9,0,1,0); // reverse physical slots after swap
  control(2,0,4,0,10,8'hC3,8'hAC);idle(0);
  control(3,0,4,0,10,8'hC3,8'hAC);idle(0);
  frames_before=checked_frames;wait(checked_frames>=frames_before+2);
  if(irq_edges!=4 || !irq)$fatal(1,"blit/PRESENT IRQ contract");
  $display("blit integration: %0d cases, four presents",blit_cases);
 end
endtask
