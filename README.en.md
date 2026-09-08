<div align="center">

# Anchorfp

An FP32 datapath under FTZ semantics, for accelerators on FPGA

[![RTL](https://img.shields.io/badge/RTL-Verilog--2001-1f6feb)](rtl/)
[![target](https://img.shields.io/badge/target-Artix--7%20xc7a200t%20%40%2050%20MHz-555555)](docs/reports/)
[![regression](https://img.shields.io/badge/regression-1.17M%20vectors-2ea043)](sim/)
[![accumulator](https://img.shields.io/badge/dot%20product-88--bit%20window-2ea043)](#the-dot-product-line)
[![license](https://img.shields.io/badge/license-SHL--2.1-lightgrey)](LICENSE)

[中文版 README](README.md) · this is the short English version

</div>

---

An accelerator on an FPGA usually sits next to a control core, and that core usually has no FPU, so
a single float multiply in C costs tens to hundreds of cycles emulated with integer instructions.
Filling that hole needs nothing new: an adder, a multiplier, a comparator, conversions and an
approximate reciprocal, built the textbook way. That is what the six scalar operations here are.
They are bit-identical to IEEE-754 binary32 under FTZ semantics, and there is nothing else to them.

The part worth thinking about is the dot product. Matrix multiply, convolution and projection are
all long dot products underneath, and a dot product is not just a multiplier chained to an adder:
chain them and every term gets rounded, so error grows with length. That is where this project makes
a call, replacing the FP32 accumulator with an 88-bit fixed-point ruler that does not round inside a
block.

![architecture](docs/figures/fig-arch.svg)

## What it is, and is not

FP32 only. Flush-to-zero only. No division, no square root, no FP64/FP16, no exception flags.

| Module | Role | Latency | Out-of-context area |
|---|---|:--:|---|
| `fp32_add` | add / subtract | 3 cycles | 399 LUT / 147 FF |
| `fp32_mul_pipe` | multiply, significand in DSP | 2 cycles | 98 LUT / 66 FF / 2 DSP |
| `fp32_cmp` | six predicates, three-state result | 1 cycle | combinational |
| `fp32_cvt` | float to int32 and back, saturating | 1 cycle | combinational |
| `fp32_recip` | table plus one Newton step | 5 cycles | 1024x32 ROM |
| `fp32_fpu_top` | routes by opcode, contains no arithmetic | — | — |
| `fp32_mac_unit` | windowed dot product | 7 cycles after last term, II = 1 | 1275 LUT / 495 FF |

The pipelines are deliberately shallow. In the target setting the caller usually waits for the
result, so latency is the price of the operation: one more stage in the adder means one more cycle
on every float add. The rule is therefore "minimum latency that still meets the clock", not the
usual "deepen the pipeline for frequency". More throughput comes from instantiating several units in
parallel, not from splitting one unit further.

## The scalar six

Nothing new here; the list is so that a user knows what they are getting. The multiplier splits into
five steps, with a 10-bit signed exponent and GRS rounding rather than truncation, which has a
systematic bias. The adder is three stages: align, normalise, round and pack. Comparator and
converter are one stage each. The reciprocal is a table plus one Newton step, with interval
midpoints stored rather than endpoints, which takes the error from 16011 ULP down to 4 ULP.

| Operation | Guarantee | Check |
|---|---|---|
| `FMUL` `FADD` `FSUB` | bit-identical to IEEE-754 binary32 round-to-nearest-even under FTZ | 450k random vectors, 0 ULP, 100% |
| `FCMP` | six predicates on one opcode, NaN unordered | 200.8k random vectors + 32 directed |
| `FCVT` | float and int32 both ways, saturating | 100k random vectors + 36 directed |
| `FRECIP` | within 4 ULP | 20k random vectors, tolerance check |
| Subnormals | flushed to zero on input and output, sign preserved | 283 directed cases |
| Latency | every value is measured, never derived from stage count | `tb_fp_lat`, 17 checks with mutation |

Three details that get missed. The comparator returns three states, not a boolean: less, equal,
greater and unordered are four distinct cases, and treating it as a boolean produces the "only the
diagonal matches" artefact. FTZ is the semantics at the hardware boundary and the only deviation
from IEEE-754 in this datapath. `FRECIP` is exposed only as an explicit call and never replaces the
`/` operator, because IEEE requires a correctly-rounded quotient and swapping in an approximation
would silently change the results of already-compiled programs.

## The dot-product line

### Chaining a multiplier to an adder

A general-purpose FPU computes a dot product by multiplying a term, rounding to FP32, adding it to
the accumulator and rounding again. The accumulator holds 24 significand bits, every term is rounded
twice, and the error grows with length. Measured on K=64 dot products against infinitely precise
summation, 300 random cases per row:

| Stimulus | 88-bit window | Same order, rounded per term in FP32 |
|---|---:|---:|
| Regular | 0 | 1168 |
| Very small values | 0 | 164 |
| Wide spread (product exponents span 210 bits) | 0 | 79 |

The right column is what reusing an off-the-shelf fmul and fadd gets you. It is not a bad
implementation, it is what a general-purpose FPU is defined to do; it just grows error when dropped
into an accelerator whose hot path is dot products.

### The other end: losing nothing

The opposite approach is an accumulator wide enough that any product in the FP32 range lands in it
unrounded, with a single rounding at the very end. That is Kulisch's idea from the 1970s, and the
posit quire is its standardised form. The length is computable: under FTZ the smallest non-zero
product is 2⁻²⁵² with its LSB at 2⁻²⁹⁹, and the largest is below 2²⁵⁶, so covering every bit
between them takes 555 bits.

Setting `GrowW` from 15 to 482 in the same RTL gives exactly that ruler. Same flow, same device
(xc7a200t-1, 20 ns, OOC single lane):

| Window width | LUT | FF | WNS | Logic levels |
|---:|---:|---:|---:|---:|
| 88 | 1278 | 496 | 7.528 ns | 17 |
| 555 | 9106 | 1956 | 0.605 ns | 49 |

7.1x the area, but the right-hand columns matter more: logic depth goes from 17 to 49 and slack
against 20 ns falls from 7.53 ns to 0.61 ns. Exact accumulation costs frequency before it costs
area, and this adder chain sits inside the feedback loop, so one more cycle on the loop halves
throughput.

![design space](docs/figures/fig-designspace.svg)

### Why the ruler is 88 bits

Most of those 555 bits are never used. What decides a dot product is the terms of comparable
magnitude; a term 2⁻⁴⁰ below the largest one cannot move the result's last bit. A full-range ruler
is built for "any term might show up", whereas one summation actually occupies a window, not the
whole ruler. So the window tracks the running maximum, under the invariant `B >= E + WinUp`, with
the accumulator arithmetic-shifted by the same amount in the same cycle.

The width is four independent quantities added up:

```
 48   unrounded product of two binary32 significands, 24 x 24
 16   WinG, the interval width the largest term lands in after anchor quantisation
  8   WinFrac, bits kept below the largest term's LSB, which sets the certified precision Q
 15   GrowW = ceil(log2 N), summation growth for up to 32768 terms
  1   sign
 ---
 88
```

The 48 is the premise of the whole design: the product is not rounded first. The 48-bit raw product
out of multiplier stage 1 goes straight into the window without passing through FP32 rounding, which
is what "fused" means here and where the gap in the table above comes from. On the same vectors,
rounding the product once per IEEE before it enters the window takes the maximum error from 0 to
1027 ULP.

### 88 is not a magic number

Read that table backwards and it is the specification of the ruler. Given a term bound N and a
target precision Q, two formulas fix the width with nothing left to tune:

```
AccW = 48 + WinG + WinFrac + ceil(log2 N) + 1
Q    = 46 + WinFrac − ceil(log2 N)
```

Q means this bound: writing `A = Σ|tᵢ|` for the sum of absolute inputs, `S` for the exact sum and
`Z` for the window value before the final rounding,

```
|Z − S| < 2^(−Q) · A
```

The contract is the formula, not a number. With the default `WinFrac = 8`, `N ≤ 255` gives `Q = 46`,
`N ≤ 4096` gives `Q = 42` and `N ≤ 32768` gives `Q = 39`. More terms means a looser bound; that is
the cost of summation itself, not of this implementation.

So 88 is just the default configuration, the one for 32768 terms. A user who only ever sums 255
terms passes `GrowW = 8` and gets the same `Q = 46` in 81 bits; passing 482 returns to the 555-bit
exact accumulator above. One RTL source covers the whole design space, and 88 is a point on it.

The formulas fix 88, but they do not say whether that point is worth taking. Sweeping `WinFrac` and
`GrowW` through the same OOC flow:

| AccW | Certified Q | LUT | FF | WNS | Logic levels |
|---:|---:|---:|---:|---:|---:|
| 81 | 32 | 1215 | 475 | 7.333 ns | 17 |
| 84 | 35 | 1359 | 488 | 7.528 ns | 17 |
| 88 | 39 | 1278 | 496 | 7.528 ns | 17 |
| 92 | 43 | 1321 | 508 | 7.528 ns | 17 |
| 96 | 47 | 1348 | 520 | 7.200 ns | 17 |

From 81 to 96 bits the curve is flat: 15 bits of certified precision for 10.9% of the LUTs, slack
unchanged, depth pinned at 17 (the non-monotonicity between neighbouring rows puts the noise of this
sweep at about ±5%). Sweeping `GrowW` gives the same shape, with LUT count set by `AccW` alone
regardless of whether those bits went to precision or to capacity. This is why 88 should not be
described as a compromise between precision and area: along this stretch there is nothing to
compromise. The cliff is on the way to 555 bits. The position of 88 is any point on the flat, and
the reason it sits here is the two formulas, not the shape of the curve.

### What the window discards

A term is right-shifted onto a common scale before it enters, so information can be lost in five
places. Three of them are covered by the bound above, which uses only the anchor invariant and
assumes nothing about how many guard bits happen to remain. That matters for the fifth: after an
anchor reset discards the old sum, cancellation can remove the result entirely, and the inequality
still holds because `A` does not shrink when `S` does. The cost of stating it this way is that
acceptance has to be checked against absolute error and input scale, not as a fixed relative error
on a near-zero `S`. Across 2352 prefix checks (5093 rescales, 1221 clears), the measured
`|Z−S|·2³²/A` peaks at 3.36e-07.

> An earlier version of this section claimed "bounded below 2⁻⁴⁰ ULP". That derivation assumed the
> largest term's alignment shift is always 8, hence a fixed 24 guard bits below it. The anchor is
> raised in 16-bit quanta, so the shift reaches 23 and as few as 9 guard bits remain. The conclusion
> held; the reasoning behind it did not, and a wrong derivation under a right conclusion is the
> harder of the two to find, because users reason with the derivation.

One path costs a deterministic 1 ULP when the shifted-out bits carry the round decision. Fixing it
measured +194 LUT (+15.2%), exactly cancelling the area recovered elsewhere in this project, and a
boolean sticky bit cannot recover the sign of the discarded residue, so the fix is not
unconditionally correct either. It is documented instead. The fifth path is inherent to any
finite-length accumulator that tracks the largest term. Besides being in the contract, the module
raises `mac_prec` per block on an anchor reset, and only on that event, since a signal whose
false-positive rate approaches one carries no information.

Full derivation, the counterexample constructions and the mutation tests that validate the checks
themselves are in [docs/reports/11](docs/reports/11-定点窗口累加器的误差边界.md) (Chinese).

### Calling contract

Not checked in the netlist, caught by assertions in simulation (`rtl/fp32_mac_assert.vh`, C1 to C5
with independent counters): the pacing between `prod_valid` pulses, `last` aligned with the final
term, no new products between the last term and `out_valid` while terms are still in flight, the
measured last-term-to-output latency, and the term count staying within `2^GrowW`. The last one has
an earlier line of defence too: a caller declares `MaxTerms`, and exceeding the certified bound is
an elaboration-time error, since block depth is a compile-time constant and finding it in simulation
would mean something checkable at elaboration was not checked there.

Port-level reference: [`rtl/datapath-manual.md`](rtl/datapath-manual.md).

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
ending on a CE pin, with 0.053 ns of setup slack; splitting them restored 1.550 ns. A single-lane
out-of-context run cannot see it, since 88 enables is not a high-fanout net. `syn/scan_reset_as_ce.py`
finds the pattern, and this repository's RTL no longer appears in its output.

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
| Carry-save accumulator in the loop | +24.4% LUT, +22% FF, and not bit-identical | withdrawn, blocked at elaboration |
| Split the 597-line MAC by pipeline stage | area flat, interface complexity up | only the simulation-only assertions were lifted out |

The carry-save row was wrong for a while. It used to read "bit-identical, no gain", and a regression
configuration tested exactly that claim and stayed green. Switching the stimulus to one that cancels,
10 of 64 cases differ: when the anchor is raised, the two components are each shifted and truncated
separately, which is not the same as truncating their sum. The check was not broken; it faithfully
compared the stimulus it was handed. What was missing was any rule about what stimulus that claim
had to be verified against.

## Verification

Three layers, each catching a class the others miss.

Bit-exact golden model. Each unit runs against an independent reference, the host machine's IEEE-754
(`sim/gen_*_vectors.c` computes expected values with C `float`). The window accumulator has two
further models: one replicating the hardware bit for bit, one summing exactly with rationals and
rounding once. Those two used to share the same bit-pattern and product-construction code, which
means there was really only one model, since an error there corrupts both. After splitting them,
breaking the first model's product exponent by one moves the cross-check from maxULP 0 to 139809444,
and that number is the evidence they are now independent.

Mutation testing. The checks themselves get checked. Five deliberate breakages of the golden model
must each turn the bit-exact comparison red. On the first run four of the five stayed green, not
because the checks were broken, but because each was paired with a stimulus that cannot observe the
mutated path. Hence a rule: a mutation that does not turn red has two possible causes, a weak check
or an unreachable path, and conflating them leads to fixing a check that was never broken.

The reporting layer needs checks too. Both entry scripts used to return success unconditionally, one
with a trailing `exit 0` and one because its exit code came from a `grep` in a pipeline. Any failing
check still returned 0, which makes them useless as a gate. Both now derive their exit code from a
failure count, and each has been mutation-tested.

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
table-plus-Newton reciprocals are all textbook, as the scalar section says. Exact fixed-point
accumulation is Kulisch's, and the FPGA design space was mapped by de Dinechin and colleagues
([Design-space exploration for the Kulisch accumulator](https://hal.science/hal-01488916v2),
[Floating-Point Accumulation and Sum of Products](https://doi.org/10.1007/978-3-031-42808-1_21)).

What this repository adds is the point in between: the accumulation line truncated into an anchored
88-bit window inside a one-cycle feedback loop, fused with an unrounded multiplier, with the cost of
that truncation measured, written as a contract a user can reason with, and defended with mutation
tests. The negative results are published alongside the positive ones.

The twelve engineering reports are in Chinese; this file is the English summary.

## License

[Solderpad Hardware License v2.1](LICENSE)

SPDX identifier: `Apache-2.0 WITH SHL-2.1`
