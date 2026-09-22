# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS (AppKit/Cocoa) desktop application that simulates the **impulse voltage distribution** through transformer windings — i.e. how a lightning/impulse voltage waveform distributes across the discs of a coil during very fast transients. It builds inductance and capacitance matrices for a winding geometry and solves the resulting network over time.

The project was called **`Rabin2021`** until 2026-09-18 — after Rabin's method, which the inductance calculation is founded
on — and everything now carries the product's own name instead: the git repo, the working directory, the source folder, the
Xcode project, the scheme, and the bundle identifier `com.huberistech.ImpulseDistribution`. Commits before that date use the
old name throughout, and GitHub still redirects the old repo URL. Note that `Rabin` on its own is NOT the old project name
where it survives in the docs and in `FePhase.swift` — it is the physicist, and those references are deliberate.

## Detailed references — read the relevant one before working

`CLAUDE.md` is the map. The physics, the failure histories and the design rationale live in `docs/`; each file is written to be
read on its own when you start work in that area. **Read the matching file before editing — most of what is in them is a real bug
that was fixed once and must not come back.**

| Working on… | Read |
|---|---|
| Series/shunt capacitance, wound-in shields, interleaving, τ_p, DelVecchio ch. 12 | `docs/capacitance.md` |
| Stress report, stress profiles, turn ladder, radial voltage profile (sheet/layer), breakdown allowables (DelVecchio ch. 13) | `docs/dielectric-stress.md` |
| Frequency-domain solver, NILT, conductor impedance, `SimulationModel`, RK45, SPICE export | `docs/solver.md` |
| Connectors, jumpers, terminations, `SetNodes`/`NodeAt`, tapping gaps, regulating-winding declarations | `docs/connectors-and-nodes.md` |
| Segment indexing, static rings, radial shields, radial build-up | `docs/segments-and-geometry.md` |
| `AppController`, `TransformerView`, graphs, `AxisScale`, dialogs | `docs/ui-layer.md` |
| Progress bars, `AsyncStream` plumbing, bounded parallelism, `assumeIsolated` | `docs/concurrency.md` |
| Running the app end-to-end without a keyboard; the test fixtures | `docs/self-test.md` |
| What is still known to deviate from the books (open items) | `TODO.md` |
| Why a question was settled the way it was — closed investigations | `docs/decisions.md` |

## Build & run

```bash
# Build (Debug)
xcodebuild -project ImpulseDistribution.xcodeproj -scheme ImpulseDistribution -configuration Debug build

# Build (Release)
xcodebuild -project ImpulseDistribution.xcodeproj -scheme ImpulseDistribution -configuration Release build
```

- Normal development is done in Xcode (open `ImpulseDistribution.xcodeproj`, ⌘R to run).
- **There is no test target** — do not look for or attempt to run XCTest. Verification is by hand: the `SelfTest` harness (`docs/self-test.md`) drives the whole pipeline from a launch argument, and several `VerifySelf()` routines pin individual formulas.
- **Swift 6 language mode** with `SWIFT_STRICT_CONCURRENCY = complete`, macOS deployment target 26.0, **Apple Silicon only** (`arm64`; see commit "Set project to build for Apple Silicon only"). Note that these two settings are on the **app target only** — the project level is still `SWIFT_STRICT_CONCURRENCY = targeted`, which is what the SPM packages inherit. Do not move them up to the project, and do not enable `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; both break `PchMatrixPackage`.
- The preprocessor macros `ACCELERATE_NEW_LAPACK=1` and `ACCELERATE_LAPACK_ILP64=1` are set **project-wide** (`GCC_PREPROCESSOR_DEFINITIONS`, in the Apple Clang – Preprocessing build settings). The LAPACK-using matrix code needs them because of Apple's 2023 LAPACK/BLAS changes. Leave them in place.

### Not everything in `ImpulseDistribution/` is compiled

Eight `.swift` files sit in the source folder but are **not in the target's Compile Sources phase**, so editing them has no effect on the built app. Check target membership before touching a file:

| File(s) | Status |
|---|---|
| `PchMatrix.swift` | Superseded. The `PchMatrix` the code actually uses comes from `PchMatrixPackage`. |
| `PCH_ProgressIndicatorWindow.swift` | Superseded by the class of the same name in `PchProgressIndicatorPackage`. |
| `EslamianVahidiModel.swift` | Dead; its only reference (`PhaseModel.swift:46`) is commented out. |
| `PCH_GraphingView.swift`, `PCH_GraphingWindow.swift` | Dead; the only reference is inside a commented-out block in `AppController.swift`. |
| `oldPchMatrixView*.swift` (3 files) | Legacy. |

The compiled target is exactly these 38: `AppController`, `AppDelegate`, `AxialStressProfileWindow`, `AxisScale`, `BasicSection`, `CoilResultsDisplayView`, `CoilResultsDisplayWindow`, `ConductorImpedance`, `Connector`, `Core`, `DielectricStress`, `FePhase`, `FrequencyDomainSolver`, `GetNumberDialog`, `GetSimDetailsDialog`, `GetWoundInShieldDialog`, `InitialDistributionWindow`, `Node`, `NumericalLaplaceTransform`, `PhaseModel`, `Preferences`, `PreferencesDialog`, `RadialProfileWindow`, `RegulatingWinding`, `RegulatingWindingDialog`, `Segment`, `SelfTest`, `ShowCoilResultsDialog`, `ShowWaveFormsDialog`, `SimulationModel`, `StressProfileView`, `StressProfileWindow`, `StressReportWindow`, `TransformerView`, `TurnLadderModel`, `WaveFormDisplayView`, `WaveFormDisplayWindow`, `Wiring`.

**When adding a `.swift` file, add it to the Compile Sources phase.** Eight files in this folder are already orphaned, and SourceKit reports a misleading `No such module 'PchBasePackage'` on a file that is not in the target — that diagnostic means "not in Compile Sources", not "package missing".

## Dependencies (Swift Package Manager)

Resolved packages live in `ImpulseDistribution.xcodeproj/.../swiftpm/Package.resolved`. Several are private/GitHub packages by the same author (megapete):

- `PchBasePackage` — core utilities (logging via `ALog`, etc.). **Keep the Release `-disable-cmo` flag** on this package; it fixes a CGFloat/Double CMO swiftmodule deserialization crash when archiving.
- `PchAxiSymFE` (from `PchAxiSymFePackage`) — the 2D axisymmetric finite-element library. **This is the path actually used to compute the inductance matrix and the eddy losses.** It is referenced as a **local package** at `../PchAxiSymFePackage`, not from GitHub, so it is edited in place and every build takes the working copy. The app talks to it through exactly one file, `ImpulseDistribution/FePhase.swift` — read that file's header before changing anything about the FE model. It replaced `PchFiniteElementPackage` (`PchFePhase`), which the project no longer references at all.
- `PchMatrixPackage`, `PchExcelDesignFilePackage`, `PchDialogBoxPackage`, `PchProgressIndicatorPackage` — matrix ops, Excel design-file import, dialogs, progress UI.
- `swift-numerics` (`ComplexModule`, `RealModule`) — complex/real math used by the matrix and inductance code.

## Domain model

The physics model is layered from smallest to largest unit. Understanding this hierarchy is essential:

- **`BasicSection`** (struct, `BasicSection.swift`) — the smallest unit the program recognizes: one coil section at a physical location. `LocStruct` gives its `(radial, axial)` position, where radial 0 is closest to the core leg and axial 0 is closest to the bottom yoke.
- **`Segment`** (`actor`, `Segment.swift`) — a collection of *axially contiguous* `BasicSection`s from the **same winding**. This is the unit that is actually modeled and drawn. Static rings and radial shields are special Segments created via class factory functions. Segments are `Equatable`/hashed **by serial number**.
- **`Core`** (struct, `Core.swift`) — core geometry (diameter, window height, leg centers) used by inductance calculations.
- **`Node`** (struct, `Node.swift`) — a connection point between segments. Its `number` is **0-based and doubles as the index into the capacitance matrix**. Shunt capacitances to ground use `toNode = -1`.
- **`Connector` / `Segment.Connection`** (`Connector.swift`, `Segment.swift`) — an electrical "jumper" or a termination (`floating`, `ground`, `impulse`) on one of eight physical locations on a segment. See `docs/connectors-and-nodes.md`.
- **`PhaseModel`** (`actor`, `PhaseModel.swift`) — the central model object. Owns the sorted `segmentStore`, the `nodeStore`, and the `core`. All model mutation/queries go through it. Throws `PhaseModelError`. It also holds `voltsPerTurn`, the one place the model knows an *actual* operating voltage rather than a per-unit one.
- **`SimulationModel`** (`actor`, `SimulationModel.swift`) — built from a `PhaseModel`; owns the matrices the solvers run on. See `docs/solver.md`.

### The standing rules

These are the invariants that get violated by plausible-looking edits anywhere in the codebase. Each has a full account in the
linked file; do not act against one of them without reading it first.

1. **`axialPos` is a coordinate, never an index.** It is the pristine design-file disc index and is never renumbered; a Segment's *ordinal* is its position in `PhaseModel.CoilSegments()`. Never derive one from the other — get index ranges from `SegmentRange(coil:)`. → `docs/segments-and-geometry.md`
2. **`CoilSegments()` is not `segments`.** `segments` includes static rings and radial shields; `CoilSegments()` drops them. Anything sized by or indexed against the FE sections or the inductance matrix must use `CoilSegments()`. → `docs/segments-and-geometry.md`
3. **`SegmentAt(location:)` searches the whole store, and must** — restricting it to `CoilSegments()` makes every shielding-element lookup return nil. → `docs/segments-and-geometry.md`
4. **τ_p is a TWO-sided paper thickness** everywhere except two named per-side constants. A stray factor of 2 moves every disc capacitance in the model by 2×. → `docs/capacitance.md`
5. **A tapping gap breaks the node chain even when it is bridged**, and `IsTappingGap` recognises it by the *location* (`inside_center`/`outside_center`), never by the termination. `SetNodes` and `NodeAt` must keep using the same predicate. → `docs/connectors-and-nodes.md`
6. **A termination lives only on the lead the user clicked.** What is at that potential through a jumper is derived by `PhaseModel.ResolveNodeConnectivity()`, never written into the connector store. → `docs/connectors-and-nodes.md`
7. **A BasicSection's radii are pristine; the live geometry is the owning Segment's `rect`.** → `docs/segments-and-geometry.md`
8. **Do not calibrate diagnostics on the synthetic validation ladder** — it is tiny, per-unit and well scaled, and a real winding is none of those. A diagnostic that fails on a correct model is worse than no diagnostic. → `docs/solver.md`
9. **Read equations off the printed PDF page as images**, not from the text layer — the math font has no `ToUnicode` CMap and extracted text silently loses decimal points. → `docs/dielectric-stress.md`

The authorities for the physics are **DelVecchio, *Transformer Design Principles*** (ch. 12 series capacitance, ch. 13 breakdown)
and **Kulkarni & Khaparde, *Transformer Engineering*** (ch. 7 shunt terms). Both PDFs live in `~/Documents/MyProjects/Claude/`.

## Concurrency

The model layer is **actor-based** — `PhaseModel`, `Segment`, and `SimulationModel` are all `actor`s, and most model methods are `async`. Many model types are `Sendable`/`Codable`. When adding or calling model code, expect `await` and respect actor isolation; concurrency correctness here has been an ongoing source of fixes.

Two AppKit patterns recur in the UI layer, both because the callback is `nonisolated` even though it only ever runs on the main thread:

- **`awakeFromNib()`** — `NSObject`'s declaration is `nonisolated`, so an override does *not* inherit its class's `@MainActor`. Every existing override therefore wraps its body in `MainActor.assumeIsolated { … }`.
- **`Timer` blocks** — the `scheduledTimer(withTimeInterval:repeats:block:)` closure is `@Sendable` and nonisolated; the animation timer in `CoilResultsDisplayWindow` uses the same `MainActor.assumeIsolated { … }` wrapper.

Long calculations report progress through an `AsyncStream` continuation and bound their own parallelism — follow the existing
pattern rather than inventing one; see `docs/concurrency.md`.
