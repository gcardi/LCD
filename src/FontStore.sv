// Validates the persistent font image, then exposes read-only 32-bit words.
// CRC-32 is the reflected IEEE/zlib variant used by the image generator.
module FontStore (
    input  wire        clk,
    input  wire        rst_n,
    output reg         fonts_ready,
    output reg         fonts_error,
    input  wire        read_request,
    input  wire [14:0] read_address,
    output wire        read_ready,
    output wire        read_valid,
    output wire [31:0] read_data
);
    localparam [2:0] HEADER_REQUEST=0, HEADER_WAIT=1,
                     CRC_REQUEST=2, CRC_WAIT=3, CRC_BYTE=4, CRC_BIT=5,
                     READY=6, ERROR=7;
    reg [2:0] state;
    reg [1:0] header_word;
    reg [31:0] total_bytes,expected_crc,crc,crc_word;
    reg [14:0] verify_address;
    reg [1:0] byte_index;
    reg [2:0] bit_index;
    wire flash_ready,flash_valid;
    wire [31:0] flash_data;
    wire verify_request = (state==HEADER_REQUEST || state==CRC_REQUEST) && flash_ready;
    wire client_request = state==READY && read_request && flash_ready;

    wire [31:0] crc_shifted = crc[0]?(crc>>1)^32'hEDB88320:(crc>>1);

    UserFlashReader reader(
        .clk(clk),.rst_n(rst_n),.request(verify_request || client_request),
        .word_address(state==READY?read_address:verify_address),
        .ready(flash_ready),.data_valid(flash_valid),.data(flash_data)
    );
    assign read_ready = state==READY && flash_ready;
    assign read_valid = state==READY && flash_valid;
    assign read_data = flash_data;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=HEADER_REQUEST;header_word<=0;total_bytes<=0;
            expected_crc<=0;crc<=32'hFFFFFFFF;crc_word<=0;
            verify_address<=0;byte_index<=0;bit_index<=0;
            fonts_ready<=0;fonts_error<=0;
        end else case(state)
          HEADER_REQUEST: if(flash_ready) state<=HEADER_WAIT;
          HEADER_WAIT: if(flash_valid) begin
              case(header_word)
                0: if(flash_data!=32'h4644434C) state<=ERROR;
                   else begin header_word<=1;verify_address<=1;state<=HEADER_REQUEST;end
                1: if(flash_data!=32'h00400001) state<=ERROR;
                   else begin header_word<=2;verify_address<=2;state<=HEADER_REQUEST;end
                2: if(flash_data<64 || flash_data>77824 || flash_data[1:0]!=0)
                       state<=ERROR;
                   else begin total_bytes<=flash_data;header_word<=3;
                       verify_address<=3;state<=HEADER_REQUEST;end
                default: begin expected_crc<=flash_data;verify_address<=16;
                    crc<=32'hFFFFFFFF;state<=CRC_REQUEST;end
              endcase
          end
          CRC_REQUEST: if(flash_ready) state<=CRC_WAIT;
          CRC_WAIT: if(flash_valid) begin crc_word<=flash_data;byte_index<=0;state<=CRC_BYTE;end
          CRC_BYTE: begin
              case(byte_index)
                0:crc<=crc^{24'd0,crc_word[7:0]};
                1:crc<=crc^{24'd0,crc_word[15:8]};
                2:crc<=crc^{24'd0,crc_word[23:16]};
                default:crc<=crc^{24'd0,crc_word[31:24]};
              endcase
              bit_index<=0;state<=CRC_BIT;
          end
          CRC_BIT: begin
              crc<=crc_shifted;
              if(bit_index==7) begin
                  if(byte_index==3) begin
                      if(((verify_address+1)<<2)>=total_bytes) begin
                          if((crc_shifted^32'hFFFFFFFF)==expected_crc)
                              begin fonts_ready<=1;state<=READY;end
                          else state<=ERROR;
                      end else begin
                          verify_address<=verify_address+1'b1;state<=CRC_REQUEST;
                      end
                  end else begin byte_index<=byte_index+1'b1;state<=CRC_BYTE;end
              end else bit_index<=bit_index+1'b1;
          end
          ERROR: begin fonts_error<=1;fonts_ready<=0;end
          default: begin fonts_ready<=1;state<=READY;end
        endcase
    end
endmodule
