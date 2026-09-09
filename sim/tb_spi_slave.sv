`timescale 1ns/1ps
module tb_spi_slave;
    reg rst_n = 0, sck = 0, cs_n = 1, mosi = 0;
    reg [7:0] tx_data = 0;
    reg tx_valid = 0;
    wire miso, oe, push, take;
    wire [7:0] rx_data;
    wire miso_pin = oe ? miso : 1'bz;
    integer received = 0, consumed = 0;
    reg [7:0] expected_rx;
    integer half_period = 500;
    reg [31:0] rng = 32'h12345678;
    reg [7:0] a, b;
    integer i, j;

    SpiSlave dut (
        .rst_n(rst_n), .spi_sck(sck), .spi_cs_n(cs_n),
        .spi_mosi(mosi), .spi_miso(miso),
        .spi_miso_oe(oe), .rx_data(rx_data),
        .rx_push(push), .tx_data(tx_data), .tx_valid(tx_valid), .tx_take(take)
    );

    always @(posedge sck) begin
        if (push) begin
            if (rx_data !== expected_rx)
                $fatal(1, "RX mismatch byte=%h expected=%h",
                       rx_data, expected_rx);
            received = received + 1;
        end
        if (take) consumed = consumed + 1;
    end

    task automatic select_slave;
        begin
            sck = 0;
            #73; cs_n = 0; #127;
            if (!oe) $fatal(1, "MISO not enabled");
        end
    endtask
    task automatic deselect_slave;
        begin
            #31; cs_n = 1; #17;
            if (miso_pin !== 1'bz || push || take)
                $fatal(1, "Deselected outputs");
        end
    endtask
    task automatic send_byte(input [7:0] value, input [7:0] reply,
                             input [7:0] following,
                             input bit following_valid);
        integer k;
        reg sampled;
        begin
            expected_rx = value;
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = value[k];
                #(half_period);
                sampled = miso_pin;
                if (sampled !== reply[k])
                    $fatal(1, "MISO bit %0d got %b expected %b", k, sampled, reply[k]);
                sck = 1;
                #1;
                // Model a show-ahead FIFO advancing after tx_take.
                if (k == 7) begin
                    tx_data = following; tx_valid = following_valid;
                end
                #(half_period-1); sck = 0;
                #1;
            end
        end
    endtask

    initial begin
        #11; rst_n = 1; #19;
        // Clock activity while deselected must have no side effects.
        repeat (9) begin #20; sck = 1; #20; sck = 0; end
        if (received || consumed) $fatal(1, "Inactive transfer");
        tx_data = 8'hA5; tx_valid = 1;
        select_slave();
        send_byte(8'h96, 8'hA5, 8'h3C, 1);
        // Pause indefinitely between bytes with CS low.
        #13007;
        send_byte(8'h00, 8'h3C, 8'h00, 0);
        send_byte(8'hFF, 8'hFF, 8'h81, 1);
        send_byte(8'h81, 8'h81, 8'h00, 0);
        deselect_slave();
        if (received != 4 || consumed != 3) $fatal(1, "Basic counts");

        // Abort after every possible partial-byte length and restart.
        for (i = 1; i < 8; i = i + 1) begin
            select_slave();
            for (j = 0; j < i; j = j + 1) begin
                #50; sck = 1; #50; sck = 0;
            end
            deselect_slave();
            if (received != 3+i) $fatal(1, "Partial byte emitted");
            select_slave();
            send_byte(8'h5A, 8'hFF, 0, 0);
            deselect_slave();
        end
        // Completed final byte must be delivered even without its falling
        // edge, or any further SCK edge, before CS rises.
        expected_rx = 8'hFF;
        select_slave(); mosi = 1;
        repeat (7) begin #50; sck = 1; #50; sck = 0; end
        #50; sck = 1; #2;
        deselect_slave(); sck = 0;
        if (received != 12) $fatal(1, "Final byte lost");

        // Reset in the middle of a selected transaction, then restart.
        select_slave();
        repeat (3) begin #50; sck = 1; #50; sck = 0; end
        rst_n = 0; #13;
        if (oe || push || take) $fatal(1, "Reset outputs");
        cs_n = 1; #17; rst_n = 1;
        select_slave();
        send_byte(8'hC3, 8'hFF, 0, 0);
        deselect_slave();
        if (received != 13) $fatal(1, "Reset recovery");

        // Deterministic randomized full-duplex transactions and SCK periods.
        for (i = 0; i < 256; i = i + 1) begin
            rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
            a = rng[7:0]; b = rng[15:8];
            half_period = 30 + rng[23:17];
            tx_data = b; tx_valid = 1;
            select_slave();
            send_byte(a, b, ~b, 1);
            send_byte(~a, ~b, 0, 0);
            deselect_slave();
        end
        if (received != 525 || consumed != 515) $fatal(1, "Final counts RX=%0d TX=%0d", received, consumed);
        $display("PASS: spi_slave RX=%0d TX=%0d", received, consumed);
        $finish;
    end
    initial begin #10000000; $fatal(1, "Simulation timeout"); end
endmodule
