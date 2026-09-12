/* gen_recip_lut.c —— 生成 fp32_recip 的牛顿迭代初值表 recip_lut.mem
 *
 * 凡是进 RTL 的表都要有可复现的生成器，表的口径以本文件为准。
 *
 * 表的内容
 *   索引 i = 尾数高 10 位（frac[22:13]），覆盖 m ∈ [1+i/1024, 1+(i+1)/1024)
 *   存 r0 = round(1/m_mid * 2^17)，m_mid = 1 + (i+0.5)/1024   —— Q0.17，18 位有效
 *
 * 为什么是**中点**而不是左端点
 *   左端点：区间内最大相对误差 ≈ 2^-10；中点：≈ 2^-11。牛顿一轮把误差平方，
 *   2^-11 → 2^-22 ≈ 2.4e-7，正好落在目标"~1e-7 量级"；用左端点只能到 2^-20。
 *   一次改表白赚一位精度，比多加一轮牛顿（一个 42 位乘法器）便宜得多。
 *
 * 为什么是 Q0.17
 *   r0 ∈ (0.5, 1] ⇒ 18 位无符号刚好装下（1.0 → 0x20000）。
 *   量化误差 2^-18 ≪ 区间误差 2^-11，不吃精度预算。
 *
 * 用法：gcc -O2 -o gen_recip_lut gen_recip_lut.c -lm && ./gen_recip_lut > recip_lut.mem
 */
#include <stdio.h>
#include <math.h>

int main(void)
{
    int i;
    for (i = 0; i < 1024; i++) {
        /* 区间中点。用 double 算，避免初值表本身带 float 舍入误差 */
        double m_mid = 1.0 + ((double)i + 0.5) / 1024.0;
        double r0    = 1.0 / m_mid;                 /* ∈ (0.5, 1] */
        long   q     = lround(r0 * 131072.0);       /* Q0.17 */
        if (q > 131072L) q = 131072L;               /* i=0 时理论上取不到，兜底 */
        printf("%08lx\n", (unsigned long)q);
    }
    return 0;
}
