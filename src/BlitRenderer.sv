// COPY/SCROLL between disjoint frame buffers. The controller serializes this
// engine with drawing and PRESENT, and gives scan-out priority at every burst.
module BlitRenderer (
 input wire clk,rst_n,start,scroll,source_buffer,
 input wire [15:0] x,y,width,height,arg_x,arg_y,fill_color,
 output wire done,output reg error,
 output wire read_valid,input wire read_take,
 output reg [20:0] read_address,
 input wire read_done,input wire [255:0] read_pixels,
 output reg update_valid,input wire update_take,
 output reg [20:0] update_address,
 output reg [255:0] update_pixels,output reg [15:0] update_mask
);
 localparam [3:0] IDLE=0,VALIDATE=1,NORMALIZE=2,SETUP=3,ROW_START=4,
  BURST_START=5,PIXEL=6,READ_ADDR=7,READ_REQUEST=8,READ_WAIT=9,
  APPEND=10,WRITE_REQUEST=11,ADVANCE=12,DONE=13,PIXEL_PREP=14,SELECT_PIXEL=15;
 reg [3:0] state;
 reg [8:0] dest_left,dest_y,source_left,source_top;
 reg [9:0] dest_right,dest_bottom,source_right,source_bottom,pixel_x;
 reg [8:0] burst_x;
 reg [8:0] last_row;
 reg [4:0] last_burst;
 reg [16:0] source_x,source_y,first_source_x;
 reg [16:0] dest_row_address,source_row_address;
 reg source_row_valid,source_slot,cache_valid;
 reg [20:0] cache_address;
 reg source_pixel_valid_q;
 reg [63:0] pixel_group;
 reg source_x_carry,source_y_carry;
 reg [3:0] pixel_index;
 reg [15:0] pixel_value,color;
 reg pixel_enabled;
 wire rect_valid = x<480 && y<272 && width!=0 && height!=0 &&
     ({1'b0,x}+{1'b0,width})<=17'd480 &&
     ({1'b0,y}+{1'b0,height})<=17'd272;
 wire dest_valid = arg_x<480 && arg_y<272 &&
     ({1'b0,arg_x}+{1'b0,width})<=17'd480 &&
     ({1'b0,arg_y}+{1'b0,height})<=17'd272;
 wire source_pixel_valid = source_row_valid && source_x[16:9]==0 &&
     source_x[8:0]>=source_left && {1'b0,source_x[8:0]}<source_right;
 wire [20:0] source_address = {3'd0,source_slot,
     (source_row_address+{8'd0,source_x[8:4],4'd0})};
 assign done=state==DONE;
 assign read_valid=state==READ_REQUEST;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     state<=IDLE;error<=0;dest_left<=0;dest_y<=0;source_left<=0;source_top<=0;
     dest_right<=0;dest_bottom<=0;source_right<=0;source_bottom<=0;pixel_x<=0;
     burst_x<=0;last_row<=0;last_burst<=0;source_x<=0;source_y<=0;first_source_x<=0;
     dest_row_address<=0;source_row_address<=0;source_row_valid<=0;source_slot<=0;
     cache_valid<=0;cache_address<=0;source_pixel_valid_q<=0;pixel_index<=0;update_valid<=0;pixel_group<=0;
     pixel_value<=0;color<=0;pixel_enabled<=0;source_x_carry<=0;source_y_carry<=0;
     read_address<=0;update_address<=0;update_pixels<=0;update_mask<=0;
   end else if(start && (state==IDLE || state==DONE)) begin
     state<=VALIDATE;error<=0;cache_valid<=0;
   end else case(state)
     VALIDATE:begin
       if(!rect_valid || (!scroll && !dest_valid))begin error<=1;state<=DONE;end
       else state<=NORMALIZE;
     end
     NORMALIZE:begin
       source_slot<=source_buffer;color<=fill_color;
       source_left<=x[8:0];source_top<=y[8:0];
       source_right<={1'b0,x[8:0]}+width[9:0];
       source_bottom<={1'b0,y[8:0]}+height[9:0];
       dest_left<=scroll?x[8:0]:arg_x[8:0];
       dest_y<=scroll?y[8:0]:arg_y[8:0];
       dest_right<=(scroll?{1'b0,x[8:0]}:{1'b0,arg_x[8:0]})+width[9:0];
       dest_bottom<=(scroll?{1'b0,y[8:0]}:{1'b0,arg_y[8:0]})+height[9:0];
       // Signed displacement extended before subtraction, including -32768.
       first_source_x<=(scroll?({1'b0,x}-{arg_x[15],arg_x}):{1'b0,x})-
                       {13'd0,(scroll?x[3:0]:arg_x[3:0])};
       source_y<=scroll?({1'b0,y}-{arg_y[15],arg_y}):{1'b0,y};
       state<=SETUP;
     end
     SETUP:begin
       dest_row_address<=({8'd0,dest_y}<<9)-({8'd0,dest_y}<<5);
       last_row<=dest_bottom-10'd1;
       last_burst<=(dest_right-10'd1)>>4;
       state<=ROW_START;
     end
     ROW_START:begin
       source_y_carry<=source_y[7:0]==8'hFF;
       source_row_valid<=source_y[16:9]==0 && source_y[8:0]>=source_top &&
                         {1'b0,source_y[8:0]}<source_bottom;
       source_row_address<=({8'd0,source_y[8:0]}<<9)-({8'd0,source_y[8:0]}<<5);
       source_x<=first_source_x;burst_x<={dest_left[8:4],4'd0};
       update_address<={4'd0,dest_row_address}+{12'd0,dest_left[8:4],4'd0};
       state<=BURST_START;
     end
     BURST_START:begin
       pixel_x<={1'b0,burst_x};pixel_index<=0;update_mask<=0;update_pixels<=0;
       state<=PIXEL_PREP;
     end
     PIXEL_PREP:begin
       source_x_carry<=source_x[7:0]==8'hFF;
       read_address<=source_address;source_pixel_valid_q<=source_pixel_valid;
       pixel_enabled<=pixel_x>={1'b0,dest_left} && pixel_x<dest_right;
       state<=PIXEL;
     end
     PIXEL:begin
       if(!pixel_enabled || !source_pixel_valid_q)begin
         pixel_value<=color;state<=APPEND;
       end else if(cache_valid && cache_address==read_address)begin
         // The controller holds the last read burst until the next read.
         pixel_group<=read_pixels[{source_x[3:2],6'd0}+:64];state<=SELECT_PIXEL;
       end else state<=READ_REQUEST;
     end
     SELECT_PIXEL:begin
       pixel_value<=pixel_group[{source_x[1:0],4'd0}+:16];state<=APPEND;
     end
     READ_ADDR:begin read_address<=source_address;state<=READ_REQUEST;end
     READ_REQUEST:if(read_take)state<=READ_WAIT;
     READ_WAIT:if(read_done)begin
       cache_address<=read_address;cache_valid<=1;state<=PIXEL;
     end
     APPEND:begin
       update_pixels<={pixel_value,update_pixels[255:16]};
       update_mask<={pixel_enabled,update_mask[15:1]};
       source_x[7:0]<=source_x[7:0]+8'd1;
       source_x[16:8]<=source_x[16:8]+{8'd0,source_x_carry};
       pixel_x<=pixel_x+10'd1;
       if(pixel_index==15)begin update_valid<=1;state<=WRITE_REQUEST;end
       else begin pixel_index<=pixel_index+1'b1;state<=PIXEL_PREP;end
     end
     WRITE_REQUEST:if(update_take)begin update_valid<=0;state<=ADVANCE;end
     ADVANCE:begin
       if(burst_x[8:4]!=last_burst)begin
         burst_x<=burst_x+9'd16;update_address<=update_address+21'd16;state<=BURST_START;
       end else if(dest_y!=last_row)begin
         dest_y<=dest_y+9'd1;dest_row_address<=dest_row_address+17'd480;
         source_y[7:0]<=source_y[7:0]+8'd1;
         source_y[16:8]<=source_y[16:8]+{8'd0,source_y_carry};state<=ROW_START;
       end else state<=DONE;
     end
     default:begin end
   endcase
 end
endmodule
