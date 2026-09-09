`timescale 1ns/1ps
// Diagnostic protocol only: first reply A5, then previous received byte.
// CS high resets the diagnostic transaction as well as the SPI bit counter.
// Entire endpoint stays in SCK domain: no PSRAM or system-clock CDC.
module SpiDiagnostic #(parameter MODE=0) (
    input wire rst_n, sck, cs_n, mosi,
    output wire miso, miso_oe
);
    wire [7:0] received;
    wire push;
    wire [7:0] reply;
    wire reset_transaction = !rst_n || cs_n;
    generate if (MODE==2) begin : crc_test
        reg [12:0] count;
        reg [15:0] crc;
        always @(posedge sck or posedge reset_transaction) begin
            if(reset_transaction) begin count<=0;crc<=16'hFFFF;end
            else begin
                if(push && count<4100) count<=count+1'b1;
                // Bit-serial CRC avoids an eight-stage combinational byte CRC.
                if(count<4096) crc<=(crc<<1)^((crc[15]^mosi)?16'h1021:16'h0000);
            end
        end
        // 4096 payload bytes, followed by status C3/CRC-high/CRC-low/5A.
        // CS stays low while the master lowers SCK for this status read.
        assign reply=count==4096 ? 8'hC3 : count==4097 ? crc[15:8] :
                     count==4098 ? crc[7:0] : count==4099 ? 8'h5A : 8'hA5;
    end else begin : stream_test
        reg [7:0] value;
        always @(posedge sck or posedge reset_transaction) begin
            if (reset_transaction) value <= 8'hA5;
            else if (push) value <= MODE==1 ? ((value>>1) ^ (value[0]?8'hB8:8'h00)) : received;
        end
        assign reply=value;
    end endgenerate
    SpiSlave serial (
        .rst_n(rst_n), .spi_sck(sck), .spi_cs_n(cs_n), .spi_mosi(mosi),
        .spi_miso(miso), .spi_miso_oe(miso_oe), .rx_data(received),
        .rx_push(push), .tx_data(reply), .tx_valid(1'b1), .tx_take()
    );
endmodule
