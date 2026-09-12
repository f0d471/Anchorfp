#!/usr/bin/env bash
# FP32 计算单元的金标准回归
#   用法：bash run_all.sh；全绿返回 0，任何一条判据不过返回 1
#   标量向量由 gen_vectors.sh 预先生成，窗口累加的向量由本脚本现生成
#   tb_fp32_recip 与 tb_fp_lat 按裸文件名读 recip_lut.mem，工作目录取 rtl/

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$(cd "$HERE/../rtl" && pwd)"
COMMON="$(cd "$HERE/../../common" && pwd)"
OUT="${TMPDIR:-/tmp}"
FAILN=0

# 判定一份输出：没有失败标记，且至少有一条通过标记（TB 什么都没打印也判失败）
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

echo "==== Anchorfp fp sim：FP32 计算单元 vs IEEE 金标准 ===="

# 倒数初值表可复现：生成器输出须与 rtl/recip_lut.mem 逐字节相同
printf "  %-18s " "gen_recip_lut"
if gcc -O2 -o "$OUT/gen_recip_lut" "$HERE/gen_recip_lut.c" -lm 2>"$OUT/gen_recip_lut.log" \
   && "$OUT/gen_recip_lut" | cmp -s - "$FP/recip_lut.mem"; then
    echo "recip_lut.mem 与生成器输出一致 -> PASS"
else
    echo "recip_lut.mem 与生成器输出不一致 -> FAIL"; FAILN=$((FAILN+1))
fi

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

# 定点窗口累加，两层金标准都在 mac_win_model.py：第一层逐位复刻硬件，
# 第二层有理数精确求和后一次正确舍入，对账打到 stderr 并入判定。
# 四种激励：常规、极小、特殊值、宽跨度
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

# 多块串接：K=256 分 4 块，块间经 FP32 回灌；跨块舍入不属于窗口，只跑第一层
python3 "$HERE/gen_dot_vectors.py" 256 100 4242 1 0 64 > "$OUT/vectors_win_mt.txt" 2>/dev/null || exit 1
TAG=tb_mac_win_mt DEFS="-DVECF=\"$OUT/vectors_win_mt.txt\" -DKLEN=256 -DKDEP=64 -DTAGNAME=\"tb_mac_win_mt\"" \
run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"

# 项数上限满额：2^GrowW = 32768 项须全绿且 C5 恒零，只取 4 组
python3 "$HERE/gen_dot_vectors.py" 32768 4 20260907 1 0 32768 > "$OUT/vectors_win_full.txt" 2>/dev/null || exit 1
TAG=tb_mac_win_full DEFS="-DVECF=\"$OUT/vectors_win_full.txt\" -DKLEN=32768 -DKDEP=32768 -DTAGNAME=\"tb_mac_win_full\"" \
run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"

# 非融合对照档（FuseMul=0）：乘积先按 IEEE 舍入一次再进窗口，与 m0 之差即融合乘加的精度收益
python3 "$HERE/gen_dot_vectors.py" 64 300 12345 0 0 64 0 \
    > "$OUT/vectors_win_f0.txt" 2> "$OUT/ref_win_f0.txt" || exit 1
TAG=tb_mac_win_f0 DEFS="-DVECF=\"$OUT/vectors_win_f0.txt\" -DFUSE=0 -DTAGNAME=\"tb_mac_win_f0\"" \
run tb_mac_win "$HERE" "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v"
printf "  %-18s %s\n" "ref_f0" "$(cat "$OUT/ref_win_f0.txt")"
verdict "$OUT/ref_win_f0.txt" 0 || FAILN=$((FAILN+1))

# 倒数：向量在本目录，表在 rtl/，软链向量后在 rtl/ 里跑
ln -sf "$HERE/vectors_recip.txt" "$FP/vectors_recip.txt"
run tb_fp32_recip  "$FP" "$FP/fp32_recip.v" "$COMMON/bram_lut_1024x32.v"
rm -f "$FP/vectors_recip.txt"

# 延迟常数：fp32_lat.vh 的判据，同样在 rtl/ 里跑
run tb_fp_lat      "$FP" "$FP/fp32_add.v" "$FP/fp32_mul_pipe.v" "$FP/fp32_cmp.v" \
                         "$FP/fp32_cvt.v" "$FP/fp32_recip.v" "$FP/fp32_mac_unit.v" \
                         "$COMMON/bram_lut_1024x32.v"

echo "SUMMARY run_all: $FAILN FAIL -> $([ "$FAILN" -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAILN" -eq 0 ]
