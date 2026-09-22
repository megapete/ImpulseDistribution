# Scripted end-to-end runs (`SelfTest.swift`)

Read this before writing, running or interpreting a self-test scenario, or before changing `SelfTest.swift`.

There is no test target, but the whole pipeline can be driven **without a human at the keyboard**, from a launch
argument. This is the thing to reach for when a change needs exercising rather than merely reasoned about; the older
`VerifySelf()` routines (`DielectricStress`, `TurnLadderModel`, `Segment.VerifyWoundInShieldCapacitance`) still cover
single formulas, but they do not load a design file, build a model or solve anything.

```bash
cp <design file>.txt ~/Library/Containers/com.huberistech.ImpulseDistribution/Data/Documents/
.../Debug/ImpulseDistribution.app/Contents/MacOS/ImpulseDistribution -PCH_SelfTest STME0999
cat ~/Library/Containers/com.huberistech.ImpulseDistribution/Data/Documents/SelfTestReport-STME0999.txt
```

Add `-PCH_SelfTestTransient YES` for the frequency-domain sweep as well, and `-PCH_SelfTestGraphs YES` (which needs the transient)
to **render the result graphs to PNGs** beside the report — `SelfTestGraph-<scenario>-axialStress.png`, `-radialStress.png` and,
for every sheet or layer winding in the model, `-radialProfile-coil<n>.png`. All three come out of `StressProfileView`, which they
share and so break together; the radial *profile* is the one whose x axis is not a height, which is exactly what a shared view is
most likely to get wrong. Its numbers go into the report as a line too, so a change of shape shows up without opening the PNG. That flag exists
because the numbers behind a graph can be asserted and the drawing cannot: a curve running off its axis, an annotation box sitting
on the line it describes, or a tick label overwriting its neighbour are invisible to any check worth writing, and are exactly what
goes wrong when a plot is edited. The window is built the way the menu item builds it and drawn with `cacheDisplay(in:to:)`, so it
is never ordered front and the run stays headless. All three of those faults were found this way on the first render of
`AxialStressProfileWindow`. A full run of the STME-0999 fixture — parse,
radial build-up, FE phase, eddy losses, inductance, capacitance, terminations, initial distribution and a 2048-step
transient — is **37 seconds**, so there is no reason not to run it.

**`SHEETLAYER-sheet` and `SHEETLAYER-layer` are the scenarios for the radial voltage profile.** `SheetAndLayer.txt` is a
two-winding design that exists for it: a 13-turn **sheet** coil inside a 938-turn, 12-layer **layer** coil, and nothing else. Each
variant impulses one coil — innermost lead grounded, 45 kV on the sheet or 125 kV on the layer at the outermost — and grounds both
leads of the other, so the coil under test is driven directly rather than by transfer and the coil beside it is at a known
potential.

**Which lead is which matters here and is not a guess.** A sheet or layer coil is one BasicSection and so one Segment, and
`AppController`'s segment-building loop gives it exactly two floating leads: `.inside_lower` in and `.outside_upper` out. So
`.coilEnd(end: .bottom)` *is* the innermost lead on these coils and `.coilEnd(end: .top)` *is* the outermost. The TERMINATIONS
section prints the location each one landed on, so a future geometry change says so rather than silently testing the winding
backwards.

`S0738-sheet-floating` is kept as the second sheet case — a coil taking its voltage by *transfer* rather than directly, which is
the ordinary way an LV sheet winding sees anything at all. It exists because every other S0738 variant grounds coil 0 at both ends,
and a winding shorted end to end has identically zero volts across it, so its profile is a correct but useless flat line.

A useful thing the SHEETLAYER runs show, which is easy to mistake for a bug: **the shorted coil still has voltage across its
gaps.** In `SHEETLAYER-sheet` the grounded layer coil reports 4.2 kV on its outermost gap against a reference of zero — the
impulsed coil beside it drives the layers capacitively even though its own terminals are tied together. The profile reports the
enhancement as `n/a` there rather than as `1.00x`, which would say the opposite of what is happening.

The `VerifySelf()` formula checks have their own gate, separate from all of this and needing no fixture:

```bash
open -a ImpulseDistribution --args -PCH_Verify YES
defaults read com.huberistech.ImpulseDistribution TurnLadderVerification
defaults read com.huberistech.ImpulseDistribution DielectricStressVerification
```

One name in that argument is not a design: **`STRANDED`** runs `SelfTest.CheckStrandedConnection` instead, which is about the
connections rather than about a winding — it drops a jumper on a node that interleaving is about to swallow and checks that the
guard sees it and that the fold leaves nothing behind. See `docs/connectors-and-nodes.md`.

Four mechanical points, each forced by something:

- **`NSUserDefaults` parses `-key value` launch arguments itself**, so there is no argument plumbing and the test path
  cannot be reached from a normal launch (`applicationDidFinishLaunching` checks for the key and returns immediately
  when it is absent).
- **The fixture is read from the app's own container**, because the entitlements grant only
  `user-selected.read-write` — a design file anywhere else needs the `NSOpenPanel` that granted access to it. Do *not*
  "fix" this with a `temporary-exception` entitlement: that changes what the shipped app may read in order to run a test.
- **The report is a file, in that same container folder**; only a one-line summary goes to `UserDefaults`
  (`defaults read com.huberistech.ImpulseDistribution PCH_SelfTestSummary`). A page of report through `defaults read` is one
  enormous escaped line.
- **`PCH_SelfTestStage` is written and flushed before each step.** The pipeline raises `NSAlert`s on failure and a modal
  alert with nobody watching hangs the run forever, so that key is the only evidence of where a hung run stopped. The one
  alert path that *is* headless-aware is `AppController.PCH_ErrorAlert`, which asks **`SelfTest.isRunningHeadless`** (true
  whenever `-PCH_SelfTest <name>` was given) and falls back to the log line. Anything else that learns to put an alert up
  should ask the same question.

**A scenario names its connections as `SelfTest.LeadPoint`s, never as (Segment, location) pairs**, and `FindLead` goes and looks
for the lead the point names. (Since 2026-09-22 the types and the lookup live in `Wiring.swift`, shared with the regulating-winding
declarations; `SelfTest`'s names are typealiases and thin wrappers, and its report text is unchanged.) Neither half of the pair is knowable from the design file: which Segment is at the bottom of a coil
depends on how many there are, and its lead sits at `.inside_lower`, `.outside_lower` or `.center_lower` depending on winding type
and disc count. A guessed one produces a connector `NodeAt` cannot resolve — which is the failure class this harness exists to
catch, so it must not be able to manufacture it. Three kinds of point exist: `.coilEnd(coil:end:)`, `.gapLead(coil:gap:side:)`
for the two leads facing each other across an internal tapping/DV gap, and `.discCrossover(coil:disc:)` for the series connector
between two adjacent discs, named by the disc **below** it counting from 1 at the bottom of the coil. That last one is an
*interior* point of the winding rather than a lead going anywhere, and it is a real place to jumper from — paralleling the two
halves of a double-stacked tap winding is exactly a set of crossover-to-crossover jumpers. Whether a given crossover is at the OD
or the ID is not a choice (it alternates disc by disc), so the run reports which side it turned out to be; and disc numbering is
refused outright on a coil whose Segments have been folded, because a crossover inside a Segment is not a node.

- **Terminations** hand the found location to `AddConnector`, which *replaces* a floating lead rather than appending to it —
  exactly what `TransformerView`'s `mouseDownWithAddGround` / `mouseDownWithAddImpulse` do, minus the hit testing. It terminates
  **that lead and nothing else**: what is at the same potential through a jumper is `ResolveNodeConnectivity`'s answer and is not
  written into the connector store (see `docs/connectors-and-nodes.md`). Both this routine and the UI used to copy the ground
  onto every jumpered lead as well, and both stopped on 2026-08-08.
- **Jumpers** (`SelfTest.Jumper`, applied between the restructure and the terminations) are a port of `TransformerView.CompleteAddConnection`,
  **cross-product and all**: a lead that already carries jumpers is at the same potential as everything on their far ends, so a
  new jumper is registered on every (Segment, location) pair at each end. Doing less would build a model the UI cannot produce.
  The order is forced from both sides — a restructure sends `UpdateConnectors` through the connectors and would sweep a jumper
  away, and a termination replaces the floating lead a later jumper needs in order to find its end.
- **`Scenario.edits`** is an ordered list applied *after* all of the above, and it is what lets a scenario describe a **session at
  the keyboard** rather than a finished wiring: `.jumper`, `.terminate`, and `.remove` (a port of `mouseDownWithRemoveConnector`,
  which sweeps the clicked jumper's whole equivalence class). A designer changes a connection scheme by editing the one already
  there, and the interesting failures live in that sequence rather than in any single operation — see the `S0738-parallel` trio.

**`AxialProfileReport`** (transient runs only) prints the disc-to-disc profile of the continuum coil gap by gap — height, stress,
allowable, ΔV, allowable ΔV — with the count of tagged gaps, and fails loudly if a disc-to-disc check of that coil carries no
height. It is the numeric half of `AxialStressProfileWindow`: a shape hides a gap tagged at the wrong height, and one dropped out
of the picture entirely leaves a curve that still looks plausible. That is how item 10's missing external gaps were measured — the
plain STME-0999 coil reports 69 gaps, the same coil interleaved reports 35.

**`Scenario.reportNodes`** turns on a table of every node of every coil with how the simulation model classified it, what the
initial distribution put there and — with `-PCH_SelfTestTransient YES` — its min/max over the run. It also prints a one-line
canonical **`Connectivity:`** fingerprint of the whole classification. Two scenarios that describe the same wiring by different
routes must print that line identically; `grep -h Connectivity: SelfTestReport-S0738-parallel*.txt | sort -u` should give exactly
one line, and more than one means derived state has outlived its source.

**The run re-runs `SetNodes` itself, after the connections are on.** Nothing else does: the node topology a scenario is carrying
was built during the restructure's recalculation, when the coil ends were still floating. That is harmless when every connection
is a coil end, and wrong the moment one is not — a jumper across a tapping gap and a ground on a centre lead both change what
`SetNodes` decides. It calls `PhaseModel.CalculateCapacitanceMatrix` directly rather than `AppController.recalculateModel`,
because that one puts an `NSAlert` up when this throws and a modal alert with nobody at the keyboard hangs the run forever.

## What the STME-0999 fixture is for

A real 4160Y/2400 V — 69 kV delta unit: 48-turn helical LV, 70-disc continuous HV, no taps and no axial gaps, both LV
leads and the HV neutral grounded and 350 kV full wave on the HV line end. The uniform geometry is the point — it is the
case **DelVecchio 13.5.1, "Uniform Capacitance Model"** (p.389) is written for, so a disagreement is more likely to be
this program's than the book's. The report checks the parse against the design (2.940 mm and 3.925 mm axial gaps for
nominal 3 mm and 4 mm unshrunk, 1379 turns at 19.7 per disc) and compares the computed initial distribution against
`sinh(αx)/sinh(α)`, α = √(C_g/C_s).

**α is reported as a bracket, not a number.** DelVecchio's C_g is capacitance to a grounded surround; a real phase has
another winding in the way, here grounded at both ends and so *nearly* — not exactly — an equipotential. So the report
gives `α` from the C_g booked straight to ground alone and again with the coil-to-coil term folded in, and the answer
should land between them. As of 2026-08-06 the HV coil gives **6.56 / 13.21 with a fitted 11.17**, and the local
d(ln V)/dx sits at 9.8 mid-coil rising to 11.5 near the line end.

## The three STME-0999 variants

`STME0999`, `STME0999-interleaved` and `STME0999-shield6` differ **only** in `Scenario.restructure` — same core, conductor,
gaps and impulse — so the line-end gradient can be read off three times with nothing else moved. The restructure runs
*before* the terminations, because swapping Segments sends `UpdateConnectors` through the connectors and a ground applied
first would not survive it. `SelfTest.ApplyRestructure` is the model-level half of `doInterleaveSelection` /
`doAddWoundInShields` without the `SegmentPath` selection or the dialogs; it deliberately does **not** re-implement their
guards (already-interleaved, non-contiguous, spans a tapping gap), because it always works on a whole coil of a freshly
loaded model where each is answered by construction. Route anything less regular through the `AppController` versions.

| | C_s per pair | fitted α | line-end gradient | worst section | transient peak |
|---|---|---|---|---|---|
| plain | 3.932e-10 (1.0×) | 11.17 | 30.31× | **65.4 kV** / 1 disc | 1.236 p.u. |
| 6-turn shield | 7.766e-09 (19.8×) | 2.46 | 2.68× | **28.6 kV** / 2 discs | 1.002 p.u. |
| interleaved | 8.917e-09 (22.7×) | 2.28 | 2.59× | **27.6 kV** / 2 discs | 1.002 p.u. |

Three things to know before reading that table:

- **"Section" is not the same amount of winding down the column.** Both restructures rebuild the coil into *two-disc*
  Segments, so the plain row's worst section is one disc and the other two are two. The **line-end gradient is the
  directly comparable number** — it is a voltage per unit of winding height and does not care how the coil is divided.
- **A 6-turn shield gets 86% of the way to full interleaving**, which surprises people. `C_s(n)` is linear in n
  (`VerifyWoundInShieldCapacitance` pins that to 4.4e-16), the slope here is 1.229e-9 F per shield turn, and
  extrapolating hits the interleaved value at **n = 6.94** out of 19.7 turns per disc. So on this design a 7-turn shield
  *is* an interleaved winding as far as C_s is concerned. That is the whole selling point of 12.11 — but it also means
  "somewhere in between" is technically true and practically misleading, and a scenario at n = 2 or 3 would sit nearer
  the middle.
- **The shield is not free and interleaving is.** The shield adds 1.778 mm of bare radial plus 0.305 mm of paper per
  shielded pair, taking the HV radial build from 56.767 to 69.264 mm; `ApplyRadialBuildUp` then grows `legCenters`
  760 → 784.994 mm and the tank depth 1343.3 → 1368.3 mm to hold the clearances. C_g rises only 1.7% because of it.

## The STME-0999_2 variants, and why they invert the answer

The second fixture is the regime intershielding actually exists for: **25 MVA, 120 kV wye / 26.4 kV delta, both coils
disc-wound in CTC**, 550 kV BIL. CTC is a large stranded conductor, so a disc holds few turns — 688 over 64 discs, 10.75
each — and interleaving a CTC winding is essentially impossible to manufacture. The interleaved scenario here is a
**reference**, not a proposal: it says what the shield is measured against.

**All three hold the HV at the same radial build**, the one the 5-turn shield needs (+10.414 mm = 5 × 2.083 mm over
paper), via `Scenario.matchedBuild` → `PhaseModel.radialBuildUpFloor`. That is not a nicety. Fitting a shield does *two*
things — it adds shield turns and it widens the disc, and a wider disc has more face area, so C_dd rises on its own
(C_dd ∝ R_out²−R_in²). On the first fixture the 6-turn shield widened the HV 22%, worth 24% more face area, and there
was no way to tell from the result how much of the gain was the shield. With the floor set, all three runs come out with
identical ID/OD/build, identical `legCenters` and tank depth, and **identical C_g to 7 figures** — so the only thing left
different is the electrical treatment. `SelfTest.SizeShield` sizes the wire for both the fitting and the matching path,
so a "matched" geometry cannot silently fail to match.

| C_s per pair, identical geometry | | α fitted | line-end gradient | worst section | peak |
|---|---|---|---|---|---|
| plain | 7.063e-10 (1.00×) | 8.22 | 23.09× | 73.1 kV / 1 disc | 1.195 p.u. |
| 5-turn shield | 4.988e-09 (7.06×) | 2.958 | 3.194× | 47.2 kV / 2 discs | 1.002 p.u. |
| interleaved | 5.006e-09 (7.09×) | 2.953 | 3.189× | 47.1 kV / 2 discs | 1.002 p.u. |

**k = 5 of N = 10.75 is 47% of the turns, which is right at the break-even point** — turn terms alone are 4.487·c_t
interleaved against 4.535·c_t shielded, and break-even is k = 4.97. That is why this fixture keeps producing photo
finishes and why it is a poor place to ask "which method is better". At the shield fractions real designs use it is not
close: 28% of the turns puts interleaving 66% ahead, 19% puts it 149% ahead. The first fixture, at n/N = 30%, gives
interleaving **+47%** and is the more representative comparison. See `docs/decisions.md` §2b for the whole cross-check.

Note what the last three columns say regardless: at α ≈ 3 the initial distribution is already near enough to linear that
more C_s has nothing left to flatten — line-end gradient 3.2 either way, envelope 1.002 p.u. either way. On this design
the choice is a manufacturing decision, not a dielectric one, which is the answer a designer wants and the opposite of
what the C_s column alone suggests.

Note that "plain" in that table is **not the as-designed transformer**: it is the design widened to the shield's build,
which raises its C_s too. It is the right baseline for isolating the shield and the wrong one for costing the design.

**The interleaved row's low section voltage is the disc-to-disc stress only**, and the report says so at that line.
Interleaving buys it by winding electrically distant turns side by side, which *raises* the turn-to-turn voltage inside
each disc — the reason an interleaved winding needs heavier turn paper. Nothing in this harness measures that, and
`TurnLadderModel` refuses interleaved windings on purpose (the position-to-turn map is scheme-dependent).

**The C_g "booked to ground" of the outermost coil is not the tank** — it is the tank *plus the adjacent phases*, which
are **76%** of it here. The report prints the split for exactly that reason; see `OuterShuntCapacitance` and
`adjacentPhaseCount` in `docs/capacitance.md`.

Two things learned from the first run, both worth keeping:

- **Fit α on ln(V), never on V.** The distribution spans four decades, so a least-squares fit in V sees only the top two
  or three discs — precisely the least representative ones, since the end disc has its own series capacitance. The
  linear fit returned **14.75** against a winding whose local α is 9.3–10.8, put the answer outside the C_g bracket, and
  so reported a disagreement with DelVecchio that was entirely an artefact of the estimator. This is the same shape of
  error as the `Residual` 1e-9 story in `docs/solver.md`: a diagnostic that fails on a correct model
  is worse than no diagnostic. The table's **local-α column** asks the same question with no fitting at all and should
  be read first.
- **The end disc is not on the curve, and that is real.** `Section Cs` shows the two end discs of the HV at **0.294 of
  the mean** (the helical LV's at 0.511), which is `SeriesCapacitance`'s end-disc branch (DV 12.63-64) doing its job —
  an end disc has a neighbour on one side only. It takes 0.366 p.u. across it at t = 0+, a local α of 36 against the
  winding's 10.8. A **uniform** continuum model cannot represent that, so the departure at x → 1 is expected; what
  would be a real finding is that departure appearing anywhere else, or the end-disc Cs ratio moving.

The line-end gradient is divided by the end section's **own** span in x, not by 1/N: the end nodes sit at the outer face
of the end disc while interior nodes sit at gap midpoints, so end sections are ~12% shorter and 1/N charges them for
length they do not have.

## The two `-rings` variants: the first fixture with a Segment that is not a circuit element

`STME0999-rings` and `STME0999-interleaved-rings` are the first two scenarios to fit a **static ring**, one at each end of the HV,
via a `Scenario.staticRings` list applied *after* the restructure (the order the user works in — a ring is fitted to whatever
Segment the coil ended up with). They exist because a static ring is the only thing in the model that is a `Segment` and is **not**
a circuit element, so the moment one is present "the number of Segments" has two different answers and every array sized by it has
to pick the right one. `SelfTest.StaticRingCheck` asserts the three that matter: the inductance matrix is `CoilSegments().count`
square and not `segments.count`; every ring in the store is reported by at least one Segment (no orphans); and the Segments on
either side of a ring agree about it. The interleaved variant is the reported failure end to end — restructure, then ring, then a
full recalculation.

Fitting the rings is not cosmetic, and the numbers say why: on the plain HV the two end discs go from **0.294 of the mean section
Cs to 0.702**, and the line-end gradient from **30.31× to 16.14×** with the worst section voltage from 65.4 kV to 51.3 kV. That is
`SeriesCapacitance`'s static-ring branch (DV 12.62) replacing its end-disc branch (12.63-64): an end disc with no ring has a
neighbour on one side only and loses its outward C_dd entirely, while a ring gives it a facing electrode across 1.96 mm of oil plus
the ring's own 3.18 mm/side wrap. It does not recover *all* of it — the wrap is thick — hence 0.70 and not 1.0. **None of this was
reachable before 2026-08-08**, because `SegmentAt` could not find a static ring at all (see `docs/segments-and-geometry.md`), so the
ring was in the picture and out of the physics.

## The S0738 fixture: a connection, not a winding

`S0738` and `S0738-plain` (`S0738_AndIn.txt`, four coils, 1050 kV on the HV) are the first fixture here that is about **how the
coils are wired together**. Coils 0 and 1 are grounded at both ends; coil 2 is the impulsed 74-disc HV, interleaved in its
entirety in the first variant and left alone in the second; **coil 3 is a double-stacked tap winding** whose two ends are tied to
each other and to the *bottom of coil 2*, and whose two centre leads are tied to each other and grounded. Three things in that are
not reachable from either STME fixture, and all three are node-topology questions rather than capacitance ones:

- a coil with an **internal tapping gap** (`AppController`'s segment-building loop cuts one into any double-stacked coil, and
  gives each side its own `outside_center`/`inside_center` floating lead);
- **both centre leads jumpered together *and* grounded**, which is the combination that erases every floating lead at the gap;
- a coil **fed from another coil** rather than from a ground, an impulse or nothing.

It was written to reproduce a reported failure and did, verbatim: *"segment 168 has a connector at outside_center with no node
there (target: 169)"* — see `IsTappingGap` in `docs/connectors-and-nodes.md`. Both variants now run the whole pipeline
including the transient (82 s with `-PCH_SelfTestTransient YES`).

**The continuum comparison is declined on this fixture, out loud.** DelVecchio 13.5.1 solves a boundary-value problem, and one of
its two boundaries is missing here: coil 2's far end returns through both halves of coil 3 to a centre ground, so it floats at
**0.652 p.u.** at t = 0+ (0.169 p.u. unrestructured) and `V(0) = 0` is simply false. Fitting anyway returned α = 0.010 "inside the
bracket" on a winding whose local α is 0.2 and rising — the same class of artefact as the linear-vs-logarithmic fit above.
`ContinuumComparison` therefore **measures** the far end against `groundedEndTolerance` (1e-6; a grounded node comes back an exact
zero from the row surgery, so there is nothing to tune between that and 0.65) and, when it fails, prints the distribution and the
line-end gradient alone. Those two are what survive the model not applying, and the gradient is still the comparable number:
**25.18× average plain against 0.615× interleaved**.

## The S0738 `-parallel` trio: the same wiring reached three ways

`S0738-parallel`, `S0738-parallel-edited` and `S0738-parallel-edited-2` wire the *same* fixture the way a double-stacked tap
winding is wired when **no taps are in circuit — the two halves paralleled**: the HV neutral goes straight to ground; coil 3's two
centre leads are tied together and grounded; its two outer ends are tied to each other and to nothing else; and the outermost
crossovers are tied across the gap in mirror pairs (2‑3↔30‑31, 4‑5↔28‑29 … 14‑15↔18‑19, i.e. disc *d* to disc 32−*d*). This is the
first scenario with a jumper at an **interior** node of a winding, and the first whose tap winding does not carry the HV's return
current — coil 3's outer ends are a genuinely floating pair at **0.165 p.u.** at t = 0+, swinging −114.6 / +181.3 kV.

**All three describe the identical finished wiring and differ only in how it is reached**, which is the whole point:

| | route |
|---|---|
| `S0738-parallel` | built in one pass from a freshly loaded model |
| `S0738-parallel-edited` | the `S0738` series wiring, then *remove the old jumper* → *ground the HV neutral* → add the crossovers |
| `S0738-parallel-edited-2` | the same three edits with the first two **swapped**: ground the neutral while the old jumper is still on it, *then* pull the jumper |

The last one is the reported failure. With the ground copied onto every jumpered lead it came back with coil 3's outer ends in
`groundedNodes`, pinned at exactly 0, and a line-end gradient of 27.34 against the other two runs' 25.31 — the same picture on
screen, a different model underneath. All three now print an identical `Connectivity:` line, and that is the regression check.

## `T0223-tap-declared`: the same wiring from a regulating-winding declaration

`T0223-tap-parallel` with coil 3's nine paralleling jumpers made by `Scenario.regulatingWindings` — a declaration of coil 3 as a
double-stacked regulating winding of 8 loops, applied through `RegulatingWinding.Apply`, the path the menu command and the design
load take — leaving only the tie to the HV neutral as a hand jumper. Declarations go on after the restructure and **before** the
scenario's jumpers. The **REGULATING WINDINGS** section lists the nine jumpers made, then checks that applying the declaration
again makes none, and that changing it to 1 loop and back removes and restores all nine. The run must print the same
`Connectivity:` line as `T0223-tap-parallel`; see `docs/connectors-and-nodes.md`.

