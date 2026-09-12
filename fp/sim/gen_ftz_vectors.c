#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

static float randf_exp(unsigned *seed, int emin, int emax){
    uint32_t sign = (uint32_t)(rand_r(seed) & 1) << 31;
    uint32_t exp  = (uint32_t)(emin + rand_r(seed) % (emax - emin + 1)) & 0xFF;
    uint32_t frac = (uint32_t)rand_r(seed) & 0x7FFFFF;
    return b2f(sign | (exp << 23) | frac);
}

static inline float ftz(float x){
    uint32_t b = f2b(x);
    return ((b & 0x7F800000u) == 0u) ? b2f(b & 0x80000000u) : x;
}

static float ref_add(float a, float b){ return ftz(ftz(a) + ftz(b)); }
static float ref_mul(float a, float b){ return ftz(ftz(a) * ftz(b)); }

/* classify for NaN comparison: 0=normal, 1=qNaN, 2=sNaN */
static int cls(uint32_t u){
    if ((u & 0x7F800000u) == 0x7F800000u){
        if (u & 0x007FFFFFu) return 1; /* qNaN */
        return 0; /* Inf */
    }
    return 0;
}

int main(int argc, char **argv){
    int which      = (argc > 1) ? atoi(argv[1]) : 0; /* 0=add, 1=mul */
    int N          = (argc > 2) ? atoi(argv[2]) : 200000;
    unsigned seed  = (argc > 3) ? (unsigned)atoi(argv[3]) : 13u;
    const char *fn = which ? "vectors_mul_ftz.txt" : "vectors_add_ftz.txt";
    FILE *fp = fopen(fn, "w");
    if (!fp) { fprintf(stderr, "ERR open %s\n", fn); return 1; }
    for (int i = 0; i < N; i++){
        float a = randf_exp(&seed, 0, 255);
        float b = randf_exp(&seed, 0, 255);
        float r = which ? ref_mul(a, b) : ref_add(a, b);
        fprintf(fp, "%08x %08x %08x\n", f2b(a), f2b(b), f2b(r));
    }
    fclose(fp);
    printf("wrote %d vectors to %s (seed=%u)\n", N, fn, seed);
    return 0;
}
