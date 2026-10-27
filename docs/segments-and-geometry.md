# Segments: ordinals vs. coordinates, static rings, and live vs. pristine geometry

Read this before touching anything that indexes Segments, sizes an array by them, locates a static ring or a radial shield, or
changes radial geometry.

## `axialPos` is a coordinate, never an index

`Segment.axialPos` returns `basicSections[0].location.axial` — the *pristine design-file disc index* of the Segment's lowest
BasicSection — and is **never renumbered**. It equals the Segment's ordinal position within its coil only while every Segment holds
exactly one BasicSection, which the load path guarantees (`AppController:955` wraps each BasicSection in its own Segment) and which
a combine, an interleave, or a wound-in-shield pairing destroys: 8 discs interleaved into 4 Segments leaves the coordinates at
0/2/4/6. The **ordinal is a Segment's position in `PhaseModel.CoilSegments()`**, which is what `CreateFePhase` walks to build the
FE sections, what `SimulationModel` sizes `vDropInd` by, and what the capacitance assembly indexes. In the FE model that ordinal
is load-bearing three times over: it is the section's index in `FePhase.sections`, its *terminal number*, and its row and column
in the inductance matrix — all the same number by construction.

Deriving one from the other — `GetHighestSection(coil:) + …`, or `+ segment.axialPos` — was a real bug at **four** sites (fixed
2026-08-04/05): it crashed *Interleave* inside the FE model's per-section current assignment with "Index out of range", and when the
restructured coil was not the last one it instead wrote one coil's currents over the next coil's sections and returned a plausible,
wrong inductance matrix with no error at all. The fourth was `ShowWaveFormsDialog`, which was handed `GetHighestSection` values and
rebuilt the flat per-coil offsets itself; it now takes `coilRanges:[ClosedRange<Int>]` from `SegmentRange(coil:)`, which deletes
that arithmetic rather than repairing it.

**When something needs a range of `CoilSegments()` indices, get it from `SegmentRange(coil:)` — do not recompute it.**
`GetHighestSection` is still correct where it is **compared against another `axialPos`** (`TransformerView`'s end-disc tests,
`PhaseModel:1483/2189/2245`); it is never a count. `CreateFePhase` asserts the `(radialPos, axialPos)` sort that the ordinal
depends on, and `recalculateModel` guards `fePhase.sections.count == coilSegments.count`.

## The other half of the same rule: `CoilSegments()` is not `segments`

`PhaseModel.segments` is the whole store, *including* static rings and radial shields; `CoilSegments()` drops them
(`radialPos < 0 || axialPos < 0`). The two are the same array only in a model that has no shielding element in it, which is every
model until the user fits one — so an index or a count taken from one and used against the other is a bug that lies dormant until
the first static ring. **Anything sized by, or indexed against, the FE sections or the inductance matrix must come from
`CoilSegments()`.**

Three sites had it backwards (fixed 2026-08-08): `recalculateModel`'s eddy-loss transfer walked `model.segments` while
subscripting `fePhase.window.sections`, which is one entry per `CoilSegments()` entry — that is the reported **"Index out of range"
when calculating inductances**, raised by the first recalculation after a static ring was added; `PhaseModel.AxiallyAdjacentSegments`
subscripted `segments` with a `SegmentIndex` ordinal (and ran off the top of a coil into the next one); and `GetBmatrix` sized its
rows from `segments.count`. Note the eddy loop's *quiet* failure mode, which is the worse one: a static ring sorts to the **front**
of its coil's block, because its axial coordinate is negative, so before the loop overran it was writing each coil Segment's eddy
losses onto its neighbour.

**The rule cuts the other way when the thing asked about *is* a shield.** `EffectiveHeight(coil:)` was moved onto `CoilSegments()` in
2024 so that a static ring (which shares its coil's `radialPos`) would not stretch the coil's height. But
`CalculateCapacitanceMatrix` also calls it with a **radial shield's** own negative `radialPos` (via `RadialShieldOutside` →
`CoilInnerShuntCapacitance` → `CapacitiveHeightInner`), and `CoilSegments()` has no shields in it, so the filter came back empty and
`coilSections[0]` trapped. That was every simulation run with a radial shield fitted, for two years (fixed 2026-10-26; reproduced
by `S0747-shield`). It now filters the whole store and drops static rings only.

## Static rings are located by GEOMETRY, not by their coordinates

(Redesigned 2026-08-08.) `PhaseModel.StaticRingAbove(segment:)` / `StaticRingBelow(segment:)` return the nearest static ring in the
same coil on the side asked for, provided no coil Segment stands between the two — see `NearestStaticRing`. A ring's own axial
coordinate is now only an *identity*: negative, so the rest of the program can tell it from a disc, and unique within the coil, so
`InsertSegment` accepts it. It is handed out by `NextStaticRingAxialPosition` and means nothing else.

It used to be `-adjacentSegment.axialPos`, and adjacency was recovered by inverting that arithmetic, which failed three ways: a
restructure renumbers nothing (see above), so interleaving a coil **orphaned** every ring already on it — the ring kept its space
and kept being drawn while the discs either side measured their gaps straight through it; "above Segment k" and "below Segment k+1"
are the *same ring* but were recovered by different routes, so an interior ring was visible from one side only; and the encoding
could not represent a ring on each side of one Segment at all. The payoff beyond correctness is that a rebuild cannot lose a ring,
which is why *Combine* no longer tears its end rings down and builds replacements (that path also silently reset a custom gap or
thickness to the default).

**"Nothing stands between" is not enough across a tapping gap** (fixed 2026-10-27). With a ring fitted on the lower middle disc of
S0747's RV, the nearest thing below the upper middle disc, 389 mm away across the 406 mm centre gap, was that ring. So the second
ring of the pair was refused with `.ShieldingElementExists`, and before it was fitted the upper disc's series C was built as though
it faced a ring. `NearestStaticRing` now keeps a ring only if it is no farther from the Segment's face than from the coil Segment on
the ring's own far side, to within `staticRingSharingTolerance` (1 mm). A ring that fills a gap is as near to both sides and is
still both Segments' ring.

## `SegmentAt(location:)` searches the whole store, and must

Restricting it to `CoilSegments()` — which is exactly the filter that removes shielding elements — did not hide them from *some*
callers, it made **every** shielding-element lookup in the model return nil unconditionally: `StaticRingAbove`/`StaticRingBelow`,
`RadialShieldInside`/`RadialShieldOutside`, the "there is already one there" guards in `AddStaticRing`/`AddRadialShieldInside`, and
the shield branches of `HiloUnder` and `CoilInnerShuntCapacitance`. No static ring in a model had reached the capacitance
calculation since. Nothing is lost by searching the whole store: a coil Segment's coordinates are both >= 0, so an ordinary
`(coil, disc)` lookup cannot match a shielding element anyway.

Two more that only a restructured coil reaches: `StandardAxialGap(coil:)` asked for the Segment at **axial 1**, which does not
exist once a coil has been interleaved or combined (the coordinates run 0/2/4/…), and reported it as "the coil does not exist" —
straight out of *Add Static Ring*, which calls it for its default gap. It now takes the gap between the two lowest **discs**,
looking inside the bottom Segment's `basicSections` when it holds more than one. And `AddStaticRing` refuses up front a ring that
would leave a Segment with one on **both** sides, rather than letting `CalculateCapacitanceMatrix` throw
`.OnlyOneStaticRingAllowed` at the next recalculation — that configuration is unsupported physics (DV 12.78-81, TODO.md §1), and
finding out afterwards left the user with a ring in the model, no undo, and nothing that would compute until it came out again.

## Segment serial numbers

Segments are `Equatable`/hashed **by serial number** — be very careful when assigning serial numbers, and note that **every Segment
now gets a real one**: shielding elements used to share a dummy `-1`, which made all of them equal to each other, so
`segmentStore.firstIndex(of: aStaticRing)` found whichever came first and *Remove Static Ring* on the second one removed the first
(or a radial shield).

## Live vs. pristine radial geometry

A `BasicSection`'s rect holds the **pristine** radii read from the design file and is never rewritten; the **live** geometry is the
owning `Segment`'s `rect`. `PhaseModel.ApplyRadialBuildUp()` recomputes every Segment's rect from pristine + the current
wound-in-shield set, widening each shielded coil by its widest disc's requirement, pushing everything outside it straight out
(preserving the hilos, which are withstand-driven minimums), and growing `core.legCenters` and `tankDepth` by twice the total.
Because it works from pristine absolutes it is idempotent and exactly reversible, so `AppController.recalculateModel` just calls it
unconditionally — which also repairs the geometry after a combine/split/interleave. `basicSections` stays a `let` deliberately:
`validateMenuItem` reads it synchronously from the main actor and cannot `await`.

`PhaseModel` also holds `voltsPerTurn`, set by `AppController.recalculateModel` from the design file. It is the one place the model
knows an *actual* operating voltage rather than a per-unit one; only the wound-in-shield paper sizing uses it so far.

## Shields and static rings from the design file (file versions 5 and 6)

`PchBasePackage` reads design file versions 4 to 6 (`../Claude/DesignSheet/PCH_ExcelDesignFile_v5_v6_changes.txt`). A version 6
file gives each disc coil's **intershields**: turns per disc, the shield wire's bare radial dimension and its paper (two-sided,
this program's convention too), and how many discs are shielded at the top and at the bottom. A version 5 file gives each coil's
**static rings**: none, top only, or top and bottom. Opening a design puts both on the model, through the same paths the menu
commands use. The shielded discs are paired from each end of the coil inwards, as *Add Wound-In Shields* pairs a selection. The
connection is **floating**, because the file does not give one. The rings go on last, against the end Segments of the coil as it
stands after pairing.

**The geometry is the part to get right.** The design sheet counts the shields in the coil's `electricalRadialBuild`, in every
inner diameter outside it, in the leg centres and in the tank. This program adds the shields' build itself, in
`ApplyRadialBuildUp`. Read straight, a shielded design would therefore get its shields' width twice. The load takes it back out
first: `AppController.DesignFileIntershieldsByCoil` works out from the file alone which coils' shields can be modelled.
`createBasicSections` lays those coils out without the shields' build and moves every coil outside them in by the same amount.
`updateModel` does the same to the leg centres and the tank. `ApplyRadialBuildUp` then puts it all back once the shields are on,
so a design opens at the file's own radii, and *Remove Wound-In Shields* takes it to the coil without them. The amount taken out
is the shields' build **without** the sheet's overbuild allowance. That is what `radialBuildAdder` adds back, so the opened
geometry is exact; a coil with its shields removed keeps the allowance on their build, a few percent of it.

A coil whose shields cannot be modelled gets an alert and keeps the file's width. Odd shielded-disc counts and fractional turns
are caught before the layout, and the coil is laid out with the shields' build in it. A pair that would straddle a tapping gap,
or swallow a node with a connection on it, is caught only after the layout. That coil is then held at the file's width by
`radialBuildUpFloor`, which is the one use of the floor outside `SelfTest`. Either way the coil has the file's geometry and
plain discs.

The version 5 BILs set the default crest in the simulation dialog: `AppController.ImpulsedLeadBIL` takes the BIL at the lead
carrying the impulse termination. That is the top BIL for a coil's top lead, the bottom BIL for its bottom lead, and the middle
BIL for a centre lead of a dual-voltage coil, with the highest if several leads are impulsed. Without a BIL the dialog opens at
`SimDetailsDlog.fallbackCrestKV`, the 30 kV it always used. The top edge pack is read and not used; see `TODO.md`.
