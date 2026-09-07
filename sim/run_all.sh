#!/usr/bin/env bash
# FP32 计算单元的金标准回归。动了 rtl/ 里任何一个模块就跑它。
#   用法：bash run_all.sh；全绿返回 0，任何一条判据不过返回 1
#   向量由 gen_*_vectors.c 生成，已生成的 vectors_*.txt 在本目录
#   tb_fp32_recip 与 tb_fp_lat 读 recip_lut.mem，须在放表的 rtl/ 目录里跑

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$(cd "$HERE/../rtl" && pwd)"
SFU="$(cd "$HERE/../rtl" && pwd)"
OUT="${TMPDIR:-/tmp}"
FAILN=0

# 判定一份输出。要求既没有失败标记，又至少有一条通过标记，
# 后半条是为了让「TB 什么都没打印」也判成失败
verdict() {                   # verdict <日志文件> <运行退出码>
    local log=$1 rc=$2 neg pos
    [ "$rc" -eq 0 ] || return 1
    neg=$(sed 's/\b0 FAIL/0-fail/g' "$log" \
          | grep -cE 'FAIL|ERROR|Unable to bind|\$fatal')
    pos=$(grep -cE 'ALL PASS|-> PASS|PASS: 100%' "$log")
    [ "$neg" -eq 0 ] && [ "$pos" -ge 1 ]
}

run() {                       # run <tb名> <运行目录> <源文件...>；DEFS 传给 iverilog 的 -D
    local tb=$1; shift
    local cwd=$1; shift
    local tag=${TAG:-$tb}
    local log="$OUT/$tag.out" rc
    printf "  %-18s " "$tag"
    if ! iverilog -g2012 -I"$FP" ${DEFS:-} -o "$OUT/$tag.vvp" "$HERE/$tb.v" "$@" 2>"$OUT/$tag.log"; then
        echo "编译失败 -> FAIL，见 $OUT/$tag.log"; FAILN=$((FAILN+1)); return 1
    fi
    ( cd "$cwd" && vvp "$OUT/$tag.vvp" ) >"$log" 2>&1
    rc=$?
    grep -iE "ALL PASS|HAS FAILURES|FAIL|PASS,|PASS:|bad=|exact|total=|random golden|超容差" "$log" \
        | tail -2
    if ! verdict "$log" "$rc"; then
        printf "  %-18s 判定 -> FAIL（退出码 %s，全文见 %s）\n" "$tag" "$rc" "$log"
        FAILN=$((FAILN+1))
    fi
}

echo "==== Anchorfp sim：FP32 计算单元 vs IEEE 金标准 ===="
run tb_fp32_add    "$HERE" "$FP/fp32_add.v"
run tb_fp32_mul    "$HERE" "$FP/fp32_mul_pipe.v"
run tb_fp32_mul_r  "$HERE" "$FP/fp32_mul_pipe.v"
run tb_fp32_cmp    "$HERE" "$FP/fp32_cmp.v"
run tb_fp32_cvt    "$HERE" "$FP/fp32_cvt.v"
run tb_fp_ftz      "$HERE" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v"
run tb_fp32_denorm "$HERE" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v"
run tb_mac_valid   "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v"
run tb_mac_cap     "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v"
run tb_mac_equiv2  "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v"
run tb_mac_prec    "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"

# fp32_mac_unit 的定点窗口累加。金标准两层都在 mac_win_model.py 里：
#   第一层逐位复刻硬件，第二层用 Fraction 精确求和后一次正确舍入。
#   生成器把第二层的对账打到 stderr，这里一并收进判定行。
# 四种激励各跑一遍：常规 / 极小(FTZ 与窗口下方截断) / 特殊值(NaN Inf 零) /
# 宽跨度(乘积指数跨 210 位，逼出基准上调)。向量现生成不入库。
for m in 0 1 2 3; do
    python3 "$HERE/gen_dot_vectors.py" 64 300 12345 0 "$m" 64 \
        > "$OUT/vectors_win_m$m.txt" 2> "$OUT/ref_win_m$m.txt" || exit 1
    TAG="tb_mac_win_m$m" DEFS="-DVECF=\"$OUT/vectors_win_m$m.txt\" -DTAGNAME=\"tb_mac_win_m$m\"" \
    run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"
    if [ -s "$OUT/ref_win_m$m.txt" ]; then
        printf "  %-18s %s\n" "ref_m$m" "$(cat "$OUT/ref_win_m$m.txt")"
        verdict "$OUT/ref_win_m$m.txt" 0 || FAILN=$((FAILN+1))
    fi
done

# 多块串 psum：K=256 分 4 块，块间经 FP32 回灌。跨 tile 那几次舍入不属于窗口的账，
# 所以这一档只跑第一层
python3 "$HERE/gen_dot_vectors.py" 256 100 4242 1 0 64 > "$OUT/vectors_win_mt.txt" 2>/dev/null || exit 1
TAG=tb_mac_win_mt DEFS="-DVECF=\"$OUT/vectors_win_mt.txt\" -DKLEN=256 -DKDEP=64 -DTAGNAME=\"tb_mac_win_mt\"" \
run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"

# 进位保存累加器档已删除：UseCarrySave = 1 与默认档不逐位等价（两个分量各自算术
# 右移，分别截断再相加不等于先相加再截断），已由 cancel 激励实测 64 例差 10 例。
# 该构型不在支持集合内，fp32_mac_unit 的例化期检查会挡住它。

# 非融合对照档：乘积侧仍按 IEEE 舍入一次再进窗口（FuseMul=0）。
# 参考层是同一把尺子，这一档与 m0 的 maxULP 之差即融合乘加买到的精度
python3 "$HERE/gen_dot_vectors.py" 64 300 12345 0 0 64 0 \
    > "$OUT/vectors_win_f0.txt" 2> "$OUT/ref_win_f0.txt" || exit 1
TAG=tb_mac_win_f0 DEFS="-DVECF=\"$OUT/vectors_win_f0.txt\" -DFUSE=0 -DTAGNAME=\"tb_mac_win_f0\"" \
run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"
printf "  %-18s %s\n" "ref_f0" "$(cat "$OUT/ref_win_f0.txt")"
verdict "$OUT/ref_win_f0.txt" 0 || FAILN=$((FAILN+1))

# recip 的向量在本目录，表在 sfu/，所以把向量软链过去再在 sfu/ 里跑
ln -sf "$HERE/vectors_recip.txt" "$SFU/vectors_recip.txt"
run tb_fp32_recip  "$SFU" "$FP/fp32_recip.v" "$SFU/bram_lut_1024x32.v"
rm -f "$SFU/vectors_recip.txt"

# 延迟对账：fp32_lat.vh 的判据。也在 sfu/ 里跑（recip 要读 recip_lut.mem）
run tb_fp_lat      "$SFU" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v" "$FP/fp32_cmp.v" \
                          "$FP/fp32_cvt.v" "$FP/fp32_recip.v" "$FP/fp32_mac_unit.v" \
                          "$SFU/bram_lut_1024x32.v"

echo "SUMMARY run_all: $FAILN FAIL -> $([ "$FAILN" -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAILN" -eq 0 ]
