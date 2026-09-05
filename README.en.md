<div align="center">

# anchorfp

**A complete FP32 datapath for FPGA edge accelerators: six bit-exact IEEE scalar operations,
plus a dot-product accumulator that rounds once per tile — every boundary written down as a contract.**

[![RTL](https://img.shields.io/badge/RTL-Verilog--2001-1f6feb)](rtl/)
[![target](https://img.shields.io/badge/target-Artix--7%20xc7a200t%20%40%2050%20MHz-555555)](docs/reports/)
[![regression](https://img.shields.io/badge/regression-1.17M%20vectors-2ea043)](sim/)
[![scalar](https://img.shields.io/badge/scalar%20add%2Fmul-0%20ULP-2ea043)](#results)
[![workload](https://img.shields.io/badge/workload-−89.3%25-2ea043)](#results)
[![license](https://img.shields.io/badge/license-TBD-lightgrey)](#license)

[中文版 README](README.md) · this is the short English version

</div>

---

A soft core with no FPU spends 131 cycles on an FP32 multiply and 82 on an add. This datapath brings
them to 4.99 and 5.99 — and the results are **bit-identical** to IEEE-754, 450k random vectors at
0 ULP. On board, the geometry stage of a 3D Gaussian splatting renderer drops from 10559 ms to
1132 ms.

There are two lines in here, each answering a different problem:

- **The scalar line** — add, subtract, multiply, compare, convert, reciprocal. Short pipelines,
  because the coprocessor blocks: latency *is* the price of the instruction. The −89.3% figure above
  belongs entirely to this line; the accumulator is not on that path.
- **The dot-product line** — an 88-bit fixed-point window that does not round inside a tile.
  Matrix multiply, convolution and projection are all long dot products, and a general-purpose FPU
  rounds once per term.

![architecture](docs/figures/fig-arch.svg)

## What it is, and is not

FP32 only. Flush-to-zero only. No division, no square root, no FP64/FP16, no exception flags.
Those boundaries are deliberate and each one is argued in the reports.

| Module | Role | Latency | Out-of-context area |
|---|---|:--:|---|
| `fp32_add` | add / subtract | 3 cycles | 399 LUT / 147 FF |
| `fp32_mul_pipe` | multiply, significand in DSP | 2 cycles | 98 LUT / 66 FF / 2 DSP |
| `fp32_cmp` | six predicates, three-state result | 1 cycle | — |
| `fp32_cvt` | float <-> int32, saturating | 1 cycle | — |
| `fp32_recip` | table + one Newton step | 5 cycles | 1024x32 ROM |
| `fp32_mac_unit` | windowed dot product | 7 cycles after last term, II = 1 | 1275 LUT / 495 FF |

## The contract

**Scalar.** `FMUL`/`FADD`/`FSUB` are bit-identical to IEEE-754 binary32 round-to-nearest-even under
FTZ semantics (450k random vectors, 0 ULP). `FCMP` returns three states — less / equal / greater plus
unordered — not a boolean; six predicates share one opcode and a family bit picks the direction.
`FCVT` saturates out-of-range conversions. `FRECIP` is within 4 ULP and is exposed **only** as an
explicit call: it never replaces the `/` operator, because IEEE requires a correctly-rounded
quotient. Subnormals flush to zero with the sign preserved, covered by 283 directed cases.
Every latency in the table is **measured and asserted**, never derived from stage count.

**Accumulator.** A term entering the window is right-shifted onto a common scale, so information can
be lost in five places. Three are bounded below 2⁻⁴⁰ ULP — provably out of reach of the result's last
bit, and confirmed by the sharper test that *breaking* those paths in the golden model changes no
output bit at all. One costs a deterministic 1 ULP when the shifted-out bits carry the round
decision; fixing it measured +194 LUT (+15.2%), exactly cancelling the area this project recovered,
and a boolean sticky bit cannot recover the sign of the discarded residue, so the fix is not
unconditionally correct either. It is documented instead. The fifth is catastrophic cancellation
after an anchor reset: every finite-length accumulator that tracks the largest term has it, and it
is stated as out of contract rather than hidden.

![design space](docs/figures/fig-designspace.svg)

An exact (Kulisch) accumulator for FP32 under FTZ needs 555 bits per lane; this window is 88, or 16%
of it. Full derivation and the mutation tests that validate the checks themselves:
[docs/reports/11](docs/reports/11-定点窗口累加器的误差边界.md) (Chinese).

## Results

![latency](docs/figures/fig-latency.svg)

![workload](docs/figures/fig-workload.svg)

The curve stops at 1132 ms because what remains is no longer floating point: loop control,
addressing, memory and integer branches account for 47% of the stage, 2.5x the largest remaining FP
item, and 4.99 cycles per multiply is already the hardware price.

![accuracy](docs/figures/fig-accuracy.svg)

![ppa](docs/figures/fig-ppa.svg)

The last pass recovered area through four **bit-equivalent** rewrites — every testbench output is
unchanged, which is the only reason they may be called free. One is worth repeating: writing data
registers in the `else` branch of a reset block means "hold during reset", which is clock-enable
semantics, so the synthesiser wired `rst_n` into the CE pin of thousands of registers. The
post-route worst path was 0 logic levels, pure routing, ending on a CE pin. A single-lane
out-of-context run cannot see this — 88 enables is not a high-fanout net. It only shows up at chip
level, after routing. `syn/scan_reset_as_ce.py` finds the pattern; this repository's RTL no longer
appears in its output.

An earlier timing fix targeted the scalar adder: hold slack had fallen to 0.010 ns on a
zero-logic-level path (register straight to register). Hold has only two cures — add data delay or
shift the clock phase — and this one rebuilt a narrow signal so that it must pass through one level
of logic, restoring 0.028 ns with directed equivalence tests guarding the numerics. The acceptance
gate was rewritten at the same time, from "slack >= 35 ps" to "all paths MET and the worst path is
not a zero-logic hop", because slack moves with placement and path shape does not.

## Engineering calls, including the rejected ones

| Idea | Measured | Verdict |
|---|---|---|
| Replace `/` with the approximate reciprocal | silently changes compiled results | no — explicit calls only |
| Correctly-rounded iterative divider | cost exceeds benefit at this workload mix | no — division stays in software |
| Support subnormals | expensive classification path on both sides | no — FTZ, written into the contract |
| Truncate instead of GRS rounding | systematic bias | no |
| Split the shared barrel shifter | +28 LUT | no — sharing is correct |
| Sticky bit for the 1-ULP case | +194 LUT, not unconditionally correct | no — documented instead |
| Carry-save accumulator in the loop | bit-identical, no gain | no |
| Split the 597-line MAC by pipeline stage | area flat, interface complexity up | only the simulation-only assertions were lifted out |

## Running it

```bash
# needs iverilog >= 12, gcc, python3; verilator for lint, Vivado for synthesis
bash sim/gen_vectors.sh      # golden vectors (derived data, not committed)
bash sim/run_all.sh          # unit regression + six MAC configurations
bash sim/run_mac_audit.sh    # five directed counterexamples + five mutation tests
bash sim/lint.sh
cd syn && vivado -mode batch -source ooc_mac.tcl -tclargs base
```

## Status

The last area-recovery pass is simulation- and synthesis-verified but **has not been run on board
yet**; the scalar path and earlier MAC revisions were. There is no CI. `fp32_fpu_top` inherits its
opcode encoding from the host SoC (`rtl/lacc_defs.vh`) — one header to change if you attach a
different core. The 12 engineering reports are in Chinese; this file is the English summary.
Port-level reference: [`rtl/datapath-manual.md`](rtl/datapath-manual.md).

## Related work

[FPnew / cvfpu](https://github.com/openhwgroup/cvfpu) and
[Berkeley HardFloat](http://www.jhauser.us/arithmetic/HardFloat.html) are the IEEE-compliant
general-purpose points; [FloPoCo](https://flopoco.org/) is the FPGA-specific operator generator and
carries exact-accumulator operators. Short-pipeline FP32 add/multiply, GRS rounding and
table-plus-Newton reciprocals are all textbook; exact fixed-point accumulation is Kulisch's, and the
FPGA design space was mapped by de Dinechin and colleagues
([Design-space exploration for the Kulisch accumulator](https://hal.science/hal-01488916v2),
[Floating-Point Accumulation and Sum of Products](https://doi.org/10.1007/978-3-031-42808-1_21)).

What is contributed here is the balance: those parts re-proportioned for a blocking coprocessor
(latency first, unit cost measured on board, contract before code), plus the truncated middle of the
accumulation line — an anchored 88-bit window in a one-cycle feedback loop, fused with an unrounded
multiplier, with the cost of truncation measured, written as a contract and defended with mutation
tests. The negative results are published alongside the positive ones.

## License

Not chosen yet. The convention for hardware IP is the
[Solderpad Hardware License v2.1](https://solderpad.org/licenses/SHL-2.1/) (the hardware variant of
Apache-2.0, used by cvfpu, lowRISC and PULP). Until a `LICENSE` file lands, treat this repository as
read-and-evaluate only.
