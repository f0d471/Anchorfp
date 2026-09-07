<div align="center">

# Anchorfp

An FP32 datapath for FPGA edge accelerators: six scalar operations, plus a dot-product accumulator

[![RTL](https://img.shields.io/badge/RTL-Verilog--2001-1f6feb)](rtl/)
[![target](https://img.shields.io/badge/target-Artix--7%20xc7a200t%20%40%2050%20MHz-555555)](docs/reports/)
[![regression](https://img.shields.io/badge/regression-1.17M%20vectors-2ea043)](sim/)
[![scalar](https://img.shields.io/badge/scalar%20add%2Fmul-0%20ULP-2ea043)](#results)
[![license](https://img.shields.io/badge/license-SHL--2.1-lightgrey)](LICENSE)

[中文版 README](README.md) · this is the short English version

</div>

---

Seven independently instantiable Verilog-2001 modules, plus a written contract stating what each
one computes and to what accuracy. The six scalar operations are bit-identical to IEEE-754 under
FTZ semantics, 450k random vectors at 0 ULP. The dot-product accumulator uses an 88-bit fixed-point
window and does not round inside a block.

The two lines address different gaps. The scalar line covers "the control core has no FPU, so a
single float multiply costs tens to hundreds of cycles". The dot-product line covers "matrix
multiply, convolution and projection are all long dot products, and a general-purpose FPU rounds
once per term, so error accumulates with length". Both share the same numeric contract and the same
multiply and add units.

![architecture](docs/figures/fig-arch.svg)

## What it is, and is not

FP32 only. Flush-to-zero only. No division, no square root, no FP64/FP16, no exception flags.

| Module | Role | Latency | Out-of-context area |
|---|---|:--:|---|
| `fp32_add` | add / subtract | 3 cycles | 399 LUT / 147 FF |
| `fp32_mul_pipe` | multiply, significand in DSP | 2 cycles | 98 LUT / 66 FF / 2 DSP |
| `fp32_cmp` | six predicates, three-state result | 1 cycle | — |
| `fp32_cvt` | float to int32 and back, saturating | 1 cycle | — |
| `fp32_recip` | table plus one Newton step | 5 cycles | 1024x32 ROM |
| `fp32_fpu_top` | routes by opcode, contains no arithmetic | — | — |
| `fp32_mac_unit` | windowed dot product | 7 cycles after last term, II = 1 | 1275 LUT / 495 FF |

The pipelines are deliberately shallow. In the target setting the caller usually waits for the
result, so latency is the price of the operation: one more stage in the adder means one more cycle
on every float add. The rule is therefore "minimum latency that still meets the clock", not the
usual "deepen the pipeline for frequency". More throughput comes from instantiating several units
in parallel, not from splitting one unit further.

## The contract

The yardstick is not "how large is the error" but **"does the error follow a rule"**. Can a
deviation be stated in one sentence with no "usually" or "in most cases", such that a user can
decide whether it affects them? If yes it is a trade-off; if no it is a defect. Flushing subnormals
to zero is a 100% relative error inside that interval and is perfectly acceptable, because it is a
rule with a clean boundary. "Some inputs happen to be off by a little" is not acceptable at any
magnitude.

Promises are tiered, and the order is the priority order:

- **Tier A, non-negotiable** — correct rounding in the supported domain; identical results for the
  same operation on any calling path; a true ordering from the comparator; no garbage on special
  values; anything checkable at elaboration must be checked at elaboration; **every accuracy number
  in the documentation must have a verified provenance**.
- **Tier B, declared deviations** — the flush-to-zero rules, the tininess detection point, one
  rounding mode only, no exception flags, an error budget per approximate primitive, no fused
  multiply-add, and the accumulator inequality below.
- **Tier C, PPA** — after the first two.

The full list lives in [`rtl/datapath-manual.md`](rtl/datapath-manual.md) §11.

### Scalar side

`FMUL`, `FADD` and `FSUB` are bit-identical to IEEE-754 binary32 round-to-nearest-even under FTZ
semantics, over 450k random vectors at 0 ULP. `FCMP` returns three states, less / equal / greater
plus unordered, not a boolean; six predicates share one opcode and a family bit picks the direction.
`FCVT` saturates out-of-range conversions. `FRECIP` is within 4 ULP and is exposed only as an
explicit call: it never replaces the `/` operator, because IEEE requires a correctly-rounded
quotient. Subnormals flush to zero with the sign preserved, covered by 283 directed cases. Every
latency in the table is measured and asserted, never derived from stage count.

### Accumulator side

A term entering the window is right-shifted onto a common scale, so information can be lost in five
places. Three are covered by a computable bound: writing `A = Σ|tᵢ|` for the sum of absolute
inputs, `S` for the exact sum and `Z` for the window value before the final rounding,

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
> conclusion is the harder of the two to find, because users reason with the derivation.

One path costs a deterministic 1 ULP when the shifted-out bits carry the round decision. Fixing it
measured +194 LUT (+15.2%), exactly cancelling the area this project recovered, and a boolean sticky
bit cannot recover the sign of the discarded residue, so the fix is not unconditionally correct
either. It is documented instead. The fifth path is catastrophic cancellation after an anchor reset;
every finite-length accumulator that tracks the largest term has it. It is **not** excused by a
disclaimer: the inequality above still holds, because `A` does not shrink when `S` does. A runtime
bit, `mac_prec`, reports exactly this event per block — and only this event, since a signal whose
false-positive rate approaches one carries no information.

![design space](docs/figures/fig-designspace.svg)

An exact Kulisch accumulator for FP32 under FTZ needs 555 bits per lane. This window is 88, or 16%
of it. Full derivation and the mutation tests that validate the checks themselves are in
[docs/reports/11](docs/reports/11-定点窗口累加器的误差边界.md) (Chinese).

## Results

All numbers below come from Vivado 2025.2, `xc7a200tfbg676-1`, 20 ns clock (50 MHz). They move with
the device and the tool version; do not copy them as constants.

![accuracy](docs/figures/fig-accuracy.svg)

![latency](docs/figures/fig-latency.svg)

The "software" column is the cycle count for an FPU-less core emulating the operation with integer
instructions. The "hardware" column is the measured cost of this datapath including the caller's
wait, which is why a 3-cycle adder shows as 5.99 cycles.

![workload](docs/figures/fig-workload.svg)

The geometry stage of a 3D Gaussian splatting renderer, projecting points into screen-space
ellipses, entirely floating point. Measured one operation at a time, 10559 ms down to 1132 ms. That
curve belongs entirely to the scalar line; the accumulator is not on that path. It stops at 1132 ms
because what remains is no longer floating point: loop control, addressing, memory and integer
branches account for 47% of the stage, 2.5x the largest remaining FP item.

![ppa](docs/figures/fig-ppa.svg)

One area pass recovered LUTs through four bit-equivalent rewrites, with every testbench output
unchanged. One is worth repeating. Writing data registers in the `else` branch of a reset block
means "hold during reset", which is clock-enable semantics, so the synthesiser wired `rst_n` into
the CE pin of thousands of registers. The post-route worst path had 0 logic levels, pure routing,
ending on a CE pin. A single-lane out-of-context run cannot see it, since 88 enables is not a
high-fanout net; it only shows up once many lanes are instantiated.
`syn/scan_reset_as_ce.py` finds the pattern, and this repository's RTL no longer appears in its
output.

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
finding is what produced the tiered contract above.

## Verification

Three layers, each catching a class the others miss.

**Bit-exact golden model.** Each unit runs against an independent reference, the host machine's
IEEE-754 (`sim/gen_*_vectors.c` computes expected values with C `float`). The window accumulator has
two further models: one replicating the hardware bit for bit, one summing exactly with rationals and
rounding once. Those two used to share the same bit-pattern and product-construction code — sharing
the input side means there is really only one model, since an error there corrupts both. After
splitting them, breaking the first model's product exponent by one moves the cross-check from
maxULP 0 to 139809444, and that number is the evidence they are now independent.

**Mutation testing.** The checks themselves get checked. Five deliberate breakages of the golden
model must each turn the bit-exact comparison red. On the first run four of the five stayed green —
not because the checks were broken, but because each was paired with a stimulus that cannot observe
the mutated path. Hence a rule: a mutation that does not turn red has two possible causes, a weak
check or an unreachable path, and conflating them leads to fixing a check that was never broken.

**The reporting layer needs checks too.** Both entry scripts used to return success unconditionally,
one with a trailing `exit 0` and one because its exit code came from a `grep` in a pipeline. Any
failing check still returned 0, which makes them useless as a gate. Both now derive their exit code
from a failure count, and each has been mutation-tested.

## Running it

```bash
# needs iverilog >= 12, gcc, python3; verilator for lint, Vivado for synthesis
git clone https://github.com/f0d471/Anchorfp.git && cd Anchorfp

bash sim/gen_vectors.sh      # golden vectors (derived data, not committed)
bash sim/run_all.sh          # unit regression plus six MAC configurations
bash sim/run_mac_audit.sh    # directed counterexamples plus mutation tests
bash sim/lint.sh
cd syn && vivado -mode batch -source ooc_mac.tcl -tclargs base
```

Both scripts return 0 when everything passes and 1 on any failing check, so they can be wired
directly into CI.

Opcode encodings live in `rtl/fp32_ops.vh`: field width plus six values. Attaching a different core
means editing that one header; the five compute units do not depend on the encoding.

## Related work

[FPnew / cvfpu](https://github.com/openhwgroup/cvfpu) and
[Berkeley HardFloat](http://www.jhauser.us/arithmetic/HardFloat.html) are the IEEE-compliant
general-purpose points. [FloPoCo](https://flopoco.org/) is the FPGA-specific operator generator and
carries exact-accumulator operators. Short-pipeline FP32 add and multiply, GRS rounding and
table-plus-Newton reciprocals are all textbook. Exact fixed-point accumulation is Kulisch's, and the
FPGA design space was mapped by de Dinechin and colleagues
([Design-space exploration for the Kulisch accumulator](https://hal.science/hal-01488916v2),
[Floating-Point Accumulation and Sum of Products](https://doi.org/10.1007/978-3-031-42808-1_21)).

What is contributed here is the balance. Those parts are re-proportioned for a setting where latency
is the price of the operation, with unit cost measured rather than estimated and the contract
written down explicitly — late, as the section above admits, but written down. The accumulation line
is truncated into an anchored 88-bit window inside a one-cycle feedback loop, fused with an
unrounded multiplier, and the cost of that truncation is measured, written as a contract and
defended with mutation tests. The negative results are published alongside the positive ones.

The twelve engineering reports are in Chinese; this file is the English summary. Port-level
reference: [`rtl/datapath-manual.md`](rtl/datapath-manual.md).

## License

[Solderpad Hardware License v2.1](LICENSE)

SPDX identifier: `Apache-2.0 WITH SHL-2.1`
