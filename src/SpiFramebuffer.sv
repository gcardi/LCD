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
 input wire [26:0] control_status
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
 reg selected_control,selected_status,accept_control;
 reg [7:0] staging_op,staging_buffer;
 reg [15:0] staging_sequence,control_crc,control_expected_crc,status_crc;
 wire control_available = control_request == control_seen;
 wire graphics_available = control_available;
 wire control_fields_valid = staging_op>=1 && staging_op<=3 &&
     (staging_op==2 ? staging_buffer<=1 : staging_buffer==0) &&
     (staging_op!=1 || staging_sequence==0);
 wire control_commit = selected_control && accept_control && index==8 &&
     rx==8'hA6 && control_fields_valid && control_crc==control_expected_crc;
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
     1:status_byte=8'h01; // protocol version
     2:status_byte=8'h02; // buffer count
     3:status_byte={4'd0,status_busy,status_packet[2:0]}; // busy, IRQ, front, enabled
     4:status_byte={7'd0,(status_packet[0] && !status_packet[1])}; // draw buffer
     5:status_byte=status_packet[26:19]; // last completed PRESENT sequence
     6:status_byte=status_packet[18:11];
     7:status_byte=status_packet[10:3]; // last control result: 00 / E1
     default:status_byte=0;
   endcase
 endfunction
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

 SpiSlave #(.FIXED_FIRST_BYTE(1),.FIRST_BYTE(8'hA5)) slave(
   .rst_n(rst_n),.spi_sck(sck),.spi_cs_n(cs_n),.spi_mosi(mosi),
   .spi_miso(miso),.spi_miso_oe(miso_oe),.rx_data(rx),.rx_push(push),
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
     selected_control<=0;selected_status<=0;accept_control<=0;
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
     if(index==0 && rx==8'hBA) echo_byte<=control_available?8'hC3:8'h00;
     if(index==0 && rx==8'hBB) begin
       echo_byte<=8'hD2;status_packet<=status_snapshot;
       status_busy<=!control_available;status_crc<=crc16_byte(16'hFFFF,8'hD2);
     end
     if(selected_status) begin
       if(index>=1 && index<=7) begin
         echo_byte<=status_byte(index);
         status_crc<=crc16_byte(status_crc,status_byte(index));
       end
       if(index==8) echo_byte<=status_crc[15:8];
       if(index==9) echo_byte<=status_crc[7:0];
     end
     if(selected_control && index==8) echo_byte<=control_commit?8'hAC:8'hE1;
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
       selected_control<=rx==8'hBA;selected_status<=rx==8'hBB;
       accept_control<=control_available;
       text_crc<=16'hFFFF;text_invalid<=0;
     end
     if(selected_control && accept_control) begin
       if(index>=2 && index<=5) control_crc<=crc16_byte(control_crc,rx);
       case(index)
         2:staging_op<=rx;3:staging_buffer<=rx;
         4:staging_sequence[15:8]<=rx;5:staging_sequence[7:0]<=rx;
         6:control_expected_crc[15:8]<=rx;7:control_expected_crc[7:0]<=rx;
       endcase
     end
     if(selected && accept_packet) begin
       if(index>=2 && index<=4) staging_addr<={staging_addr[15:0],rx};
       if(index==5 || index==6) staging_mask<={staging_mask[7:0],rx};
       if(index>=7 && index<=38) staging_pixels<={rx,staging_pixels[255:8]};
     end
     if(selected_shape && accept_shape) begin
       if(index>=2 && index<=13) text_crc<=crc16_byte(text_crc,rx);
       if(index==2 && rx>1)text_invalid<=1;   // rettangolo o linea
       if(index==3 && rx!=0)text_invalid<=1;   // flags riservati
       if((index==4 || index==6 || index==10) && rx>1)text_invalid<=1;
       if(index==8 && rx>3)text_invalid<=1;
       if(index==14) text_expected_crc[15:8]<=rx;
       if(index==15) text_expected_crc[7:0]<=rx;
     end
     if(selected_text && accept_text) begin
       if(index>=2 && index<=16+text_length)
         text_crc<=crc16_byte(text_crc,rx);
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
