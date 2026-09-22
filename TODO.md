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
- **Multi-start (DV 12.12)** — unimplemented. A `.multistart` BasicSection type exists and is produced by
  `AppController` from the design file, but `CapacitanceTurnToTurn` throws `.UnimplementedWdgType` for it.
  **Settled 2026-09-22: it stays one lumped section** (`docs/decisions.md` §2c), so 12.12 is the whole of
  what is left. The loop count it needs is already known: it is the `numLoops` of a regulating-winding
  declaration (`RegulatingWinding.swift`), and the design file's own `turnDefinition.multistartLoops`
  is what the declaration dialog opens on.

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

## Notes

- There is no test target, so numerical changes are verified by hand against the books' worked examples.
  `docs/capacitance.md` records the one for `DiscToDiscSeriesCapacitance`.
- The frequency-domain solver's validation table (`docs/solver.md`) uses a synthetic ladder and is
  unaffected by capacitance-model changes — but exported `.cir` netlists will change whenever these do.
