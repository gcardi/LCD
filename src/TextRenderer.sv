// Fixed-cell UTF-8 renderer. Font rows come from FontStore; output uses the
// existing masked 16-pixel PSRAM update interface. Both UTF-8 decoding and
// burst construction are deliberately serial to keep the logic small.
module TextRenderer (
 input wire clk,rst_n,fonts_ready,
 input wire command_valid,output wire command_take,
 // kind 0 = testo; kind 1 = forma B9, font_id 0 fill / 1 linea.
 // Testo e forme condividono coda, campi e percorso dei burst. Per le linee
 // box_width/box_height contengono x1/y1, non dimensioni del riquadro.
 input wire command_kind,
 input wire [1:0] command_font_id,input wire [7:0] command_flags,
 input wire [8:0] command_x,input wire [8:0] command_y,
 input wire [9:0] command_box_width,input wire [8:0] command_box_height,
 input wire [15:0] command_foreground,input wire [15:0] command_background,
 input wire [6:0] command_length,
 output reg [5:0] text_read_address,input wire [7:0] text_read_data,
 output wire flash_request,output wire [14:0] flash_address,
 input wire flash_ready,input wire flash_valid,input wire [31:0] flash_data,
 output wire update_valid,input wire update_take,
 output reg [20:0] update_address,output reg [255:0] update_data,
 output reg [15:0] update_mask
);
 localparam [4:0] IDLE=0,CHAR_ADDR=1,CHAR_WAIT=2,CHAR_CONSUME=3,
                  PROCESS_CHAR=4,GLYPH_BASE=5,POSITION_CHAR=6,
                  FETCH_REQUEST=7,FETCH_WAIT=8,PREP_BURST=9,
                  BUILD_PIXEL=10,ISSUE_BURST=11,DONE=12,WAIT_CLEAR=13,
                  FILL_PREP=14,LINE_INIT=15,LINE_START=16,
                  LINE_PIXEL=17,LINE_CHECK=18,LINE_FLUSH=19,LINE_RELEASE=20;
 reg [4:0] state;
 reg [8:0] origin_x,pen_x,pen_y;
 reg [9:0] clip_right;
 reg [8:0] clip_bottom;
 // Screen bounds: |dx| <= 479, |dy| <= 271; signed error needs 11 bits.
 reg signed [10:0] line_dx,line_dy,line_error;
 reg line_left,line_up,line_last;
 wire signed [10:0] delta_x = $signed({1'b0,clip_right})-$signed({2'b00,pen_x});
 wire signed [10:0] delta_y = $signed({2'b00,clip_bottom})-$signed({2'b00,pen_y});
 wire signed [10:0] abs_dx = delta_x<0 ? -delta_x : delta_x;
 wire signed [10:0] abs_dy = delta_y<0 ? -delta_y : delta_y;
 wire signed [11:0] twice_error = $signed({line_error,1'b0});
 wire line_step_x = twice_error >= line_dy;
 wire line_step_y = twice_error <= line_dx;
 wire [20:0] line_address = ({12'd0,pen_y}<<9)-({12'd0,pen_y}<<5)+
                            {12'd0,pen_x[8:4],4'b0000};
 reg kind;
 reg [1:0] font_id;
 reg [7:0] flags;
 reg [15:0] foreground,background;
 reg [5:0] font_width,font_height;
 reg row_bytes_two;
 reg [6:0] length,byte_index;
 reg [20:0] codepoint,decode_value,decode_minimum;
 reg [2:0] decode_remaining;
 reg [7:0] glyph_index;
 reg [16:0] glyph_base;
 reg [5:0] glyph_row;
 reg [15:0] glyph_bits;
 reg second_burst;
 reg [9:0] burst_x;
 reg [4:0] pixel_index;
 reg row_visible;

 wire [16:0] glyph_byte_address = glyph_base +
                                      (row_bytes_two ? {glyph_row,1'b0} : glyph_row);
 wire [20:0] decoded_continuation = (decode_value<<6)|text_read_data[5:0];
 wire [9:0] candidate_burst_x = {1'b0,pen_x[8:4],4'd0}+
                                  (second_burst?10'd16:10'd0);
 wire [9:0] render_y = {1'b0,pen_y}+glyph_row;
 wire [20:0] render_row_address = (render_y<<9)-(render_y<<5);
 wire [9:0] build_x = burst_x+pixel_index;
 wire [9:0] build_column = build_x-{1'b0,pen_x};
 wire build_inside = row_visible && build_x>={1'b0,pen_x} &&
                     build_column<font_width && build_x<clip_right &&
                     build_x<480;
 wire build_bit_on = build_inside && build_column<16 &&
                     glyph_bits[15-build_column[3:0]];
 wire build_selected = build_inside && (!flags[0] || build_bit_on);
 // Il riempimento non ha glifo: la selezione e' il solo rettangolo, e i
 // limiti sono gia' quelli calcolati per il box del testo.
 wire fill_selected = row_visible && build_x>={1'b0,pen_x} &&
                      build_x<clip_right;

 function automatic [7:0] map_glyph(input [20:0] cp);
   begin
     if(cp>=21'h20 && cp<=21'h7E) map_glyph=cp[7:0]-8'h20;
     else if(cp>=21'hA0 && cp<=21'hFF) map_glyph=8'd95+cp[7:0]-8'hA0;
     else case(cp)
       21'h20AC:map_glyph=8'd191;21'h2190:map_glyph=8'd192;
       21'h2191:map_glyph=8'd193;21'h2192:map_glyph=8'd194;
       21'h2193:map_glyph=8'd195;default:map_glyph=8'd31;
     endcase
   end
 endfunction
 wire [7:0] mapped_glyph=map_glyph(codepoint);

 assign command_take = state==DONE;
 assign flash_request = state==FETCH_REQUEST && flash_ready;
 assign flash_address = glyph_byte_address[16:2];
 assign update_valid = (state==ISSUE_BURST || state==LINE_FLUSH) && update_mask!=0;

 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     state<=IDLE;font_id<=0;flags<=0;origin_x<=0;pen_x<=0;pen_y<=0;
     clip_right<=0;clip_bottom<=0;foreground<=0;background<=0;
     font_width<=0;font_height<=0;row_bytes_two<=0;length<=0;byte_index<=0;
     text_read_address<=0;codepoint<=0;decode_value<=0;decode_minimum<=0;
     decode_remaining<=0;glyph_index<=0;glyph_base<=0;glyph_row<=0;glyph_bits<=0;
     second_burst<=0;burst_x<=0;pixel_index<=0;update_address<=0;
     update_data<=0;update_mask<=0;row_visible<=0;kind<=0;
     line_dx<=0;line_dy<=0;line_error<=0;line_left<=0;line_up<=0;line_last<=0;
   end else case(state)
     // Un riempimento non tocca la User Flash, quindi resta disponibile
     // anche quando i font mancano o non superano il CRC.
     IDLE: if(command_valid && (command_kind || fonts_ready)) begin
       kind<=command_kind;glyph_row<=0;
       burst_x<={1'b0,command_x[8:4],4'd0};
       font_id<=command_font_id;flags<=command_flags;origin_x<=command_x;
       pen_x<=command_x;pen_y<=command_y;foreground<=command_foreground;
       background<=command_background;length<=command_length;byte_index<=0;
       decode_remaining<=0;
       clip_right<=(command_box_width==0 ||
                    {1'b0,command_x}+command_box_width>480)?
                    10'd480:{1'b0,command_x}+command_box_width;
       clip_bottom<=(command_box_height==0 ||
                     {1'b0,command_y}+command_box_height>272)?
                     9'd272:command_y+command_box_height;
       case(command_font_id)
         0:begin font_width<=8;font_height<=16;row_bytes_two<=0;end
         1:begin font_width<=12;font_height<=24;row_bytes_two<=1;end
         default:begin font_width<=16;font_height<=32;row_bytes_two<=1;end
       endcase
       if(command_kind && command_font_id==1) begin
         // Reuse clipping registers for inclusive endpoint x1/y1.
         clip_right<=command_box_width;clip_bottom<=command_box_height;
         state<=LINE_INIT;
       end else state<=command_kind?FILL_PREP:CHAR_ADDR;
     end
     CHAR_ADDR: begin
       if(byte_index>=length) begin
         if(decode_remaining!=0) begin
           codepoint<=21'h3F;decode_remaining<=0;state<=PROCESS_CHAR;
         end else state<=DONE;
       end else begin
         text_read_address<=byte_index[5:0];state<=CHAR_WAIT;
       end
     end
     CHAR_WAIT:state<=CHAR_CONSUME;
     CHAR_CONSUME: begin
       if(decode_remaining==0) begin
         byte_index<=byte_index+1'b1;
         if(text_read_data<8'h80) begin
           codepoint<={13'd0,text_read_data};state<=PROCESS_CHAR;
         end else if(text_read_data>=8'hC2 && text_read_data<=8'hDF) begin
           decode_value<={16'd0,text_read_data[4:0]};decode_minimum<=21'h80;
           decode_remaining<=1;state<=CHAR_ADDR;
         end else if(text_read_data>=8'hE0 && text_read_data<=8'hEF) begin
           decode_value<={17'd0,text_read_data[3:0]};decode_minimum<=21'h800;
           decode_remaining<=2;state<=CHAR_ADDR;
         end else if(text_read_data>=8'hF0 && text_read_data<=8'hF4) begin
           decode_value<={18'd0,text_read_data[2:0]};decode_minimum<=21'h10000;
           decode_remaining<=3;state<=CHAR_ADDR;
         end else begin codepoint<=21'h3F;state<=PROCESS_CHAR;end
       end else if((text_read_data&8'hC0)==8'h80) begin
         byte_index<=byte_index+1'b1;
         if(decode_remaining==1) begin
           decode_remaining<=0;
           if(decoded_continuation<decode_minimum ||
              (decoded_continuation>=21'hD800 && decoded_continuation<=21'hDFFF) ||
              decoded_continuation>21'h10FFFF) codepoint<=21'h3F;
           else codepoint<=decoded_continuation;
           state<=PROCESS_CHAR;
         end else begin
           decode_value<=decoded_continuation;
           decode_remaining<=decode_remaining-1'b1;state<=CHAR_ADDR;
         end
       end else begin
         decode_remaining<=0;codepoint<=21'h3F;state<=PROCESS_CHAR;
       end
     end
     PROCESS_CHAR: begin
       if(pen_y>=clip_bottom) state<=DONE;
       else if(codepoint==10) begin
         pen_x<=origin_x;pen_y<=pen_y+font_height;state<=CHAR_ADDR;
       end else if(codepoint==13) state<=CHAR_ADDR;
       else begin
         glyph_index<=mapped_glyph;glyph_row<=0;second_burst<=0;state<=GLYPH_BASE;
       end
     end
     GLYPH_BASE:begin
       case(font_id)
         0:glyph_base<=17'd64+({9'd0,glyph_index}<<4);
         1:glyph_base<=17'd3200+({9'd0,glyph_index}<<5)+
                                   ({9'd0,glyph_index}<<4);
         default:glyph_base<=17'd12608+({9'd0,glyph_index}<<6);
       endcase
       state<=POSITION_CHAR;
     end
     POSITION_CHAR:begin
         if(flags[1] && {1'b0,pen_x}+font_width>clip_right && pen_x!=origin_x) begin
           pen_x<=origin_x;pen_y<=pen_y+font_height;
           if({1'b0,pen_y}+font_height>=clip_bottom) state<=DONE;
           else state<=FETCH_REQUEST;
         end else if(pen_x>=clip_right) state<=DONE;
         else state<=FETCH_REQUEST;
     end
     FETCH_REQUEST:if(flash_ready)state<=FETCH_WAIT;
     FETCH_WAIT:if(flash_valid)begin
       if(!row_bytes_two)case(glyph_byte_address[1:0])
         0:glyph_bits<={flash_data[7:0],8'd0};
         1:glyph_bits<={flash_data[15:8],8'd0};
         2:glyph_bits<={flash_data[23:16],8'd0};
         default:glyph_bits<={flash_data[31:24],8'd0};
       endcase else if(glyph_byte_address[1])
         glyph_bits<={flash_data[23:16],flash_data[31:24]};
       else glyph_bits<={flash_data[7:0],flash_data[15:8]};
       state<=PREP_BURST;
     end
     LINE_INIT:begin
       line_dx<=abs_dx;line_dy<=-abs_dy;line_error<=abs_dx-abs_dy;
       line_left<=delta_x<0;line_up<=delta_y<0;line_last<=0;
       state<=LINE_START;
     end
     LINE_START:begin
       update_address<=line_address;update_data<={16{foreground}};
       update_mask<=0;state<=LINE_PIXEL;
     end
     LINE_PIXEL:begin
       update_mask<=update_mask | (16'h0001<<pen_x[3:0]);
       if(pen_x==clip_right && pen_y==clip_bottom) begin
         line_last<=1;state<=LINE_FLUSH;
       end else begin
         // Both decisions use the same old error, including exact ties.
         line_error<=line_error+(line_step_x?line_dy:11'sd0)+
                                  (line_step_y?line_dx:11'sd0);
         if(line_step_x) pen_x<=line_left?pen_x-9'd1:pen_x+9'd1;
         if(line_step_y) pen_y<=line_up?pen_y-9'd1:pen_y+9'd1;
         state<=LINE_CHECK;
       end
     end
     LINE_CHECK:begin
       // Merge consecutive pixels in the same aligned burst/row.
       // Otherwise hold payload stable until the memory consumer accepts it.
       state<=line_address==update_address?LINE_PIXEL:LINE_FLUSH;
     end
     LINE_FLUSH:if(update_take)state<=LINE_RELEASE;
     // TOP uses a four-phase CDC handshake: wait for acknowledge release.
     LINE_RELEASE:if(!update_take)state<=line_last?DONE:LINE_START;
     FILL_PREP:begin
       row_visible<=pen_y<clip_bottom;
       update_address<=render_row_address+burst_x;
       update_data<=0;update_mask<=0;pixel_index<=0;state<=BUILD_PIXEL;
     end
     PREP_BURST:begin
       burst_x<=candidate_burst_x;
       row_visible<=render_y<clip_bottom;
       update_address<=render_row_address+candidate_burst_x;
       update_data<=0;update_mask<=0;pixel_index<=0;state<=BUILD_PIXEL;
     end
     BUILD_PIXEL:begin
       update_data<={((kind||build_bit_on)?foreground:background),
                     update_data[255:16]};
       update_mask<={(kind?fill_selected:build_selected),update_mask[15:1]};
       if(pixel_index==15)state<=ISSUE_BURST;
       else pixel_index<=pixel_index+1'b1;
     end
     ISSUE_BURST:if(update_mask==0 || update_take)begin
       // Riempimento: si avanza di un gruppo da 16 finche' la riga non e'
       // coperta, poi si scende di una riga ripartendo dal gruppo allineato
       // che contiene il bordo sinistro.
       if(kind)begin
         if(burst_x+10'd16<clip_right)begin
           burst_x<=burst_x+10'd16;state<=FILL_PREP;
         end else if(pen_y+9'd1>=clip_bottom)state<=DONE;
         else begin
           pen_y<=pen_y+9'd1;burst_x<={1'b0,pen_x[8:4],4'd0};state<=FILL_PREP;
         end
       end else if(!second_burst && pen_x[3:0]+font_width>16 &&
          ({1'b0,pen_x[8:4],4'd0}+10'd16)<480)begin
         second_burst<=1;state<=PREP_BURST;
       end else if(glyph_row+1>=font_height ||
                   {1'b0,pen_y}+glyph_row+1>=clip_bottom)begin
         pen_x<=pen_x+font_width;state<=CHAR_ADDR;
       end else begin
         glyph_row<=glyph_row+1'b1;second_burst<=0;state<=FETCH_REQUEST;
       end
     end
     DONE:state<=WAIT_CLEAR;
     WAIT_CLEAR:if(!command_valid)state<=IDLE;
     default:state<=IDLE;
   endcase
 end
endmodule
