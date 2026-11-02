# Concurrency details

Read this before adding a long-running calculation, wiring up a progress bar, or reaching for `assumeIsolated`.

The basics are in `CLAUDE.md`: the model layer is actor-based, and two AppKit callbacks (`awakeFromNib()`, `Timer` blocks) are
`nonisolated` and so wrap their bodies in `MainActor.assumeIsolated { … }`.

## Progress reporting from a long calculation

Both long calculations report progress the same way, and new ones should follow it. The calculation takes an optional
`AsyncStream<…>.Continuation`; the UI creates the stream with `.bufferingNewest(1)`, drains it in a
`Task { @MainActor in for await … }`, and finishes the continuation when the work returns (**including on the error path** —
otherwise the drain task outlives the calculation). `AsyncStream.Continuation` is `Sendable`, so it crosses into an actor with no
`assumeIsolated` and no `DispatchQueue.main.async`; `.bufferingNewest(1)` means the solver never blocks on a slow UI; and because
each `for await` iteration resumes on the main actor, AppKit actually gets to redraw *between* updates. That last point is the whole
reason the pattern works where ad-hoc main-thread hops historically didn't.

Two things learned the hard way, both worth preserving:

- **An indeterminate `NSProgressIndicator` animates off the main run loop**, so it keeps spinning even when the main thread is wedged. A determinate bar does not. If a converted bar stalls, that is a real main-thread block being *exposed*, not introduced.
- **A bar that never moves usually means the work isn't completing incrementally**, not that the plumbing is broken. Check whether the underlying units of work actually finish at different times before touching the UI code. The inductance bar is one update per Segment, which is one solve against a single shared factorization; those solves are serialized inside `PchAxiSymFE` (one factorization, one solve at a time), so there is no bounded-concurrency knob at this level and none is wanted.

Throttle the emitting side to roughly what the bar can show. `SimulateRK45` reports only when its fraction advances ≥0.2% (a run is
10⁵+ steps; a 100pt bar has ~100 useful positions) and checks `Task.isCancelled` at the **top of its loop** rather than at the
throttled report site — a long run of rejected steps would otherwise never reach a check. `FrequencyDomainSolver.Sweep` reports
every `points/200` completed solves; unlike the RK45 bar, its progress is genuinely **linear in wall-clock time**, because every
contour point costs the same.

## `@MainActor` is not mutual exclusion — `recalculateModel` is gated

`AppController` is `@MainActor`, and that guarantees nothing about a long `async` method running only once at a time. `@MainActor`
serialises *steps*, not *calls*: every `await` is a suspension point at which the main actor is free to run something else, and
`recalculateModel` is minutes long and `await`s at nearly every line. Any menu action that spawns a `Task { … }` — which is all of
them — could therefore start a second full recalculation on top of the first.

The symptom, when it happened, was interleaving one coil and then interleaving a *second* coil before the first inductance
calculation had finished. Two recalculations then ran at once over state that is inherently single-run, and each one clobbered the
other's:

| Shared state | What the overlap did |
|---|---|
| `currentFePhase` | The newer run overwrote it. `didFinishInductanceCalculation()` read it back and so reported on the *other* run's half-built phase: no inductance matrix on it yet, so it turned the light red and returned before ever setting `inductanceIsValid`. |
| `runningInductanceTask` | Each run overwrote the other's handle and then nil'd it on completion, so **Cancel Inductance could no longer reach the calculation that was actually running**. |
| `indCalcProgInd` | Two `InductanceProgress` streams drove the one bar from different fractions, and each run zeroed it as it started — the bar appeared to climb part-way and restart, over and over. |
| the `PhaseModel` | The older run's `fePhase` was built from the pre-edit segment store. It kept walking `CoilSegments()` for eddy losses and FE currents while the newer run swapped Segments underneath it, and then wrote an inductance matrix computed for a winding that no longer existed. |

`recalculateModel` is now a **gate**; the work lives in `PerformRecalculation`. A new request calls
`CancelRecalculationInFlight()`, then queues a task that waits out the old run's unwind before touching anything. Points worth
keeping:

- **Supersede, don't block.** The in-flight result is *stale*, not merely late — its caller has already changed the geometry it was computed for. Disabling the editing menu items instead (the way `simulateMenuItem` gates on `runningSimulationTask == nil`) would lock the user out for the length of a full inductance run to protect an answer that is already garbage.
- **`Task {}` is unstructured and does not inherit cancellation**, so cancelling the gate does *not* reach the inner `inductanceTask` on its own. `withTaskCancellationHandler` forwards it. The Cancel Inductance menu item still cancels `runningInductanceTask` directly and lands in the same `catch`.
- **A superseded run must stay silent.** It legitimately reaches the `feSectionCount == coilSegments.count` guard (the store changed under it) and can fail anywhere in the FE solve, so every alert on those paths is guarded by `!Task.isCancelled`, and the `catch` treats `Task.isCancelled` the same as a `CancellationError` — a cut-off run surfaces as a mesh or solver failure just as readily.
- **Cancel before mutating.** `updateModel` signals cancellation at the *top*, before the segment swap, so the old run's next checkpoint sees it rather than waking up in a store that is half old and half new.
- **`didFinishInductanceCalculation` takes its phase as a parameter.** Reading `currentFePhase` told it which phase was *newest*, not which one it was reporting on. The gate makes the overlap impossible; the parameter makes it unstateable.

## Bounded parallelism in the frequency sweep

The frequency sweep bounds its own parallelism to one task per core (primed, then topped up as each completes) rather than
launching all ~2000 solves at once. Each in-flight solve holds an nx×nx complex matrix — ~2.5 MB at nx=400 — so an unbounded
`TaskGroup` would need several GB of live matrices. Keep the bound if you touch that loop.

**Each solve runs LAPACK single-threaded, and must (2026-11-02).** The sweep's tasks occupy every thread of Swift's cooperative
pool, one per core. Accelerate's default threading model may split a factorization into sub-jobs and then *block* the calling
thread on a dispatch group until they finish; with every pool thread parked in `_dispatch_group_wait_slow` under `zgetrf`, the
sub-jobs never run and the sweep hangs at 0% CPU, forever, with no error. Whether Accelerate splits is chip-dependent: S0749
hung every time on an M4 Pro (14 cores) and never on a plain M4 — same build, same file, same macOS 27.0.1. A `sample` of the
stuck process is the diagnosis; the progress bar just stops.

`FrequencyDomainSolver.Solve` therefore calls `zgesv_` **directly and synchronously**, with `BLASSetThreading(BLAS_THREADING_SINGLE_THREADED)`
set immediately before and the previous model restored after. Two things about that are forced:

- **`BLASSetThreading` is thread-local.** Setting it once around the sweep does nothing reliable: a task can resume on a different
  pool thread after every `await`. Setting and calling back to back with no suspension point between them is the only form that
  is guaranteed to reach the thread that enters LAPACK.
- **It cannot go through `PchMatrix`.** `PchMatrix` is an actor, so its LAPACK call runs on whatever thread the actor is
  scheduled on, not the one that made the setting. (Going direct also drops four actor hops and three buffer copies per point.)

The same trap is open to any other code that runs dense LAPACK from several tasks at once on the cooperative pool. Nothing is lost
by single-threading inside a sweep: the parallelism is already across frequency points.

## `assumeIsolated`

It *traps* if the assumption is ever wrong, so only use it where the main thread is guaranteed — otherwise hop with
`Task { @MainActor in … }`. The existing sites were exercised by hand (design-file load → inductance/capacitance → simulation →
coil-results animation → pinch-zoom) when Swift 6 mode was adopted, so a trap firing in one of them signals a genuine regression,
not a pre-existing latent bug.
