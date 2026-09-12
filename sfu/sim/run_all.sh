#!/usr/bin/env bash
# SFU 回归：表校验、三个发起形态测试台、逐位对拍与独立数学参考复核
#   用法：bash run_all.sh；全绿返回 0，任何一条判据不过返回 1
#   仿真在临时目录里跑，查找表与激励先拷进去，源目录不留产物

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL="$(cd "$HERE/../rtl" && pwd)"
COMMON="$(cd "$HERE/../../common" && pwd)"
OUT="${TMPDIR:-/tmp}/anchorfp_sfu"
PY=${PYTHON:-python3}
FAILN=0
mkdir -p "$OUT"
cp -f "$RTL"/*.mem "$HERE/vec.hex" "$OUT/"

# 判定一份输出：没有失败标记，且至少有一条通过标记
verdict() {                   # verdict <日志文件> <运行退出码>
    local log=$1 rc=$2 neg pos
    [ "$rc" -eq 0 ] || return 1
    neg=$(grep -cE 'FAIL|ERROR|Unable to bind|\$fatal|WATCHDOG' "$log")
    pos=$(grep -cE 'ALL PASS|^PASS ' "$log")
    [ "$neg" -eq 0 ] && [ "$pos" -ge 1 ]
}

fail() { printf "  %-18s 判定 -> FAIL（全文见 %s）\n" "$1" "$2"; FAILN=$((FAILN+1)); }

run() {                       # run <tb名> <源文件...>
    local tb=$1; shift
    local log="$OUT/$tb.out" rc
    printf "  %-18s " "$tb"
    if ! iverilog -g2012 -I"$RTL" -o "$OUT/$tb.vvp" "$HERE/$tb.v" "$@" 2>"$OUT/$tb.clog"; then
        echo "编译失败 -> FAIL，见 $OUT/$tb.clog"; FAILN=$((FAILN+1)); return 1
    fi
    ( cd "$OUT" && vvp "$OUT/$tb.vvp" ) >"$log" 2>&1
    rc=$?
    grep -E 'SUMMARY' "$log" | tail -1 | sed 's/^ *//'
    verdict "$log" "$rc" || fail "$tb" "$log"
}

echo "==== Anchorfp sfu sim：超越函数单元 ===="

# 表可复现：rtl/ 下的表与 manifest 须逐字节等于生成器输出
printf "  %-18s " "gen_luts --check"
if "$PY" "$HERE/gen_luts.py" --check >"$OUT/gen_luts.out" 2>&1; then
    echo "$(grep -c '^OK' "$OUT/gen_luts.out") 个文件一致 -> PASS"
else
    echo "表或 manifest 与生成器输出不一致 -> FAIL"; FAILN=$((FAILN+1))
fi

run tb_rsqrt_stream  "$RTL/rsqrt_func.v" "$COMMON/bram_lut_1024x32.v"
run tb_sfu_stream    "$RTL/exp_func.v" "$RTL/sin_func.v" "$RTL/cos_func.v" \
                     "$RTL/sincos_func.v" "$RTL/trig_phase_reduce.v" "$COMMON/bram_lut_1024x32.v"
run tb_sincos_shared "$RTL/sincos_func.v" "$RTL/trig_phase_reduce.v" "$COMMON/bram_lut_1024x32.v"

# 逐位对拍：取样台写出 golden.txt，先交独立数学参考复核，再与冻结参考逐位比较
printf "  %-18s " "tb_sfu_golden"
if iverilog -g2012 -I"$RTL" -o "$OUT/tb_sfu_golden.vvp" "$HERE/tb_sfu_golden.v" \
        "$RTL/exp_func.v" "$RTL/sin_func.v" "$RTL/cos_func.v" "$RTL/sincos_func.v" \
        "$RTL/trig_phase_reduce.v" "$RTL/rsqrt_func.v" "$COMMON/bram_lut_1024x32.v" \
        2>"$OUT/tb_sfu_golden.clog" \
   && ( cd "$OUT" && rm -f golden.txt && vvp "$OUT/tb_sfu_golden.vvp" ) >"$OUT/tb_sfu_golden.out" 2>&1 \
   && [ -s "$OUT/golden.txt" ]; then
    echo "$(wc -l < "$OUT/golden.txt") 条激励已取样"
else
    echo "取样失败 -> FAIL，见 $OUT/tb_sfu_golden.out"; FAILN=$((FAILN+1))
fi

printf "  %-18s " "verify_sfu"
"$PY" "$HERE/verify_sfu.py" "$OUT/golden.txt" >"$OUT/verify_sfu.out" 2>&1
rc=$?
grep -E '^PASS|^FAIL' "$OUT/verify_sfu.out" | head -1
grep -E 'max_error' "$OUT/verify_sfu.out" | sed 's/^/                       /'
verdict "$OUT/verify_sfu.out" "$rc" || fail verify_sfu "$OUT/verify_sfu.out"

printf "  %-18s " "golden_ref"
if cmp -s "$HERE/golden_ref.txt" "$OUT/golden.txt"; then
    echo "9500 条激励逐位等于 golden_ref.txt -> PASS"
else
    echo "与 golden_ref.txt 有 $(diff "$HERE/golden_ref.txt" "$OUT/golden.txt" | grep -c '^<') 行不同 -> FAIL"
    FAILN=$((FAILN+1))
fi

echo "SUMMARY run_all: $FAILN FAIL -> $([ "$FAILN" -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAILN" -eq 0 ]
