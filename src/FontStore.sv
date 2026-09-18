// Validates the persistent font image, then exposes read-only 32-bit words.
// CRC-32 is the reflected IEEE/zlib variant used by the image generator.
//
// The image may also carry a boot logo. Its descriptor is read after the CRC
// has already vouched for every byte, so these checks are about layout, not
// corruption: they catch an image whose logo section does not match what this
// fabric knows how to draw. A logo that fails them is dropped and the fonts
// still come up, because text is the function and the logo is decoration.
module FontStore (
    input  wire        clk,
    input  wire        rst_n,
    output reg         fonts_ready,
    output reg         fonts_error,
    input  wire        read_request,
    input  wire [14:0] read_address,
    output wire        read_ready,
    output wire        read_valid,
    output wire [31:0] read_data,
    // Boot logo descriptor, stable from the cycle fonts_ready rises.
    output reg         logo_valid,
    output reg  [8:0]  logo_width,
    output reg  [8:0]  logo_height,
    output reg  [8:0]  logo_x,
    output reg  [8:0]  logo_y,
    output reg  [1:0]  logo_format,
    output reg  [14:0] logo_base
);
    localparam [3:0] HEADER_REQUEST=0, HEADER_WAIT=1,
                     CRC_REQUEST=2, CRC_WAIT=3, CRC_BYTE=4, CRC_BIT=5,
                     READY=6, ERROR=7, LOGO_REQUEST=8, LOGO_WAIT=9;
    reg [3:0] state;
    reg [2:0] header_word;
    reg [31:0] total_bytes,expected_crc,crc,crc_word;
    reg [14:0] verify_address;
    reg [1:0] byte_index;
    reg [2:0] bit_index;
    reg [1:0] logo_word;
    reg [14:0] logo_section;
    reg logo_present;
    wire flash_ready,flash_valid;
    wire [31:0] flash_data;
    wire verify_request = (state==HEADER_REQUEST || state==CRC_REQUEST ||
                           state==LOGO_REQUEST) && flash_ready;
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
            logo_word<=0;logo_section<=0;logo_present<=0;logo_valid<=0;
            logo_width<=0;logo_height<=0;logo_x<=0;logo_y<=0;logo_format<=0;logo_base<=0;
        end else case(state)
          HEADER_REQUEST: if(flash_ready) state<=HEADER_WAIT;
          HEADER_WAIT: if(flash_valid) begin
              case(header_word)
                0: if(flash_data!=32'h4644434C) state<=ERROR;
                   else begin header_word<=1;verify_address<=1;state<=HEADER_REQUEST;end
                // V3 adds the RGB565-RLE logo payload while retaining the
                // original raw RGB565 descriptor format for the renderer.
                1: if(flash_data!=32'h00400003) state<=ERROR;
                   else begin header_word<=2;verify_address<=2;state<=HEADER_REQUEST;end
                2: if(flash_data<64 || flash_data>77824 || flash_data[1:0]!=0)
                       state<=ERROR;
                   else begin total_bytes<=flash_data;header_word<=3;
                       verify_address<=3;state<=HEADER_REQUEST;end
                3: begin expected_crc<=flash_data;header_word<=4;
                    verify_address<=6;state<=HEADER_REQUEST;end
                // Word 6 is the byte offset of the logo section. Zero means
                // there is none, and so does an offset that is not a word
                // inside the payload.
                default: begin
                    logo_section<=flash_data[16:2];
                    logo_present<=flash_data!=0 && flash_data[1:0]==0 &&
                                  flash_data>=64 && flash_data<total_bytes;
                    verify_address<=16;crc<=32'hFFFFFFFF;state<=CRC_REQUEST;end
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
                          if((crc_shifted^32'hFFFFFFFF)!=expected_crc)
                              state<=ERROR;
                          else if(logo_present) begin
                              verify_address<=logo_section;logo_word<=0;
                              state<=LOGO_REQUEST;
                          end else begin fonts_ready<=1;state<=READY;end
                      end else begin
                          verify_address<=verify_address+1'b1;state<=CRC_REQUEST;
                      end
                  end else begin byte_index<=byte_index+1'b1;state<=CRC_BYTE;end
              end else bit_index<=bit_index+1'b1;
          end
          // Four words of logo sub-header: magic, size, format, origin. Any
          // mismatch leaves logo_valid low and still brings the fonts up.
          LOGO_REQUEST: if(flash_ready) state<=LOGO_WAIT;
          LOGO_WAIT: if(flash_valid) begin
              case(logo_word)
                0: if(flash_data!=32'h314F474C) begin fonts_ready<=1;state<=READY;end
                   else begin logo_word<=1;verify_address<=verify_address+15'd1;
                       state<=LOGO_REQUEST;end
                // Raw RGB565 uses two pixels per word and therefore needs an
                // even width. RLE can represent any width, but the generator
                // deliberately keeps the same constraint for one simple
                // image contract across both encodings.
                1: if(flash_data[15:0]==0 || flash_data[0] ||
                      flash_data[15:0]>16'd480 ||
                      flash_data[31:16]==0 || flash_data[31:16]>16'd272)
                       begin fonts_ready<=1;state<=READY;end
                   else begin logo_width<=flash_data[8:0];
                       logo_height<=flash_data[24:16];
                       logo_word<=2;verify_address<=verify_address+15'd1;
                       state<=LOGO_REQUEST;end
                2: if(flash_data!=32'd1 && flash_data!=32'd2) begin fonts_ready<=1;state<=READY;end
                   else begin logo_format<=flash_data[1:0];logo_word<=3;verify_address<=verify_address+15'd1;
                       state<=LOGO_REQUEST;end
                // The rectangle must close inside the panel. TextRenderer
                // consumes exactly one stored pixel per selected column, so a
                // logo that would be clipped is dropped rather than drawn from
                // a stream that has slipped out of step.
                default: if(({7'd0,flash_data[8:0]}+{7'd0,logo_width})>16'd480 ||
                            ({7'd0,flash_data[24:16]}+{7'd0,logo_height})>16'd272 ||
                            flash_data[15:9]!=0 || flash_data[31:25]!=0)
                           begin fonts_ready<=1;state<=READY;end
                         else begin logo_x<=flash_data[8:0];
                             logo_y<=flash_data[24:16];
                             logo_base<=verify_address+15'd1;logo_valid<=1;
                             fonts_ready<=1;state<=READY;end
              endcase
          end
          ERROR: begin fonts_error<=1;fonts_ready<=0;end
          default: begin fonts_ready<=1;state<=READY;end
        endcase
    end
endmodule
