#!/usr/bin/env python3
"""生成「给对齐移出位补 sticky」的实验副本，用来量这个修法的面积代价。

只改 exp2/ 下的副本，不动产线 RTL。跑法：
    python3 mk_exp2.py
    vivado -mode batch -source ooc_mac.tcl -tclargs exp_sticky 8 8 0 1 ./exp2

修法的形状：al_pre = {8'b0, mant48, 32'b0}，低 TW-48 位恒零，
所以「右移 a1_sh 丢掉非零位」等价于 a1_sh > TW-48 且 mant48 的低
(a1_sh-(TW-48)) 位里有 1，也就是尾随零个数小于被丢的位数。
这样只要一个 48 位尾随零计数器加一个比较器，不必再挂一个 AccW 位的
可变掩码移位器 —— 后者的形状与桶形移位器同阶，那才是真贵的做法。

注意这个修法在数值上**不是无条件正确的**：一个布尔 sticky 恢复不了被丢残差的
符号，正负项抵消时它可能把结果推向错误的方向。这里只量代价，不主张采纳。
"""

import io
import os

SRC = "../rtl/fp32_mac_unit.v"
DST = "exp2/fp32_mac_unit.v"

ADD = '''    // 实验：对齐移出位的 sticky
    integer ci;
    reg [5:0] ctz_c;
    always @(*) begin
        ctz_c = 6'd48;
        for (ci = 47; ci >= 0; ci = ci - 1)
            if (a1_mant[ci]) ctz_c = ci[5:0];
    end
    wire [ShAmtW:0] al_drop = {1'b0, a1_sh} - (TW - 48);
    wire al_lost = (a1_sh > (TW - 48)) && ({{(ShAmtW-5){1'b0}}, ctz_c} < al_drop);

    reg f_lost;
    always @(posedge clk) begin
        if (!rst_n)                   f_lost <= 1'b0;
        else if (acc_load)            f_lost <= 1'b0;
        else if (a1_valid && al_lost) f_lost <= 1'b1;
    end

    // 共用桶形右移器'''

EDITS = [
    ("    // 共用桶形右移器", ADD),
    ("    reg               n1_sign, n1_zero,",
     "    reg               n1_lost;\n    reg               n1_sign, n1_zero,"),
    ("            n1_zero <= (acc_mag == {AccW{1'b0}});",
     "            n1_zero <= (acc_mag == {AccW{1'b0}});\n            n1_lost <= f_lost;"),
    ("    reg             n2_sign, n2_zero,",
     "    reg             n2_lost;\n    reg             n2_sign, n2_zero,"),
    ("            n2_stk  <= |mn[AccW-26:0];",
     "            n2_stk  <= |mn[AccW-26:0];\n            n2_lost <= n1_lost;"),
    ("    wire        mn_stk = n2_stk;",
     "    wire        mn_stk = n2_stk | n2_lost;"),
]


def main():
    s = io.open(SRC, encoding="utf-8").read()
    for old, new in EDITS:
        if old not in s:
            raise SystemExit("锚点不在了，产线 RTL 变过：%r" % old[:40])
        s = s.replace(old, new, 1)
    os.makedirs("exp2", exist_ok=True)
    io.open(DST, "w", encoding="utf-8", newline="\n").write(s)
    print("EXP2-OK 已生成 %s" % DST)


if __name__ == "__main__":
    main()
