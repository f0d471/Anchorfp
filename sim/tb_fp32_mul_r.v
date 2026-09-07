`timescale 1ns/1ps
//==============================================================================================//
// TB: tb_fp32_mul_r
//
// DESCRIPTION: fp32_mul_pipe 的右移粘滞位定向用例，覆盖随机向量打不到的进位边界。
//
// NOTE:
//   1. 随机向量命中率极低，这一族只能定向构造
//   2. 对应右移规格化时把原积 bit0 并回 sticky 那一步
//==============================================================================================//
module tb_fp32_mul_r;
    localparam MAXN = 250000;
    reg clk=0, rst_n=0; reg [31:0] a,b; reg in_valid;
    wire [31:0] p; wire out_valid;
    fp32_mul_pipe dut(.clk(clk),.rst_n(rst_n),.a(a),.b(b),.p(p),
                        .in_valid(in_valid), .flush(1'b0),.out_valid(out_valid));
    always #5 clk=~clk;
    reg [31:0] av[0:MAXN-1],bv[0:MAXN-1],ev[0:MAXN-1],expq[0:MAXN-1];
    integer count,total,exact,ulp1,ulpgt1,maxulp,i,fd,code,wr,rdp;
    integer dir_bad;            // 定向用例失败标志
    reg [31:0] dir_p;           // 定向用例捕获的结果
    reg [31:0] ta,tbb,te;
    function integer ud(input [31:0] x,input [31:0] y); ud=(x>=y)?(x-y):(y-x); endfunction
    // 定向阶段用：随时记录最近一次有效输出
    always @(posedge clk) if (out_valid) dir_p <= p;
    initial begin
        count=0; fd=$fopen("vectors_mul.txt","r");
        if(fd==0) begin $display("ERR open"); $finish; end
        while(!$feof(fd)&&count<MAXN) begin code=$fscanf(fd,"%h %h %h\n",ta,tbb,te);
            if(code==3) begin av[count]=ta;bv[count]=tbb;ev[count]=te;count=count+1; end end
        $fclose(fd); $display("loaded %0d", count);
        total=0;exact=0;ulp1=0;ulpgt1=0;maxulp=0;wr=0;rdp=0; a=0;b=0;in_valid=0;
        rst_n=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);
        for(i=0;i<count+6;i=i+1) begin
            @(negedge clk);
            if(i<count) begin a=av[i];b=bv[i];in_valid=1; expq[wr]=ev[i]; wr=wr+1; end
            else begin a=0;b=0;in_valid=0; end
            @(posedge clk);
            if(out_valid) begin total=total+1;
                if(ud(p,expq[rdp])==0) exact=exact+1;
                else if(ud(p,expq[rdp])==1) ulp1=ulp1+1;
                else begin ulpgt1=ulpgt1+1; if(ulpgt1<=5) $display("BIG got=%h exp=%h",p,expq[rdp]); end
                if(ud(p,expq[rdp])>maxulp) maxulp=ud(p,expq[rdp]); rdp=rdp+1; end
        end
        // 定向用例：右移规格化分支的粘滞位覆盖范围。
        // product[47]=1 走右移，原积 bit0 会移出 48 位容器；若不并回粘滞位，
        // 这一对的舍入会少进一位。随机向量命中该位型的概率极低，必须定向打。
        //
        // 实测：把 `prod_n[0] = product_r[1] | product_r[0]` 退回不并粘滞位的
        //    旧写法，上面那 20 万条金标准向量 **exact 仍然是 200000 (100%)，一条都不红**，
        //    只有下面这批定向用例会红。随机扫描覆盖不到这个边界不是推断，是量过的。
        //
        // 向量由 a_mant * b_mant ≡ 0x800001 (mod 2^25) 解出（a_mant 取奇数则模逆存在），
        // 阶码都取 127 ⇒ 积落在 [2,4)，不碰上溢也不碰 FTZ。
        // NEAR 那三组是**负控**：同样满足 P[22:1]==0 && P[0]==1（那一位同样被丢掉），
        // 但 P[24]==1 ⇒ lsb=1 ⇒ (sticky|lsb) 恒为 1 ⇒ 丢不丢都一样，**旧写法也应通过**。
        // 少了负控，一片红时无法区分"硬件有缺陷"和"这批向量本身算错了"。
        //
        dir_bad = 0;
        for (i = 0; i < 9; i = i + 1) begin
            case (i)
              // ---- HIT：不并回粘滞位则每组少 1 ULP ----
              0: begin ta=32'h3F800C3D; tbb=32'h3FFFEB15; te=32'h400001C7; end
              1: begin ta=32'h3F801001; tbb=32'h3FFFF001; te=32'h40000801; end
              2: begin ta=32'h3F801221; tbb=32'h3FFFF1E1; te=32'h40000B11; end
              3: begin ta=32'h3F8013C5; tbb=32'h3FFFF30D; te=32'h40000D4B; end
              4: begin ta=32'h3F801DF5; tbb=32'h3FFFE65D; te=32'h40001121; end
              5: begin ta=32'h3F801FFF; tbb=32'h3FFFDFFF; te=32'h40000FFB; end
              // ---- NEAR：负控，旧写法也应通过 ----
              6: begin ta=32'h3F800CF3; tbb=32'h3FFFEC3B; te=32'h40000310; end
              7: begin ta=32'h3F800E1F; tbb=32'h3FFFEDDF; te=32'h4000050E; end
              8: begin ta=32'h3F800FFF; tbb=32'h3FFFEFFF; te=32'h400007FE; end
            endcase
            @(negedge clk); a=ta; b=tbb; in_valid=1;
            @(negedge clk); a=0; b=0; in_valid=0;
            repeat(8) @(negedge clk);
            // 上一拍的流水已排空，此处 dir_p 即该用例结果
            if (dir_p !== te) begin
                dir_bad = dir_bad + 1;
                $display("FAIL 定向[%0d] %0s: a=%h b=%h got=%h exp=%h",
                         i, (i < 6) ? "HIT" : "NEAR", ta, tbb, dir_p, te);
            end
        end

        $display("==== fp32_mul_pipe vs IEEE golden ====");
        $display("total=%0d exact=%0d (%0d%%) off1=%0d off>1=%0d max=%0d",
                 total,exact,(exact*100)/total,ulp1,ulpgt1,maxulp);
        $display("定向(右移粘滞位) 9 组: %0d FAIL", dir_bad);
        if(exact==total && !dir_bad) $display("PASS: 100%% 精确"); else $display("FAIL/note");
        $finish;
    end
endmodule
