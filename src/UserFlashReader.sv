// Read-only, word-addressed wrapper for the GW1NR-9C FLASH608K primitive.
// A request is accepted only while ready is high; data_valid is one cycle.
module UserFlashReader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        request,
    input  wire [14:0] word_address,
    output wire        ready,
    output reg         data_valid,
    output reg  [31:0] data
);
`ifdef SIMULATION
    reg [31:0] memory [0:19455];
    reg [14:0] saved_address;
    reg [2:0] wait_count;
    initial $readmemh("fonts/user_flash_fonts.mem", memory);
    assign ready = wait_count == 0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            saved_address<=0;wait_count<=0;data_valid<=0;data<=0;
        end else begin
            data_valid<=0;
            if(request && ready) begin
                saved_address<=word_address;wait_count<=3;
            end else if(wait_count!=0) begin
                wait_count<=wait_count-1'b1;
                if(wait_count==1) begin
                    data<=memory[saved_address];data_valid<=1;
                end
            end
        end
    end
`else
    localparam [2:0] IDLE=0, SELECT=1, STROBE=2, RECOVER1=3, RECOVER2=4;
    reg [2:0] state;
    reg [8:0] x_address;
    reg [5:0] y_address;
    reg xe,ye,se;
    wire [31:0] flash_data;
    assign ready = state == IDLE;
    FLASH608K flash608k_inst (
        .DOUT(flash_data),.DIN(32'd0),.XADR(x_address),.YADR(y_address),
        .XE(xe),.YE(ye),.SE(se),.ERASE(1'b0),.PROG(1'b0),.NVSTR(1'b0)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;x_address<=0;y_address<=0;xe<=0;ye<=0;se<=0;
            data_valid<=0;data<=0;
        end else begin
            data_valid<=0;
            case(state)
              IDLE: if(request) begin
                  x_address<=word_address[14:6];
                  y_address<=word_address[5:0];
                  xe<=1;ye<=1;se<=0;state<=SELECT;
              end
              SELECT: begin se<=1;state<=STROBE;end
              STROBE: begin data<=flash_data;data_valid<=1;se<=0;state<=RECOVER1;end
              RECOVER1: state<=RECOVER2;
              default: begin xe<=0;ye<=0;state<=IDLE;end
            endcase
        end
    end
`endif
endmodule
