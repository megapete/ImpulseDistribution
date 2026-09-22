# App / UI layer

Read this before touching `AppController`, `TransformerView` (including connector routing), the graph views, `AxisScale`,
`InitialDistributionWindow`, or the dialogs.

## `AppDelegate.swift`

Standard NSApplication delegate (entry point).

## `AppController.swift`

The main controller: menu/IBActions, User Defaults, and file loading. Input comes from Excel transformer **design files**
(`PchExcelDesignFilePackage`); `.cir` is **export only** (see `docs/solver.md`). Iteration constants like
`PCH_IMPULSEDISTRIBUTION_IterationCount = 200` live here. It also owns the two long-running calculations' UI:

- **`recalculateModel(reinitialize:includeInductance:)` is the recalculation pipeline**, split out of `updateModel`'s tail: radial build-up → FE phase → eddy losses → inductance → capacitance → `updateViews()`. Anything that changes the model *without* swapping Segments calls it directly, because `updateModel` cannot be reached with empty segment arrays (`PhaseModel.UpdateConnectors` throws on those). It always calls `ApplyRadialBuildUp()` first — cheap, idempotent, and it means no caller has to reason about when geometry went stale. `includeInductance: false` recomputes only the capacitance, which is what a geometry search wants: the inductance dominates the cost and barely moves when a coil widens by millimetres.
- The main window's two progress bars (`indCalcProgInd`, `simCalcProgInd`) are **determinate** and driven by the progress streams described in `docs/concurrency.md`. Set up at launch, reset in `didFinishInductanceCalculation()` / `didFinishSimulationRun()`. The bar's `toolTip` carries the detail text (which pass, which section) because `workingLabel` is *shared* by both calculations — don't write per-calculation text into it.
- **`PCH_ErrorAlert(message:info:)` is the only way the app tells the user a command refused to act**, and there are ~50 call sites: nearly every guard in a menu handler ends there. It used to be a `PchBasePackage` global that put a real alert up; when the package dropped it, a local stub that only called `DLog` replaced it — and `DLog` is `#if DEBUG`, so in Release every refusal became *completely* silent. The visible symptom was a menu command that could be picked and then did nothing (reported against **Interleave Section** on a double-stacked tap winding, where the tapping-gap guard was firing into a log nobody was reading). It now puts an `NSAlert` up, *except* when `SelfTest.isRunningHeadless` — a modal alert in a scripted run hangs it forever, which is the same reason the harness never calls `recalculateModel` (see `docs/self-test.md`). A guard that cannot say why it refused is worth no more than no guard at all; keep new ones reporting through this function.
- **The simulation model is a build product, not user-maintained state** (2026-08-12). There used to be a **Create Simulation Model** item next to **Simulate** in the Simulate menu — a development convenience, so the matrices could be dumped before committing to a run — and it made `currentSimModel` a thing the user created once and nothing ever invalidated: every edit made after the create (a jumper moved, a static ring added, a coil interleaved) left the model built on the old geometry, and running gave a confident answer for a design that was no longer on screen. The item is gone; the one item is **Simulate now**, and it rebuilds the model unconditionally before it runs. `currentSimModel` is `private(set)` and only `doCreateSimulationModel()` writes it, which is what makes that guarantee checkable. The two commands that need a *model* but not a *run* — the initial distribution and the debug solver comparison — call `doGetSimulationModel()`, which reuses an existing model rather than rebuilding, since rebuilding discards the current result. The rebuild is done **inside** the simulation task, after the details dialog is accepted, so cancelling the dialog costs nothing. `simCalcProgInd` stays **determinate** across it and sits at zero — the rebuild reports no progress of its own, and the bar says which step is running through its `toolTip`, as the solver's own passes do.
- **A model change invalidates the whole result chain, not just the matrices** (2026-08-12). The chain is: Segments → inductance + capacitance matrices → `SimulationModel` → the run → the stress screen. `inductanceIsValid`/`capacitanceIsValid` covered the first link only, so an edit left `currentSimModel`, `latestSimulationResult` and `latestStressChecks` in place — a stress report opened after adding a static ring screened the *previous* design and looked exactly as authoritative as a correct one. `recalculateModel` now opens with **`DiscardResultsForChangedModel()`**, which nils the sim model, the result, the undo slot and the `PhaseModel`'s `fixedC` (written only by `SimulationModel.init`, so unlike `C` nothing else replaces it — hence `PhaseModel.ClearFixedC()`), and closes the open result windows. It is called from the **gate** rather than from `PerformRecalculation` so that the results die when the design changes, not when the recalculation gets a turn. Only the matrices are recomputed for the user; the simulation is minutes long and needs a crest and a bandwidth from them, so the downstream commands simply go back to disabled — the answer is *absent* rather than stale.
- **`latestStressChecks` is invalidated by `latestSimulationResult`'s `didSet`**, not by its callers. `StressChecks()` returns the cache whenever it is non-empty, and before this only a `.dielectricDesignMargin` preference change ever emptied it — so a *second* simulation run put its own waveforms up while the stress report went on showing the first run's findings. Anything else derived from a result should hang off the same `didSet`.
- **Only the six held windows can be closed** (`coilResultsWindow`, `stressReportWindow`, `stressProfileWindow`, `axialStressProfileWindow`, `radialProfileWindow`, `initialDistributionWindow`). The waveform and max-voltage-difference windows are created and let go — AppKit keeps them alive until the user closes them — so `CloseResultWindows()` cannot reach them. They are graphs of a named run rather than a screen of the current design, so a stale one is at least self-describing; putting them in an array of `NSWindowController` is what it would take to close those too.
- **What a rebuild replaces is saved, not dropped**: `AppController.SimulationState` (sim model + the results computed on it + the `fixedC` that `SimulationModel.init` wrote into the `PhaseModel`) goes into `previousSimulationState` one deep. Nothing offers an Undo yet — `doRestorePreviousSimulationModel()` is written and unwired, and swaps rather than pops so the undo is itself undoable. The three pieces travel together on purpose: a result belongs to the network it was solved on, and displaying one beside another model is exactly the failure removing the create item was about. Making it a stack is changing that one property to an array; nothing else reads it.
- Both are cancellable via `runningInductanceTask` / `runningSimulationTask` and the **Cancel Inductance Calculation** (Inductance menu) and **Cancel Simulation** (Simulate menu, ⌘.) items, enabled by `validateMenuItem` only while the matching task is live. The inductance calculation is wrapped in its own `Task` inside `recalculateModel` purely to get a cancel handle — none of its callers retains a `Task`. A user cancellation is **not** an error: no alert, but `inductanceIsValid` is forced false (a previous successful run could otherwise leave it stale-true) and the view is still refreshed, since the segment edits that triggered the update have already been applied to the model.

## `TransformerView.swift`

The `NSView` that draws the winding cross-section (adapted from the author's earlier *AndersenFE_2020* project). All drawn
dimensions are multiplied by the file-scope `dimensionMultiplier` (`1000`) because `NSView` misbehaves with sub-1 (meter-scale)
coordinates. It also contains the **connector-routing subsystem**:

- `@MainActor struct SegmentPath` wraps a `Segment` for drawing; `SegmentPath.SetUpConnectors(...)` builds a `ViewConnector` (path + optional ground/impulse image) for each of a segment's `Connection`s. It classifies each connection (adjacent same-coil, non-adjacent same-coil, coil-to-coil, or termination) and routes accordingly: connectors avoid crossing coils by running in the radial gaps and crossing over/under the winding, choosing over-vs-under by shortest total travel (`ConnectorCrossover`); overlapping runs are spread into parallel **lanes** (`ViewConnector.assignLane` + `ConnectorChannel`); connectors attach to the tip of an existing `floating` lead rather than drawing a new stub.
- Routing **offsets are derived from the model geometry** by `UpdateConnectorMetrics()` (tightest hilo gap and winding height) so they scale with model size; lead-stub length instead tracks the **view scale** so it stays constant on screen.
- **Adding a connection is a click, move, click** (2026-08-12), not a drag: the first click on a lead's hit zone stores `addConnectionStartConnector`, the mouse then drags a rubber band behind it *with the button up* (`TrackAddConnection`, driven from `mouseMoved` — `mouseDragged` calls it too, so holding the button still draws, but the release does nothing), and the second click on another lead calls `CompleteAddConnection`, which is where the jumper cross-product described in `docs/connectors-and-nodes.md` is built. `addConnectionStartConnector` being non-nil *is* the "a gesture is running" flag, and it is what `mouseDownWithAddConnection` tests to know which of the two clicks it is holding. Two rules keep the state from outliving the gesture: `CompleteAddConnection` calls `EndAddConnection()` **before** launching its `Task` (the model work suspends on the Segment actors, and a click in that window would otherwise be read as a second second-click and add the jumper twice), and the `mode` setter throws a half-drawn connection away whenever the mode leaves `.addConnection` — which is how **Esc** cancels, and also covers a right-click or another mode picked from a menu, without any of those places knowing about it. A second click that lands on nothing (or back on the starting lead) deliberately keeps the gesture alive, so a mis-click costs nothing. Completing a connection ends the *gesture* but **not the mode** — like add-ground, add-impulse and remove-connector, add-connection stays armed for the next one until Esc, so a run of jumpers is not a trip back to the menu between each.
- **The mode's cursor is a cursor RECT, not an `NSCursor.set()`** (`modeCursor` + `resetCursorRects`, 2026-08-12). AppKit owns the pointer: a bare `.set()` is a one-shot that lasts only until the window next recalculates its cursor rectangles, and a redraw does exactly that. So adding a ground put the arrow back the instant the new connector was drawn — while the mode was *still* `.addGround`, since none of the `mouseDownWithAdd…` routines change it. The cursor was the only thing that had forgotten. The `.set()` calls in the `mode` setter and in `mouseEntered` are kept because they make the change immediate; the rect is what makes it stick, and it reads `modeStore`, so the mode must be assigned **before** `invalidateCursorRects(for:)` is called. All four editing modes now behave the same way — they stay armed, and their cursor stays up, until Esc drops out of them.
- **What can be clicked is `ViewConnector.hitZone`**, each leg of a connector's path inflated by `TransformerViewConstants.connectorHitTolerance` — and that is a **screen** dimension (4 view points at magnification 1), not a model one. It was 3 mm of winding until 2026-08-12, which is the wrong frame of reference for a pointing target: aiming happens in screen space, so a model-space zone grew when the user zoomed in and vanished when they zoomed out, which is when the help was wanted. The same rule already governed the lead stubs and the ground/impulse symbols, and `hitZone` now converts out of the scrollView exactly as they do. Two consequences: the constant is in points, so compare it against line widths rather than against `connectorStubOffset`; and because lanes are spaced by a *model* dimension while the zone is not, zoomed far out two lanes' zones can overlap, where the first match in `viewConnectors` wins rather than the nearest.
- **A run down a coil flank is pushed out past any radial lead stub it would cross** (`FlankRunX` inside `SetUpConnectors`, `RadialLeadClearance`, 2026-08-12). The stubs at `inside_center`/`outside_center` — a tapping gap, or the break in a double-stacked winding — poke straight out into the very gap the connectors are routed through, and used to be invisible to the routing: a later jumper between two other discs was drawn through them. They cannot be handled by `assignLane`, which only detects two runs *sharing* a channel: a stub is a **horizontal** run and the jumper a **vertical** one, and the conflict is a crossing, not an overlap. Three things are worth knowing before editing this. Only leads whose take-off lies **within the run's axial span** count, or a jumper nowhere near the gap would be shoved out by it. The reach includes the **symbol** on the lead's tip, so `groundSymbolScreenReach`/`impulseSymbolScreenReach` have to follow `GroundConnection`/`ImpulseConnection` if those are ever redrawn. And the clearance is recomputed on **every rebuild** rather than folded into `connectorStubOffset` once, because a lead is drawn at a constant length *on screen* while the routing is laid out in *model* metres — so whether a lead reaches the lane at all is a question about the current zoom, and the crossing only appears when zoomed out. The push is capped at `connectorMaxFlankFraction` of the radial gap: a grounded or impulsed radial lead can be longer than the gap it sits in, and clearing *that* would route the connector through the neighbouring coil, which is a worse drawing than a crossed lead.
- `RebuildConnectors()` re-runs the whole pass; it is triggered by `segments` changes **and on zoom** (menu/button handlers + a `didEndLiveMagnify` observer) and coalesces concurrent requests. Incremental add/remove-connector paths call `SetUpConnectors` directly on the affected segment(s).

## `AxisScale.swift`

Y-axis ticks and labels for the two result graphs. `AxisScale.Ticks(...)` returns the major ticks plus a highlighted tick at each
extreme the simulation reached; `AxisScale.DrawYAxis(...)` draws them and `AxisScale.YAxisWidth(ticks:)` reports how wide a left
margin they need. Major intervals are **25 kV up to a 250 kV crest and 100 kV above that** (`MajorVoltageInterval`), falling back to
a computed 1-2-5 interval when the fixed one does not divide the axis — a single coil of a 550 kV unit only reaches ~50 kV, which
would otherwise get no ticks at all. Extremes are rounded to the nearest kilovolt for a voltage and to two significant figures for
a current (0.1 kA in the kiloamp range, 1 kA in the ten-kiloamp range).

**Both graph views set their `bounds` to the data rectangle and let AppKit do the scaling**, which is why `DrawYAxis` takes a
`pointSize`: everything drawn at a fixed on-screen size has to be multiplied by the view's bounds-to-frame ratio. That only works
because the two views now build their bounds so the ratio is *the same in both directions* — the old code inflated the vertical
margin by `scaleMultiplier.y` as well as by the scale, which made it anisotropic. If you change how the bounds are computed, keep
`bounds.height == frame.height * scale`, or the tick labels come out stretched.

**`AxisScale.DrawXEndLabels(...)` marks only the two ENDS of an x axis**, and is used by exactly one graph — the initial
distribution, whose x axis is axial position and whose ends are "Top" and "Bottom". On an axis where the ends say everything, a
millimetre scale is clutter — and that graph runs top-to-bottom, so the names are what stop it being read backwards. Where the
intermediate values *do* matter, the two stress profiles use **`AxisScale.TickValues` + `AxisScale.DrawXAxis`**: a labelled grid at
a **fixed** 100 mm interval, thinning its labels (never its ticks) when they would collide, so that a 900 mm coil and a 2400 mm one
are read against the same ruler. **`AxisScale.Label(value:quantity:axisMaximum:)`** is for a caller adding a tick of its own to a
list from `Ticks(...)`; it goes through the same `UnitScale`, because a voltage axis slides through the SI prefixes with its
magnitude and a hand-written "1735.31 kV" beside ticks in MV is two units on one axis. The labels are pushed to the outside of their
own ends (a centred left label would hang over the y axis, the one place on the plot that already has ink) and are hung from the
**bottom of the data rectangle**, not from the zero line the x axis is drawn on — the two coincide only while every value is
positive, and a negative-polarity impulse would otherwise draw them down across the curve. A view that sets
`CoilResultsDisplayView.xEndLabels` gets a taller bottom margin (`AxisScale.XEndLabelHeight`) automatically, the same way the left
margin already grows to fit the y tick labels; leaving it `nil` is byte-identical to before.

The data reaching both views is in **volts or amps**, not pre-multiplied by the caller. Each view applies its own power-of-ten
`yValueMultiplier` on the way into view coordinates (same "keep the numbers near 1000" trick as before), but it has to know the real
values to label them. `AppController.doShowWaveforms` and `CoilResultsDisplayWindow` therefore pass `yQuantity` and
`peakTestVoltage` and hand over raw results. Both views also rescale on `setFrameSize`, so a resized window redraws rather than
stretching; `CoilResultsDisplayView.currentData` is a point array rather than a prebuilt `NSBezierPath` for the same reason.

## `InitialDistributionWindow.swift`

Graphs the **capacitive (initial) distribution**, α, against axial position for the impulsed coil. *Simulate → Show Initial Voltage
Distribution*. Three things about it are deliberate:

- **It needs no simulation run**, only a simulation *model*. α is the s→∞ limit of the sweep's own assembly, so `FrequencyDomainSolver.CapacitiveDistribution` produces it in one extra solve — which is the point, since the steepness at the line end is what decides whether a winding needs interleaving or shields, and that is worth knowing *before* the expensive part. `validateMenuItem` therefore enables it on `designIsValid` alone — no result and not even a model, since `doShowInitialDistribution` builds one through `doGetSimulationModel()` if there is none — unlike every other item in that menu. A simulation result is used only if one is to hand, and only to scale the y axis from per-unit into volts (`peakVoltage`); with none, the axis is `.unitless` and the note says so.
- **It reads the same α the stress report does**, rather than computing an initial distribution of its own — so this graph and the report's `0+ (initial)` rows cannot disagree.
- **The x axis runs top-to-bottom, left-to-right**, which is why `Distribution.points` carries a *depth below the top of the coil* and not a height above the yoke. That is the textbook orientation and it puts the line end on the left in the usual case, but it is the **opposite** of `CoilResultsDisplayView`'s other two users, whose x is a height — hence the end labels, which exist so the two graphs cannot be confused. "Impulsed coil" means a coil with a node carrying an impulse connector; if there is more than one they all go in the picker. Coils that are not driven are left out on purpose — α there is a small shunt-capacitance residual that would flatten the driven curve into the floor of the plot.

## The three profiles (`StressProfileView.swift`, `AxialStressProfileWindow.swift`, `StressProfileWindow.swift`, `RadialProfileWindow.swift`)

`AxialStressProfileWindow` is the disc-to-disc stress of one coil against height (*Simulate → Show Axial Stress Profile…*);
`StressProfileWindow` is the radial voltage difference — or radial stress, on a picker — between one coil and the next
(*Simulate → Show Radial Stress Profiles…*); `RadialProfileWindow` is the conductor-to-conductor voltage across the radial build
of a sheet or layer winding (*Simulate → Radial Voltage Profile for Selected Winding…*, enabled only for those two types).
**All three draw into `StressProfileView`**, and that sharing is the point: they are read side by side, so a difference in where
the ticks fall, in what the allowable looks like or in what the annotation says would be taken for a difference in the *data*. The
windows do the physics — which findings belong to which curve, what the allowable at a point is, what the annotation rows say —
and the view knows nothing about coils or gaps.

Two things vary between them and are therefore passed in rather than branched on, both added for the radial profile:
`Plot.xAxis`, since that one counts gaps instead of measuring a height, and `Plot.allowableMayGoOffScale`, since a sheet
winding's turn-to-turn voltage is a per cent or two of what the paper withstands and scaling to the allowable would flatten the
profile onto the x axis. The two stress windows leave both at their defaults and draw exactly as they did.

Six things about them are deliberate:

- **The view is not `CoilResultsDisplayView`.** It needs a second series, a labelled x axis on a fixed 100 mm grid, markers at
  named heights and an annotation block inside the plot, none of which that view has and none of which its remaining user wants.
  It draws in plain view coordinates (bounds == frame), which is what lets it hand `AxisScale` a `pointSize` of 1 and reuse
  `DrawYAxis` unchanged; `CoilResultsDisplayView` instead sets its bounds to the data rectangle, which is why that one needs two
  passes to settle a margin and scales everything it draws by hand.
- **Either quantity is judged against its own allowable.** The radial window's voltage view is compared with the ΔV that would put
  the governing layer at its limit, its stress view with the limit itself; both fall out of the finding as a division by its
  utilization, so the two views of one profile carry the same margin and the picker cannot move the worst point.
- **The allowable is a series, not a rule.** With one duct size and one paper thickness the length of a coil every point of it is
  equal and it draws as the horizontal line it is meant to be, but a widened duct or a gap facing a static ring genuinely has a
  different allowable, and one rule at the smallest of them would understate the margin everywhere else. Where it varies the note
  under the picker says so. Measured on the STME-0999 fixture: constant at 19.87 kV/mm plain, 19.87–25.50 kV/mm with static rings.
- **The y axis starts at zero and reaches past the allowable**, because the picture is how much room is left. Its ticks are a
  round grid plus the two values the graph is read for — the worst stress and the allowable — each with a guide line across the
  plot. `AxisScale`'s own extreme ticks are dropped (except zero): they mark the ends of the range they are handed, and the top of
  this one is headroom rather than anything the coil reached.
- **The annotation box is placed by measurement.** Four positions are scored by how many plotted points they would cover, with a
  flat penalty for hiding the allowable line, and the cheapest wins. Both windows open on the coil (or coil pair) with the worst
  point in it, not on the first in the picker, and both pick "worst" by **utilization** — a point with a lower allowable can be
  the one in trouble at a lower field, which is what the report table ranks on too. The rows never repeat a number: with volts on
  the axis the third row is the stress there, with stress on the axis it is the ΔV.
- **The radial profile marks where the inner coil ends** with a vertical rule, named once (to the left of the rule where there is
  no room to its right). Past that height the field is genuinely two-dimensional and the plotted value is indicative only —
  `TODO.md` item 11. The note said so already; the rule says *where*, which is the half that matters when reading a curve.

## Dialogs / windows

(`*.swift` + matching `*.xib`): `GetNumberDialog`, `GetSimDetailsDialog`, `ShowCoilResultsDialog`, `ShowWaveFormsDialog`,
`CoilResultsDisplayView/Window`, `WaveFormDisplayView/Window`. `GetSimDetailsDialog` carries the **bandwidth** field (MHz, default
10, clamped 2–200 by `bandwidthInHz`) — the solver's only accuracy control, since there is no longer a step size or error tolerance
to set. Those four dialogs subclass `PCH_DialogBox` from `PchDialogBoxPackage`.

**`GetWoundInShieldDialog` is the exception**: no `.xib`, an `NSAlert` with an accessory `NSGridView` built in code. It has six
read-only fields (insulation, stress, shield radial, build increase, C_s multiple) that all recompute as the user steps the shield
count, and keeping that right in hand-maintained auto-layout is not worth it. It clamps `n` to `floor(N) − 1` and opens on
`round(0.15·N)`.

**`RegulatingWindingDialog`** (*Connections → Regulating Winding…*) is built the same way, for the same reason: its readout — discs
per loop and the crossovers that will be tied — moves with the loop stepper, and a loop count that does not divide the stack
disables the Declare button on the spot and lists the counts that would work. The declaration itself and what it connects are in
`docs/connectors-and-nodes.md`.

**`StressReportWindow` sizes itself from its columns, and nothing else may have a say.** It opens exactly as wide as the columns
that are displayed (their widths live on `Column.width`, plus the table's intercell spacing and room for the scroller), or as wide
as the screen's `visibleFrame` if that is narrower — so turning the corner columns off makes the window narrower by those two
columns. The notes above the table are a `WrappingLabel`, an `NSTextField` that tracks its own bounds in `preferredMaxLayoutWidth`
and has **low horizontal compression resistance**: an ordinary label's intrinsic width is its whole string, and since the label is
pinned to both edges of the content view that width becomes a constraint the window has to satisfy. That is what once opened this
window 1768 pt wide on a 1728 pt screen. Keep the notes one per line, keep the low compression resistance, and do not give the
window a frame autosave name — `setFrameAutosaveName` only writes the frame (restoring takes an explicit `setFrameUsingName`), and
a restored frame would reinstate a width that the corner-column preference may since have changed.

## Preferences (`Preferences.swift`, `PreferencesDialog.swift`)

*ImpulseDistribution → Preferences…* (⌘,). `Preferences.swift` is the store — a `Preference` case per setting, whose raw value is
its User Defaults key, and a `Definition` giving its title, its explanation, its `Kind` and its factory default.
`PreferencesDialog` is an `NSAlert` with an accessory `NSGridView`, like `GetWoundInShieldDialog` and for a different reason: it
**generates itself from `Preference.allCases`**, so adding a preference is one case plus one `Definition` and no UI work at all.
The how-to is in the file header; keep it accurate, because the whole design is that nobody has to read the dialog to add a
setting.

Three things in there are deliberate:

- **The dialog holds the live values in `edited`, not in its controls.** A text field still being edited when a modal alert's OK
  button is hit has not necessarily committed to the cell, so reading the controls at the end silently drops the last keystrokes.
- **There is no cache in front of `UserDefaults`.** The hottest reader is the dielectric screen, which asks once per layer per
  site, and the reads come from **nonisolated** code (`DielectricStress.StressAllowable.Strike` runs wherever `Scan` was called
  from). `UserDefaults` is thread-safe and keeps its own in-memory copy; a bare global would need synchronization and its own
  invalidation.
- **`runModal()` returns which preferences changed**, so `AppController.handleShowPreferences` can invalidate exactly what went
  stale. Two do today, and they invalidate different amounts. The **dielectric design margin** invalidates the findings: every
  utilization is a fraction of an allowable carrying that margin, so the cached `latestStressChecks` is cleared and an open
  report window is re-run (the screen is milliseconds). **Show corner stresses** invalidates only the *window* — the columns are
  built once in `StressReportWindow`'s initializer and no finding depends on the setting — so an open report is rebuilt from the
  cached checks. Anything else added later that a preference invalidates belongs in that one method.

`Preferences.VerifySelf()` checks the store the same way the other `VerifySelf()`s check their formulas — and it walks
`Preference.allCases`, so a new preference is covered the moment it is added. Run it by calling it from
`AppDelegate.applicationDidFinishLaunching` and reading `defaults read com.huberistech.ImpulseDistribution PreferencesVerification`.

The progress-indicator window (`rb2021_progressIndicatorWindow` in `AppController`) is `PchProgressIndicatorPackage`'s class;
`PCH_GraphingView/Window` and the `old...`-prefixed files are dead — see the target-membership table in `CLAUDE.md`.
