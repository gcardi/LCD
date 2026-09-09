`timescale 1ns/1ps
module tb_spi_diagnostic;
    reg rst_n=1, sck=0, cs_n=0, mosi=0;
    wire miso, oe;
    reg [7:0] expected, data_byte;
    integer i,j,n,count=0;
    SpiDiagnostic dut(rst_n,sck,cs_n,mosi,miso,oe);
    task automatic byte_transfer(input [7:0] data_in, input [7:0] expected_out);
        integer k;
        begin
            for(k=7;k>=0;k=k-1) begin
                mosi=data_in[k]; #640;
                if(!oe || miso !== expected_out[k]) $fatal(1,"Echo mismatch byte %0d bit %0d",count,k);
                sck=1; #640; sck=0; #1;
            end
            count=count+1;
        end
    endtask
    initial begin
        #1; rst_n=0; cs_n=1;
        #10; rst_n=1;
        for(n=0;n<8;n=n+1) begin
            #100; cs_n=0; expected=8'hA5;
            for(i=0;i<4097;i=i+1) begin
                data_byte=(i*37+n*53) ^ (i>>3);
                byte_transfer(data_byte,expected); expected=data_byte;
            end
            #50; cs_n=1; #50;
            if(oe) $fatal(1,"MISO still driven with CS high");
            // Partial byte must not survive the next selection.
            cs_n=0;
            for(j=0;j<n;j=j+1) begin #640;sck=1;#640;sck=0;end
            #50;cs_n=1;#50;
        end
        cs_n=0;byte_transfer(8'h55,8'hA5);
        $display("PASS: spi_diagnostic bytes=%0d",count);$finish;
    end
    initial begin #500000000; $fatal(1,"timeout");end
endmodule
