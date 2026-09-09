// One-entry asynchronous packet queue. Payload remains stable from request
// until acknowledgement; CS only resets the parser, never the queue toggles.
// B7, dummy (reply C3=space / 00=busy), address BE24, mask BE16,
// 16 RGB565 pixels little endian, 5A commit. Exactly one packet per CS.
module SpiFramebuffer (
 input wire rst_n, sck, cs_n, mosi,
 output wire miso, miso_oe,
 input wire clk, mem_rst_n,
 output wire valid, input wire take,
 output reg [20:0] address,
 output reg [255:0] pixels,
 output reg [15:0] mask
);
 wire [7:0] rx;
 wire push;
 reg [7:0] echo_byte;
 reg [5:0] index;
 reg selected, accept_packet;
 reg [23:0] staging_addr;
 reg [15:0] staging_mask;
 reg [255:0] staging_pixels;
 reg request, ack;
 (* async_reg = "true" *) reg ack1, ack2, req1, req2;
 wire available = request == ack2;
 wire reset_parser = !rst_n || cs_n;
 // Register the next response on the byte-completion edge. No index/status
 // mux remains on the half-cycle path into the falling-edge TX register.
 wire [7:0] reply = echo_byte;
 SpiSlave #(.FIXED_FIRST_BYTE(1), .FIRST_BYTE(8'hA5)) slave(.rst_n(rst_n), .spi_sck(sck), .spi_cs_n(cs_n),
 .spi_mosi(mosi), .spi_miso(miso), .spi_miso_oe(miso_oe),
 .rx_data(rx), .rx_push(push), .tx_data(reply), .tx_valid(1'b1), .tx_take());
 always @(posedge sck or negedge rst_n) begin
   if (!rst_n) begin ack1<=0; ack2<=0; end
   else begin ack1<=ack; ack2<=ack1; end
 end
 always @(posedge clk or negedge mem_rst_n) begin
   if (!mem_rst_n) begin req1<=0; req2<=0; ack<=0; end
   else begin req1<=request; req2<=req1; if (valid && take) ack<=req2; end
 end
 assign valid = req2 != ack;
 // Commit queue independently of parser reset, including when SCK stops.
 always @(posedge sck or negedge rst_n) begin
   if (!rst_n) begin request<=0; address<=0; pixels<=0; mask<=0; end
   else if (push && selected && accept_packet && index == 39 && rx == 8'h5A &&
            staging_addr < 24'd130560 && staging_addr[3:0] == 0) begin
      address<=staging_addr[20:0]; pixels<=staging_pixels;
      mask<=staging_mask; request<=!request;
   end
 end
 always @(posedge sck or posedge reset_parser) begin
   if (reset_parser) begin
     index<=0; selected<=0; accept_packet<=0; echo_byte<=8'hA5;
     staging_addr<=0; staging_mask<=0; staging_pixels<=0;
   end else if (push) begin
     echo_byte<=rx;
     if (index == 0 && rx == 8'hB7)
         echo_byte <= available ? 8'hC3 : 8'h00;
     if (selected && index == 39)
         echo_byte <= (accept_packet && rx == 8'h5A &&
             staging_addr < 24'd130560 && staging_addr[3:0] == 0) ? 8'hAC : 8'hE1;
     if (index != 63) index<=index+1'b1;
     if (index == 0) begin selected<=rx==8'hB7; accept_packet<=available; end
     if (selected && accept_packet) begin
       if (index >= 2 && index <= 4) staging_addr<={staging_addr[15:0],rx};
       if (index == 5 || index == 6) staging_mask<={staging_mask[7:0],rx};
       if (index >= 7 && index <= 38) staging_pixels<={rx,staging_pixels[255:8]};
     end
   end
 end
endmodule
