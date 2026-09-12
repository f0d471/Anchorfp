// gen_mul_vectors.c —— FP32 乘法金标准向量生成器
// 用 C 的 float（正确舍入的 IEEE FP32）计算 a*b，输出 "a_bits b_bits prod_bits" 十六进制。
// 仅生成规格化、乘积不溢出/不下溢的常规用例，专测核心舍入。
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

// 随机规格化 float：指数限定在 [emin,emax]，避免 denormal/Inf/NaN
static float randf(unsigned *seed, int emin, int emax){
    uint32_t sign = (uint32_t)(rand_r(seed) & 1) << 31;
    uint32_t exp  = (uint32_t)(emin + rand_r(seed) % (emax - emin + 1)) & 0xFF;
    uint32_t frac = (uint32_t)rand_r(seed) & 0x7FFFFF;
    return b2f(sign | (exp << 23) | frac);
}

int main(int argc, char **argv){
    int N         = (argc > 1) ? atoi(argv[1]) : 200000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 1u;
    // 指数范围 [110,145]：乘积指数约 [93,163]，均规格化、不溢出
    for(int i = 0; i < N; i++){
        float a = randf(&seed, 110, 145);
        float b = randf(&seed, 110, 145);
        float p = a * b;                 // 正确舍入的 IEEE FP32 乘积
        printf("%08x %08x %08x\n", f2b(a), f2b(b), f2b(p));
    }
    return 0;
}
