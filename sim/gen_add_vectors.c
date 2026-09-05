// gen_add_vectors.c —— FP32 加法金标准向量生成器
// 用 C 的 float 计算 a+b，输出 "a_bits b_bits sum_bits"。
// 随机符号 + 指数有差（测对阶）+ 部分接近（测抵消），规格化范围避免 Inf/NaN/denormal。
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

static float randf(unsigned *seed, int emin, int emax){
    uint32_t sign = (uint32_t)(rand_r(seed) & 1) << 31;
    uint32_t exp  = (uint32_t)(emin + rand_r(seed) % (emax - emin + 1)) & 0xFF;
    uint32_t frac = (uint32_t)rand_r(seed) & 0x7FFFFF;
    return b2f(sign | (exp << 23) | frac);
}

int main(int argc, char **argv){
    int N         = (argc > 1) ? atoi(argv[1]) : 200000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 7u;
    for(int i = 0; i < N; i++){
        float a = randf(&seed, 110, 140);
        float b;
        // 一半用接近 a 的指数（测对阶/抵消），一半完全随机
        if (rand_r(&seed) & 1) b = randf(&seed, 110, 140);
        else                   b = randf(&seed, (a==0?120: ( (f2b(a)>>23)&0xFF )) - 2,
                                                 ( (f2b(a)>>23)&0xFF ) + 2);
        float s = a + b;
        // 跳过结果为 0/denormal/Inf 的极端（这些走另一路径，不在本测核心）
        uint32_t sb = f2b(s);
        uint32_t se = (sb>>23)&0xFF;
        if (se==0 || se==0xFF) continue;
        printf("%08x %08x %08x\n", f2b(a), f2b(b), sb);
    }
    return 0;
}
