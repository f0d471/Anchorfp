<div align="center">

# anchorfp

An FP32 datapath for FPGA edge accelerators: six scalar operations, plus a dot-product accumulator.

[![RTL](https://img.shields.io/badge/RTL-Verilog--2001-1f6feb)](rtl/)
[![target](https://img.shields.io/badge/target-Artix--7%20xc7a200t%20%40%2050%20MHz-555555)](docs/reports/)
[![regression](https://img.shields.io/badge/regression-1.17M%20vectors-2ea043)](sim/)
[![scalar](https://img.shields.io/badge/scalar%20add%2Fmul-0%20ULP-2ea043)](#results)
[![workload](https://img.shields.io/badge/workload-−89.3%25-2ea043)](#results)
[![license](https://img.shields.io/badge/license-TBD-lightgrey)](#license)

[中文版 README](README.md) · this is the short English version

</div>

---

A soft core with no FPU spends 131 cycles on an FP32 multiply and 82 on an add. With this datapath
attached it spends 4.99 and 5.99, and the results are bit-identical to IEEE-754: 450k random vectors
at 0 ULP. On board, the geometry stage of a 3D Gaussian splatting renderer drops from 10559 ms to
1132 ms.

There are two lines here. The scalar line is add, subtract, multiply, compare, convert and
reciprocal. The pipelines are short because the coprocessor blocks: latency is the price of the
instruction. The −89.3% figure above belongs entirely to this line; the accumulator is not on that
path. The dot-product line is an 88-bit fixed-point window that does not round inside a tile. Matrix
multiply, convolution and projection are all long dot products, and a general-purpose FPU rounds
once per term.

![architecture](docs/figures/fig-arch.svg)

## What it is, and is not

FP32 only. Flush-to-zero only. No division, no square root, no FP64/FP16, no exception flags. Each
of those boundaries is argued in the reports rather than left implicit.

| Module | Role | Latency | Out-of-context area |
|---|---|:--:|---|
| `fp32_add` | add / subtract | 3 cycles | 399 LUT / 147 FF |
| `fp32_mul_pipe` | multiply, significand in DSP | 2 cycles | 98 LUT / 66 FF / 2 DSP |
| `fp32_cmp` | six predicates, three-state result | 1 cycle | — |
| `fp32_cvt` | float to int32 and back, saturating | 1 cycle | — |
| `fp32_recip` | table plus one Newton step | 5 cycles | 1024x32 ROM |
| `fp32_mac_unit` | windowed dot product | 7 cycles after last term, II = 1 | 1275 LUT / 495 FF |

## The contract

The yardstick is not "how large is the error" but **"does the error follow a rule"**. Can a deviation
be stated in one sentence with no "usually" or "in most cases", such that a user can decide whether
it affects them? If yes it is a trade-off; if no it is a defect. Flushing subnormals to zero is a
100% relative error inside that interval and is perfectly acceptable, because it is a rule with a
clean boundary. "Some inputs happen to be off by a little" is not acceptable at any magnitude.

Promises are tiered, and the order is the priority order:

- **Tier A, non-negotiable** — correct rounding in the supported domain; bit-identical to libgcc on
  the common domain; a true ordering from the comparator; no garbage on special values; anything
  checkable at elaboration must be checked at elaboration; **every accuracy number in the
  documentation must have a verified provenance**.
- **Tier B, declared deviations** — the flush-to-zero rules, the tininess detection point, one
  rounding mode only, no exception flags, an error budget per approximate primitive, no fused
  multiply-add, and the accumulator inequality above.
- **Tier C, PPA** — after the first two.

The full list lives in [`rtl/datapath-manual.md`](rtl/datapath-manual.md) §11.

To be honest about it: **these tiers were written after the fact**, not before the first line of RTL.
Auditing the directory against them turned up two places where an unachieved accuracy figure had been
printed in the documentation, two regression scripts that always exited successfully, and the
carry-save claim above. Getting that order backwards costs real rework, which is why the tiers now
open chapter 01 rather than trailing the series as an appendix.

On the scalar side, `FMUL`, `FADD` and `FSUB` are bit-identical to IEEE-754 binary32
round-to-nearest-even under FTZ semantics, over 450k random vectors at 0 ULP. `FCMP` returns three
states, less / equal / greater plus unordered, not a boolean; six predicates share one opcode and a
family bit picks the direction. `FCVT` saturates out-of-range conversions. `FRECIP` is within 4 ULP
and is exposed only as an explicit call: it never replaces the `/` operator, because IEEE requires a
correctly-rounded quotient. Subnormals flush to zero with the sign preserved, covered by 283 directed
cases. Every latency in the table is measured and asserted, never derived from stage count.

On the accumulator side, a term entering the window is right-shifted onto a common scale, so
information can be lost in five places. Three are covered by a computable bound: writing `A = Σ|tᵢ|`
for the sum of absolute inputs, `S` for the exact sum and `Z` for the window value before the final
rounding,

```
|Z − S| < 2⁻⁴⁶ · A          the contract asks for 2⁻³² · A, so 14 bits of headroom
```

The bound uses only the anchor invariant and assumes nothing about "how many guard bits there are",
which matters for the fifth path below. It is confirmed by a sharper test as well: breaking those
paths in the golden model changes no output bit at all.

> An earlier version of this section claimed "bounded below 2⁻⁴⁰ ULP". That derivation assumed the
> largest term's alignment shift is always 8, hence a fixed 24 guard bits below it. The anchor is
> raised in 16-bit quanta, so the shift reaches 23 and as few as 9 guard bits remain. **The
> conclusion held; the reasoning behind it did not** — and a wrong derivation under a right
> conclusion is the harder of the two to find, because users reason with the derivation, not the
> conclusion.

One path costs a deterministic 1 ULP when the shifted-out bits carry the round decision. Fixing it
measured +194 LUT (+15.2%), exactly cancelling the area this project recovered, and a boolean sticky
bit cannot recover the sign of the discarded residue, so the fix is not unconditionally correct
either. It is documented instead. The fifth path is catastrophic cancellation after an anchor reset;
every finite-length accumulator that tracks the largest term has it. It is **not** excused by a
disclaimer: the inequality above still holds, because `A` does not shrink when `S` does. A runtime
bit, `mac_prec`, reports exactly this event per tile — and only this event, since a signal whose
false-positive rate approaches one carries no information.

![design space](docs/figures/fig-designspace.svg)

An exact Kulisch accumulator for FP32 under FTZ needs 555 bits per lane. This window is 88, or 16% of
it. Full derivation and the mutation tests that validate the checks themselves are in
[docs/reports/11](docs/reports/11-定点窗口累加器的误差边界.md) (Chinese).

## Results

![latency](docs/figures/fig-latency.svg)

![workload](docs/figures/fig-workload.svg)

The curve stops at 1132 ms because what remains is no longer floating point. Loop control,
addressing, memory and integer branches account for 47% of the stage, 2.5x the largest remaining FP
item, and 4.99 cycles per multiply is already the hardware price.

![accuracy](docs/figures/fig-accuracy.svg)

![ppa](docs/figures/fig-ppa.svg)

The last pass recovered area through four bit-equivalent rewrites, with every testbench output
unchanged. One is worth repeating. Writing data registers in the `else` branch of a reset block means
"hold during reset", which is clock-enable semantics, so the synthesiser wired `rst_n` into the CE
pin of thousands of registers. The post-route worst path had 0 logic levels, pure routing, ending on
a CE pin. A single-lane out-of-context run cannot see this, since 88 enables is not a high-fanout
net; it only shows up at chip level, after routing. `syn/scan_reset_as_ce.py` finds the pattern, and
this repository's RTL no longer appears in its output.

An earlier fix targeted the scalar adder, where hold slack had fallen to 0.010 ns on a
zero-logic-level path, register straight to register. Hold has only two cures, add data delay or
shift the clock phase. This one rebuilt a narrow signal so that it must pass through one level of
logic, restoring 0.028 ns with directed equivalence tests guarding the numerics. The acceptance gate
was rewritten at the same time, from "slack >= 35 ps" to "all paths MET and the worst path is not a
zero-logic hop", because slack moves with placement and path shape does not.

## Engineering calls, including the rejected ones

| Idea | Measured | Verdict |
|---|---|---|
| Replace `/` with the approximate reciprocal | silently changes compiled results | no, explicit calls only |
| Correctly-rounded iterative divider | cost exceeds benefit at this workload mix | no, division stays in software |
| Support subnormals | expensive classification path on both sides | no, FTZ, written into the contract |
| Truncate instead of GRS rounding | systematic bias | no |
| Split the shared barrel shifter | +28 LUT | no, sharing is correct |
| Sticky bit for the 1-ULP case | +194 LUT, not unconditionally correct | no, documented instead |
| Carry-save accumulator in the loop | +24.4% LUT, +22% FF, and **not** bit-identical | withdrawn, blocked at elaboration |
| Split the 597-line MAC by pipeline stage | area flat, interface complexity up | only the simulation-only assertions were lifted out |

The carry-save row is worth reading twice, because it was wrong for a while. It used to read
"bit-identical, no gain" — and a regression configuration tested exactly that claim, and stayed
green. Switching the stimulus to one that cancels, 10 of 64 cases differ: when the anchor is raised,
the two components are each shifted and truncated separately, which is not the same as truncating
their sum. The check was not broken; it faithfully compared the stimulus it was handed. What was
missing was any rule about **what stimulus that claim had to be verified against**. That single
finding is what produced the tiered contract below.

## Running it

```bash
# needs iverilog >= 12, gcc, python3; verilator for lint, Vivado for synthesis
git clone https://github.com/f0d471/anchorfp.git && cd anchorfp

bash sim/gen_vectors.sh      # golden vectors (derived data, not committed)
bash sim/run_all.sh          # unit regression plus six MAC configurations
bash sim/run_mac_audit.sh    # five directed counterexamples plus five mutation tests
bash sim/lint.sh
cd syn && vivado -mode batch -source ooc_mac.tcl -tclargs base
```

## Status

The last two passes — area recovery and the contract audit — are simulation- and synthesis-verified
(timing fully MET, bitstream produced) but have not been run on board yet. The scalar path and
earlier MAC revisions were. Chip-level worst-case hold slack moved from 0.024 to 0.019 ns across the
audit pass; the path shape did not change at all, only the placement did, so that pass cannot claim
to be free — only that the cost is not in that path's logic.

There is no CI, though both entry scripts now propagate failures as a non-zero exit code and every
check is a counting check, so wiring one up is straightforward. `fp32_fpu_top` inherits its opcode
encoding from the host SoC (`rtl/lacc_defs.vh`), one header to change if you attach a different core.
The 12 engineering reports are in Chinese; this file is the English summary. Port-level reference:
[`rtl/datapath-manual.md`](rtl/datapath-manual.md).

## Related work

[FPnew / cvfpu](https://github.com/openhwgroup/cvfpu) and
[Berkeley HardFloat](http://www.jhauser.us/arithmetic/HardFloat.html) are the IEEE-compliant
general-purpose points. [FloPoCo](https://flopoco.org/) is the FPGA-specific operator generator and
carries exact-accumulator operators. Short-pipeline FP32 add and multiply, GRS rounding and
table-plus-Newton reciprocals are all textbook. Exact fixed-point accumulation is Kulisch's, and the
FPGA design space was mapped by de Dinechin and colleagues
([Design-space exploration for the Kulisch accumulator](https://hal.science/hal-01488916v2),
[Floating-Point Accumulation and Sum of Products](https://doi.org/10.1007/978-3-031-42808-1_21)).

What is contributed here is the balance. Those parts are re-proportioned for a blocking coprocessor,
with latency first, unit cost measured on board, and the contract written down explicitly — late,
as the section above admits, but written down. The
accumulation line is truncated into an anchored 88-bit window inside a one-cycle feedback loop, fused
with an unrounded multiplier, and the cost of that truncation is measured, written as a contract and
defended with mutation tests. The negative results are published alongside the positive ones.

## License

Not chosen yet. The convention for hardware IP is the
[Solderpad Hardware License v2.1](https://solderpad.org/licenses/SHL-2.1/), the hardware variant of
Apache-2.0, used by cvfpu, lowRISC and PULP. Until a `LICENSE` file lands, treat this repository as
read-and-evaluate only.
