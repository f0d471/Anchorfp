#!/usr/bin/env bash
# fp32_mac_unit 定点窗口的精度闭环：定向反例、注错见红、项数边界与误差报告。
#   用法：bash run_mac_audit.sh；全绿返回 0，任何一条不过返回 1
#   注错见红指把金标准改坏一处，逐位对拍必须当场红
#   向量现生成不入库；PYTHON 环境变量可覆盖解释器

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$(cd "$HERE/../rtl" && pwd)"
OUT="${TMPDIR:-/tmp}"
PY=${PYTHON:-python3}
BAD=0

# 编译并跑一次 tb_mac_win，回显它的 SUMMARY 行。$1 标签 $2 向量文件 $3 K $4 KDEP
run_win() {
    local tag=$1 vecf=$2 klen=$3 kdep=$4
    if ! iverilog -g2012 -I"$FP" \
            -DVECF="\"$vecf\"" -DKLEN=$klen -DKDEP=$kdep -DTAGNAME="\"$tag\"" \
            -o "$OUT/$tag.vvp" "$HERE/tb_mac_win.v" \
            "$FP/fp32_mac_unit.v" "$FP/fp32_mul_pipe.v" 2>"$OUT/$tag.clog"; then
        echo "COMPILE-FAIL $tag，见 $OUT/$tag.clog"; return 2
    fi
    ( cd "$HERE" && vvp "$OUT/$tag.vvp" ) 2>&1 | grep '^SUMMARY'
}

echo "==== fp32_mac_unit 窗口精度闭环：五类定向反例 + 契约枚举 ===="

# 一 正常档：RTL 与逐位金标准在五类边界上必须完全相同
for c in halfway tiny mirror cancel xtile spec; do
    geo=$("$PY" "$HERE/mac_error_audit.py" vectors "$c" "$OUT/vec_$c.txt" 2>/dev/null)
    K=${geo% *}; KD=${geo#* }
    line=$(run_win "mac_$c" "$OUT/vec_$c.txt" "$K" "$KD")
    printf "  %-20s %s\n" "$c" "$line"
    case "$line" in *"-> PASS"*) ;; *) BAD=$((BAD+1));; esac
done

# 二 注错见红。每个注入点要配一类能观测到它的向量，配错向量则注错也不红：
#   align_jam   配 halfway  丢的正是决定 RNE 进位的 sticky
#   rescale_rtz 配 cancel   换基之后要发生抵消，低位才重新主导结果
#   clr_keep    配 cancel   注入是让旧和原地不动，右移到底与清空同结果
#   pack_trunc  配 mirror   随机尾数才有进位，halfway 取偶与截断都不进位
#   win_pad     配 halfway  加宽窗口只在丢的那一位可观测时才看得出
# 向量本身不变，只有期望值由被注错的金标准算出，所以红必须红在 bad 上。
echo "==== 注错见红：金标准被改坏时上面那五条判据必须当场红 ===="
inject_case() {
    local inj=$1 c=$2
    local geo K KD line nbad
    geo=$("$PY" "$HERE/mac_error_audit.py" vectors "$c" "$OUT/vec_inj_$inj.txt" "$inj" 2>/dev/null)
    K=${geo% *}; KD=${geo#* }
    line=$(run_win "macinj_$inj" "$OUT/vec_inj_$inj.txt" "$K" "$KD")
    nbad=$(printf '%s' "$line" | sed -n 's/.*bad=\([0-9]*\).*/\1/p')
    if [ -n "$nbad" ] && [ "$nbad" -gt 0 ]; then
        printf "  %-20s 注错见红 (%s 组不匹配, 用 %s 向量) -> PASS\n" "$inj" "$nbad" "$c"
    else
        printf "  %-20s 注错未见红 (bad=%s, 用 %s 向量) -> FAIL\n" "$inj" "${nbad:-空}" "$c"
        BAD=$((BAD+1))
    fi
}
inject_case align_jam   halfway
inject_case rescale_rtz cancel
inject_case clr_keep    cancel
inject_case pack_trunc  mirror
inject_case win_pad     halfway

# 三 C5 的项数边界。上限 255 是 fp32_mac_assert.vh 认证的，非零 psum 也算一项，
#    所以 K 项加 psum 等于 K+1 项。满额的合法 tile 不许报，超一项必须报，
#    三个 tile 连跑是为了逼出「新 tile 沿用上个 tile 计数」那一类误报
echo "==== C5 项数边界：满额不误报，超限必报 ===="
c5_case() {                   # c5_case <K> <zero|nonzero> <说明>
    local k=$1 want=$2 note=$3 line c5 ok
    "$PY" "$HERE/gen_dot_vectors.py" "$k" 3 777 0 0 "$k" > "$OUT/vec_c5_$k.txt" 2>/dev/null
    line=$(run_win "c5_$k" "$OUT/vec_c5_$k.txt" "$k" "$k")
    c5=$(printf '%s' "$line" | sed -n 's/.*C1\.\.C5=[0-9]*,[0-9]*,[0-9]*,[0-9]*,\([0-9]*\).*/\1/p')
    ok=0
    if [ "$want" = zero ]    && [ "${c5:-x}" = "0" ];                       then ok=1; fi
    if [ "$want" = nonzero ] && [ -n "$c5" ] && [ "$c5" -gt 0 ] 2>/dev/null; then ok=1; fi
    if [ "$ok" = 1 ]; then
        printf "  %-20s %s 项进窗口, C5=%s -> PASS\n" "$note" "$((k+1))" "${c5:-空}"
    else
        printf "  %-20s %s 项进窗口, C5=%s -> FAIL\n" "$note" "$((k+1))" "${c5:-空}"
        BAD=$((BAD+1))
    fi
}
c5_case 254 zero    "满额 tile"
c5_case 255 nonzero "超一项"

# 四 三份报告。每份的判定行与退出码都并进 BAD
report() {                    # report <mac_error_audit.py 的参数...>
    local out rc
    out=$("$PY" "$HERE/mac_error_audit.py" "$@" 2>&1); rc=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qE '\-> FAIL|Traceback'; then
        BAD=$((BAD+1))
    fi
}

echo "==== 误差归因与边界报告 ===="
report
report ktrend
report bound

echo "SUMMARY run_mac_audit: 6 类逐位对拍 + 5 个注错见红 + 2 档 C5 边界 + 3 份报告, $BAD FAIL -> $([ $BAD -eq 0 ] && echo PASS || echo FAIL)"
[ "$BAD" -eq 0 ]
