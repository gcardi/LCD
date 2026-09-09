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
 output reg [7:0] text_read_data
);
 wire [7:0] rx;
 wire push;
 reg [7:0] echo_byte;
 reg [6:0] index;
 reg selected,selected_text,accept_packet,accept_text;
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
 wire text_commit_index = selected_text && index==(7'd19+text_length);
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
     text_background<=0;text_length<=0;
   end else if(push && selected_text && accept_text) begin
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
   end
 end

 always @(posedge sck or negedge rst_n or posedge cs_n) begin
   if(!rst_n || cs_n) begin
     index<=0;selected<=0;selected_text<=0;accept_packet<=0;accept_text<=0;
     echo_byte<=8'hA5;staging_addr<=0;staging_mask<=0;staging_pixels<=0;
     text_crc<=16'hFFFF;text_expected_crc<=0;text_invalid<=0;
   end else if(push) begin
     echo_byte<=rx;
     if(index==0 && rx==8'hB7)
       echo_byte<=available?8'hC3:8'h00;
     if(index==0 && rx==8'hB8)
       echo_byte<=!text_enabled2?8'hE2:(text_available?8'hC3:8'h00);
     if(selected && index==39)
       echo_byte<=(accept_packet && rx==8'h5A && staging_addr<24'd130560 &&
                   staging_addr[3:0]==0)?8'hAC:8'hE1;
     if(text_commit_index)
       echo_byte<=(accept_text && rx==8'hA6 && text_fields_valid &&
                   text_expected_crc==text_crc)?8'hAC:8'hE1;
     if(index!=127) index<=index+1'b1;
     if(index==0) begin
       selected<=rx==8'hB7;selected_text<=rx==8'hB8;
       accept_packet<=available;
       accept_text<=text_available && text_enabled2;
       text_crc<=16'hFFFF;text_invalid<=0;
     end
     if(selected && accept_packet) begin
       if(index>=2 && index<=4) staging_addr<={staging_addr[15:0],rx};
       if(index==5 || index==6) staging_mask<={staging_mask[7:0],rx};
       if(index>=7 && index<=38) staging_pixels<={rx,staging_pixels[255:8]};
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
