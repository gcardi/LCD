`timescale 1ns/1ps
// SPI mode 0, 8 bits, MSB first. All parallel ports belong to spi_sck.
// rx_push/rx_data are sampled ON the rising edge (FIFO write interface),
// not registered notifications to be sampled on a later edge.
// tx_data/tx_valid form a show-ahead source; tx_take consumes on a rising edge.
// See docs/SPI_SLAVE.md for timing, reset and CDC integration requirements.
module SpiSlave #(
    parameter [7:0] IDLE_BYTE = 8'hFF,
    // Fixed-response endpoints can drive MISO directly from the shift register.
    // Their first tx_data byte must equal FIRST_BYTE. Generic FIFO mode is unchanged.
    parameter FIXED_FIRST_BYTE = 0,
    parameter [7:0] FIRST_BYTE = 8'hA5
) (
    input  wire       rst_n,
    input  wire       spi_sck,
    input  wire       spi_cs_n,
    input  wire       spi_mosi,
    output wire       spi_miso,
    output wire       spi_miso_oe,
    output wire [7:0] rx_data,
    output wire       rx_push,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_take
);
    wire active = rst_n && !spi_cs_n;
    wire serial_reset = !rst_n || spi_cs_n;
    reg [2:0] bit_count;
    reg [6:0] rx_shift;
    reg [7:0] tx_latched;
    reg [7:0] tx_shift;
    reg tx_started;
    wire [7:0] next_tx = tx_valid ? tx_data : IDLE_BYTE;

    assign rx_data = {rx_shift, spi_mosi};
    assign rx_push = active && (bit_count == 3'd7);
    assign tx_take = active && (bit_count == 3'd0) && tx_valid;
    assign spi_miso_oe = active;
    // Tri-state is deliberately left to the top-level I/O buffer.
    assign spi_miso = FIXED_FIRST_BYTE ? tx_shift[7] :
                     (!active ? 1'b0 : (!tx_started ? next_tx[7] : tx_shift[7]));

    always @(posedge spi_sck or posedge serial_reset) begin
        if (serial_reset) begin
            bit_count <= 3'd0;
            rx_shift <= 7'd0;
            tx_latched <= IDLE_BYTE;
        end else begin
            bit_count <= bit_count + 3'd1;
            rx_shift <= {rx_shift[5:0], spi_mosi};
            if (bit_count == 3'd0) begin
                tx_latched <= next_tx;
            end
        end
    end

    // First MSB is visible before any clock. Subsequent bits change only
    // on falling edges; the latched byte survives a source FIFO advance.
    always @(negedge spi_sck or posedge serial_reset) begin
        if (serial_reset) begin
            tx_shift <= FIXED_FIRST_BYTE ? FIRST_BYTE : IDLE_BYTE;
            tx_started <= 1'b0;
        end else begin
            tx_started <= 1'b1;
            if (bit_count == 3'd0)
                tx_shift <= next_tx;
            else if (bit_count == 3'd1)
                tx_shift <= {tx_latched[6:0], 1'b0};
            else
                tx_shift <= {tx_shift[6:0], 1'b0};
        end
    end
endmodule
