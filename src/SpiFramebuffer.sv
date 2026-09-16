// SPI graphics endpoint with independent one-entry CDC queues.
// B7 retains the masked 16-pixel burst protocol.
// B8 accepts a bounded UTF-8 text command; see docs/SPI_TEXT.md.
module SpiFramebuffer (
 input wire rst_n, sck, cs_n, mosi,
 output wire miso, miso_oe,
 input wire clk, mem_rst_n,
 output wire valid, input wire take,
 output reg [20:0] address,
 output reg [255:0] pixels,
 output reg [15:0] mask,
 input wire text_clk,text_rst_n,text_enabled,
 output wire text_valid, input wire text_take,
 // 0 = comando testo B8, 1 = forma B9. Le due condividono coda e registri.
 output reg text_kind,
 output reg [1:0] text_font_id,
 output reg [7:0] text_flags,
 output reg [8:0] text_x,
 output reg [8:0] text_y,
 output reg [9:0] text_box_width,
 output reg [8:0] text_box_height,
 output reg [15:0] text_foreground,
 output reg [15:0] text_background,
 output reg [6:0] text_length,
 input wire [5:0] text_read_address,
 output reg [7:0] text_read_data,
 // BA control mailbox. Payload stays stable until completion, not acceptance.
 output wire control_valid, input wire control_take,
 output reg [7:0] control_op, output reg control_buffer,
 output reg [15:0] control_sequence,
 input wire [26:0] control_status,
 output reg blit_source,
 output reg [15:0] blit_x,blit_y,blit_width,blit_height,blit_arg_x,blit_arg_y,blit_color
);
 wire [7:0] rx;
 wire push;
 reg [7:0] echo_byte;
 reg [6:0] index;
 reg selected,selected_text,selected_shape,accept_packet,accept_text,accept_shape;
 reg [23:0] staging_addr;
 reg [15:0] staging_mask;
 reg [255:0] staging_pixels;
 reg request,ack,text_request,text_ack;
 (* async_reg = "true" *) reg ack1,ack2,req1,req2;
 (* async_reg = "true" *) reg text_ack1,text_ack2,text_req1,text_req2;
 (* async_reg = "true" *) reg text_enabled1,text_enabled2;
 reg [15:0] text_crc,text_expected_crc;
 reg text_invalid;
 reg [7:0] text_memory[0:63];
 wire available = request == ack2;
 wire text_available = text_request == text_ack2;
 reg control_request,control_ack;
 (* async_reg = "true" *) reg control_req1,control_req2,control_ack1,control_ack2;
 (* async_reg = "true" *) reg text_mem_req1,text_mem_req2,text_mem_ack1,text_mem_ack2;
 reg control_seen;
 reg [26:0] status_snapshot,status_packet;
 reg status_busy;
 reg graphics_idle;
 reg selected_control,selected_status,selected_fast_status,accept_control;
 reg selected_blit,blit_invalid,blit_scroll,blit_destination;
 // BD streaming row write. The payload carries whole 16-pixel groups, so the
 // pixel path is the same byte shift register B7 already uses; the host pads
 // the ragged ends and describes them with a head and a tail mask. Keeping the
 // shifter shared is what makes the opcode nearly free in logic.
 reg selected_stream,selected_fast,accept_stream,stream_armed,stream_overflow,stream_first;
 reg [2:0] stream_phase; // 0 header, 1 payload, 2 CRC hi, 3 CRC lo, 4 commit, 5 done
 reg [4:0] stream_byte;   // position inside the current 32-byte group
 reg [4:0] stream_groups; // groups still to write, current one included
 reg [16:0] stream_addr;  // pixel address of the current group
 reg [15:0] stream_head,stream_tail;
 reg [15:0] stream_arg_y;
 reg [7:0] stream_arg_start,stream_arg_count;
 reg [7:0] staging_op,staging_buffer;
 reg [15:0] staging_sequence,control_crc,control_expected_crc,status_crc;
 // BE is the write-only form of BD. Its result survives CS rising and is read
 // later with BF, when the master deliberately uses the slow MISO clock.
 reg [15:0] fast_status_y;
 reg [7:0] fast_status_result;
 reg fast_status_valid,fast_status_ready;
 wire control_available = control_request == control_seen;
 wire graphics_available = control_available;
 wire control_fields_valid = staging_op>=1 && staging_op<=3 &&
     (staging_op==2 ? staging_buffer<=1 : staging_buffer==0) &&
     (staging_op!=1 || staging_sequence==0);
 wire stream_payload = selected_stream && accept_stream && stream_phase==3'd1;
 // One CRC16 datapath per register instead of one per call site. BA, BC and BD
 // are mutually exclusive opcodes, as are B8 and B9, so a shared enable costs
 // far less logic than the separate instances the per-site calls synthesised.
 wire control_crc_enable =
     (selected_blit && accept_control && index>=7'd2 && index<=7'd19) ||
     (selected_control && accept_control && index>=7'd2 && index<=7'd5) ||
     (selected_stream && accept_stream && index>=7'd2 && index<=7'd9) ||
     stream_payload;
 wire text_crc_enable =
     (selected_shape && accept_shape && index>=7'd2 && index<=7'd13) ||
     (selected_text && accept_text && index>=7'd2 && index<=(7'd16+text_length));
 wire stream_group_end = stream_payload && stream_byte==5'd31;
 // Both masks apply when the row fits a single group.
 wire [15:0] stream_mask = (stream_first?stream_head:16'hFFFF) &
                           (stream_groups==5'd1 ? stream_tail:16'hFFFF);
 wire stream_fields_valid = stream_arg_y<16'd272 && stream_arg_start<8'd30 &&
     stream_arg_count!=0 && stream_head!=0 && stream_tail!=0 &&
     ({1'b0,stream_arg_start}+{1'b0,stream_arg_count})<=9'd30;
 wire stream_header_ok = selected_stream && accept_stream && rx==8'hA6 &&
     stream_fields_valid && control_expected_crc==control_crc;
 // SCK cannot be stalled, so a full queue is latched as an overflow and the
 // rest of the row is dropped. The trailer reports it and the host resends.
 wire stream_commit = stream_group_end && !stream_overflow;
 wire control_commit = selected_control && accept_control && index==8 &&
     rx==8'hA6 && control_fields_valid && control_crc==control_expected_crc;
 wire blit_commit = selected_blit && accept_control && index==22 &&
     rx==8'hA6 && !blit_invalid && control_crc==control_expected_crc;
 // Both producers must finish before the memory controller sees the barrier.
 assign control_valid = control_req2!=control_ack && graphics_idle;

 // Status is bundled with the completion toggle: capture only after its
 // two-stage synchronizer, when the source bus has already settled. Hold a
 // second snapshot throughout each BB packet, including its CRC.
 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     control_ack1<=0;control_ack2<=0;control_seen<=0;status_snapshot<=0;
     control_request<=0;control_op<=0;control_buffer<=0;control_sequence<=0;
   end else begin
     control_ack1<=control_ack;control_ack2<=control_ack1;
     if(control_ack2!=control_seen) begin
       status_snapshot<=control_status;control_seen<=control_ack2;
     end
     if(push && control_commit) begin
       control_op<=staging_op;control_buffer<=staging_buffer[0];
       control_sequence<=staging_sequence;control_request<=!control_request;
     end
     if(push && blit_commit) begin
       control_op<=blit_scroll?8'd5:8'd4;control_buffer<=blit_destination;
       control_sequence<=0;control_request<=!control_request;
     end
   end
 end
 always @(posedge clk or negedge mem_rst_n) begin
   if(!mem_rst_n) begin
     control_req1<=0;control_req2<=0;control_ack<=0;
     text_mem_req1<=0;text_mem_req2<=0;text_mem_ack1<=0;text_mem_ack2<=0;
     graphics_idle<=0;
   end else begin
     control_req1<=control_request;control_req2<=control_req1;
     text_mem_req1<=text_request;text_mem_req2<=text_mem_req1;
     text_mem_ack1<=text_ack;text_mem_ack2<=text_mem_ack1;
     graphics_idle<=req2==ack && text_mem_req2==text_mem_ack2;
     if(control_valid && control_take) control_ack<=control_req2;
   end
 end
 function automatic [7:0] status_byte(input [6:0] n);
   case(n)
     0:status_byte=8'hD2;
     1:status_byte=8'h02; // version 2 adds BC COPY/SCROLL
     2:status_byte=8'h02; // buffer count
     3:status_byte={4'd0,status_busy,status_packet[2:0]}; // busy, IRQ, front, enabled
     4:status_byte={7'd0,(status_packet[0] && !status_packet[1])}; // draw buffer
     5:status_byte=status_packet[26:19]; // last completed PRESENT sequence
     6:status_byte=status_packet[18:11];
     7:status_byte=status_packet[10:3]; // last control result: 00 / E1
     default:status_byte=0;
   endcase
 endfunction
 function automatic [7:0] fast_status_byte(input [6:0] n);
   case(n)
     0:fast_status_byte=8'hD3;
     1:fast_status_byte=8'h01;
     2:fast_status_byte={6'd0,fast_status_ready,fast_status_valid};
     3:fast_status_byte=fast_status_y[15:8];
     4:fast_status_byte=fast_status_y[7:0];
     5:fast_status_byte=fast_status_result;
     default:fast_status_byte=0;
   endcase
 endfunction
 // Descriptor is bundled with the control mailbox and immutable while busy.
 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     blit_source<=0;blit_x<=0;blit_y<=0;blit_width<=0;blit_height<=0;
     blit_arg_x<=0;blit_arg_y<=0;blit_color<=0;
   end else if(push && selected_blit && accept_control) begin
     case(index)
       3:blit_source<=rx[0];
       6,7:blit_x<={blit_x[7:0],rx};8,9:blit_y<={blit_y[7:0],rx};
       10,11:blit_width<={blit_width[7:0],rx};12,13:blit_height<={blit_height[7:0],rx};
       14,15:blit_arg_x<={blit_arg_x[7:0],rx};16,17:blit_arg_y<={blit_arg_y[7:0],rx};
       18,19:blit_color<={blit_color[7:0],rx};
     endcase
   end
 end
 wire text_commit_index = selected_text && index==(7'd19+text_length);
 // Il pacchetto forma e' a lunghezza fissa: 18 byte, commit all'indice 16.
 wire shape_commit_index = selected_shape && index==7'd16;
 wire shape_fields_valid = !text_invalid && text_x<480 && text_y<272 &&
                           (text_font_id==0 ||
                            (text_font_id==1 && text_box_width<480 && text_box_height<272));
 wire text_fields_valid = !text_invalid && text_font_id<=2 && text_flags[7:2]==0 &&
                          text_x<480 && text_y<272 && text_length<=64;

 function automatic [15:0] crc16_byte(input [15:0] current,input [7:0] value);
   integer bit_index;reg [15:0] next;
   begin
     next=current^{value,8'd0};
     for(bit_index=0;bit_index<8;bit_index=bit_index+1)
       next=next[15]?(next<<1)^16'h1021:(next<<1);
     crc16_byte=next;
   end
 endfunction

 wire slave_miso_oe;
 // The first byte is driven before the opcode is known. From the second byte
 // onward BE is electrically write-only as well as ignored by the STM32.
 assign miso_oe=slave_miso_oe && !selected_fast;
 SpiSlave #(.FIXED_FIRST_BYTE(1),.FIRST_BYTE(8'hA5)) slave(
   .rst_n(rst_n),.spi_sck(sck),.spi_cs_n(cs_n),.spi_mosi(mosi),
   .spi_miso(miso),.spi_miso_oe(slave_miso_oe),.rx_data(rx),.rx_push(push),
   .tx_data(echo_byte),.tx_valid(1'b1),.tx_take());

 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     ack1<=0;ack2<=0;text_ack1<=0;text_ack2<=0;
     text_enabled1<=0;text_enabled2<=0;
   end else begin
     ack1<=ack;ack2<=ack1;text_ack1<=text_ack;text_ack2<=text_ack1;
     text_enabled1<=text_enabled;text_enabled2<=text_enabled1;
   end
 end

 // Result mailbox for the write-only stream. FE means that CS rose before a
 // complete trailer; 00 is backpressure, E1 a bad header, E2 overflow and E3
 // a bad payload CRC/commit. AC is the only successful completion.
 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     fast_status_y<=0;fast_status_result<=8'hFE;fast_status_valid<=0;
   end else if(push) begin
     if(index==0 && rx==8'hBE) begin
       fast_status_y<=0;fast_status_valid<=1;
       fast_status_result<=(available && graphics_available)?8'hFE:8'h00;
     end
     if(selected_fast) begin
       if(index==2) fast_status_y[15:8]<=rx;
       if(index==3) fast_status_y[7:0]<=rx;
       if(index==12 && accept_stream && !stream_header_ok)
         fast_status_result<=8'hE1;
       if(stream_phase==3'd4)
         fast_status_result<=stream_overflow?8'hE2:
             ((rx==8'hA6 && control_expected_crc==control_crc)?8'hAC:8'hE3);
     end
   end
 end
 always @(posedge clk or negedge mem_rst_n) begin
   if(!mem_rst_n) begin
     req1<=0;req2<=0;ack<=0;
   end else begin
     req1<=request;req2<=req1;
     if(valid && take) ack<=req2;
   end
 end
 always @(posedge text_clk or negedge text_rst_n) begin
   if(!text_rst_n) begin
     text_req1<=0;text_req2<=0;text_ack<=0;text_read_data<=0;
   end else begin
     text_req1<=text_request;text_req2<=text_req1;
     text_read_data<=text_memory[text_read_address];
     if(text_valid && text_take) text_ack<=text_req2;
   end
 end

 // Command fields and text RAM are not reset by CS. Once committed they stay
 // stable until the memory-domain consumer acknowledges the queue entry.
 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     text_font_id<=0;text_flags<=0;text_x<=0;text_y<=0;
     text_box_width<=0;text_box_height<=0;text_foreground<=0;
     text_background<=0;text_length<=0;text_kind<=0;
   end else if(push) begin
    // Il tipo si fissa sull'opcode, prima di qualunque campo.
    if(index==0 && text_available && graphics_available) begin
      if(rx==8'hB8 && text_enabled2) text_kind<=0;
      if(rx==8'hB9) begin text_kind<=1;text_length<=0;end
    end
    if(selected_shape && accept_shape) case(index)
       2:text_font_id<=rx[1:0]; // B9: 0 fill, 1 inclusive-endpoint line.
       3:text_flags<=rx;
       4:text_x[8]<=rx[0];5:text_x[7:0]<=rx;
       6:text_y[8]<=rx[0];7:text_y[7:0]<=rx;
       8:text_box_width[9:8]<=rx[1:0];9:text_box_width[7:0]<=rx;
       10:text_box_height[8]<=rx[0];11:text_box_height[7:0]<=rx;
       12,13:text_foreground<={text_foreground[7:0],rx};
    endcase
    if(selected_text && accept_text) begin
     case(index)
       2:text_font_id<=rx[1:0];3:text_flags<=rx;
       4:text_x[8]<=rx[0];5:text_x[7:0]<=rx;
       6:text_y[8]<=rx[0];7:text_y[7:0]<=rx;
       8:text_box_width[9:8]<=rx[1:0];9:text_box_width[7:0]<=rx;
       10:text_box_height[8]<=rx[0];11:text_box_height[7:0]<=rx;
       12,13:text_foreground<={text_foreground[7:0],rx};
       14,15:text_background<={text_background[7:0],rx};
       16:text_length<=rx[6:0];
     endcase
     if(index>=17 && index<=16+text_length) text_memory[index-17]<=rx;
    end
   end
 end
 assign valid = req2 != ack;
 assign text_valid = text_req2 != text_ack;

 // Queue commits are independent of CS: raising CS cannot cancel a command
 // whose commit byte has already completed.
 always @(posedge sck or negedge rst_n) begin
   if(!rst_n) begin
     request<=0;text_request<=0;address<=0;pixels<=0;mask<=0;
   end else if(push) begin
     if(selected && accept_packet && index==39 && rx==8'h5A &&
        staging_addr<24'd130560 && staging_addr[3:0]==0) begin
       address<=staging_addr[20:0];pixels<=staging_pixels;
       mask<=staging_mask;request<=!request;
     end
     if(stream_commit && available) begin
       address<={4'd0,stream_addr};pixels<={rx,staging_pixels[255:8]};
       mask<=stream_mask;request<=!request;
     end
     if(text_commit_index && accept_text && rx==8'hA6 && text_fields_valid &&
        text_expected_crc==text_crc)
       text_request<=!text_request;
     if(shape_commit_index && accept_shape && rx==8'hA6 && shape_fields_valid &&
        text_expected_crc==text_crc)
       text_request<=!text_request;
   end
 end

 always @(posedge sck or negedge rst_n or posedge cs_n) begin
   if(!rst_n || cs_n) begin
     index<=0;selected<=0;selected_text<=0;selected_shape<=0;
     accept_packet<=0;accept_text<=0;accept_shape<=0;
     echo_byte<=8'hA5;staging_addr<=0;staging_mask<=0;staging_pixels<=0;
     text_crc<=16'hFFFF;text_expected_crc<=0;text_invalid<=0;
     selected_control<=0;selected_status<=0;selected_fast_status<=0;accept_control<=0;
     selected_blit<=0;blit_invalid<=0;blit_scroll<=0;blit_destination<=0;
     selected_stream<=0;selected_fast<=0;accept_stream<=0;stream_armed<=0;stream_overflow<=0;
     stream_first<=0;stream_phase<=0;stream_byte<=0;stream_groups<=0;
     stream_addr<=0;stream_head<=0;stream_tail<=0;
     stream_arg_y<=0;stream_arg_start<=0;stream_arg_count<=0;
     staging_op<=0;staging_buffer<=0;staging_sequence<=0;
     control_crc<=16'hFFFF;control_expected_crc<=0;
     status_packet<=0;status_busy<=0;status_crc<=16'hFFFF;
   end else if(push) begin
     echo_byte<=rx;
     if(index==0 && rx==8'hB7)
       echo_byte<=(available && graphics_available)?8'hC3:8'h00;
     if(index==0 && rx==8'hB8)
       echo_byte<=!text_enabled2?8'hE2:((text_available && graphics_available)?8'hC3:8'h00);
     // Un riempimento non usa i font, quindi non dipende da text_enabled.
     if(index==0 && rx==8'hB9)
       echo_byte<=(text_available && graphics_available)?8'hC3:8'h00;
     if(index==0 && rx==8'hBD)
       echo_byte<=(available && graphics_available)?8'hC3:8'h00;
     if(index==0 && rx==8'hBA) echo_byte<=control_available?8'hC3:8'h00;
     if(index==0 && rx==8'hBC) echo_byte<=control_available?8'hC3:8'h00;
     if(index==0 && rx==8'hBB) begin
       echo_byte<=8'hD2;status_packet<=status_snapshot;
       status_busy<=!control_available;status_crc<=crc16_byte(16'hFFFF,8'hD2);
     end
     if(index==0 && rx==8'hBF) begin
       echo_byte<=8'hD3;fast_status_ready<=available && graphics_available;
       status_crc<=crc16_byte(16'hFFFF,8'hD3);
     end
     if(selected_status) begin
       if(index>=1 && index<=7) begin
         echo_byte<=status_byte(index);
         status_crc<=crc16_byte(status_crc,status_byte(index));
       end
       if(index==8) echo_byte<=status_crc[15:8];
       if(index==9) echo_byte<=status_crc[7:0];
     end
     if(selected_fast_status) begin
       if(index>=1 && index<=5) begin
         echo_byte<=fast_status_byte(index);
         status_crc<=crc16_byte(status_crc,fast_status_byte(index));
       end
       if(index==6) echo_byte<=status_crc[15:8];
       if(index==7) echo_byte<=status_crc[7:0];
     end
     if(selected_control && index==8) echo_byte<=control_commit?8'hAC:8'hE1;
     if(selected_blit && index==22) echo_byte<=blit_commit?8'hAC:8'hE1;
     if(selected && index==39)
       echo_byte<=(accept_packet && rx==8'h5A && staging_addr<24'd130560 &&
                   staging_addr[3:0]==0)?8'hAC:8'hE1;
     if(text_commit_index)
       echo_byte<=(accept_text && rx==8'hA6 && text_fields_valid &&
                   text_expected_crc==text_crc)?8'hAC:8'hE1;
     if(shape_commit_index)
       echo_byte<=(accept_shape && rx==8'hA6 && shape_fields_valid &&
                   text_expected_crc==text_crc)?8'hAC:8'hE1;
     if(index!=127) index<=index+1'b1;
     if(index==0) begin
       selected<=rx==8'hB7;selected_text<=rx==8'hB8;
       selected_shape<=rx==8'hB9;
       accept_packet<=available && graphics_available;
       accept_text<=text_available && text_enabled2 && graphics_available;
       accept_shape<=text_available && graphics_available;
       selected_stream<=rx==8'hBD || rx==8'hBE;selected_fast<=rx==8'hBE;
       accept_stream<=available && graphics_available;
       selected_control<=rx==8'hBA;selected_status<=rx==8'hBB;
       selected_fast_status<=rx==8'hBF;
       selected_blit<=rx==8'hBC;
       accept_control<=control_available;
       text_crc<=16'hFFFF;text_invalid<=0;
     end
     if(control_crc_enable) control_crc<=crc16_byte(control_crc,rx);
     if(text_crc_enable) text_crc<=crc16_byte(text_crc,rx);
     if(selected_blit && accept_control) begin
       case(index)
         2:begin blit_scroll<=rx[0];if(rx>1)blit_invalid<=1;end
         3:if(rx>1)blit_invalid<=1;
         4:begin blit_destination<=rx[0];if(rx>1 || rx[0]==blit_source)blit_invalid<=1;end
         5:if(rx!=0)blit_invalid<=1;
         18,19:if(!blit_scroll && rx!=0)blit_invalid<=1;
         20:control_expected_crc[15:8]<=rx;21:control_expected_crc[7:0]<=rx;
       endcase
     end
     if(selected_control && accept_control) begin
       case(index)
         2:staging_op<=rx;3:staging_buffer<=rx;
         4:staging_sequence[15:8]<=rx;5:staging_sequence[7:0]<=rx;
         6:control_expected_crc[15:8]<=rx;7:control_expected_crc[7:0]<=rx;
       endcase
     end
     if(selected_stream && accept_stream) begin
       case(index)
         2:stream_arg_y[15:8]<=rx;   3:stream_arg_y[7:0]<=rx;
         4:stream_arg_start<=rx;     5:stream_arg_count<=rx;
         6:stream_head[15:8]<=rx;    7:stream_head[7:0]<=rx;
         8:stream_tail[15:8]<=rx;    9:stream_tail[7:0]<=rx;
         10:control_expected_crc[15:8]<=rx;
         11:control_expected_crc[7:0]<=rx;
         12:begin
           echo_byte<=stream_header_ok?8'hAC:8'hE1;
           if(stream_header_ok) begin
             stream_armed<=1;stream_first<=1;stream_byte<=0;
             stream_groups<=stream_arg_count[4:0];
             // y*480 without a multiplier, plus the first group's offset.
             // y*480 + group*16. The 24-bit intermediate never exceeds
             // 271*480+464 = 130544, so the slice back to 17 bits is exact.
             stream_addr<=17'(({15'd0,stream_arg_y[8:0]}<<9)-
                              ({15'd0,stream_arg_y[8:0]}<<5)+
                              {15'd0,stream_arg_start[4:0],4'd0});
           end
         end
         13:if(stream_armed) begin
           stream_phase<=3'd1;control_crc<=16'hFFFF;
           echo_byte<=8'hC3; // healthy from the first payload byte onwards
         end
       endcase
       if(stream_phase==3'd1) begin
         echo_byte<=stream_overflow?8'h00:8'hC3;
         stream_byte<=stream_byte+5'd1;
         if(stream_byte==5'd31) begin
           stream_first<=0;stream_groups<=stream_groups-5'd1;
           stream_addr<=stream_addr+17'd16;
           if(!available) stream_overflow<=1;
           if(stream_groups==5'd1) stream_phase<=3'd2;
         end
       end
       if(stream_phase==3'd2) begin
         control_expected_crc[15:8]<=rx;stream_phase<=3'd3;
       end
       if(stream_phase==3'd3) begin
         control_expected_crc[7:0]<=rx;stream_phase<=3'd4;
       end
       if(stream_phase==3'd4) begin
         echo_byte<=(!stream_overflow && rx==8'hA6 &&
                     control_expected_crc==control_crc)?8'hAC:8'hE1;
         stream_phase<=3'd5;
       end
     end
     // One 256-bit shift register serves both pixel paths: B7 fills it from its
     // packet body, BD from the payload stream. The two opcodes are never
     // selected together, so the shifter and its enable are shared.
     if((selected && accept_packet && index>=7 && index<=38) || stream_payload)
       staging_pixels<={rx,staging_pixels[255:8]};
     if(selected && accept_packet) begin
       if(index>=2 && index<=4) staging_addr<={staging_addr[15:0],rx};
       if(index==5 || index==6) staging_mask<={staging_mask[7:0],rx};
     end
     if(selected_shape && accept_shape) begin
       if(index==2 && rx>1)text_invalid<=1;   // rettangolo o linea
       if(index==3 && rx!=0)text_invalid<=1;   // flags riservati
       if((index==4 || index==6 || index==10) && rx>1)text_invalid<=1;
       if(index==8 && rx>3)text_invalid<=1;
       if(index==14) text_expected_crc[15:8]<=rx;
       if(index==15) text_expected_crc[7:0]<=rx;
     end
     if(selected_text && accept_text) begin
       if(index==2 && rx>2)text_invalid<=1;
       if(index==3 && rx[7:2]!=0)text_invalid<=1;
       if((index==4 || index==6 || index==10) && rx>1)text_invalid<=1;
       if(index==8 && rx>3)text_invalid<=1;
       if(index==16 && rx>64)text_invalid<=1;
       if(index==17+text_length) text_expected_crc[15:8]<=rx;
       if(index==18+text_length) text_expected_crc[7:0]<=rx;
     end
   end
 end
endmodule
