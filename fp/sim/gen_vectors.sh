#!/usr/bin/env bash
# 金标准向量的生成入口。向量是派生数据，不入库；跑回归之前先跑一次这个。
#
# 参照是运行生成器的机器上的 IEEE-754：每个 gen_*_vectors.c 用 C 的 float 算出期望值，
# 与被测 RTL 完全独立。窗口累加那一档的向量由 run_all.sh 自己现生成
# （gen_dot_vectors.py，两层金标准），不在这里。
#
# 用法：bash gen_vectors.sh
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CC=${CC:-gcc}
CFLAGS="-O2 -ffp-contract=off"
BIN="${TMPDIR:-/tmp}/anchorfp_gen"
mkdir -p "$BIN"

build() { $CC $CFLAGS -o "$BIN/$1" "$1.c"; }

for g in gen_add_vectors gen_mul_vectors gen_cmp_vectors gen_cvt_vectors \
         gen_ftz_vectors gen_denorm_vectors gen_recip_vectors; do
    build "$g"
done

# 加法与乘法的生成器跳过结果为 0/denormal/Inf 的样本，所以多要一些再截断，
# 保证每次生成的条数是定值
"$BIN/gen_add_vectors" 300000 7 | head -n 250000 > vectors_add.txt
"$BIN/gen_mul_vectors" 220000 1 | head -n 200000 > vectors_mul.txt

# 这三个生成器自己写文件，条数由内部的定向用例决定
"$BIN/gen_cmp_vectors"   200000 37
"$BIN/gen_cvt_vectors"   100000 37
"$BIN/gen_recip_vectors" 20000 37

# FTZ 档：0 为加法，1 为乘法
"$BIN/gen_ftz_vectors" 0 200000 13
"$BIN/gen_ftz_vectors" 1 200000 13

# denormal 档全是定向用例，无随机
"$BIN/gen_denorm_vectors" > vectors_denorm.txt

wc -l vectors_*.txt
