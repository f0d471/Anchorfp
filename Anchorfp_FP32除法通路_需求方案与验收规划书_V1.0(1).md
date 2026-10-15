# Anchorfp FP32 除法通路（FDIV）需求方案与验收规划书

> 文档版本：V1.0  
> 文档状态：**开发基线已冻结（GO FOR DEVELOPMENT）**  
> 编制日期：2026-09-16  
> 冻结日期：2026-09-16  
> 适用项目：`E:\Workspace\FPGA\anchorfp`  
> 目标读者：产品负责人、架构师、RTL 开发、验证、综合与集成人员

---

## 0. 执行摘要

Anchorfp 当前具备 FP32 加减、乘法、比较、转换、近似倒数和乘累加通路，但尚未实现真正的 FP32 除法通路。现有 `fp32_recip` 是 5 拍、启动间隔为 1 拍的显式近似原语，正常有限数最大误差契约为 4 ULP；它不能通过 `a × FRECIP(b)` 代替正确舍入的除法。

本开发基线新增独立 `FDIV`：

- 数值语义采用 Anchorfp 现有风格：输入 DAZ、输出 FTZ、RNE 舍入、无异常标志、规范 qNaN。
- 正常有限共同定义域要求相对本项目精确金标准 **0 ULP、0 mismatch**。
- 特殊值、符号、DAZ/FTZ 结果要求逐位一致。
- 微架构采用精确余数的 radix-4/每拍 2 位商流水方案，主版本固定延迟、`II=1`、无反压。
- 固定延迟冻结为 **14 拍**，由 `FP32_DIV_LAT` 唯一声明并由测试实测锁定；本期不得在实现阶段自行改为 13 拍。
- 目标器件为 `xc7a200tfbg676-1`，时钟周期 20 ns；建议资源目标不超过 1200 LUT、1600 FF，且不使用 DSP/BRAM。

**发布结论规则：** 数值、接口、回归、综合和文档五类门禁全部通过，且无未关闭的 S0/S1 缺陷时，FDIV 才可标记为可发布。

### 0.1 工程启动结论

前期产品与架构决策已经完成，当前结论为 **GO FOR DEVELOPMENT**。工程师可立即开始参考模型、RTL 和验证开发，无需等待额外产品决策。

| 启动条件 | 状态 | 结论 |
|---|---|---|
| 范围与非目标明确 | 已完成 | 仅实现 FP32 FDIV，不扩展其他精度、舍入模式和异常标志 |
| 数值契约冻结 | 已完成 | DAZ + RNE24 + FTZ，normal 共同域 0 ULP |
| 特殊值矩阵冻结 | 已完成 | canonical qNaN、signed zero/Inf、符号 XOR |
| 接口与时序冻结 | 已完成 | 无反压、II=1、固定 14 拍、flush 作废全部在飞请求 |
| 操作码冻结 | 已完成 | `FP32_OP_FDIV = 4'd7` |
| 实现路线冻结 | 已完成 | 精确余数、每级 2 位商、12 个迭代级 |
| 验收基线冻结 | 已完成 | 精确整数 oracle 为主裁决，五类发布门禁 |
| 工程清单就绪 | 已完成 | 见 `Temp/anchorfp_fdiv_handoff/` |

### 0.2 变更控制

从冻结日起，下列内容均视为基线：D-01 至 D-10、接口端口、`FP32_DIV_LAT=14`、操作码 `4'd7`、特殊值矩阵和验收阈值。任何修改必须提交变更记录，至少说明原因、影响文件、兼容性、验证增量和回退方式；未经产品与架构共同批准，不得通过代码实现隐式改变契约。

---

## 1. 背景与现状

### 1.1 当前能力盘点

| 能力 | 当前实现 | 延迟/精度 | 与 FDIV 的关系 |
|---|---|---:|---|
| FP32 加减 | `fp32_add.v` | 3 拍，定义域内正确舍入 | 可复用接口风格，不复用数值核心 |
| FP32 乘法 | `fp32_mul_pipe.v` | 2 拍，定义域内正确舍入 | 不用于拼接伪除法 |
| FP32 比较 | `fp32_cmp.v` | 1 拍 | 无直接复用 |
| FP32 转换 | `fp32_cvt.v` | 1 拍 | 无直接复用 |
| FP32 倒数 | `fp32_recip.v` | 5 拍，误差不超过 4 ULP | 保留为近似原语，禁止替代 FDIV |
| 顶层派发 | `fp32_fpu_top.v` | 多独立出口 | 需新增 FDIV 派发与出口 |
| 延迟常数 | `fp32_lat.vh` | 统一声明 | 需新增 `FP32_DIV_LAT` |
| 操作码 | `fp32_ops.vh` | 4 位编码 | `4'd7` 当前空闲，可作为候选 |
| 回归入口 | `fp/sim/run_all.sh` | 覆盖现有单元 | 需纳入 FDIV 测试与模型 |
| 综合入口 | `fp/syn/ooc_units.tcl` | 20 ns，Artix-7 | 需纳入 `fp32_div` |

### 1.2 核心问题

1. 当前没有 `fp32_div` RTL、FDIV 操作码、顶层出口和延迟常数。
2. 当前没有除法专用精确金标准、随机向量生成器、流式时序测试和特殊值矩阵。
3. `FRECIP` 的近似误差会与乘法舍入叠加，不能满足除法 0 ULP 的产品目标。
4. 若不先冻结 DAZ/FTZ、NaN、除零、舍入与时序契约，RTL 与验证模型容易产生系统性分歧。

### 1.3 产品目标

- **G1：语义明确。** 新增独立 FDIV，所有输入类别均有唯一、可测试的输出定义。
- **G2：结果可靠。** 正常有限共同定义域相对精确金标准 0 ULP。
- **G3：接口一致。** 沿用 `in_valid/flush/out_valid`、固定延迟、无反压的现有通路风格。
- **G4：持续吞吐。** 主版本 `II=1`，支持每拍接收一组输入。
- **G5：可综合可维护。** Verilog-2001 可实现，延迟宏、回归、lint、综合和文档形成闭环。
- **G6：可证明。** 所有验收结论均能从固定种子、日志、波形或综合报告复现。

---

## 2. 范围与边界

### 2.1 本期范围

- 新增 FP32 二元除法 `a ÷ b`。
- 支持正常数、零、无穷、NaN 和输入 denormal 的确定语义。
- 支持 RNE（round to nearest, ties to even）一种舍入模式。
- 输入 denormal 按 DAZ 处理，输出 tiny 按 FTZ 处理。
- 支持固定延迟、`II=1`、无反压、同步 `flush` 作废全部在飞请求。
- 集成到操作码、FPU 顶层、延迟常数、测试、lint、综合和说明文档。

### 2.2 明确不在本期范围

- FP16、BF16、FP64 或可配置精度。
- denormal 的渐进下溢计算与 denormal 结果输出。
- RTZ、RUP、RDN、ties-to-away 等其他舍入模式。
- IEEE 754 的 NV、DZ、OF、UF、NX 异常标志及其累积。
- ready/valid 反压、乱序返回、可变延迟或请求取消 ID。
- 用 `FRECIP` 或 `FMUL(FRECIP)` 冒充 FDIV。
- 在本期改写现有加减乘、转换、比较、倒数与 MAC 的数值语义。

### 2.3 兼容性原则

1. 原有 `FRECIP` 操作码、端口、5 拍延迟和不超过 4 ULP 的误差契约保持不变。
2. 新 FDIV 必须使用独立模块、独立操作码和独立输出，避免调用方误将近似倒数当作除法。
3. 顶层新增端口属于接口扩展；所有例化点必须同步修改并通过编译。
4. 旧回归必须零退化。

---

## 3. 数值契约与精度标准

### 3.1 规范定义

FDIV 的规范语义定义为：

```text
FDIV(a, b) = FTZ(RNE24(DAZ(a) / DAZ(b)))
```

其中：

- `DAZ(x)`：当 `exp(x) == 0` 时，将输入解释为同符号零；原 fraction 不再参与运算。
- `RNE24(x)`：以无界中间阶码和 24 位有效位执行就近舍入，精确平局时取偶数。
- `FTZ(x)`：舍入后结果仍处于 tiny/denormal 区间时，输出数学符号对应的零；上溢输出同符号无穷。
- 特殊值分类与下表规则优先于常规尾数除法。

### 3.2 输入分类顺序

为避免模型与 RTL 对 denormal 的解释不同，分类顺序必须固定：

1. 拆分 `sign/exp/fraction`。
2. 对 `exp == 0` 的输入执行 DAZ，保留 sign、数值视为零。
3. 再按 NaN、Inf、Zero、Normal 分类。
4. 特殊值命中时生成固定结果，并沿与正常运算相同的 valid 流水返回。
5. 仅 Normal/Normal 进入尾数除法。

### 3.3 特殊值矩阵

令结果符号 `s = sign(a) XOR sign(b)`。除 NaN 外，零和无穷均保留该符号。

| DAZ 后的 `a` | DAZ 后的 `b` | 结果 | 位级要求 |
|---|---|---|---|
| NaN | 任意 | canonical qNaN | `0x7FC00000` |
| 任意 | NaN | canonical qNaN | `0x7FC00000` |
| ±0 | ±0 | canonical qNaN | `0x7FC00000` |
| ±Inf | ±Inf | canonical qNaN | `0x7FC00000` |
| 非零有限数 | ±0 | ±Inf | 符号为 XOR |
| ±Inf | 非零有限数 | ±Inf | 符号为 XOR |
| ±0 | 非零有限数 | ±0 | 符号为 XOR |
| 非零有限数 | ±Inf | ±0 | 符号为 XOR |
| 正常有限数 | 正常有限数 | 精确商经 RNE24，再做 FTZ/上溢 | 见 3.4、3.5 |

补充约束：

- sNaN 与 qNaN 不区分异常标志，本期均收敛为 `0x7FC00000`。
- NaN 不保留输入 sign 或 payload。
- denormal 因 DAZ 变为零后，完全按带符号零参与上表，例如 `Inf / denormal` 等价于 `Inf / ±0`。

### 3.4 正常有限数的精确商与舍入

设：

```text
A = {1'b1, a_fraction}  // 24 位整数
B = {1'b1, b_fraction}  // 24 位整数
ea = a_exp
eb = b_exp
```

归一化整数除法定义：

```text
if A >= B:
    N = A << 23
    E = ea - eb + 127
else:
    N = A << 24
    E = ea - eb + 126

Q = floor(N / B)
R = N - Q * B
```

`Q` 是舍入前 24 位有效数，`R` 是精确余数。RNE 判定：

```text
round_up = (2*R > B) || ((2*R == B) && Q[0])
Q_round  = Q + round_up
```

若 `Q_round` 产生第 25 位进位，则有效数右移一位、`E` 加一。之后：

- `E >= 255`：输出 `±Inf`。
- 舍入后的 `E <= 0`：输出 `±0`，但必须允许边界值因舍入进位成为最小 normal。
- 其他情况：输出 `{s, E[7:0], Q_round[22:0]}`。

**关键要求：** 舍入必须依据精确余数，不能只保留固定 guard/round/sticky 后近似判断，否则无法证明 0 ULP。

### 3.5 精度标准

| 类别 | 精度标准 | 验收方法 |
|---|---|---|
| Normal / Normal，结果为 normal | 0 ULP | 与精确整数 oracle 逐位相等 |
| 舍入边界 | ties-to-even 完全正确 | `2R<B`、`2R=B`、`2R>B` 定向族 |
| 下溢边界 | RNE 后再判断 FTZ | 最小 normal 邻域定向向量 |
| 上溢边界 | RNE 后输出有限最大值或 Inf | 最大有限值邻域定向向量 |
| NaN、Inf、Zero | 逐位一致 | 特殊值笛卡尔矩阵 |
| DAZ 输入 | 逐位一致 | 正负 denormal 与各类别交叉 |
| FTZ 输出 | 逐位一致 | 数学结果落入 tiny 区间的定向族 |

“0 ULP”只用于数值可排序的非 NaN 结果；NaN、signed zero、Inf 与 DAZ/FTZ 情况采用位级比较，不以 ULP 替代。

### 3.6 与 IEEE 754 的关系

该方案不是 IEEE 754 全功能除法器，差异包括：

- 输入 denormal 被 DAZ，不参与渐进下溢运算。
- tiny 结果被 FTZ，不输出 denormal。
- 仅支持 RNE。
- 不输出异常标志。

因此 SoftFloat/TestFloat 只能用于 **共同定义域二次复核**。项目最终裁决基准必须是实现本节 DAZ/FTZ 契约的精确整数 oracle。

---

## 4. 接口与时序契约

### 4.1 建议模块接口

```verilog
module fp32_div (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    input             in_valid,
    input             flush,
    output reg        out_valid,
    output reg [31:0] result
);
```

### 4.2 请求与返回

- 当时钟上升沿采样到 `in_valid=1 && flush=0 && rst_n=1` 时，接收一组 `{a,b}`。
- 请求在固定 `FP32_DIV_LAT` 拍后使 `out_valid=1`，同拍 `result` 有效。
- `in_valid` 可连续每拍为 1；每个请求必须按输入顺序逐拍返回。
- 无 `ready`，调用方不得假设反压能力。
- `out_valid=0` 时 `result` 为 don't-care，验证不得比较无效数据。
- 特殊值与普通值使用相同延迟，不允许早返回。

### 4.3 Reset 与 Flush

- `rst_n=0` 在时钟沿优先清空全部 valid 状态；数据寄存器无需因功能正确性强制复位。
- `flush=1` 在时钟沿作废当前全部在飞请求，并阻止同拍新请求进入。
- flush 后不得出现来自被作废请求的“幽灵” `out_valid`。
- flush 释放后下一拍即可接收新请求，不应引入额外气泡。

### 4.4 延迟定义

以 `in_valid` 被采样的时钟沿为 `T`，对应 `out_valid` 拉高的时钟沿为 `T + FP32_DIV_LAT`。

- 方案基线：固定 14 拍。
- 13 拍优化不属于本期范围；若未来需要，必须以新版本需求变更立项。
- 验收以最终提交的 `FP32_DIV_LAT` 为唯一真值，不接受 RTL、注释、文档和测试各自维护不同数字。
- `tb_fp_lat.v` 必须新增 FDIV 实测项。

### 4.5 顶层集成

冻结定义如下：

```verilog
`define FP32_OP_FDIV 4'd7
`define FP32_DIV_LAT 14
```

`4'd7` 已冻结为 FDIV 编码。同步修改：

- `FP32_OP_IS_FPU(c)`，纳入 FDIV。
- `fp32_fpu_top.v`，增加 `cmd_div`、模块实例、`fpu_div_valid` 与 `fpu_div_data`。
- 顶层 `OpWidth` 约束与所有例化点。
- `datapath-manual.md` 的操作码、延迟、接口与数值契约表。

---

## 5. 实现方案

### 5.1 方案比较

| 方案 | 0 ULP 可证明性 | II=1 | 典型资源 | 风险 | 结论 |
|---|---:|---:|---|---|---|
| `FRECIP` 后接 `FMUL` | 否 | 是 | 约 6 DSP + 1 BRAM | 近似误差与二次舍入 | 禁止作为 FDIV |
| 查表 + 牛顿迭代 + 修正 | 可实现 | 是 | DSP/BRAM 较多 | 边界修正与证明复杂 | 后续高性能版本候选 |
| radix-2 精确逐位流水 | 是 | 是 | LUT/FF | 延迟约 26 拍 | 可行但延迟偏高 |
| radix-4/每拍 2 位精确流水 | 是 | 是 | LUT/FF | 余数比较与布线 | **本期冻结方案** |
| 单共享迭代器 | 是 | 否 | 资源低 | 吞吐与现有风格不符 | 本期不选 |

### 5.2 推荐微架构

采用 24 位 significand 的精确 digit-recurrence 流水，每级产生 2 位商并保留精确余数：

1. **预处理级**：DAZ、分类、符号、特殊值编码、`A/B` 归一化选择及初始阶码。
2. **12 个 radix-4 迭代级**：每级生成 2 位商，更新余数，支持每拍接收新请求。
3. **舍入与封装级**：以最终 `Q/R/B` 判定 RNE，处理尾数进位、阶码、FTZ、上溢与特殊值覆盖。
4. **伴随信息链**：sign、exp、special、special_result、valid 与请求数据严格同级传播。

形成固定 14 拍流水：1 个预处理级、12 个商位迭代级、1 个舍入封装级。本期不合并预处理与首轮迭代，以降低组合路径、验证和维护风险。

为避免工程师对“radix-4”产生不同实现理解，本期冻结为**每个流水级串接两次 restoring bit-step**，而不是使用近似商数字选择。预处理先得到：

```text
S = (A >= B) ? A : (A << 1)   // B <= S < 2B，25 位
R = S                          // 25 位精确余数状态
Q = 0                          // 24 位商
```

随后严格执行 24 次 bit-step，每级执行相邻两次：

```text
for j = 0 .. 23:
    bit = (R >= B)
    R   = bit ? (R - B) : R
    Q   = (Q << 1) | bit
    if j != 23:
        R = R << 1
```

结束后 `Q=floor(S*2^23/B)`，`R=(S*2^23) mod B`。当 `A>=B` 时等价于 `floor((A<<23)/B)`；当 `A<B` 时等价于 `floor((A<<24)/B)`。最后一次 bit-step 后不得再左移 `R`，否则 RNE 比较会错误。每个迭代级的 `R` 使用 25 位、`B` 零扩展到 25 位；不得截断余数或在中间级舍入。

### 5.3 迭代级实现约束

- 必须使用显式定宽有符号/无符号信号，禁止依赖 Verilog 隐式扩展。
- 比较 `2R` 与 `B` 时至少保留一位扩展，避免左移溢出。
- 余数在每一级必须保持精确；禁止为省寄存器截断低位。
- 特殊值标志可以旁路数值核心，但必须走满固定 latency。
- valid 清空优先级必须与项目其他模块一致：`!rst_n` 或 `flush` 优先于移位。
- 数据寄存器可不复位；所有可观察结果必须由 valid 约束。
- Verilog-2001 兼容，不引入 SystemVerilog 专属语法。

### 5.4 资源与时序目标

| 指标 | 必须门槛 | 目标值 | 说明 |
|---|---:|---:|---|
| 启动间隔 II | 1 | 1 | 每拍一组输入 |
| 固定延迟 | 14 拍且与宏完全一致 | 14 拍 | 本期已冻结，不得自行调整 |
| 时钟周期 | 20 ns | WNS ≥ 0 | OOC，`xc7a200tfbg676-1` |
| DSP | 0 | 0 | 精确余数方案无需乘法器 |
| BRAM | 0 | 0 | 不使用倒数表 |
| LUT | 不设阻断上限，超目标需评审 | ≤ 1200 | 初始估算 600–1000 |
| FF | 不设阻断上限，超目标需评审 | ≤ 1600 | 初始估算 900–1500 |

资源目标用于工程优化，不得以降低正确性、吞吐率或固定延迟契约为代价。若超标，需附层级资源报告和优化结论，由架构评审决定是否放行。

### 5.5 预计文件变更

| 文件 | 变更 |
|---|---|
| `fp/rtl/fp32_div.v` | 新增 FDIV RTL |
| `fp/rtl/fp32_ops.vh` | 新增操作码并扩展 `FP32_OP_IS_FPU` |
| `fp/rtl/fp32_lat.vh` | 新增 `FP32_DIV_LAT` |
| `fp/rtl/fp32_fpu_top.v` | 新增派发、实例和独立出口 |
| `fp/sim/gen_div_vectors.c` | 新增精确向量/参考结果生成器 |
| `fp/sim/tb_fp32_div.v` | 新增功能、流式、flush 与边界测试 |
| `fp/sim/tb_fp_lat.v` | 新增延迟实测 |
| `fp/sim/run_all.sh` | 纳入向量生成与 FDIV 回归 |
| `fp/sim/lint.sh` | 纳入新 RTL |
| `fp/syn/ooc_units.tcl` | 纳入 `fp32_div` OOC 综合 |
| `fp/rtl/datapath-manual.md` | 增补最终契约与实测结果 |

### 5.6 当前实现状态

截至本文编制时：

| 工作项 | 状态 | 证据/说明 |
|---|---|---|
| FDIV RTL | 未实现 | `fp/rtl` 中无 `fp32_div.v` |
| FDIV 操作码 | 未定义 | `fp32_ops.vh` 中 `4'd7` 空闲 |
| FDIV 延迟宏 | 未定义 | `fp32_lat.vh` 仅有 ADD/MUL/CMP/CVT/RECIP |
| 顶层 FDIV 出口 | 未实现 | `fp32_fpu_top.v` 当前只有五类独立出口 |
| 精确除法 oracle | 未实现 | `fp/sim` 中无除法生成器 |
| FDIV testbench | 未实现 | `fp/sim` 中无 `tb_fp32_div.v` |
| FDIV 综合入口 | 未实现 | `ooc_units.tcl` 未列出 `fp32_div` |
| 可复用工程基础 | 已具备 | valid/flush、DAZ/FTZ、RNE、回归和 OOC 框架已存在 |
| 近似倒数 | 已实现 | 5 拍、II=1、≤4 ULP，不能作为 FDIV |

---

## 6. 需求清单与优先级

| 编号 | 优先级 | 需求 | 验收口径 |
|---|---|---|---|
| FDIV-001 | P0 | 提供独立 FDIV，不改变 FRECIP 语义 | 操作码、模块和出口可独立调用 |
| FDIV-002 | P0 | 正常有限共同定义域正确舍入 | 精确 oracle：0 ULP、0 mismatch |
| FDIV-003 | P0 | 输入 DAZ、输出 FTZ | denormal/tiny 全矩阵逐位通过 |
| FDIV-004 | P0 | 特殊值和符号符合 3.3 | 全部逐位通过 |
| FDIV-005 | P0 | 仅实现 RNE，平局取偶 | 平局奇/偶两族定向通过 |
| FDIV-006 | P0 | 主版本 `II=1`、无反压 | 连续不同输入不丢、不重、不乱序 |
| FDIV-007 | P0 | 固定延迟且由宏统一定义 | 实测值等于 `FP32_DIV_LAT` |
| FDIV-008 | P0 | flush 作废全部在飞操作 | 各流水深度注入 flush，无幽灵输出 |
| FDIV-009 | P0 | 旧功能零退化 | `fp/sim/run_all.sh` 全绿 |
| FDIV-010 | P0 | 目标器件时序闭合 | 20 ns 下 WNS ≥ 0 |
| FDIV-011 | P1 | 独立参考与二次审计 | 整数 oracle + SoftFloat/TestFloat 共同域复核 |
| FDIV-012 | P1 | lint、综合、文档纳入一键流程 | 脚本退出码可供 CI 使用 |
| FDIV-013 | P1 | 回归能够识别关键错误 | 至少 5 类 mutation 均稳定失败 |
| FDIV-014 | P2 | 资源优化 | ≤1200 LUT、≤1600 FF、0 DSP/BRAM |

优先级定义：

- **P0：** 发布阻断，缺失或失败不得合入。
- **P1：** 质量阻断，原则上发布前完成；延期必须由产品与架构共同批准。
- **P2：** 优化项，不影响首版功能发布，但需记录差距和后续计划。

---

## 7. 开发计划与里程碑

建议按 10 个工作日组织，实际排期可根据人员并行度调整。

| 阶段 | 时间 | 工作内容 | 退出条件 |
|---|---:|---|---|
| M0 契约冻结 | 已完成 | 数值矩阵、接口、操作码、延迟和资源目标 | D-01 至 D-10 已冻结，可启动开发 |
| M1 参考模型 | D1–D2 | 精确整数 oracle、定向向量、随机生成器 | 自校验通过，固定种子可复现 |
| M2 RTL 骨架 | D2–D3 | 模块接口、分类、valid/special 旁路 | 编译/lint 通过，特殊值先行通过 |
| M3 除法流水 | D3–D6 | 12 级 digit recurrence、精确余数、RNE | normal 随机 0 mismatch |
| M4 顶层集成 | D6–D7 | 操作码、延迟宏、FPU 顶层、延迟测试 | 顶层编译与 14 拍 latency 通过 |
| M5 强化验证 | D7–D8 | 全类别随机、流式、flush、mutation | P0/P1 验证项全部通过 |
| M6 综合收敛 | D8–D9 | OOC 综合、关键路径和资源优化 | 20 ns WNS ≥ 0，资源结论明确 |
| M7 发布评审 | D10 | 全回归、文档、证据归档、签署 | 五类门禁全部通过 |

若精确 oracle 未完成，不得以主机 `float` 或单一 SoftFloat 输出直接开始 RTL 验收；否则 DAZ/FTZ 语义偏差会污染测试基线。

---

## 8. 验收规划

### 8.1 验收环境基线

| 项目 | 基线 |
|---|---|
| RTL 语言 | Verilog-2001 |
| 主仿真器 | Icarus Verilog 12 或项目 CI 已固定版本 |
| 辅助 lint/仿真 | Verilator，版本写入验收日志 |
| 参考模型 | C/C++ 精确整数 oracle；64 位以上中间量需证明不溢出 |
| 二次参考 | Berkeley SoftFloat/TestFloat，仅用于共同 IEEE 定义域 |
| 综合工具 | Vivado 2025.2 |
| 目标器件 | `xc7a200tfbg676-1` |
| OOC 时钟 | 20.000 ns（50 MHz） |
| 随机复现 | 固定并记录 seed、生成器版本和向量 SHA-256 |

### 8.2 金标准模型要求

精确 oracle 必须：

1. 直接按 3.1–3.4 实现 DAZ、特殊值、整数商余数、RNE、FTZ 和上溢。
2. 不依赖宿主机浮点除法作为最终裁决。
3. 对 `2R`、阶码和左移使用足够宽度，显式防溢出。
4. 输出 32 位十六进制结果和可选分类信息。
5. 至少对一组人工可验向量进行自测试。
6. 对正常共同域抽样与 SoftFloat 做交叉核对；差异必须解释为 DAZ/FTZ 或模型错误。

### 8.3 测试矩阵

| 测试组 | 最低规模 | 重点 | 通过标准 |
|---|---:|---|---|
| 特殊值矩阵 | 全组合 | ±0、±Inf、qNaN、sNaN、符号 | 逐位 0 mismatch |
| DAZ 交叉 | 每类不少于 100 例 | 正负 denormal 作分子/分母 | 逐位 0 mismatch |
| Normal 随机 | ≥500,000 对 | 指数全范围、尾数随机 | 0 ULP、0 mismatch |
| 全位图随机 | ≥200,000 对 | 32 位均匀分布、类别自然覆盖 | 逐位 0 mismatch |
| 舍入定向 | 每族不少于 100 例 | `<half`、`=half`、`>half`、奇偶 | 逐位 0 mismatch |
| 下溢边界 | ≥1,000 对 | 最大 tiny、最小 normal 邻域 | 逐位 0 mismatch |
| 上溢边界 | ≥1,000 对 | 最大有限值与 Inf 分界 | 逐位 0 mismatch |
| 流式压力 | ≥10,000 连续请求 | `in_valid` 每拍为 1 | 不丢、不重、不乱序 |
| 稀疏 valid | ≥10,000 拍 | 随机气泡 | 数据与 valid 精确对齐 |
| flush 扫描 | 每个在飞深度均覆盖 | flush 前后边界 | 无幽灵输出，新请求正常返回 |
| reset 扫描 | 启动、中途、满流水 | valid 清零 | reset 后无旧输出 |
| 延迟检查 | 定向 + 连续流 | 固定 latency | 每笔均为 `FP32_DIV_LAT` |
| 旧功能回归 | 全量 | 现有 FP/MAC 测试 | 0 新失败 |

### 8.4 必测定向场景

- `1.0 / 1.0 = 1.0`、`1.0 / 2.0 = 0.5`、`2.0 / 1.0 = 2.0`。
- 正负号四象限，尤其 `-0`、`-Inf` 与负 denormal。
- `0/0`、`Inf/Inf`、有限数/0、0/有限数、Inf/有限数、有限数/Inf。
- 两个输入的 qNaN/sNaN 以及 NaN 与各类别交叉。
- `A == B`、`A = B±1`、`A < B` 与 `A > B` 的归一化分支边界。
- `R=0` 的精确可除、`2R=B` 且 Q 为奇/偶、`2R=B±1`。
- 舍入导致尾数进位和阶码加一。
- 舍入后从 tiny 进入最小 normal 的边界。
- 最大有限结果与上溢 Inf 的分界。
- denormal 分子/分母经 DAZ 后触发零、除零和 NaN 规则。
- 连续 normal、special、normal 交替，确认 special 旁路不改变 latency。
- flush 与输入同拍、flush 位于每个流水深度、flush 后第一拍重新输入。

### 8.5 Mutation 验证

至少临时注入以下 5 类错误，确认回归必然失败；mutation 代码不得进入正式分支。

| Mutation | 预期捕获测试 |
|---|---|
| 将 ties-to-even 改为 ties-up | 平局奇/偶定向族 |
| 删除余数比较扩展位 | 大余数及边界随机族 |
| 把 `A<B` 的阶码调整写错 1 | 归一化分支定向族 |
| valid 链增减 1 拍 | latency 与流式 scoreboard |
| flush 少清一级 valid | flush 深度扫描 |
| canonical qNaN 改为 payload 透传 | 特殊值矩阵 |
| FTZ 在舍入前执行 | 最小 normal 邻域 |

### 8.6 综合与静态检查

必须提供：

- Icarus 编译与全回归日志。
- Verilator lint 报告；不得新增 warning，或每条 warning 有书面豁免。
- Vivado 2025.2 OOC `report_timing_summary`。
- 层级资源报告，列出 LUT、FF、DSP、BRAM。
- 若 WNS < 0，验收直接失败，不允许仅以“功能仿真通过”放行。
- 若资源超目标但不超器件容量，需架构负责人签署偏差接受。

### 8.7 Go/No-Go 门禁

| 门禁 | Go 条件 | No-Go 条件 |
|---|---|---|
| 数值 | oracle 全测试 0 mismatch | 任意未解释 mismatch |
| 接口 | latency、II、顺序、flush/reset 全通过 | 丢请求、错位、幽灵输出 |
| 回归 | 新旧测试全部通过 | 任意 P0 回归失败 |
| 工具 | lint 无新增未豁免项；综合 WNS ≥ 0 | lint 阻断或时序违例 |
| 文档 | 宏、RTL、测试、手册一致 | 关键契约仍有歧义 |
| 缺陷 | S0/S1 全关闭；S2 有批准的规避方案 | 存在未关闭 S0/S1 |

### 8.8 缺陷分级与关闭规则

| 级别 | 定义 | 示例 | 发布规则 |
|---|---|---|---|
| S0 致命 | 基本功能不可用或大面积错误 | 无输出、全流水错位、综合失败 | 必须关闭 |
| S1 严重 | P0 契约错误、数据损坏或不可接受时序风险 | 非零 ULP、特殊值错误、flush 幽灵输出、WNS<0 | 必须关闭 |
| S2 一般 | 局部非阻断问题，有明确规避方式 | 诊断不足、资源超目标但可用 | 需批准并有计划 |
| S3 轻微 | 不影响功能和交付 | 注释、日志格式、非关键命名 | 可带入后续版本 |

缺陷关闭必须附复现用例、修复提交和回归证据；仅修改测试期望值不能视为关闭。

---

## 9. 交付物清单

### 9.1 RTL 与集成

- `fp32_div.v`
- 更新后的 `fp32_ops.vh`
- 更新后的 `fp32_lat.vh`
- 更新后的 `fp32_fpu_top.v`
- 所有上层例化点修改

### 9.2 验证

- 精确整数 oracle 源码与自测试
- 除法向量生成器
- `tb_fp32_div.v`
- 更新后的 `tb_fp_lat.v`
- 更新后的 `run_all.sh` 与 `lint.sh`
- 固定 seed、向量摘要、回归日志和 mutation 结果

### 9.3 综合与文档

- 更新后的 `ooc_units.tcl`
- timing summary 和资源报告
- 更新后的 `datapath-manual.md`
- 操作码、延迟、特殊值矩阵与已知限制说明
- 验收记录与签署结论

---

## 10. 风险与应对

| 风险 | 概率/影响 | 预警信号 | 应对措施 |
|---|---|---|---|
| 把 FRECIP 路径误当 FDIV | 中/高 | 方案出现“近似可接受”或非零 ULP | 模块、操作码、文档彻底分离；P0 评审阻断 |
| 舍入边界错误 | 中/高 | 随机总体通过但定向平局失败 | 精确余数；三类比较与奇偶定向 |
| DAZ/FTZ 模型不一致 | 中/高 | SoftFloat 与 RTL 在 tiny 区域大量差异 | 自定义 oracle 为主，SoftFloat 仅共同域复核 |
| valid 与数据错位 | 中/高 | 单笔通过、连续流失败 | 请求队列 scoreboard、延迟实测、mutation |
| flush 少清流水级 | 中/高 | flush 后出现迟到输出 | 深度全扫描、valid 统一清零模板 |
| radix-4 组合路径偏长 | 中/中 | WNS 接近或小于 0 | 降低单级逻辑、局部复制比较器或退回 radix-2 |
| 资源超目标 | 中/中 | 余数比较/多路选择 LUT 激增 | 查看层级资源，优化共享表达式与扇出 |
| 位宽/符号隐式转换 | 中/高 | 极端指数或余数用例失败 | 所有中间量显式定宽，lint + 边界测试 |
| 顶层接口扩展遗漏 | 中/中 | 某例化点编译失败 | 全仓编译，操作码与端口清单评审 |

---

## 11. 已冻结决策

| 编号 | 决策项 | 冻结值 | 状态 |
|---|---|---|---|
| D-01 | FDIV 精度定位 | 正确舍入，normal 共同域 0 ULP | 已冻结 |
| D-02 | denormal 策略 | 输入 DAZ、输出 FTZ | 已冻结 |
| D-03 | NaN 策略 | canonical qNaN `0x7FC00000` | 已冻结 |
| D-04 | 握手与吞吐 | 无反压、固定延迟、II=1 | 已冻结 |
| D-05 | 操作码 | `FP32_OP_FDIV = 4'd7` | 已冻结 |
| D-06 | 延迟基线 | `FP32_DIV_LAT = 14` | 已冻结 |
| D-07 | 资源目标 | ≤1200 LUT、≤1600 FF、0 DSP/BRAM | 已冻结 |
| D-08 | 主参考模型 | 自定义精确整数 oracle；SoftFloat 仅作共同域复核 | 已冻结 |
| D-09 | Reset/Flush | `!rst_n`/`flush` 清空全部 valid，flush 同拍不接收请求 | 已冻结 |
| D-10 | 发布门禁 | 五类门禁全通过且无开放 S0/S1 | 已冻结 |

### 11.1 工程师可直接执行的起步顺序

1. 先实现 `gen_div_vectors.c` 中的精确整数 oracle 和自测试，不依赖 RTL。
2. 再建立 `fp32_div.v` 的 14 拍 valid/special 骨架，以特殊值和 flush 测试先行。
3. 接入 12 个每级 2 位商的精确余数流水，完成 RNE 和 FTZ/上溢封装。
4. 更新操作码、延迟宏与 FPU 顶层，并扩展 `tb_fp_lat.v`。
5. 完成随机、流式、mutation、旧回归和 OOC 综合。
6. 按工程交接包中各目录的 `ACCEPTANCE_CHECKLIST.md` 逐项勾选并归档证据。

---

## 12. 验收签署模板

| 角色 | 关注项 | 结论 | 签署/日期 |
|---|---|---|---|
| 产品负责人 | 范围、优先级、发布门禁 | □通过 □有条件通过 □拒绝 |  |
| 架构负责人 | 数值契约、接口、微架构 | □通过 □有条件通过 □拒绝 |  |
| RTL 负责人 | 实现、lint、时序、资源 | □通过 □有条件通过 □拒绝 |  |
| 验证负责人 | oracle、覆盖、回归、mutation | □通过 □有条件通过 □拒绝 |  |
| 集成负责人 | 操作码、顶层、旧功能回归 | □通过 □有条件通过 □拒绝 |  |

最终发布结论：

```text
□ GO
□ CONDITIONAL GO（必须附 S2 偏差、规避方案、责任人和关闭日期）
□ NO-GO
```

---

## 附录 A：验收参考伪代码

```text
function fdiv_anchorfp(a_bits, b_bits):
    a = decode_fp32(a_bits)
    b = decode_fp32(b_bits)

    if a.exp == 0: a = signed_zero(a.sign)  // DAZ
    if b.exp == 0: b = signed_zero(b.sign)

    if a.is_nan or b.is_nan:
        return 0x7FC00000

    sign = a.sign xor b.sign

    if (a.is_zero and b.is_zero) or (a.is_inf and b.is_inf):
        return 0x7FC00000
    if (a.is_inf and not b.is_inf) or (not a.is_zero and b.is_zero):
        return pack_inf(sign)
    if (a.is_zero and not b.is_zero) or (not a.is_inf and b.is_inf):
        return pack_zero(sign)

    A = (1 << 23) | a.frac
    B = (1 << 23) | b.frac

    if A >= B:
        N = A << 23
        E = a.exp - b.exp + 127
    else:
        N = A << 24
        E = a.exp - b.exp + 126

    Q = N / B       // integer floor
    R = N % B

    if (2*R > B) or ((2*R == B) and (Q & 1)):
        Q = Q + 1

    if Q == (1 << 24):
        Q = Q >> 1
        E = E + 1

    if E >= 255:
        return pack_inf(sign)
    if E <= 0:
        return pack_zero(sign)  // FTZ after rounding

    return (sign << 31) | (E << 23) | (Q & 0x7FFFFF)
```

## 附录 B：项目证据与外部参考

### B.1 项目内证据

- [`fp/rtl/datapath-manual.md`](../FPGA/anchorfp/fp/rtl/datapath-manual.md)：现有 DAZ/FTZ、RNE、valid/flush、FRECIP 与总体精度契约。
- [`fp/rtl/fp32_recip.v`](../FPGA/anchorfp/fp/rtl/fp32_recip.v)：5 级近似倒数及特殊值实现。
- [`fp/rtl/fp32_lat.vh`](../FPGA/anchorfp/fp/rtl/fp32_lat.vh)：现有单元延迟的唯一声明位置。
- [`fp/rtl/fp32_ops.vh`](../FPGA/anchorfp/fp/rtl/fp32_ops.vh)：现有 4 位操作码空间。
- [`fp/rtl/fp32_fpu_top.v`](../FPGA/anchorfp/fp/rtl/fp32_fpu_top.v)：独立出口和无反压派发方式。
- [`fp/sim/run_all.sh`](../FPGA/anchorfp/fp/sim/run_all.sh)：现有回归入口。
- [`fp/syn/ooc_units.tcl`](../FPGA/anchorfp/fp/syn/ooc_units.tcl)：Vivado 2025.2、Artix-7 与 20 ns OOC 基线。
- [`fp/docs/reports/06-FP32倒数的查表与牛顿迭代实现.md`](../FPGA/anchorfp/fp/docs/reports/06-FP32倒数的查表与牛顿迭代实现.md)：FRECIP 的误差、资源和不替代除法的设计依据。

### B.2 外部参考

- [RISC-V Unprivileged ISA Specification](https://docs.riscv.org/reference/isa/_attachments/riscv-unprivileged.pdf)：FDIV.S、canonical NaN 与舍入语义参考。
- [AMD Floating-Point Operator v7.1 Product Guide (PG060)](https://docs.amd.com/v/u/en-US/pg060-floating-point)：FPGA 浮点 IP 的 denormal 与算子实现参考。
- [Berkeley HardFloat Documentation](https://www.jhauser.us/arithmetic/HardFloat-1/doc/HardFloat-Verilog.html)：可参数化 IEEE 浮点硬件结构参考。
- [Berkeley SoftFloat `f32_div.c`](https://raw.githubusercontent.com/ucb-bar/berkeley-softfloat-3/master/source/f32_div.c)：软件除法与舍入实现的二次审计参考。

---

**文档结束。**
