# The capacitance matrix

Read this before touching `Segment.SeriesCapacitance`, `PhaseModel.CalculateCapacitanceMatrix`, or anything to do with
wound-in shields, interleaving, τ_p or the shunt terms.

The capacitance matrix is built by `Segment.SeriesCapacitance` (the series capacitance of each segment) and
`PhaseModel.CalculateCapacitanceMatrix` (shunt capacitances + assembly). The authorities are **DelVecchio, *Transformer Design
Principles*, chapter 12** for everything series/disc-related, and **Kulkarni & Khaparde, *Transformer Engineering*, chapter 7**
for the coil-to-tank and phase-to-phase terms. Both PDFs live in `~/Documents/MyProjects/Claude/`. A full conformance audit was
done 2026-08-02/03; see `TODO.md` for what is still known to deviate.

| quantity | equation | where |
|---|---|---|
| C_tt turn-turn | DV 12.47 | `Segment.CapacitanceTurnToTurn` |
| C_s = C_tt(N−1)/N² | DV 12.49 | `Segment.BasicSectionSeriesCapacitance` |
| C_dd disc-disc, f_ks | DV 12.52, 12.50 | `Segment.DiscToDiscSeriesCapacitance` |
| general / Stein / static ring / end disc | DV 12.53-54, 12.35, 12.62, 12.63-64 | `Segment.SeriesCapacitance`, `.disc` branch |
| helical (C_s = 0) | DV 12.41, generalized to unequal gaps | same, `.helical` branch |
| wound-in shields | DV 12.96-99 | `Segment.WoundInShieldSeriesCapacitance`, `.WoundInShieldPairCapacitance` |
| shield wire paper | τ_w = τ_p (see below) | `Segment.WoundInShieldWire.Standard` |
| C_ll layer-layer | DV 12.60-61, transposed | `Segment.LayerToLayerCapacitance` |
| multi-start, whole winding | DV 12.12 (12.110-111), c_g/c_k split, exact between-group voltage | `Segment.MultiStartSeriesCapacitance`, `.MultiStartCapacitance` |
| coil-to-coil ground capacitance | DV 12.60-61 | `PhaseModel.CoilInnerShuntCapacitance` |
| coil-to-tank, phase-to-phase | K&K 7.15 (+ App. D.28/D.30) | `PhaseModel.OuterShuntCapacitance` |

## The τ_p convention is the landmine in this code

DelVecchio's τ_p is the **two-sided** paper thickness of a turn (his worked example: "The 2-sided paper thickness is 1 mm", then
τ_p = 0.001), and the Excel design file's insulation fields are two-sided totals as well. Three places depend on that silently:
`tp` in `DiscToDiscSeriesCapacitance`, `tau` in `CapacitanceTurnToTurn`, and the `height - tp` that turns disc height into bare
copper height in the same function. C_tt goes as 1/τ_p, so a stray factor of 2 moves **every** disc capacitance in the model by
2×. Both sites carried a commented-out `2.0 *` for years; do not put it back. Two exceptions, each deliberate and noted at its
declaration: `Segment.staticRingInsulationPerSide` is a **per-side** figure (3.18 mm, the T1 of the static-ring drawing — see `docs/dielectric-stress.md`), and `woundInShieldMinInsulationPerSide`
likewise (0.006") — everything downstream of it doubles it. `WoundInShieldWire.insulation` is two-sided like the rest.

Note the interaction with `CapacitanceTurnToTurn(effectiveInsulation:)`: that parameter overrides the **gap** (τ_avg = ½(τ_p + τ_w),
for a coil turn facing a shield turn) but `h` keeps using the coil turn's own τ_p, because h is the coil turn's bare copper height
and does not change because a shield sits beside it. With the default `nil` the two are the same number and the behaviour is
byte-identical to before.

## `OuterShuntCapacitance` is two terms, and on a tight design the one nobody expects is the larger

It returns the tank and phase-to-phase capacitances **split**, because they are routinely mistaken for each other: on the
STME-0999 fixture *each* neighbouring phase contributes 1.759e-10 against the tank's 1.085e-10, so at the default two neighbours
the phase-to-phase term is **76%** of the total. 760 mm leg centres against a 693.9 mm outermost OD leave 66 mm between phases,
and `acosh` is steep near 1 — `acosh(1.0953) = 0.433` against `acosh(1.936) = 1.279`. A hand calculation of coil-to-tank checked
against the sum looks wrong by 4× when nothing is. The caller adds them straight back together and books both to ground, which
assumes **the adjacent phases are at ground potential** — true in an impulse test, where the untested phases are grounded, but an
assumption and not a geometric fact.

**`PhaseModel.adjacentPhaseCount` is 2, i.e. the CENTRE leg, on purpose.** That is the highest C_g the geometry can give, so the
highest α = √(C_g/C_s), so the steepest initial distribution. `AppController.recalculateModel` sets it from the design file: 2 for
a polyphase unit, **0 for a single-phase one**, which has no neighbour and used to be charged for one anyway.

Two things not to overclaim about that "worst case", both measured on the fixture when the default changed from 1 neighbour to 2:

- **It is worst for the dielectric numbers, not for everything.** The line-end gradient went 29.05 → 30.31 × average and the worst
  section voltage 63.0 → 65.4 kV, which is the point. But the mid-winding envelope went *down*, 1.247 → 1.236 p.u.: more shunt C
  diverts more of the surge to ground, and the classical "envelope grows with α" is a result for a lossless uniform line, not for
  this network. The move is under 1% either way, so the honest summary is **conservative for turn-to-turn stress, neutral for the
  envelope**.
- **The tank term does not distinguish the legs at all.** It uses `tankDepth/2`, the distance to the **front and back** walls,
  which is the same for every leg; the tank's **end** walls, which only an outer leg is near, are not modelled. So an outer leg is
  missing a term the centre leg genuinely does not have. It is much smaller than a whole phase-to-phase gap, so the centre leg is
  still worst — by less than the arithmetic suggests.

## Wound-in shields vs. interleaving

**A shield turn is papered like the coil turn it sits against** — `WoundInShieldWire.Standard` takes the largest of the coil
turn's own covering, what the working stress needs, and the shop minimum, then rounds up to a whole wrap. This is not cosmetic:
**c_w/c_t is exactly τ_p/½(τ_p + τ_w)**, so τ_w = τ_p gives c_w = c_t and a shield-to-turn interface identical to a turn-to-turn
one, while a thin-papered shield sits *closer* to the coil copper than another coil turn would and drives c_w/c_t towards 2.

That single ratio decides whether shields or interleaving win, because at n ≈ N/2 the two methods are within 7% on interface
count alone — interleaving's `c_t(N−1)/2` against a shield's `n·c_w·[4β²+1−1/N+1/2N²]`, i.e. 4.875 against 4.557 at N = 10.75,
n = 5. Until 2026-08-06 `Standard` clamped τ_w to `woundInShieldMinInsulationPerSide` (0.006″/side) whenever the coil's own paper
already satisfied the stress check, which on a CTC coil with τ_p = 1.638 mm gave τ_w = 0.305 mm, c_w/c_t = 1.55, and a 5-turn
shield *beating a fully interleaved winding*. Interleaving is the higher-capacitance method; the model now says so. The minimum
is still there as a floor and now only bites on a coil whose own covering is under 0.012″ two-sided.

The fix costs radial build, which is the honest trade: the shield wire goes from 2.083 mm over-paper to 3.454 mm, so five turns
take 17.272 mm instead of 10.414 mm.

The implementation of 12.96-99 itself was checked against the printed page during this and is **exact**: 12.84-12.91 give four
voltage differences per shield turn — (V−V_bias), (V−V_bias−ΔV), V_bias, (V_bias−ΔV) — whose squares sum to precisely the code's
`4β²+1−2δ+2δ²`. Note 12.90's "This does not depend on i": the shield crosses over at the *outermost* turn while the coil crosses
at the innermost, so the shield ramps opposite to the coil and every shield turn holds ~V/2 whatever its radial position. That is
structurally the same trick as interleaving, which is why the two land so close at n ≈ N/2 and why c_w/c_t is decisive. Table 12.1
is measured on two disks of **10 turns/disk at n = 0, 3, 5, 7, 9**, so n/N up to 0.9 is inside his validated range, not an
extrapolation.

**The interleaved branch takes the interturn capacitance alone — no Stein, no disc-disc term.** K&K 7.3.5: "it is sufficient to
consider only the interturn capacitances for the calculation of the series capacitance of interleaved windings." It used to fall
through to the Stein branch, which was wrong twice: Stein assumes one radial traverse where a two-disc unit makes two (the same
objection that earned the shielded pair its own route), and the disc-disc energy it added was 24% of the interleaved total. The
turn term itself is now **K&K 7.39 exact**, `(C_T/4)[N + ((N−1)/N)²(N−2)]`, rather than his 7.40 `N ≫ 1` form — which is what
Veverka 6.4 is, and which runs 4.9% high at N = 19.7 and 8.6% high at N = 10.75, worst exactly where CTC coils live.

Because `Cs` is now the whole answer for an interleaved unit, `endDisc` and `adjStaticRing` no longer do anything on that path:
both exist only to modify the disc-disc term. An interleaved unit at a coil end is no longer reduced, which is right — there is
nothing left for the end condition to act on.

**Both two-disc units get their disc-disc energy from `Segment.TwoDiscPairCapacitance`** — the interleaved pair and the
wound-in-shield pair alike, using DelVecchio's linear-voltage `Cs + Cdd_int/3 + (Cdd_below + Cdd_above)/6`. They are structurally
the same object (two discs wound as one thing, one internal gap, one external gap per face), and letting them get that term from
different places is how a comparison between the two methods ends up measuring the bookkeeping rather than the physics — which is
what happened when the interleaved path followed K&K 7.3.5 and dropped it: the resulting 17% gap on STME-0999_2 was *entirely* the
asymmetry, since the turn terms there are a dead heat. The shielded pair passes an `internalCddScale` below 1; an interleaved pair
passes 1, because every turn in its discs is a coil turn.

## Other structural facts worth knowing before editing

- **`DiscToDiscSeriesCapacitance` gaps are measured between *insulated* surfaces.** A disc's `z1`/`z2` are over-paper and a static ring's rect is its overall wrapped thickness (`stdStaticRingThickness`, 5/8"), so the gap handed in is pure key-spacer/oil and every solid layer is added separately. That is exactly why 12.52 uses τ_p and not 2τ_p for a disc-disc gap: each disc contributes half of its two-sided paper. It takes `innerRadius`/`outerRadius` as **explicit parameters** rather than reading them off the `BasicSection`, because a BasicSection carries the pristine design-file radii while the live geometry lives on the Segment — pass `self.r1`/`self.r2`.
- **The multi-unit loop in `SeriesCapacitance` iterates *units*, not BasicSections.** A unit is one disc normally and a **double disc when interleaved or spanned by a wound-in shield**. The spans are *not* a fixed stride — `SeriesCapacitanceUnits()` builds an explicit `[(range, shieldTurns)]` list, because a shielded pair whose `n` is 0 is emitted as two single discs so it keeps the plain path's Stein/end-disc/static-ring treatment. Derive indices from the unit's own range, never by arithmetic on the loop counter; doing the latter made interleaved segments silently read the wrong sections, which was a real bug.
- **The temporary Segments built by that recursion need `SetRadialGeometry` handed down.** `Segment.init` takes its rect from the BasicSections, and those hold the **pristine** design-file radii — the live radii live on the Segment's `rect`. Skip this and a built-up coil is measured at the radius it had before the build-up.
- **Wound-in shields (DV 12.11).** `Segment.WoundInShield` carries a coil-level `WoundInShieldWire` (connection, bare radial, insulation) plus a **per-disc-pair** `turnsPerDisc: [Int]`, so a graded scheme is a data change rather than a code change. The pair — not the disc — is the unit, because a shield crosses over at the outermost turn of a pair. A shielded pair does **not** go through Stein: Stein assumes one radial traverse and a pair makes two, which over-counts the disc-disc energy 2× and drops the pair's internal gap. It uses DelVecchio's linear-voltage form, `Cs + (1/3)·Cdd_internal + (1/6)·(Cdd_below + Cdd_above)` — the per-gap split of his "(2/3)·c_d embedded". That assumption costs +2.96% at n=1 and 0.47% at n=3, but +117% at n=0, which is why n=0 is routed to the plain path. `Segment.VerifyWoundInShieldCapacitance()` re-measures all of this; the doc comment says how to run it.

  Because the pair is the unit, **a shield can only exist inside a Segment that holds an even number of discs** — `SeriesCapacitanceUnits()` emits units within one Segment, so a pair straddling two Segments is not representable. The load path gives every disc its own Segment, so `AppController.doAddWoundInShields` **rebuilds an odd selection into two-disc Segments** (flatten → pair → `updateModel(oldSegments:newSegments:)`), exactly as `doInterleaveSelection` does, and sets the shield on each new Segment *before* handing it to `updateModel` so the geometry and matrices are recomputed once rather than twice. A selection whose Segments are already all-even is left structurally alone. `validateMenuItem` therefore accepts **either** an even segment count (rebuild path) **or** all-even disc counts (no rebuild); testing only one of the two disabled the item on, respectively, every freshly loaded model and every already-combined Segment.
- **Only the two end units of a segment can be at a coil end or beside a static ring**, and only on their outward face. The recursion passes a non-nil tuple with the far side cleared, so both the `endDisc` and `adjStaticRing` tests need the `!= (false, false)` guard — a missing one on the static-ring side was a real bug.
- **`.sheet` correctly has no shunt term**; `.layer` genuinely needs one. A sheet winding is a single BasicSection spanning the full height, so its radial neighbours are *other coils* (a shunt path, handled in `PhaseModel`), whereas adjacent *layers* belong to the same winding at different potentials and are true series energy. Layer windings use the "Huber method" — DelVecchio's disc treatment turned on its side, with C_dd → C_ll — and are outside the book entirely.

## Multi-start windings (DV 12.12)

A multi-start winding is **one lumped BasicSection** (`docs/decisions.md` §2c) and its whole series capacitance is 12.12, from
`Segment.MultiStartSeriesCapacitance`. N_s is the design file's axial cables per turn, carried in `BasicSectionWindingData.multiStart`
with the insulation between starts and the key-spacer gap between revolutions. Three things differ from the printed 12.111,
`C_ms = c_t(4nN_s − 6n − 1)/N_s²`, and each is deliberate:

- **Two turn-to-turn capacitances, not one.** DelVecchio says c_t depends on whether turns touch paper to paper or face across an oil
  gap with key spacers; in a multi-start helix it is both, fixed by position. Conductors of one revolution touch: **c_g** is 12.47
  transposed (face = bare radial w, as the layer branch of `CapacitanceTurnToTurn` does), with τ = τ_p + the insulation between
  starts. One revolution faces the next across the spacers: **c_k** is 12.52, the treatment the helical branch already gives the gap
  between helical turns. Of the (2n − 1) pairs at ΔV_s, n are inside a revolution and n − 1 between; all n(N_s − 2) pairs at 2ΔV_s are
  inside. With c_g = c_k the sum is 12.110 term for term. A zero spacer is handled separately: `DiscToDiscSeriesCapacitance` reads a
  zero gap as *no neighbour* and returns 0.
- **The between-revolution voltage is exact.** Those pairs are n − 1 turns apart, (1 − 1/n)·ΔV_s; the book rounds to ΔV_s. Same choice
  as K&K 7.39 over 7.40 for interleaving, same reason: the rounding makes 12.111 up to 33% high at N_s = 2, n = 2, 1.5–4% at N_s = 4,
  under 1.5% at N_s = 8.
- **n = N/N_s, and a count that does not divide is refused.** The design file's turn definition divides the axial dimension of a
  revolution's N_s cables by N_s, i.e. it counts one conductor of one start as a turn, so its turns are every turn in series. If a
  design counted the other way n would be N_s times too small; refusing a non-integer n catches most such files.

`Segment.VerifyMultiStartCapacitance()` (under `-PCH_Verify YES`, key `MultiStartCapacitanceVerification`) walks N_s = 2…8 and
n = 1, 2, 5, 12 conductor by conductor in Figure 12.22's order at true potentials: it checks the pair counts, the closed form against
the walk (to 1e-12), and that the walk with the book's rounding and one c_t gives 12.111 exactly. End to end, SelfTest
**`T0223-multistart`** (T0223 with coil 3 made an 8-start, 48-turn multi-start) gives C_ms = 1.2213e-9 F, which a hand calculation
from the design data reproduces to six figures; c_k there is 8% of c_g, and 12.111 with c_t = c_g would be 3.1% higher. Not
reached yet: a multi-start winding of more than one radial layer (refused — 12.12 is a single helix) and any turn-to-turn stress
screen for this winding type (`TODO.md` §2).

## Verification is by hand

There is no test target, so two checks carry the weight. First, `DiscToDiscSeriesCapacitance` must reproduce DelVecchio's own
worked example (p.337: R_in 0.3, R_out 0.37, f_ks 0, τ_p 0.001, τ_ks 0.005 ⇒ C_dd = 5.0991e-10 F) — re-run it mentally after
touching that function. Second, **`Segment.VerifyWoundInShieldCapacitance()`** is a runnable self-check for the 12.11 path; its
doc comment gives the one-liner for `AppDelegate` and the `defaults read` that gets the report back out (the app is sandboxed, so
`print` and `/tmp` are both dead ends). It asserts three things, all passing as of 2026-08-03: 12.96 at n = 0 equals two plain
discs in series **exactly**; the pair capacitance is linear in n at fixed radius to 4.4e-16; and the linear-voltage assumption
costs +2.96% at n = 1, falling to +0.47% at n = 3.

**The 12.11 comparison against Table 12.1 was done separately** (his air constants, ε_p 1.5 / ε_ks 4.0, not the program's oil
values) and lands high by a flat 4.6–6.0% across all 13 entries and all three connections. That is DelVecchio's own
winding-looseness correction — p.357, "about a 5% correction" — and it must **not** be built into the code, since it is a property
of his loose two-disc test coil. The thing to check after editing is that the residual stays *flat*; a residual that varies with n
is a real error.
