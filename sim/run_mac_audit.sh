#!/usr/bin/env bash
# fp32_mac_unit 定点窗口的精度闭环。Todo fp32-mac-window-accuracy-closure.md 的
# 刀 A（反例与归因）、刀 D（跨 tile 回灌）、刀 E（规格遵循）。
#
# 与 run_all.sh 的分工：那一份跑随机与四种模式的激励，回答「常规输入下对不对」；
# 这一份跑五类定向反例，回答「窗口在边界上丢了什么、丢多少、哪一条该修」。
#
# 三段：
#   一 五类定向向量的 RTL 逐位对拍。RTL 必须与逐位金标准完全相同。
#   二 五个注错见红。把金标准自己改坏一条数值路径，第一段那条判据必须当场红。
#      判据抓不住金标准里的错，就更抓不住 RTL 里的错。
#   三 误差归因、K 趋势、对齐丢位的误差界，三份报告。
#
# 用法：bash run_mac_audit.sh
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

# 二 注错见红。每个注入点配一类**能看见它**的向量。
# 第一版这里踩了四个坑，四个都不是判据坏，是配错了向量：
#   rescale_rtz 配 mirror  -> 不红。mirror 有 215 次负数换基，但丢的位在结果
#                             ULP 之下 40 位，换个截断方向也照样看不见。
#                             要看见它，得让换基之后发生抵消，低位重新主导
#                             -> 改配 cancel，且 cancel 的旧和现在正负交替。
#   clr_keep    配 cancel  -> 不红。原注入把旧和右移 AccW-1 位再留，
#                             移完就是 0，与清空同结果 -> 改成原地不动。
#   pack_trunc  配 halfway -> 不红。halfway 每条都精确卡在中点且尾数取偶，
#                             RNE 向偶与截断都不进位 -> 改配 mirror，随机尾数才有进位。
#   win_pad     配 tiny    -> 不红。tiny 丢的位本来就不可观测，加宽窗口也白加
#                             -> 改配 halfway，那一类丢的正是决定进位的那一位。
# 教训是一样的：注错见红只有在「这条路径的输出真的被观测得到」时才成立。
# 前三个不红反过来是刀 C 的证据：那几条路径在无抵消时数值上摸不着。
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

# 三 三份报告。归因与 K 趋势各自带判定行
echo "==== 误差归因与边界报告 ===="
"$PY" "$HERE/mac_error_audit.py"        2>&1 | sed 's/^/  /'
"$PY" "$HERE/mac_error_audit.py" ktrend 2>&1 | sed 's/^/  /'
"$PY" "$HERE/mac_error_audit.py" bound  2>&1 | sed 's/^/  /'

echo "SUMMARY run_mac_audit: 6 类逐位对拍 + 5 个注错见红, $BAD FAIL -> $([ $BAD -eq 0 ] && echo PASS || echo FAIL)"
exit 0
