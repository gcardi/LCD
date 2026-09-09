`timescale 1ns/1ps
module tb_spi_directions;
    reg rst_n=1,sck=0,cs_n=0,mosi=0;
    wire seq_out,crc_out,seq_oe,crc_oe;
    SpiDiagnostic #(.MODE(1)) seq_dut(rst_n,sck,cs_n,mosi,seq_out,seq_oe);
    SpiDiagnostic #(.MODE(2)) crc_dut(rst_n,sck,cs_n,mosi,crc_out,crc_oe);
    reg [7:0] sequence_byte=8'hA5;
    reg [15:0] crc;
    reg [7:0] b,crc_expected;
    integer i,r,count=0;
    task automatic transfer(input [7:0] data_in,input [7:0] expected_crc,input integer half_period);
        integer k;
        begin
            for(k=7;k>=0;k=k-1) begin
                mosi=data_in[k]; #(half_period);
                if(!seq_oe || !crc_oe || seq_out!==sequence_byte[k] || crc_out!==expected_crc[k])
                    $fatal(1,"Direction mismatch byte %0d bit %0d",count,k);
                sck=1;#(half_period);sck=0;#1;
            end
            sequence_byte=(sequence_byte>>1)^((sequence_byte&1)?8'hB8:0);
            count=count+1;
        end
    endtask
    // Independent bit-by-bit CCITT reference (known vector checked below).
    function automatic [15:0] update_crc(input [15:0] initial_crc,input [7:0] data_in);
        integer k;reg [15:0] c;reg feedback;
        begin
            c=initial_crc;
            for(k=7;k>=0;k=k-1) begin
                feedback=c[15]^data_in[k];c=c<<1;if(feedback)c=c^16'h1021;
            end
            update_crc=c;
        end
    endfunction
    initial begin
        crc=16'hFFFF;
        for(i=8'h31;i<=8'h39;i=i+1)crc=update_crc(crc,i);
        if(crc!==16'h29B1)$fatal(1,"CRC reference vector");
        #1;rst_n=0;cs_n=1;#10;rst_n=1;
        for(r=0;r<3;r=r+1) begin
            #100;cs_n=0;sequence_byte=8'hA5;crc=16'hFFFF;
            for(i=0;i<4096;i=i+1) begin
                b=(i*37+r*53)^(i>>3);crc=update_crc(crc,b);transfer(b,8'hA5,40);
            end
            // Clock pause and slower read under the same CS.
            #1000;
            transfer(0,8'hC3,640);transfer(0,crc[15:8],640);
            transfer(0,crc[7:0],640);transfer(0,8'h5A,640);
            cs_n=1;#20;if(seq_oe || crc_oe)$fatal(1,"OE after CS");
        end
        // Abort a partial byte and verify transaction state is reset.
        cs_n=0;#40;sck=1;#40;sck=0;#40;cs_n=1;#40;cs_n=0;
        sequence_byte=8'hA5;transfer(0,8'hA5,40);
        $display("PASS: spi_directions bytes=%0d",count);$finish;
    end
    initial begin #100000000;$fatal(1,"timeout");end
endmodule
