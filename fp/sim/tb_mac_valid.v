`timescale 1ns/1ps

// fp32_mac_unit 的结果与 out_valid 同拍检查。
module tb_mac_valid;
    reg clk = 0;
    reg rst_n;
    reg prod_valid;
    reg acc_load;
    reg last;
    reg [31:0] a;
    reg [31:0] b;
    reg [31:0] psum_in;
    wire [31:0] mac_out;
    wire out_valid;

    fp32_mac_unit dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .prod_valid (prod_valid),
        .acc_load   (acc_load),
        .last       (last),
        .a          (a),
        .b          (b),
        .psum_in    (psum_in),
        .mac_out    (mac_out),
        .out_valid  (out_valid)
    );

    always #5 clk = ~clk;

    integer waited;
    integer failures;

    initial begin
        rst_n = 0;
        prod_valid = 0;
        acc_load = 0;
        last = 0;
        a = 0;
        b = 0;
        psum_in = 0;
        failures = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // 单项点积：0 + 1.0 * 1.0
        prod_valid = 1;
        acc_load = 1;
        last = 1;
        a = 32'h3F800000;
        b = 32'h3F800000;
        psum_in = 32'd0;

        @(negedge clk);
        prod_valid = 0;
        acc_load = 0;
        last = 0;

        waited = 0;
        while (!out_valid && waited < 16) begin
            @(negedge clk);
            waited = waited + 1;
        end

        if (!out_valid) begin
            failures = failures + 1;
            $display("FAIL: out_valid timeout");
        end else if (mac_out !== 32'h3F800000) begin
            failures = failures + 1;
            $display("FAIL: out_valid 时 mac_out=%h exp=3f800000", mac_out);
        end

        @(negedge clk);
        if (out_valid) begin
            failures = failures + 1;
            $display("FAIL: out_valid 不是单拍脉冲");
        end

        if (failures == 0) $display("ALL PASS: MAC result/out_valid alignment");
        else               $display("HAS FAILURES: %0d", failures);
        $finish;
    end
endmodule
