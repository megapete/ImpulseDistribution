# TODO

**Open** gaps and deviations, with enough context to pick any of them up cold. See `CLAUDE.md` for how the
surrounding code is organised, `docs/capacitance.md` and `docs/dielectric-stress.md` for the physics as it
stands, and **`docs/decisions.md` for investigations that are already settled** — several items below were
partly closed and keep only their outstanding half here.

Item numbers are stable and are cited from elsewhere in the repo; do not renumber them.

## Capacitance

From the conformance audit against DelVecchio *Transformer Design Principles* ch. 12 and Kulkarni &
Khaparde *Transformer Engineering* ch. 7 (2026-08-02/03). Both PDFs are in `~/Documents/MyProjects/Claude/`.

Everything below is a **known** deviation. The audit found the disc path otherwise faithful: 12.47, 12.49,
12.50, 12.52, 12.53/12.54, 12.62 and 12.63 are all implemented correctly, and 12.52 reproduces the book's
own worked example exactly.

### 1. Two end static rings (DV 12.9) and a ring between the first two discs (DV 12.10)

`PhaseModel.CalculateCapacitanceMatrix` throws `.OnlyOneStaticRingAllowed` rather than handling either
configuration. This is **not** just a missing formula. 12.78-12.81 show the first two discs become
electrostatically coupled *through* the rings, producing a mutual C₁₃ that bypasses the intermediate node.
A scalar `Segment.seriesCapacitance` cannot represent that, so supporting it means adding an off-diagonal
term to the C matrix, not just a new branch in `SeriesCapacitance`.

`AddStaticRing` refuses the configuration up front, so the user is told at the point of fitting the second
ring. Workaround for a single Segment carrying a whole coil: split it into at least 2 Segments, which puts
the two rings on different discs and out of 12.78-81's way. → `docs/decisions.md` §1 for how this used to
fail.

### 2. Interleaved and multi-start windings

- Interleaved discs use **Veverka eq. 6.4** (`Cs = Ctt·(N−1)`, halved by the caller), not DelVecchio, who
  covers only wound-in-shields and multi-start in ch. 12. It also drops the (N−1)/N voltage-fraction
  argument that 12.48 applies to plain discs — see the comment in `BasicSectionSeriesCapacitance`.
- **Multi-start (DV 12.12)** — **implemented 2026-09-22**, as one lumped section (`docs/decisions.md` §2c)
  — see `docs/capacitance.md`. Two things remain. The design file's turn count is *taken* to be every turn
  in series (all starts), on the evidence of its turn definition; no multi-start design has been checked
  against that, and a count that does not divide by the starts is refused so the other reading cannot
  pass silently. And nothing screens a multi-start winding's own turn-to-turn stress — at up to 2ΔV_s
  between neighbours it is the one number a designer most wants from this winding (`DielectricStress`
  covers disc, sheet and layer only).

#### 2b. Cross-check against Kulkarni & Khaparde §7.3 — **closed 2026-08-06**

Nothing outstanding. The two books were shown to agree term for term, three deviations were found and all
three were applied, and the interleaved/shielded ranking now matches the texts at realistic shield
fractions (interleaving +47% on STME-0999 at n/N = 30%, +0.4% on STME-0999_2 at 47%). The full
cross-check, the measured tables and the shield-fraction analysis are in **`docs/decisions.md` §2b**.

### 2a. Wound-in shields — implemented, with two known gaps

DV 12.11 is implemented. Remaining gaps:

- **A shielded pair beside a static ring** keeps its (1/6)·Cdd term with `DiscToDiscSeriesCapacitance`'s
  static-ring solid term. DelVecchio has nothing for this combination; the treatment is a plausible
  extension, not something from the book.
- **Combine / split / interleave refuse to operate on shielded Segments** rather than carrying the
  shields across. They rebuild Segments from their BasicSections, which would drop the shield silently.
  Carrying it would mean re-slicing `turnsPerDisc` to the new grouping.

### 3. Hilo stick count is borrowed from the disc's key spacers

`PhaseModel.CoilInnerShuntCapacitance` sets `Ns = numAxialColumns` (the *disc's* key-spacer columns) and
hard-codes `ws = 0.75"`, where DV 12.61 wants the number and width of the **sticks in that hilo**. The
`Npress = round(hilo/0.0084 − 0.5)` barrier count is likewise a shop heuristic with no counterpart in the
book. `Segment.LayerToLayerCapacitance` makes the same substitution deliberately, for consistency.

The barrier count now carries more weight than it did, because `PhaseModel.HiloLayerStack` builds the
stress stack duct by duct from it (`Npress` barriers, `Npress + 1` oil ducts, oil against both winding
surfaces) rather than lumping — and the oil allowable goes as `d^−0.36`, so one barrier more or fewer moves
the reported coil-to-coil utilization by several percent. The capacitance is unaffected either way (Σ(ℓ/ε)
is subdivision-independent). If the heuristic is ever replaced by a real barrier schedule, the stress
report is what will notice.

### 4. Shunt capacitance is always split 50/50 onto the two end nodes

DV 12.71 gives `C₁ₐ = Cs·γa(α/tanh α − α/sinh α)`; 12.72 says only that this *approaches* Ca/2 for small α,
which is where the π model comes from. `PhaseModel.CalculateCapacitanceMatrix` applies the π split
unconditionally. Harmless while segments are one or two discs; the error grows if segments get long.

### 5. `EffectiveHeight`'s 75 mm rule

`PhaseModel.EffectiveHeight` drops any axial gap larger than 75 mm from the height used for the ground
capacitance. A house rule with no book counterpart, and the threshold is arbitrary (it is commented as
such).

### 6. Super Duper Shunt Capacitance Algorithm™

`PhaseModel.CalculateCapacitanceMatrix`, the `capLink` loop. Matches up mis-aligned node sets on two
adjacent coils and distributes the total inter-coil capacitance between them. Entirely original — neither
book gives a procedure for this. It does conserve the total by construction. **Parked deliberately**: PCH
wants to discuss the approach before anything is changed here.

#### 6a. A quarter of the LV–HV capacitance goes missing on S0747 — found 2026-10-26, not yet investigated

On `S0747` (no radial shield) the HV books **2.123e-10 F** to the LV and the LV books the same back, but
`CoilInnerShuntCapacitance(coil: 1)` gives **2.831e-10 F** for that pair, recomputed by hand from the same formula. That is
75% of the total, which contradicts "conserves the total by construction" above. The same formula reproduces the shield-to-HV
value exactly (3.336e-10 F, `S0747-shield`), so the shortfall is in how the total is shared out, not in the total itself.
The likely place is the `capLink` loop, or the `referenceHt`/`referenceZero` bookkeeping in front of it. The LV here is a
**sheet**, so it has only two nodes against the HV's 77, which is the most mismatched pairing the loop can be given. First
step: sum the capLinks for each coil pair on every fixture and compare each sum against `CoilInnerShuntCapacitance`.

**The HV–RV pair on the same fixture (hand-checked 2026-10-26):**

- **Tank and adjacent phase:** exact. `OuterShuntCapacitance` gives 3.4357e-11 F and 9.9389e-11 F, and so does the hand
  calculation, to six figures.
- **The pair's total is 7% short as well:** 6.687e-10 F booked against 7.215e-10 F from `CoilInnerShuntCapacitance(coil: 2)`.
  The shield-to-HV pair, which never enters the `capLink` loop, is exact, so the loop is the suspect for both pairs.
- **The total itself is arguably high.** `CapacitiveHeightInner` takes the AVERAGE of the two effective heights, 0.623 m, but
  the RV's own effective height is only 0.310 m: two 155 mm stacks either side of a 406 mm gap. What the two coils actually
  present to each other is the RV's height plus fringing.
- **The distribution is the bigger problem.** The coupling is spread along the HV's full 1012 mm at a uniform rate. So the HV
  discs facing the RV's empty 406 mm gap (HV nodes 22–47), and those above and below the RV's ends, are each linked to the
  nearest RV node. Result:
  - RV centre leads 95 and 96 carry **1.49e-10 and 1.44e-10 F**, 43% of all the HV–RV coupling, against 6–8e-12 F on an
    ordinary RV node.
  - HV nodes 37 and 38 carry a spike of **7.7e-11 F each**, 17× their neighbours.
  - Because 95 and 96 are tied to the HV centre on S0747, about 25 HV discs that face only oil end up capacitively coupled
    to their own centre node. That is a large part of the lower half's ~0.17 p.u. "pedestal" in the initial distribution.
- **The RV's ground capacitance has the same gap effect:** the total is conserved, but 58% of it lands on 95 and 96.

A fix would book coupling only where the two coils' conductors actually face each other, plus some fringing at the
ends and gap edges. That is item 6's algorithm, which is parked for discussion.

#### 6b. How much it matters, and a proposed replacement — measured 2026-10-26

**The one-off run.** This was temporary code, now removed. Just before C was assembled, it took out all the HV–RV coupling and
re-booked it RV disc by RV disc, each in proportion to its height. Each RV disc's share was split over the HV discs it overlaps
axially, a quarter to each end-node pair, with no fringing. It ran on the S0747 wiring in two variants: the same total as now
(6.687e-10 F), and a total from the RV's own effective height (0.310 m instead of the 0.623 m average, 3.59e-10 F).

| | now | overlap, same total | overlap, RV-height total |
|---|---|---|---|
| `S0747-shield` line-end gradient | 7.02× | 7.03× | 6.65× |
| `S0747-shield` worst section | 35.8 kV | 36.1 kV | 34.1 kV |
| `S0747` line-end gradient | 5.62× | 5.73× | 5.27× |
| `S0747` worst section | 28.8 kV | 29.5 kV | 27.1 kV |
| HV node 55, about 2/3 up (shield) | 0.335 p.u. | 0.275 | 0.303 |
| HV centre, node 40 (shield) | 0.173 | 0.166 | 0.157 |
| RV outer ends (shield) | 0.277 | 0.215 | 0.193 |

Peak is 1.002 p.u. in every case. **At the line end, the placement barely matters and the total matters by about 5%. In the
middle of the coil and on the RV itself, the shifts are up to about 0.07 p.u. (about 35 kV at 550 kV)**, which matters for any
HV-to-RV or along-the-RV stress check.

**Why the average height overstates this pair.** `CapacitiveHeightInner` averages the two effective heights. That is fine for
coils of similar height. Here it credits (0.936 − 0.310)/2 = 0.31 m of fringing, about 78 mm (one full hilo) at each of the
RV's four free edges: top, bottom and both faces of its 406 mm centre gap. PCH believes the averaging rule is from DelVecchio;
find the page and see what case it was written for.

**Proposed fringing estimate.** In the slot between two coils, the field from a disc beyond the end of the opposite
electrode decays roughly as exp(−π·d/g). Here d is the axial distance past the edge and g is the radial gap. This is a
textbook two-dimensional slot result and should be treated as an engineering estimate. Integrated, it is equivalent to
extending the facing height by **g/π per free edge**: 24.5 mm here, so H ≈ 0.310 + 4 × 0.0245 ≈ **0.41 m**. The same weight
answers "close but not too close": an HV disc 12 mm past an RV edge gets 60% of a facing disc's coupling, 25 mm gets 36%,
50 mm gets 13%, and 77 mm (one hilo) gets 4%. So only 2–4 discs past each edge matter. Today every HV disc out to about 400 mm
away gets the full rate, piled onto the RV's nearest node. The estimate ignores the RV's end faces (82 mm of radial build)
and the HV's other paths to the tank.

**Proposed next steps, in order (item 6 is parked, so PCH to approve the first):**

1. Replace the `capLink` matching with **overlap-plus-decay booking**: for each pair of discs, book coupling where they face
   each other, weighted by exp(−πd/g) beyond each edge. Conserve the pair's total, and derive that total from the same
   weighted height rather than the average. That should also cure 6a's lost quarter.
2. Settle the fringing with an **electrostatic FE solve** of S0747 as the reference. `PchAxiSymFE` already carries an
   `ElectrostaticFormulation`, marked "phase two". It would give the whole disc-to-disc shunt matrix directly, fringing
   included, and it is the calibration for the g/π allowance.

#### 6c. Overlap-plus-decay booking — implemented behind a switch, 2026-10-26

Step 1 of 6b is in, as `PhaseModel.BookShuntCapacitancesByOverlap` (the rule and its integration are documented on
`OverlapDecayCoupling`). **It has been the default since 2026-10-26 (version 1.3.2).** `-PCH_ShuntBooking capLink` on the
command line brings back the original booking, which is unchanged and now lives in `BookShuntCapacitancesByCapLink`. Keep that
switch until the FE run (6d) has settled the rule, then delete `capLink`.
The SelfTest report now has a `SHUNT BOOKING` section that prints, for either method, the booked total for each coil pair and
for each coil to ground, the single node that carries the largest share, and the analytic totals beside them.

The rule: at each z the coupling is `c′·exp(−π(d_A + d_B)/g)·dz`, booked to the nearest Segment on each side. Here
`c′ = C(H)/H` comes from the existing formulas and g is the radial gap. The core, a radial shield, the tank and the adjacent
phase are grounded electrodes; the core, tank and phase run the full window height. The tank and the adjacent phase are two
separate walks, because their gaps differ by a factor of eight on S0747.

**The checks it passes.** LV to core grows by exactly 2·(g/π)(1 − e^(−π·61/g)) = 12.1 mm for g = 19.05 mm: the core runs on
61 mm past each end of the LV. HV–RV comes out at 0.400 m of effective height, against 0.41 m estimated in 6b. Every coil pair
books the same total from both sides, and `S0747-shield` under `capLink` reproduces 6b's "now" column exactly.

| | S0747 capLink | S0747 overlap | -shield capLink | -shield overlap |
|---|---|---|---|---|
| LV–HV (or shield–HV) | 2.123e-10 | 3.025e-10 | 3.336e-10 | 3.671e-10 |
| HV–RV | 6.687e-10 | 4.636e-10 | 6.687e-10 | 4.636e-10 |
| RV to ground (tank + phase) | 1.337e-10 | 2.083e-10 | 1.337e-10 | 2.083e-10 |
| largest RV node's share of HV–RV | 22.3% (node 95) | 5.2% | 22.3% | 5.2% |
| line-end gradient | 5.62× | **7.02×** | 7.02× | 7.42× |
| worst section | 28.8 kV | 35.8 kV | 35.8 kV | 37.8 kV |
| HV node 55 / centre node 40 | 0.416 / 0.230 | 0.295 / 0.161 | 0.335 / 0.172 | 0.275 / 0.147 |
| RV outer ends (79, 112) | 0.321 | 0.176 | 0.277 | 0.165 |

**What it shows:**

- **6a was worse than a lost quarter.** `capLink` put 34% of the LV–HV coupling on HV node 78, which is the line terminal. A
  capacitance on a driven node does nothing to the distribution, so the HV effectively had about half its LV coupling.
  Booked properly, the unshielded S0747 line-end gradient rises from 5.62× to 7.02×, the same as the shielded variant. That
  is what physics says it should be, since the LV is grounded at both ends and acts as a shield. **The current S0747 numbers
  understate the line-end stress by about 20%.**
- **The pile-up on the RV centre leads is gone.** The largest single node falls from 22% to 5% of the HV–RV coupling. Mid-coil
  and RV potentials drop by 0.06–0.15 p.u.
- **The shield–HV term rises 10%.** That is the HV's 76 mm gap, now about two-thirds counted with g = 150 mm, plus about g/2π
  at each aligned end. The aligned-end term is the weakest part of the rule and FE should check it.
- **The tank term is where the slot model is least defensible.** g = 467 mm makes g/π = 149 mm, which is comparable to the
  RV's 213 mm clearance to the yoke and larger than half its 406 mm centre gap. This is the main reason the RV's ground C rises
  56%. The phase-to-phase walk (g = 57 mm) is on firmer ground. The FE run should settle both.

**Found on the way, and fixed in 1.3.2:** `CoilInnerShuntCapacitance` for a radial shield (negative `coil`) took its `prevIR`
from `SegmentAt(radial: -coil)`. For a shield, that is the coil **outside** it, so rGap was 537 mm instead of 222 mm on
`S0747-shield`. The LV-to-shield capacitance was 3.065e-9 F; it is now 1.346e-9 F. The HV results are unchanged, because the
LV is grounded at both ends.

#### 6d. Electrostatic FE reference for the shunt matrix — built and run 2026-10-26; the questions it raised are open

The purpose: 6c's rule `exp(−π·d/g)` is a slot estimate. It is weakest at the tank (g = 467 mm on S0747), at aligned coil ends
(the g/2π-per-end term), and across layered barrier/oil gaps. An axisymmetric electrostatic solve gives the whole Segment-to-Segment
and Segment-to-ground matrix, fringing included, as the reference for choosing g or for replacing the rule outright.

**What was built.**

- **`PchAxiSymFE`:** the formulation now chooses the material coefficient (`Formulation.stiffnessCoefficient(of:)`: ν for
  magnetics, ε for electrostatics) as well as the radial weight. A new `CapacitanceMatrixSolver` treats each electrode's nodes as
  constrained, factorizes the free block once, solves once per electrode, and takes the charge by reaction with the unreduced K.
  The mesh's Dirichlet faces are the grounded enclosure. Tests in `CapacitanceTests.swift`: a coax against 2πεL/ln(b/a), two
  dielectric layers in series (both to 1e-5), symmetry, Maxwell signs, refinement, and touching electrodes rejected. All 113
  package tests pass, so the magnetic results did not move.
- **The app:** `FeShuntReference` in `FePhase.swift` (the bridge; no package type leaks out of it), and
  `PhaseModel.ElectrostaticReferenceInputs` (every Segment is an electrode, plus the dielectric regions).
  `-PCH_SelfTestShuntFE YES` adds a `SHUNT MATRIX: ELECTROSTATIC FE REFERENCE` section after `SHUNT BOOKING`, solved on the base
  mesh and once refined. `-PCH_ShuntBooking fe` books C from the FE (a third choice beside `overlap` and `capLink`), with the
  adjacent phase still added by the overlap rule. That booking is an experiment; it costs a mesh and ~110 solves every time C is
  built (3 s on S0747).

**One modelling choice differs from the plan above.** Each hilo is one homogeneous region with `HiloRelativePermittivity`, the
factor now pulled out of `CoilInnerShuntCapacitance`. The plan was real pressboard tubes plus oil smeared with the sticks. That
differs from the formula by about 1% even with no fringing at all, because a smeared layer in series with the tubes is not the same
as the formula's two parallel paths. The tubes' radial positions are not in the design file either. With the homogeneous fill,
FE and formula differ in geometry alone, which was the stated aim. The tank gap gets `OuterShuntCapacitance`'s oil/barrier factor
over the full window height; everything else is oil.

**Numerics.** S0747: 34k nodes, then 136k (3 s and 12 s). `-shield`: 63k, then 250k (6 s and 22 s). Every total of any size moves
by less than 0.3% under refinement, and the matrix is symmetric to 3e-16.

**Results on S0747 (FE on the refined mesh; `-shield` is the same except where noted).**

| | overlap (6c) | FE | FE / overlap | node distribution, TV distance |
|---|---|---|---|---|
| LV–HV | 3.025e-10 | 2.696e-10 | 0.89 | 0.075 |
| HV–RV | 4.636e-10 | 5.562e-10 | 1.20 | 0.25 (HV side), 0.15 (RV side) |
| HV to ground (core, yokes, tank) | 0 | 2.958e-10 | — | — |
| `-shield`: HV to ground (shield included) | 3.671e-10 | 6.267e-10 | 1.71 | 0.19 |
| RV to ground | 2.083e-10 (tank + phase) | 1.708e-10 (coaxial tank and yokes, no phase) | — | 0.15 |
| LV to core | 1.953e-9 | 2.025e-9 | 1.04 | — |

(TV distance is half the sum over nodes of |booked share − FE share|: 0 means the same distribution, 1 means no node in common.)

**What it shows:**

1. **The biggest term is one nothing books: the HV's own ground capacitance, 3.0e-10 F**, as large as its whole coupling to the LV.
   About 1e-10 of it is in the top 144 mm of the HV, which stands proud of the RV (its top is at 929 mm, the HV's at 1074 mm). With
   only oil between it and the tank (626 mm) and the top yoke (346 mm), it gets about 8e-12 F per node, against 2e-13 F a few discs
   lower, where the RV shields it. A free coil end acts like a torus: a rough torus-to-infinity estimate for that 144 mm gives
   9e-11 F. The coax-per-metre picture every analytic term is built on has no end term at all. A smaller share sits on the bottom
   three discs, 61 mm above the bottom yoke, next to the grounded end. Only the outermost coil gets any ground term from the
   booking. A coil's ends, and any surface of it not facing a neighbour, get nothing.
2. **LV–HV is 11% below the overlap rule and 5% below the plain formula** (2.831e-10 at H = 974 mm). With a 178 mm hilo and the
   yokes 61 mm from the coil ends, the field at the ends goes to the yokes instead of across the hilo. So the g/2π-per-aligned-end
   term 6c adds is the wrong sign here. The distribution along the HV is right (TV 0.075).
3. **HV–RV sits between the two bookings:** 1.20× overlap, 0.83× `capLink`. The FE puts 4–5e-11 F on each of the RV's gap-edge
   nodes (94–97), twice what overlap books, and 6e-12 on its outer ends (79, 112), a third of what overlap books. The RV's gap
   faces see more of the HV than exp(−πd/g) allows, and its outer ends see less, because the yokes and the tank take the field
   there.
4. **Effect on the initial distribution (`-PCH_ShuntBooking fe` against `overlap`):**

| | S0747 overlap | S0747 FE | `-shield` overlap | `-shield` FE |
|---|---|---|---|---|
| line-end gradient | 7.02× | **9.45×** | 7.42× | **9.73×** |
| HV node 55 / centre node 40 | 0.295 / 0.161 | 0.234 / 0.114 | 0.275 / 0.147 | 0.220 / 0.104 |
| HV node 77 (one disc below the line) | 0.926 | 0.900 | 0.922 | 0.897 |
| RV outer ends (79, 112) | 0.176 | 0.123 | 0.165 | 0.117 |

   The gradient rise is what the totals predict: the HV's effective capacitance to ground goes from 3.0e-10 to 5.7e-10 F, and
   √(5.7/3.0) ≈ 1.37. The transient (worst section kV) has not been run with the FE booking.

5. **The control, STME0999** (a plain two-winding design, no gaps): the formulas hold where the geometry is what they assume.
   LV–HV is 1.426e-9 F by FE against 1.384e-9 booked (+3%), LV–core is +4%, and the two distributions are nearly identical
   (TV 0.006 and 0.022). The HV's ground term is 3.36e-10 by FE, against 4.73e-10 booked for tank and phase together. The FE puts
   it on the HV's two end discs (9.2% of it on one node), where the booking spreads it evenly. With `-PCH_ShuntBooking fe` the
   line-end gradient goes from 31.6× to 35.2× (+11%): the same end effect as on S0747, smaller because no coil end stands proud
   of a neighbour.

**Open, for PCH:**

- **Is the HV's end capacitance real on the unit?** The FE has an idealized enclosure: the core, two flat yokes and a coaxial tank
  at half the tank depth. The real top end has clamping structure, leads and end insulation (pressboard, εr ≈ 4.5, not oil). The
  real tank is a box, and the adjacent phases are grounded in the test, all of which add ground capacitance rather than remove it.
  The size of the effect (+35% gradient) means it should be settled before trusting either booking's line-end numbers on a design
  whose impulsed coil stands proud of its neighbours.
- **Reference or production?** The FE booking runs in 3 s and needs no calibrated constant, and it is now one launch argument away.
  But it is the only booking that gives a coil end its ground term. Switching to it changes S0747's line-end gradient by a third,
  which is a decision about the physics, not the code. If it stays a reference, the analytic rule needs an end term: a coil end to a
  yoke, and a coil's free surface to the tank.
- **`capLink` stays** until that is settled (6c said to delete it once the FE had spoken). The FE agrees with neither booking
  closely enough to choose between them on totals alone.
- Still shared with 6c: a continuous disc faces the inner coil with its inner turn, so splitting a quarter onto each node pair is
  itself an approximation. The FE booking inherits it.

## Dielectric stress screen

Added 2026-08-05 (`DielectricStress.swift`, `TurnLadderModel.swift`). See `docs/dielectric-stress.md` for the method and its
accuracy. Known gaps:

### 7. One open question on the chapter 13 allowables

`DielectricStress.StressAllowable` uses DelVecchio ch. 13 (see `docs/dielectric-stress.md` for the table and citations). One thing
in it is not straight from the book:

- **`creepImpulseRatio` (2.8)** — the book gives creep breakdown only at power frequency (13.15, 13.16). The impulse creep figure
  here is 13.16 scaled by the oil impulse ratio, on the grounds that creep along a pressboard surface in oil is an oil-adjacent
  process. It is isolated as a named constant so it can be replaced if a real impulse creep source turns up. All four creep
  allowables are currently unused (item 12), so this affects no reported number today.

**`designMargin` is settled (2026-08-09): it is a user preference, factory default 0.65.** It was 0.80 on the strength of the
book's Figure 13.5; re-reading ch. 13 showed that the only quantified margin in it is that one worked example in a different
geometry, and that the disk–disk examples on p.383 carry none. Since it is a house rule and not a citation, it became a setting —
see `docs/dielectric-stress.md` and `docs/ui-layer.md`.

All eight coefficients were verified against the printed page on 2026-08-05 and the self-check pins each one. Do not re-derive them
from `pdftotext`: the equations are set in a subsetted math font with no `ToUnicode` CMap, so the text layer drops decimal points
and cannot distinguish `16.0 − 1.09·ln A` from `16.0·A^−0.09`. That exact confusion produced a wrong 13.15 in the first version.
Render the page instead (poppler is installed; the Read tool does this).

### 8. The turn ladder covers one disc, and only continuous discs

`TurnLadderModel` solves a single disc with its neighbours as boundary potentials from the lumped model. Extending it to a group of
discs needs the crossover conductor modelled explicitly; interleaved and wound-in-shield discs are refused rather than guessed. Both
extensions were considered and declined — reasoning in `docs/decisions.md` §8.

**That scope is now actually enforced (2026-08-13).** `notContinuousDisc` was declared and never thrown, so every winding type ran
through the disc ladder. Sheet and layer windings went somewhere better rather than being merely refused — see §8a — and
interleaved and wound-in-shield Segments are refused with the explanation, as the decision record says.

### 8a. Two of the layer solve's inputs are not in the design file

**The fixture gap is closed (2026-08-14).** `SheetAndLayer.txt` is a two-winding design — a 13-turn sheet coil inside a 938-turn,
12-layer coil — and `SHEETLAYER-sheet` and `SHEETLAYER-layer` impulse one of them each while shorting the other out. Both paths now
run end to end. The layer result carries an independent cross-check: the solved worst inter-layer gap comes out at **2.46×** twice
the volts per layer, against **2.71×** for α/tanh α formed from the coil's lumped Cs and Cg — two entirely different routes to one
number, agreeing to 9%. That figure is *reported and not asserted*: the two are not the same quantity (the continuum line-end
gradient of a uniform winding, against the worst discrete inter-layer gap), so a tolerance would be fitted to this one design
rather than tested against it. Standing rule 8.

Two inputs are still assumed, because `PCH_ExcelDesignFile.Winding` does not carry them:

- **Turns per layer.** It has `numRadialSections` and a total turn count, nothing per layer, so `Segment.LayerTurnCounts` splits
  them equally at *N/L* per layer, fractions included, and `SolveLayer` assigns each whole turn to the layer holding its midpoint.
  A graded winding, whose layer counts are chosen rather than falling out of the height, will not match.
- **Duct positions.** It has `numRadialDucts` and `radialDuctDimension` — a count and a size — so `LayerGapCapacitances` spreads
  them evenly, exactly as `LayerToLayerCapacitance` already did. A winding whose ducts sit at particular gaps has a much lower Cll
  at those gaps and a higher one everywhere else, and neither routine will show it.

Turns per layer needs a field in `BasicSectionWindingData.LayerData` and somewhere to fill it from. **Duct positions no longer do
(2026-08-14):** `Segment.DuctGaps` spaces them evenly and centres the run — duct *j* of *n* at gap `round((j − ½)·gaps/n)`, count
clamped to the gap count — so 3 ducts in a 12-layer winding (11 gaps) land at gaps 2, 6 and 9, with insulation-only gaps at both
ends. `LayerGapCapacitances` and `SheetGapCapacitances` place them instead of smearing them. `TurnLadderModel.VerifySelf` pins the
worked example, both ends being free, and that every clamped duct lands on its own gap over all counts to 40 × 45 — a rounding
change that collided two ducts would cost one of them and be invisible in the graph, three spikes and two spikes looking equally
plausible.

**The reported worst case is sensitive to this rule, and that is the argument for real positions.** It is still an assumption, and
on the `SheetAndLayer` layer coil it is worth better than a factor of two: with the ducts at 4/7/11 the outermost gap carries one
and the worst inter-layer voltage is 76.8 kV (3.68× twice the volts per layer); centred at 2/6/9 the line-end gap is plain
insulation and the worst is 32.0 kV (1.54×). Both are the same coil at the same instant. The concentration at the line end and the
low capacitance of a duct are independent, and what the number comes out at depends on whether they coincide — which is exactly the
thing the design file does not tell us.

### 8c. `LayerToLayerCapacitance` still spreads the ducts, and the α screen inherits it

The per-gap routines place the ducts; the aggregate `LayerToLayerCapacitance`, which feeds `SeriesCapacitance` and so the whole
simulation, still uses `tDuct = numDucts·ductDimn/(numLayers − 1)` — a fraction of a duct in every gap. **This was left alone on
purpose**, because changing it moves every existing layer-winding result and there is no obviously right single Cll for a coil whose
gaps genuinely differ: the Stein layer formula wants one representative value, and the smeared duct is a defensible way to get one.

It has a visible consequence. The radial profile's α screen (`α = √(Cg/Cs)`, line-end gradient `α/tanh α`) reads Cs through
`CoilSeriesCapacitance` and so through the smeared aggregate, while the profile itself is solved with the ducts placed. On a coil
with no ducts the two agree closely — 2.46× against 2.71× on the `SheetAndLayer` layer coil before the ducts were placed. With them
placed the solve goes to 3.68× while the screen stays at 2.71×, and that gap is the two models describing different windings rather
than a disagreement about one. Both the window and the report say which basis the screen is on. Resolving it means deciding what a
single representative Cll should be for a ducted layer winding, which is a modelling question and not a bug.

### 8b. ~~The sheet series capacitance is built on a smeared τ that swallows the ducts~~ — DONE (2026-08-15)

**Resolved.** `BasicSectionSeriesCapacitance` now returns the exact series chain `1/Σ(1/C_k)` for a sheet winding, and
`Segment.VerifySheetCapacitance` (under `-PCH_Verify YES`) pins it against `SolveSheet` through the common-charge identity. On the
`SheetAndLayer` fixture the sheet coil went from 0.923 nF to 0.695 nF (×0.753), which moves every sheet-winding transient result.
**The trap, kept because it is worth not walking into again.** What was there was DelVecchio's disc formula `Cs = Ctt(N−1)/N²` with
`Ctt` built on `τ = (width − N·turnRadialDimn)/(N − 1)` — the whole leftover build, three 6.35 mm oil ducts and a 6% overbuild
allowance included, 1.77 mm of notional paper in a gap holding 0.254 mm. The obvious repair, substituting the design file's
`interLayerInsulation` into the same formula, would have been **much worse than leaving it alone**: the ducts would have gone
entirely and Cs would have landed about 9× the exact chain, where the smear was 1.33×. The smear was wrong twice in opposite
directions and mostly cancelling. The lesson generalises — a wrong input feeding a wrong formula is not repaired one at a time.

Note this was never the same situation as §8c. For a layer winding there is a genuine modelling question about what one
representative Cll should be; for a sheet winding there was none, because the exact answer is available in closed form.

**Still open, and unrelated:** `SheetGapCapacitances` takes the radial build from the Segment's live `r2 − r1`, per standing rule 7,
while `CapacitanceTurnToTurn` uses `basicSections[0].width`. The two agree unless a sheet coil has been built up to carry shields,
which nothing does today. (`SheetTurnInsulation`, which both now go through for τ, uses the live radii.)

### 9. `SteinParameters.gradientEnhancement` interpolates the intermediate case

It is exact at Ya = Yb (linear, an interior disc with equal gaps) and at Ya = 1, Yb = 0 (α/tanh α, a one-sided disc) and
interpolates on |Ya − Yb| between them. The exact general case needs the boundary-value problem solved for the Ya/Yb-weighted
environment potential. The turn ladder is the intended escape hatch when the exact answer matters.

### 10. Disc-to-disc uses the two-node span only for plain continuous discs

Interleaved Segments, and Segments holding more than one disc, fall back to the single node step across the gap (the location
string says which was used). The 2V crossover argument does not carry over unchanged to those winding orders. Gaps *inside* a
multi-disc Segment are driven at 2·ΔV_segment/n, which is the same argument applied to the Segment's own span.

**That fallback currently measures nothing, and so drops the gap entirely (found 2026-08-11).** Its terms are
`+1·V[aboveNodes.below] − 1·V[nodes.above]`, and for two series-connected Segments those are **the same node**: the node between
them has `belowSegment == segment` and `aboveSegment == above`, so `AdjacentNodes` returns that one index as this Segment's
`.above` and as the next one's `.below`. The driving voltage is therefore identically zero at every step, `Evaluate` refuses a site
with no volts across it, and **no finding is produced for any external disc-to-disc gap of a coil whose Segments hold more than one
disc or are interleaved.** Measured on the STME-0999 fixture: the plain coil reports 69 gaps, the same coil interleaved into 35
two-disc Segments reports 35 — exactly its internal gaps, at twice the disc pitch, with all 34 external gaps missing. The table,
the ranking and `AxialStressProfileWindow`'s curve are all short by those gaps.

The tapping-gap case is **not** affected: a tapping gap breaks the node chain, so the two terms name different nodes.

Fixing it is a physics choice, not a typo, which is why it is recorded rather than patched: what a designer wants across that gap
for an interleaved winding depends on the interleaving pattern (the facing conductors are deliberately *not* electrically
adjacent), and for a plain multi-disc Segment the honest one-step measure is the drop across one of the two Segments rather than
zero. Whatever is chosen has to be defensible from ch. 12/13 — do not put an invented span in there to make rows appear.

### 11. Coil-end radial fields are flagged, not valued

Past the end of a shorter adjacent coil the field is genuinely two-dimensional. The screen holds the nearest inner potential and
marks the finding "value indicative only". No Schwaiger-type end enhancement and no oblique-spill estimate is attempted — both were
considered and declined (`docs/decisions.md` §11).

### 12. There is no creep check — the screen is strike-only

Creep sites were built and then removed on 2026-08-06 (`docs/decisions.md` §12), because the model has no way to measure a creep
path. The allowables (13.15, 13.16, `creepImpulseRatio`) stay in `StressAllowable`, unused, and `VerifySelf` still pins them.

What has to come first is **geometry that is not in `PhaseModel` today**:

- a hilo barrier **extends past the coil ends**, so the path is up one face, around the overhang and back down the other;
- at high voltage that end carries **angle rings and caps**, which lengthen it further;
- a key spacer's path runs around the spacer, bounded by the disc faces clamping it.

Note also that some creep paths are better judged on **area** than length — a stick surface bridging a hilo, say — which is what
`CreepPowerFrequencyByArea` (13.15) was implemented for and why it is worth keeping.

## Design file versions 5 and 6

Opening a design now puts its intershields and static rings on the model; see `docs/segments-and-geometry.md`. Left open:

- **The shields' connection.** The file does not say how a shield is connected, so it opens floating. A shop that ties its
  intershields to the line would need the file, or a preference, to say so; for now it is Remove and Add again.
- **The BILs beyond the crest.** The simulation dialog's crest now defaults to the BIL at the impulsed lead
  (`AppController.ImpulsedLeadBIL`). Nothing else uses the BILs yet; the stress report's allowables are the obvious next place.
- **The top edge pack.** Coils are still centred on the tallest coil's bottom edge pack plus half its height. The top edge pack
  would say where the yoke actually is above each coil, which matters to a static ring's clearance and to the end-disc stresses.
- **Shielded discs that are not at the ends, or not in pairs.** The file can only say "this many at the top, this many at the
  bottom", which is what this program can model. An odd count is refused with an alert rather than rounded.

## Notes

- There is no test target, so numerical changes are verified by hand against the books' worked examples.
  `docs/capacitance.md` records the one for `DiscToDiscSeriesCapacitance`.
- The frequency-domain solver's validation table (`docs/solver.md`) uses a synthetic ladder and is
  unaffected by capacitance-model changes — but exported `.cir` netlists will change whenever these do.
