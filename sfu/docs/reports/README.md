# sfu 系列

FP32 超越函数单元的开发记录：指数、正弦、余弦与平方根倒数。

四个单元采用同一种结构：把输入压缩到有界区间，查一张 1024 × 32 的表，
再把压缩时保存的整数信息还原到结果的阶码或符号上。结果是近似值，延迟固定，
每拍可以发起一条，既可以被阻塞式调用方一次调用一条，也可以被流水式调用方连续发起。

## 篇目

| | 章 | 覆盖内容 |
|---|---|---|
| 01 | [SFU 查表架构与函数选型](01-SFU查表架构与函数选型.md) | 函数选型、查表结构、表规格、流水骨架、延迟常数、数值契约、表的生成与加载检查、验证分层 |
| 02 | [FP32 指数函数的阶码分解与查表实现](02-FP32指数函数的阶码分解与查表实现.md) | Q8.20 双向定点化、常数乘法与切位、中点表与负数镜像、上下溢阈值、5 拍流水 |
| 03 | [正弦余弦的相位归约与查表实现](03-正弦余弦的相位归约与查表实现.md) | 相位分数法、二补数负角、象限映射、余弦偏移、零点与支持域 |
| 04 | [平方根倒数的阶码奇偶分表实现](04-平方根倒数的阶码奇偶分表实现.md) | 阶码奇偶分表、双表并行读、阶码基准取自表项、DAZ、4 拍流水 |
| 05 | [正弦余弦共用一条流水](05-正弦余弦共用一条流水.md) | 偏移由参数改为端口、函数标签随 valid 传递、一块表、收益成立的条件 |

01 是骨架，02 到 04 各落地一个函数，05 在 03 的基础上把正弦与余弦合成一条流水。
每章正文写当前实现，被替换的旧实现与修复过程记在该章的「遇到的问题」里。

按顺序阅读。只关心某一个函数时，读 01 之后直接读对应章；读 05 之前需要先读 03。

## 当前接口参数

| 函数 | 单元 | 单元延迟 | 发起间隔 | 表 |
|---|---|---:|---:|---|
| exp | `exp_func` | 5 | 1 | 1 块，模块内 |
| sin | `sincos_func`，`is_cos = 0` | 2 | 1 | 与 cos 共用 1 块，模块外 |
| cos | `sincos_func`，`is_cos = 1` | 2 | 1 | 同上 |
| rsqrt | `rsqrt_func` | 4 | 1 | 2 块，模块内 |

延迟定义为 `in_valid` 被采样的时钟沿到 `out_valid` 拉高的时钟沿，常数在 `sfu_lat.vh`。

## 验证状态

回归入口依次执行表校验、三个发起形态测试台、逐位对拍与独立数学参考复核：

```text
gen_luts --check     6 个文件一致 -> PASS
tb_rsqrt_stream      SUMMARY ALL PASS   (13 checks)
tb_sfu_stream        SUMMARY ALL PASS   (22 checks)
tb_sincos_shared     SUMMARY ALL PASS   (3 checks)
tb_sfu_golden        9500 条激励已取样
verify_sfu           PASS independent SFU math/special-value verification
                       exp    samples=7737 max_error=3.578873720e-04 input=c2983333
                       sin    samples=8644 max_error=1.501499313e-03 input=c2a9999a
                       cos    samples=8644 max_error=1.501260884e-03 input=c1d5cccd
                       rsqrt  samples=5115 max_error=4.594921836e-04 input=39841f10
golden_ref           9500 条激励逐位等于 golden_ref.txt -> PASS
SUMMARY run_all: 0 FAIL -> PASS
```

离线综合（Vivado 2025.2，`xc7a200tfbg676-1`，20 ns）：

| 单元 | LUT | FF | DSP48 | RAMB36 | WNS |
|---|---:|---:|---:|---:|---:|
| `exp_func` | 290 | 89 | 2 | 1 | 11.193 ns |
| `sincos_func` 与一块表 | 285 | 40 | 4 | 1 | 1.864 ns |
| `rsqrt_func` | 107 | 92 | 0 | 2 | 13.866 ns |
