# Dielectric stress screening (`DielectricStress.swift`, `TurnLadderModel.swift`)

Read this before touching the stress report, the stress profiles, the turn ladder, or any breakdown allowable.

Turns a simulation result into **electric stress in V/m**, to locate the places in a design that need redesign or extra care in
manufacture. It is not a substitute for finite element, and it is explicit about that. Reached from *Simulate → Show Dielectric
Stress Report / Show Radial Stress Profiles / Turn Ladder for Selected Disc*.

**It needs no new physics, because the capacitance code already contains the field solution.** Every capacitance routine here is a
series-dielectric reduction; `Segment.DiscToDiscSeriesCapacitance` forms Σ(ℓ/ε) over the layers in a gap, and continuity of normal
**D** turns that straight into the field: `E_i = V/(ε_i·Σ(ℓⱼ/εⱼ))`. So the screen reuses the same geometry, and a full run is
milliseconds against hours for an FE solve per time step.

**There are two profile graphs, and `StressCheckKind.isRadial` is what keeps them apart.** Both plot against height and both
assemble themselves from the `profileName`/`profileHeight` a site carries, so the filter is the only thing stopping each from
showing the other's curves: `StressProfileWindow` (radial, coil-to-coil/core/tank) takes the radial kinds, and
`AxialStressProfileWindow` (disc-to-disc against height, one coil at a time) takes `.discToDisc`. Both graphs now carry the same
furniture — millimetre ticks, the allowable drawn across the curve, and the worst point named in the body of the plot — because
both draw into `StressProfileView`; see `docs/ui-layer.md`. The axial sites are tagged in `AppendAxialSites` at the **middle of
each gap** — a value per gap, not per disc, so the gap's own centre is the only height that does not shift the curve half a gap
along the coil. All three kinds of axial gap are tagged: the ones inside a multi-disc Segment, the ones facing a static ring, and
the ordinary gap between Segments.

Nothing in either window is recomputed from the geometry. The allowable at a point is `averageField / averageUtilization` and the
allowable ΔV is `deltaV / averageUtilization`, both **exact** rather than a second evaluation of the allowable, because the field
is linear in the driving voltage — the same property `Scan` is built on. `SelfTest.AxialProfileReport` prints the axial profile gap
by gap and `-PCH_SelfTestGraphs YES` renders **both** profile windows to PNGs, which is how the curves get checked without a
keyboard.

Note what item 10 in `TODO.md` says about interleaved and multi-disc Segments: their **external** disc-to-disc gaps produce no
finding at all today, so they are missing from the table, the ranking and this curve alike.

**Everything that wants the findings goes through `AppController.StressChecks()`**, which runs the screen if the cache is empty
and **shows nothing**. Each menu item then opens its own window and only its own. It was not always so: "Show Radial Stress
Profiles" filled the cache by calling `doShowStressReport()`, so the first use of it put the report table on the screen as well.
The cache is what keeps the graph and the table from disagreeing about a model, so a caller that wants the numbers must not have
to open a window to get them.

Two extractions exist purely so the stress and the capacitance can never disagree about what is in a gap — the same discipline
`FrequencyDomainSolver.CapacitiveDistribution` follows for the assembly. **`Segment.DiscToDiscLayerStack`** returns the layers in
physical order and `DiscToDiscSeriesCapacitance` builds its Σ(ℓ/ε) from it; **`Segment.SteinParameters`** holds α/Ya/Yb and
collapses what used to be three inline copies in `SeriesCapacitance`'s `.disc` branch. Both refactors were verified exactly
value-preserving (worst 3.5e-16 over 160 gap cases, 1.8e-16 over all 432 endDisc/staticRing combinations), and the three branches
are one formula because 12.63's `Cs·α/tanh α` **is** 12.53 at Ya = 1, Yb = 0.

| accuracy vs. FE | |
|---|---|
| average field across a laminar gap | **2–5%**; the reduction is analytically exact, the error is the finite disc width |
| peak field at a conductor corner | **20–30%, biased high** (conservative — do not "fix" it) |
| end regions with no static ring | genuinely 2-D; weakest case, flagged rather than valued |
| peak field at a static ring's corner | as above, and the ring's own Kraft is the layer at risk — see below |
| **ranking gaps worst-first** | **reliable** — this is what the feature is for |

## The allowables are DelVecchio chapter 13

"Voltage Breakdown Theory and Practice", and they are **functions of distance, not constants** — a single number would be wrong by
a factor of two across the gaps in one coil. That distance dependence is also what makes the screen match the book's own procedure
for non-uniform fields (p.371): subdivide the path, average the field over each subdivision, compare against the breakdown value
*for that subdivision's length*. Each dielectric layer is one such subdivision.

All eight were **read off the printed page** (poppler is installed, so the Read tool renders PDF pages as images) rather than
decoded from the text layer — the equations are set in a subsetted math font with no `ToUnicode` CMap, so extracted text loses the
decimal points. Verify any change the same way; do not trust `pdftotext` for the formulas.

| | eq. | kV/mm, d in mm |
|---|---|---|
| oil, planar, impulse peak | 13.30 | 50·d^−0.36 |
| oil, planar, a.c. rms | 13.27 | 17.8·d^−0.36 |
| kraft, impulse peak (90 °C) | 13.4 | 79.43·d^−0.275 |
| kraft, a.c. rms | 13.5 | 32.8·d^−0.33 |
| pressboard, impulse peak (90 °C) | 13.8 | 91.2·d^−0.26 |
| pressboard, a.c. rms (90 °C) | 13.8 | 27.5·d^−0.26 |
| **creep**, a.c. rms, by distance | 13.16 | 16.6·d_c^−0.46 |
| **creep**, a.c. rms, by area | 13.15 | **16.0 − 1.09·ln A_c** |

**The screen is strike-only — the two creep rows are present but unused (2026-08-06).** The creep *allowables* are fine and
`VerifySelf` still pins all three; what was wrong was the *geometry* fed to them. A creep path was taken as the straight axial run
between the electrodes: the gap itself for a key spacer, and for a hilo barrier the **difference in the two coils' end heights**.
That last one is what removal was really about — it is not the hilo at all, so a design with a 19 mm hilo and coil ends a
millimetre apart got a 1 mm path carrying the full end-to-end voltage, judged at a 1 mm path's strength, and duly sorted to the top
of the table. A real creep path runs up one face of the barrier, **around its overhang past the coil end** and back down, longer
again where angle rings and caps are fitted at high voltage. None of that structure is in `PhaseModel`, so **bringing creep back
starts with the geometry, not with `DielectricStress.swift`** — see the long note above `StressAllowable.CreepPowerFrequency`. Until
then the summary line in `StressReportWindow` says "strike only" out loud, because "0 over allowable" otherwise reads as a clean
bill of health on a check that was never made.

Two traps in that table. **13.15 is logarithmic in area, not a power law** — 16.0 and 1.09 in a subtraction, not 16.0 and 0.09 in an
exponent; 13.9 (oil by volume) has the same shape, and both eventually go negative, which the book flags for 13.9 on p.370 and
which `CreepPowerFrequencyByArea` clamps. And **pressboard uses 13.8 (90 °C), not 13.7 (room temperature)** — 13.8 is the more
conservative of the two everywhere in range and keeps the temperature assumption consistent with the paper figures, where 13.4 is
also a 90 °C measurement whose 10% room-temperature bonus is deliberately declined. 13.7 remains available as
`PressboardImpulseRoomTemperature`.

Four distinctions in there must never be collapsed: **strike vs. creep** (different formulas and much steeper creep exponent — which
is why a short creep path carrying a large voltage so often governs, and why the missing creep check above is not a small gap);
**power frequency vs. impulse** (ratio ≈2.8 for oil, 2.7 for
paper, 3.0 for pressboard); **rms vs. peak** (the a.c. forms are rms, the impulse forms peak, and the simulation gives instantaneous
volts, so the impulse forms compare like with like); and **50% breakdown vs. design level** (p.368 — the book's data are the former,
so `StressAllowable.designMargin` brings it to the latter; see the next section).

## The design margin is a preference, and the book barely supports a number

`StressAllowable.designMargin` is **`Preference.dielectricDesignMargin`, a user setting (⌘,) whose factory default is 0.65** — see
`docs/ui-layer.md` for the preferences mechanism. It is a preference because it is the one figure in this file that is a house rule
rather than a citation, and the book was re-checked on 2026-08-09 to see how much it actually says:

- **That a margin is needed: stated, unquantified.** p.368 — "Generally, the breakdown voltages are those for which the
  probability of breakdown is 50%. Thus, some margin below these levels would be needed in actual design."
- **The number 20%: one worked example.** p.382, the cylinder-to-ground-plane calculation, whose Figure 13.5 is captioned
  "Breakdown kV with a 20% margin". That is the only number in the chapter, it is a different geometry, and the disk–disk
  examples on the very next page (p.383: 30.0, 34.0, 40.0 kV/mm impulse) carry **no margin at all**.

So the old 0.80 was one figure's choice, not a recommendation, and an earlier version of this file overstated it by calling
Figure 13.5 its basis. For calibration: the author's long-standing empirical disc-to-disc formula — 43·(rs_t/0.11)^0.7 +
25·(cp_t/0.02)^0.75 kV, dimensions in inches — lands at **0.67–0.90 of this screen's allowable** across the practical range (ducts
2.5–12.7 mm, paper 0.25–2 mm total), an effective margin of roughly 0.6–0.8 on the book's 50% level, so 0.65 sits inside house
practice rather than beside it.

What the setting does and does not do is worth keeping straight: every allowable is multiplied by it, so **every utilization scales
as 1/margin**. It moves the pass/fail line and **cannot change the worst-first ranking**, which is what the screen is for. At 1.00
the report reads as a straight percentage of the book's 50%-breakdown level. `StressReportWindow`'s summary line prints the margin
in force, so a screenshot of a report is self-describing.

**`Segment.woundInShieldMaxWorkingStress` (2755 V/mm, 70 V/mil) must never be used here.** It is a *power-frequency working*
turn-to-turn stress for sizing wound-in-shield paper, not an impulse allowable. An earlier version of this file cited it as the
model for the allowables and shipped invented numbers alongside; both are gone.

**Only the average field carries a margin.** The corner column reports an *enhancement ratio*, not a percentage of an allowable,
because chapter 13's data are uniform-gap measurements judged against average fields — there is no sourced criterion for a corner
peak. That is also why the two corner columns are **hidden unless `Preferences.showCornerStresses` is on** (factory default off,
added 2026-08-11): they are the only columns in the table that cannot be failed, and a column sitting beside "% of allowable" that
is not a margin is read as one. Nothing else changes with the setting — no finding is ranked, coloured or computed differently, so
`AppController.handleShowPreferences` rebuilds the report window without re-running the screen. That is precisely where the book says (p.16) "there is usually some judgment involved", and where an FE run earns its keep.
The one figure here that is an extrapolation rather than a citation is `creepImpulseRatio` (the book gives creep only at power
frequency); it is isolated as a named constant for that reason, and is on the unused creep path.

**The corner model is geometry, not a tabulated factor — but the radius it turns on *is* tabulated.** `CoaxialField` does double
duty: at r ≈ 0.3 m it is the hilo, at the strand's corner radius it *is* the corner. The paper follows the corner, so the paper's
field is read at the copper radius and the oil's at the paper's outer radius. Anchor to re-check after any edit: a 4 mm duct with
0.4 mm paper per face, at the 0.81 mm fallback radius, gives **2.12×** over laminar.

`DielectricStress.CornerRadius(thickness:width:)` reads the radius off **Essex *Magnet Wire / Winding Wire Engineering Data* p. 54**
("RECTANGULAR, BARE WIRE — DIMENSIONAL LIMITS"), which cites **ASTM B 48**, so it is the industry limit rather than one shop's
practice. The PDF is `~/Documents/MyProjects/Claude/EssexCornerRadius.pdf`. It takes the **bare strand's own two dimensions**
(`TurnData.strandRadial`/`strandAxial`) — not the turn, not the cable: a CTC presents each strand's corner to the gap. `StressSite`
and `StressCheck` both carry the radius that was used, and the report shows it as a tooltip on the two corner columns.

The table is genuinely two-dimensional and the spread is large — 0.81 mm for a 4 × 10 mm strand, 1.02 mm at 6 × 10 mm, 3.18 mm at
12 × 25 mm — a factor of four across sizes that all appear in ordinary disc coils, and the peak field goes as 1/√r. That is why one
constant would not do. Four things in the reading are easy to get wrong, and `VerifySelf` pins all of them:

- **Thickness is the smaller dimension**; the arguments are sorted, not trusted.
- Bands are **closed at the bottom, open at the top** ("Under 0.226 to 0.166 Incl." means 0.166 ≤ t < 0.226).
- **"Rounded Edge" is not a radius.** The page's own note — an edge with "corner radii that are essentially half the thickness of
  the wire" — is what those cells return.
- **The square-wire footnote overrides the table** and is applied first: square wire ≤ 0.072 in. (1.83 mm) gets 0.012 in. (0.30 mm).

The printed **mm** values are used for the radii (the page's inch and mm columns disagree slightly in two cells — 0.039 in. printed
as 1.02 mm, 0.031 in. as 0.81 mm) and exact **inch** conversions for the band boundaries. `defaultCornerRadiusOnCopper` (0.81 mm)
survives only as the fallback for a site with no strand data — a radial shield, a design file with no cable definition.

## A gap has two electrodes, and either may be the sharper one (2026-08-10)

`Evaluate` reads each stack from **both ends**: once from the near electrode at `StressSite.cornerRadius`, and once from the
**reversed** stack at `farCornerRadius`, mapping the result back. The worse of the two is the layer's peak, and `StressCheck`
carries whichever radius produced it, so the report's tooltip names the electrode the number belongs to.

For a plain disc-to-disc gap the stack is symmetric and **the far view adds nothing** — `VerifySelf` pins that, because any slip in
the reversal or the index mapping shows up as a changed answer on a case whose answer is already known. It earns its keep where the
gap is asymmetric, and the case it was built for is the static ring below.

`farCornerRadius` is **nil where the far electrode has no corner this model knows** — a tank wall, a core. Nil is not "smooth"; it
means not represented, which is the honest answer.

## Static rings are Weidmann EHV00112-2, and they are not smooth (2026-08-10)

The drawing is `~/Documents/MyProjects/Claude/EHV00112_REV_2-SHT_1(Static_Rings).pdf` ("NOTCHED STATIC RING"). It leaves the
dimensions to the engineer; the house values live as constants in `Segment.swift`, since no design file carries them:

| | | |
|---|---|---|
| **T** | 9.51 mm | pressboard core thickness, inside the foil |
| **T1** | 3.18 mm (1/8″) | Kraft paper covering, **per side** |
| **R1 = R2** | 1.6 mm (1/16″) | corner radius of the core, which the foil follows |
| **FT** | T + 2·T1 = 15.87 mm | finished thickness — 5/8″ to within 5 µm, which is what `stdStaticRingThickness` always was |

ID and OD match the adjacent disc (`Segment.StaticRing` copies its rect in x). **LR and LV are ignored** — the lead notch is a local
feature at one azimuth and this is a rotationally symmetric model.

Three consequences, and they are the reason the drawing matters at all:

- **The core is wrapped in aluminium foil, so the foil is the electrode.** The core's pressboard is inside it, at one potential
  throughout, and therefore never appears as a dielectric layer in any gap — only T1 of Kraft over it does. That is what
  `DiscToDiscLayerStack` builds, and now the reason is written down. `staticRingInsulationPerSide` was 3.0 mm and is now T1's
  3.18 mm; on STME-0999 with rings that moves the end sections' Cs by −1.4% and the coil's by −0.06%.
- **A ring has a corner.** The old code switched the corner model off at a static ring — "a smoothly wrapped surface, not a
  conductor corner". The drawing says otherwise: R1 = R2 = 1.6 mm, about twice a strand's, which is generous but finite. The gap is
  now read from both ends, and the ring's own Kraft turns out to be governed by the ring's corner and not by the disc's — on the
  reference stack in `VerifySelf`, by a factor of **five** over what the one-sided model saw. That layer was previously read at the
  far end of the gap, where its field is lowest.
- **The lead L bonds the ring to the outermost turn of the adjacent disc**, so the ring sits at that turn's potential: the voltage
  across a disc-to-ring gap is zero at the OD and the disc's whole span at the ID. One node step, worst at the ID.

**The disc-to-ring gaps used to produce no sites at all.** A ring above the topmost disc has no coil Segment beyond it, so
`AppendAxialSites`' "gap above" loop ran off the end of the coil — leaving the end of the winding, the very place a ring is fitted,
unchecked. A ring *between* two discs was worse: that loop measured disc to disc straight **through** the ring and handed the whole
span to `DiscToDiscLayerStack` as though it were oil. Both are now covered by explicit disc-to-ring sites at their real spacings,
and the lumped site is suppressed when a ring stands in the gap.

## A hilo is a stack of ducts, and lumping it is only legal for the capacitance (2026-08-09)

`PhaseModel.HiloLayerStack` returns the oil column **duct by duct** — `Npress` barriers of 0.080″ from the shop heuristic
`round(hilo/0.0084 − 0.5)`, with oil against *both* winding surfaces, so `Npress + 1` ducts share the remaining space. It used to
return one lumped board layer and one lumped oil layer, the way `CoilInnerShuntCapacitance` does. **That is exact for a capacitance
and wrong for a withstand**: a series reduction is Σ(ℓ/ε), which does not care how a material is subdivided, but
`StressAllowable.Strike` is a function of the layer's own thickness. On STME-0999 the 35.506 mm HV/LV hilo came back as a single
27.4 mm oil gap allowed 12.15 kV/mm where the five real 5.48 mm ducts earn 21.69, and **every coil-to-coil finding on that report
was manufactured by the lumping** — utilization 0.820 against a true 0.470, a factor of **1.75**. The 15.875 mm LV hilo is out by
1.29. Note the field barely moves (9.97 → 10.19 kV/mm, the innermost duct now sitting at a smaller radius); essentially the whole
error was the allowable. The **stick** column stays one solid `Pressboard(hilo)` layer deliberately — where a stick bridges the gap
the path is board the whole way across, barrier and stick alike, so its allowable belongs at the full thickness.
`AppendRadialSites` also now puts the **inner** coil's half-wrap on the front of the stack (and starts the stack half a wrap
further in, at that coil's copper), which `HiloLayerStack`'s doc comment had promised the caller would do and no caller did; it is
worth about 1%, and it is skipped when a radial shield stands in the gap.

## Two physics points that decide right from wrong answers

- **A continuous-disc gap sees twice the disc voltage and spans two node steps.** Disc A winds ID→OD, B winds OD→ID, joined at the
  OD; B's potential at radial position *x* is (2−x)V against A's xV, so ΔV is 2V(1−x) — zero at the crossover, **2V at the far
  end**, which alternates ID/OD gap by gap. Reading the adjacent diagonal of `MaximumInternodalVoltages` understates this by ~2×.
  The rule is applied only to plain continuous discs; interleaved and multi-disc Segments fall back to the single node step and the
  location string says so.
- **Max stress is not at max voltage.** Turn-to-turn peaks at t→0⁺ and ground stress peaks late, so every step is scanned and each
  site keeps its own worst instant. The t = 0+ capacitive distribution is prepended as an extra sample (from
  `FrequencyDomainSolver.CapacitiveDistribution`) because the uniform grid's first sample has already missed the steepest part.
  Because the field is linear in the driving voltage, the reduction runs once per site rather than once per site per step — exact,
  but it assumes time-invariant geometry.

## Turn-to-turn is screened by α and resolved by the ladder

`SteinParameters.gradientEnhancement` returns `1 + (α/tanh α − 1)·|Ya − Yb|`, an interpolation that is *exact* at both ends: an
interior disc whose neighbours ramp in step with it (Ya = Yb) is exactly linear — the case people get wrong by applying α/tanh α
everywhere — and a one-sided disc (Ya = 1) is exactly α/tanh α. `TurnLadderModel` then solves the real turn network for **one
disc**, with the neighbours as boundary potentials from the lumped model. It is one disc and not a group deliberately: with turns
as free nodes and no capacitance between two discs those discs disconnect, which is right for that network but at odds with the
lumped model's series-through-Cs picture, and fixing it needs the crossover conductor modelled. Continuous discs only — an
interleaved winding's position-to-turn map is scheme-dependent and guessing it would give a confidently wrong answer.

### The ladder's scope is now enforced, and sheet/layer windings have their own command

`TurnLadderModel.LadderError.notContinuousDisc` was declared from the start and **never thrown** — the menu let any Segment that
was not a static ring or a radial shield through the continuous-disc ladder. A sheet, layer, interleaved or wound-in-shield Segment
was therefore given a confident answer about a winding order the ladder does not model. `doShowTurnLadder` now refuses anything
that is not a plain single-disc `.disc` Segment, and `validateMenuItem` greys the command out for a sheet or layer winding.

Two things that fed it were also wrong, and both **understated** every number it produced:

- **The worst step was the model's, not the segment's.** It picked the step with the largest span over *all* nodes and read this
  segment's two nodes at that instant. That is when the winding set is most stressed, not when a given coil is — an LV coil takes
  its surge by transfer and peaks well after the impulsed winding's line end. `AppController.WorstInstant` now maximises
  `|V[above] − V[below]|` for the segment itself.
- **t = 0+ was not a candidate.** Turn-to-turn gradients peak there, and `DielectricStress.Scan` prepends
  `FrequencyDomainSolver.CapacitiveDistribution` for exactly that reason; the ladder scanned only the time grid, whose first sample
  has already missed the steepest part. `WorstInstant` now considers it too, and returns the whole node vector so that a
  neighbouring coil can be read at the *same* instant.

## Sheet and layer windings: the radial voltage profile

`DielectricStress.AppendTurnToTurnSites` takes `.disc` and skips everything else, so **a sheet or layer winding got no
turn-to-turn or layer-to-layer number anywhere in the report**. `RadialProfileWindow` is where they are looked at: one value per
radial gap, innermost first, with the paper-impulse allowable from the same `DielectricStress.Evaluate` the report uses, plus a
layer winding's worst turn-to-turn pair beside them (see below — the gaps are layer-to-layer and do not cover it).

**A sheet winding is a pure series chain, and this is a physical result, not a simplification.** Every turn is a full-height
cylinder, so each turn completely screens the next from everything outside the coil: no interior turn has a capacitance to
anything but its two radial neighbours, and the neighbouring coil and the core attach only to the two driven end turns, where they
cannot perturb the interior. Adding a radial shunt to the neighbouring coil — the obvious fix, and the one first proposed — changes
nothing at all for that reason. The entire non-uniformity is that the gap capacitance grows with radius: C ∝ r, so ΔV ∝ 1/r and
the innermost gap is worst by exactly the ratio of the radii, about 4% on the S0738 fixture. `CapacitanceTurnToTurn` returns one
value at the mean radius and so reports *none* of it; `Segment.SheetGapCapacitances` gives each gap its own.

**A layer winding is the opposite and has to be solved.** Its turns run axially within a layer and the layers stack radially, so a
turn's radial neighbour is a turn of a different layer, `turnsPerLayer` away electrically. `TurnLadderModel.SolveLayer` puts every
turn on the network — Ctt along each layer, Cll/slots between layers at the same axial slot, and Cin/Cout out of the innermost and
outermost layers to the neighbouring coils **at their own potentials** — and solves it by conjugate gradient. The ground path is
what makes the distribution non-uniform: without a path out of the winding the network has only its two terminals and the answer
collapses to the linear one. Layers alternate direction, so each starts where the previous ended and a short final layer sits at
the end it actually occupies.

**Cross-checked against α/tanh α on a real design.** On the `SheetAndLayer` fixture (938 turns over 12 layers, 125 kV on the
outermost lead), *before the ducts were placed*, the solve put **51.3 kV** on the outermost inter-layer gap where twice the volts
per layer is 20.9 kV — a 2.46× concentration at the line end — against **2.71×** for the classical screen, α = √(Cg/Cs) = 2.69 and
a line-end gradient of α/tanh α. Those are independent routes, a turn-level network against two lumped capacitances, and agreeing
to 9% is the best evidence available that the network is assembled correctly. That comparison is now historical: with the ducts
placed the solve reads 3.68× while the screen, which still reads a smeared Cs, stays at 2.71×. The window reports both side by side
with the basis of each, as the turn ladder's alert already does for a disc. Neither is asserted against the other: they are not
quite the same quantity (a continuum line-end gradient of a uniform winding, against the worst discrete inter-layer gap), so a
tolerance would be fitted rather than tested.

**A coil grounded at both ends still has voltage across its gaps**, and the profile says so. Its terminals are tied together, so
the reference is zero and the enhancement reads `n/a` rather than `1.00x`; but the winding beside it drives its layers
capacitively, and on the `SHEETLAYER-sheet` run the shorted layer coil carries 4.2 kV on its outermost gap. That is a real
stress on a coil a designer would not think to look at.

### Cooling ducts are placed, not smeared, and they dominate both winding types

`Segment.DuctGaps` spaces the ducts evenly over the radial gaps and centres the run — duct *j* of *n* at gap
`round((j − ½)·gaps/n)`, count clamped to the gap count by `DuctCount`, so 3 ducts in a 12-layer winding (11 gaps) land at gaps 2,
6 and 9, with insulation-only gaps at both ends. The half-step is what centres it: the obvious form, `round(j·gaps/n)`, spaces them
just as evenly but puts *j = n* exactly on the last gap, so the outermost gap would carry a duct in every winding ever built. The
design file gives a count and a size and no positions, so this is a rule rather than a reading.

**It matters more for a sheet winding than for a layer one, and that is not obvious.** `electricalRadialBuild` in
`PCH_ExcelDesignFile.Winding` is `(numTurnsRadially·turnRadialDimn + numRadialDucts·radialDuctDimension)·overbuild`, so a sheet
coil's ducts are *already inside* the radial build. `SheetGapCapacitances` originally took what was left after the copper and
divided it by the gap count — which silently spread every millimetre of oil duct across every gap as paper. On the `SheetAndLayer`
fixture that is 3 × 6.35 mm of duct smeared over 12 gaps: 1.77 mm of "paper" in a gap really holding 0.254 mm, and all twelve
gaps identical when three of them are oil ducts. The ducts are now placed, and the insulation is read rather than derived.

**The plain gap is a design dimension and is read as one.** `PCH_ExcelDesignFile.Winding.interLayerInsulation` carries it for a
sheet winding as well as for a layer one — a foil turn *is* a layer — and the layer path has always used it. The sheet path used to
back it out of the radial build instead, and that measures something else: `electricalRadialBuild` is
`(numTurnsRadially·turnRadialDimn + numRadialDucts·radialDuctDimension)·overbuild`, with **no insulation term at all**, so
`(build − copper − ducts)/gaps` returns the overbuild allowance spread over the gaps. On the fixture that is 0.178 mm — 6% of
35.6 mm over 12 gaps — against the 0.254 mm the file actually specifies. The two landing within 40% of each other is a property of
that one overbuild allowance and not a reason to trust the derivation. The leftover survives only as a fallback for a file that
leaves the field at zero, since a zero gap is an infinite capacitance; the window's `Insulation:` row says which is in force.

One consequence worth knowing: with real dimensions the stack (copper + insulation + ducts) need not add up to the radial build,
because the build carries a percentage allowance rather than a dimensioned insulation. It is 0.9 mm over on the fixture. Only the
gap radii are affected, and C goes as r, so that is 0.3% on the outermost gap.

**A sheet coil's series capacitance is now the exact chain.** The screening argument above says the coil *is* N − 1 capacitors in
series between its terminals, so its terminal-to-terminal series capacitance is `1/Σ(1/C_k)` over `SheetGapCapacitances` — no
representative τ, ducts at the gaps they are in, the 1/r growth carried gap by gap. `BasicSectionSeriesCapacitance` used to return
DelVecchio's disc formula `Ctt(N−1)/N²` with a `Ctt` built on `τ = (width − N·t)/(N−1)`: the whole leftover build, **ducts
included**, 1.77 mm of notional paper on the fixture. On `SheetAndLayer` the coil goes from **0.923 nF to 0.695 nF**, ×0.753.

Note which error was which, because the obvious repair was the wrong one. The smeared τ was wrong twice in opposite directions —
far too much paper, but that paper standing in for the ducts — and the two mostly cancelled, leaving Cs about 1.33× the exact value.
Substituting the real 0.254 mm into the disc formula would have dropped the ducts altogether and taken Cs to about **9×** it; the
self-check below measures 10.3× between the ducted coil and the same coil with the ducts removed, which is that error's size. The
disc formula was never derived for this winding anyway: it is an energy argument for N turns in a plane each at V/N, and even with a
correct τ it differs from a series chain by 17% at N = 13. `CapacitanceTurnToTurn`'s `.sheet` branch now reads the design file's τ
too and means what its name says — one plain gap at the mean radius — but it is no longer the route to Cs, and must not be made one.

**`Segment.VerifySheetCapacitance` pins all three of these** and runs under `-PCH_Verify YES` beside the other two self-checks
(`defaults read com.huberistech.ImpulseDistribution SheetCapacitanceVerification`). The middle check is the one worth knowing about: Cs and
`TurnLadderModel.SolveSheet` are independent routes over the same gaps, and both are statements about one charge on one chain, so
`Q = Cs·V` must equal `C_k·ΔV_k` at *every* gap. Putting the disc formula back breaks it immediately.

The effect is large, because an oil duct is not a perturbation on a foil gap — it is some **fifty times** the reduced thickness of
the turn insulation beside it, and takes about fifty times the volts. The sheet coil's worst gap goes from 4.1 kV at the innermost
gap (1.09× an even division, the pure 1/r story) to **15.2 kV at gap 2** (4.05×), and the profile stops being a gentle slope and
becomes a floor with a spike on every ducted gap. Both shapes are real; the note under the graph says which one is on screen. (The
15.2 kV was read with the derived τ of 0.178 mm; reading the design file's 0.254 mm brings it to **14.9 kV (3.97×)** and lifts the
plain gaps from about 250 V to about 340 V, still a floor.)

**WHERE the ducts are matters as much as whether they are placed**, on a layer winding, and this is worth understanding before
trusting a number off that graph. A duct's low capacitance and the line-end concentration are independent effects, so what the
worst gap comes out at depends on whether the two coincide. On the `SheetAndLayer` layer coil, the same coil at the same instant
reads **76.8 kV (3.68×)** with the ducts at 4/7/11, where the outermost gap carries one, and **35.2 kV (1.69×)** centred at 2/6/9,
where the line-end gap is plain insulation and the ducts sit down in the low-voltage part of the winding. A sheet winding is not
sensitive this way — its chain is uniform apart from 1/r, so a duct carries much the same wherever it is put. `TODO.md` §8a.

### The equal-spacing convention is drawn beside the model, never instead of it (2026-09-21)

Some clients specify a sheet winding's turn-to-turn voltages as though every turn were separated by the same dimension:
`s = ((OD − ID)/2 − N·t)/(N − 1)`, the build less the copper divided over the gaps, ducts and all. That is exactly the smearing the
section above removed from the model, so it is carried as a **comparison only**. `Segment.SheetGapCapacitancesEqualSpacing` forms
the gaps at that one spacing (each at its own radius, so the curve differs from the model's only in how the ducts are treated),
`BuildRadialProfile` runs them through the same `SolveSheet` with the same coil voltage at the same instant, and the radial profile
window draws the result as a thin **blue** curve beside the red one, with its own rows in the annotation. It never feeds Cs, the
simulation or the stress report; do not let it.

Its worst ΔV is evaluated across the **real plain-gap paper** (τ from the design file), not across s: s has oil smeared into it and
is no material that could be judged, and "is the turn paper good for this voltage" is the question the convention is asked. On the
`SheetAndLayer` fixture it gives 1.765 mm per gap and **4.10 kV at gap 1 (21.5% of the paper's allowable)**, against the model's
**383 V (2.0%)** on the worst plain gap and **14.9 kV** on the worst duct. So the convention is conservative for the turn paper by
roughly a factor of ten and understates the voltage across a duct by nearly four — which the duct's own allowable absorbs here, but
that is a fact about this design, not a property of the convention.

### The worst gap has two answers on a ducted coil, and the turn-to-turn pair is a third site

Rank the gaps by **volts** and the answer is a ducted gap in every ducted winding, for the reason above: the duct is some fifty
times the reduced thickness of the paper beside it, so it takes some fifty times the volts and it is the spike on the graph. Rank
them by **utilization** and the answer is usually a gap with no duct in it, because the duct is *allowed* most of what it takes.
Reporting only one of the two invites the reader to check the graph, find a bigger number on it than the annotation quotes, and
distrust both. `RadialProfileWindow` therefore reports the worst of **each kind**, each against its own allowable, and marks the
one that governs; the graph's own marker stays on the governing gap, which is what `StressProfileView.Plot.worst` picks. Where the
coil has no duct there is one kind and one block, exactly as before. The self-test line prints both as well — it used to print the
largest ΔV under the *governing* gap's index, which read as one gap with two numbers on it.

**Turn-to-turn in a layer winding is a different site again, and it is now reported.** The gaps are layer-to-layer, across the
interlayer insulation and any duct; turn-to-turn is across one turn's own paper, between two turns that are axially adjacent within
a layer. Neither implies the other — the volts are smaller by roughly the turns per layer and so is the insulation — so which is
nearer its limit is a fact about the design. `SolveLayer` already has the answer in the network it solved (these are the pairs the
`Ctt` edges were built on) and returns the worst of them with its layer and height; `BuildRadialProfile` evaluates it **exactly as
`AppendTurnToTurnSites` evaluates a disc's**: laminar rather than coaxial, two half-wraps of τ/2 rather than one span of τ, and the
same conductor corner at both ends. The half-wrap split is not cosmetic — the allowable is taken at the governing layer's *own*
thickness and thinner paper is allowed a higher field, so the two forms give different utilizations for the same volts, and a disc
and a layer coil in one report must not disagree about what a turn's paper withstands.

It is read at the **same single instant as the gaps**, which is the one where that coil's terminals are furthest apart (`t = 0+` is
among the candidates `WorstInstant` weighs). That is the right instant for the gaps — they are one network driven by one coil
voltage and they peak together — but it need not be the instant of the steepest turn-to-turn gradient, which in a real winding
lives at the wavefront. Where a later instant wins on terminal volts, treat the turn-to-turn figure as a reading at the stated
instant rather than as an envelope over the run.

**The remaining assumption the design file cannot support** is per-layer turn counts: `Winding` carries a layer *count* and nothing
per layer, so `Segment.LayerTurnCounts` splits the turns equally — *N/L* per layer, **fractions and all**. 938 turns over 12 layers
is twelve layers of 78.1666…, not eleven of 79 and a last one of 69: the winding is wound to one pitch over one height, so every
layer holds the same amount and the conductor crosses over part way through a turn wherever the count runs out. `SolveLayer` turns
that back into whole turns by giving each turn to the layer holding its **midpoint**, so a layer carries 78 or 79 whole turns and
the pattern steps up the winding — the real geometry, and exactly the old rectangular map when *N/L* is whole. A deliberately
graded winding, where the counts are chosen rather than falling out of the height, still needs a new field in
`BasicSectionWindingData.LayerData`.

**`LayerToLayerCapacitance` still smears**, deliberately — see `TODO.md` §8c. It feeds `SeriesCapacitance`, so changing it moves
every existing layer-winding result, and there is no obviously right single Cll for a coil whose gaps genuinely differ. The α screen
reads Cs through it, so on a ducted coil the screen and the profile now describe slightly different windings and no longer have to
agree closely; both the window and the report say so.

**The y axis may drop the allowable.** Turn-to-turn in a sheet or layer winding runs at a per cent or two of what the paper
withstands, and scaling to the allowable flattens the profile onto the x axis. `StressProfileView.Plot.allowableMayGoOffScale` is
set only by this window — the two stress-profile windows exist to show how much room is left, and a comfortable coil that reads as
comfortable is the right picture there.

**Verification is by hand**, as everywhere else here. `DielectricStress.VerifySelf()` and `TurnLadderModel.VerifySelf()` write to
`UserDefaults` (the app is sandboxed, so `print` and `/tmp` are dead ends); each doc comment gives the `defaults read` line. Both
pass as of 2026-08-13, `TurnLadderModel.VerifySelf()` now covering the two radial solves as well: the sheet chain's gap voltages
sum to the terminal voltage and stand in inverse proportion to the gap capacitances, and the layer network holds a constant
potential (the Laplacian null space, which catches any diagonal that is not the exact sum of its incident capacitances) and is
symmetric under conductor reversal (which catches a turn-to-slot map anchored at the wrong end). Both `VerifySelf()`s now run from
a launch argument rather than an edit to `AppDelegate`: `open -a ImpulseDistribution --args -PCH_Verify YES`. The ladder asserts its **convergence rate** rather than a bare threshold — the scheme is first order, since
the shunt lands only on interior turns, so doubling N must halve the departure from `sinh(αx)/sinh(α)`; measured ratio 2.0029. That
distinction matters: a discretisation error shrinks with N, an assembly error does not.
