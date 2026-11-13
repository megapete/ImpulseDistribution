//
//  FrequencyDomainSolver.swift
//  ImpulseDistribution
//
//  Created by Claude on 2026-08-01.
//
//  ===========================================================================
//  WHAT THIS FILE IMPLEMENTS
//  ===========================================================================
//
//  The impulse transient, solved exactly, by working one frequency at a time
//  and transforming back. This replaces the adaptive RK45 time-marching in
//  SimulationModel.
//
//  ---------------------------------------------------------------------------
//  WHY NOT TIME-MARCH
//  ---------------------------------------------------------------------------
//
//  The system being solved is linear and time-invariant, and it is driven by
//  a forcing function known in closed form. Nothing about it requires
//  numerical integration.
//
//  Marching it explicitly is actively bad here. An impulse network is a
//  lightly-damped LC ladder whose eigenfrequencies span decades, and an
//  explicit integrator's step is capped by STABILITY - roughly |h*omega| < 3
//  for the fastest mode in the model - not by accuracy. That cap applies for
//  the whole 100 us run, long after the fast modes have stopped contributing
//  anything. The old RK45 settled near h = 1 ns and took 10^5+ steps, almost
//  all of them spent resolving modes far above the frequency where a lumped
//  disc model means anything at all.
//
//  Solving per-frequency inverts that trade completely: the bandwidth becomes
//  a parameter the engineer chooses, and nothing is spent above it.
//
//  ---------------------------------------------------------------------------
//  THE SYSTEM
//  ---------------------------------------------------------------------------
//
//  Unknowns: nodal voltages V (nNodes) and segment currents I (nSegments).
//  At each complex frequency s:
//
//      +-                    -+ +- -+   +-        -+
//      |  s*C'        -Abar    | | V |   |  E*U(s)  |
//      |                       | |   | = |          |
//      |  -B      s*M + Z(s)   | | I |   |    0     |
//      +-                    -+ +- -+   +-        -+
//
//  This is the SAME system the RK45 path integrates, written algebraically.
//  It comes directly from the two time-domain equations in
//  SimulationModel.DifferentialFormula:
//
//      C' dV/dt = Abar * I           ->    s*C'*V - Abar*I = 0
//      M  dI/dt = B*V - R*I          ->    -B*V + (s*M + Z)*I = 0
//
//  SIGN AND ORIENTATION CONVENTIONS - the easiest thing in this whole change
//  to get silently wrong, so stated explicitly and tied back to the arrays
//  they come from:
//
//      Abar[node, seg]  = +1 if seg is BELOW node    (from iDropInd.belowSeg)
//                       = -1 if seg is ABOVE node    (from iDropInd.aboveSeg)
//
//          because DifferentialFormula builds
//              currentDrop[i] = I[belowSeg] - I[aboveSeg]
//
//      B[seg, node]     = +1 if node is BELOW seg    (from vDropInd.belowNode)
//                       = -1 if node is ABOVE seg    (from vDropInd.aboveNode)
//
//          because DifferentialFormula builds
//              voltageDrop[i] = V[belowNode] - V[aboveNode]
//
//  Z(s) is diagonal, Z[i,i] = R_i(omega) from ConductorImpedance - evaluated
//  at THIS frequency. That is the whole reason the two-pass
//  "guess a fundamental frequency, run twice" scheme is gone: every frequency
//  component now sees its own resistance, exactly, with no estimate involved.
//
//  E is the selector for impulsed nodes and U(s) is the Laplace transform of
//  the applied wave - the VOLTAGE, not its derivative. The impulsed node's
//  voltage is therefore imposed as an algebraic constraint at every
//  frequency, rather than being reached by integrating dV/dt as the RK45 path
//  does, so it cannot drift.
//
//  ---------------------------------------------------------------------------
//  THE ASYMPTOTE SUBTRACTION - why this file does not just invert V(s)
//  ---------------------------------------------------------------------------
//
//  Inverting V(s) directly converges far too slowly to be usable. The applied
//  wave's transform decays only as 1/s^2, so the spectral tail beyond the
//  band edge is still substantial and its absence shows up as a large error
//  right at the wavefront - measured 1.7e-2 at f_max = 10 MHz, improving only
//  as 1/f_max. Reaching 1e-4 that way would need roughly 2 GHz of bandwidth
//  and 400,000 solves.
//
//  So the leading behaviour is removed analytically first. As s -> infinity:
//
//      from the lower block,  I = (s*M + Z)^-1 * B * V  ~  O(1/s)
//      substituting into the upper block,  s*C'*V = Abar*I ~ O(1/s)
//      so the free-node rows tend to      C'*V -> 0
//
//  which, with V = U(s) imposed at the impulsed node and V = 0 at ground, is
//  exactly the ELECTROSTATIC problem. Its solution
//
//      alpha = C'^-1 * E
//
//  is the classical initial (capacitive) voltage distribution that impulse
//  theory already talks about - the distribution the winding sees at t = 0+
//  before any current has had time to flow. It costs one real solve, once.
//
//  Splitting on it,
//
//      V(s) = alpha*U(s)  +  W(s),        W(s) = V(s) - alpha*U(s)
//
//  the first term inverts in closed form (it is a known constant vector times
//  the known applied wave, so v(t) = alpha*u(t) exactly, with NO numerical
//  error at all), and W(s) decays as 1/s^4 rather than 1/s^2 - it is
//  identically zero at the impulsed and grounded nodes, where the Dirichlet
//  rows make V exactly alpha*U. Measured, this is 15x-40x more accurate at
//  identical cost.
//
//  The segment currents need no such treatment: I ~ O(1/s^3) already, because
//  it picks up one power of 1/s from the inductance and two from U(s).
//
//  ---------------------------------------------------------------------------
//  SYMBOL GLOSSARY
//  ---------------------------------------------------------------------------
//
//    nN, nS    number of nodes / of coil segments                    [-]
//    nx        total unknowns, nN + nS                               [-]
//    C         nodal capacitance matrix, nN x nN                     [F]
//    C'        C after the boundary-condition row surgery            [F]
//    M         segment inductance matrix, nS x nS, UNFACTORED        [H]
//    Abar      node-segment incidence, nN x nS                       [-]
//    B         segment-node incidence, nS x nN                       [-]
//    Z(s)      diagonal segment impedance, Z[i,i] = R_i(omega)       [ohm]
//    U(s)      Laplace transform of the applied impulse              [V*s]
//    alpha     capacitive initial voltage distribution, per unit     [-]
//    W(s)      V(s) - alpha*U(s), the part solved numerically        [V*s]
//
//  ===========================================================================

import Foundation
import Accelerate
import ComplexModule
import RealModule
import PchBasePackage
import PchMatrixPackage

/// Everything the frequency sweep needs, extracted from the model ONCE.
///
/// This exists so the sweep can run with no actor involvement at all.
/// `PchMatrix` is an actor and `SimulationModel` is an actor; reaching into
/// either from inside a 2000-iteration parallel loop would serialise the whole
/// thing on actor hops. Snapshotting into a plain `Sendable` value first means
/// the frequency loop touches nothing shared.
///
/// All matrices are stored COLUMN-MAJOR (index = col*rows + row), matching
/// both LAPACK and `PchMatrix`'s own `.general` layout, so they can be handed
/// over without a transpose.
struct NetworkSnapshot:Sendable {

    /// Number of nodes, nN.
    let nodeCount:Int

    /// Number of coil segments, nS.
    let segmentCount:Int

    /// Base nodal capacitance matrix C, nN x nN, column-major. This is the
    /// UNMODIFIED matrix - the boundary-condition surgery is applied during
    /// assembly, not baked in here, because it has to be applied to the whole
    /// block row (capacitance AND incidence together) to stay consistent.
    let capacitance:[Double]

    /// Segment inductance matrix M, nS x nS, column-major. Must be the
    /// UNFACTORED matrix (`PhaseModel.unfactoredM`) - `PhaseModel.M` holds a
    /// Cholesky factorisation and is not the matrix itself.
    let inductance:[Double]

    /// Per node: the segment indices below and above it, or -1. Straight from
    /// `SimulationModel.iDropInd`. Gives Abar.
    let nodeIncidence:[(belowSegment:Int, aboveSegment:Int)]

    /// Per segment: the node indices below and above it. From
    /// `SimulationModel.vDropInd`. Gives B.
    let segmentIncidence:[(belowNode:Int, aboveNode:Int)]

    /// Node indices held at the applied impulse voltage.
    let impulsedNodes:[Int]

    /// Node indices held at zero.
    let groundedNodes:[Int]

    /// Node indices with no galvanic connection, carrying only the very large
    /// `floatingResistance` to ground.
    let floatingNodes:[Int]

    /// Pairs of nodes shorted together by a jumper, as (kept, eliminated).
    /// The eliminated node's row becomes the constraint V_from - V_to = 0
    /// after its own equation has been folded into the kept node's.
    let mergedNodes:[(kept:Int, eliminated:Int)]

    /// Resistance data per segment, in segment-index order.
    let resistances:[SimulationModel.Resistance]

    /// The very large resistance standing in for "no connection".
    let floatingResistance:Double

    /// When non-nil, every segment's resistance is evaluated at THIS frequency
    /// instead of at the frequency being solved.
    ///
    /// This exists solely to make the RK45 cross-check meaningful. A
    /// time-marching solver can only carry one resistance per segment for a
    /// whole run, so with the frequency dependence active the two solvers are
    /// not solving the same equations and a disagreement between them cannot
    /// be attributed to anything in particular. Pinning this to
    /// `SimulationModel.defaultEddyFreq` makes them identical, so any
    /// remaining difference is purely numerical - which is exactly what a
    /// cross-check should be measuring.
    ///
    /// Leave it nil for production runs. Setting it throws away the main
    /// advantage of solving in the frequency domain.
    var resistanceFrequencyOverride:Double? = nil

    /// Total unknowns.
    var unknownCount:Int { nodeCount + segmentCount }
}

/// Solves the impulse transient exactly, in the frequency domain.
enum FrequencyDomainSolver {

    // MARK: - Assembly

    /// Builds the system matrix at one complex frequency, plus its right-hand
    /// side, as an interleaved column-major complex buffer ready for
    /// `PchMatrix.SetBuffer`.
    ///
    /// The buffer layout is [re, im, re, im, ...] with the underlying index
    /// being `col*rows + row` - this is what `PchMatrix.Storage` expects for a
    /// `.general` `.Complex` matrix, and it is also LAPACK's column-major
    /// convention, so nothing is transposed anywhere.
    ///
    /// - parameter s: The complex frequency.
    /// - parameter drive: U(s), the transform of the applied wave.
    /// - parameter snapshot: The network.
    /// - returns: `matrix`, the interleaved nx*nx buffer, and `rhs`, the
    ///   interleaved nx right-hand side.
    static func Assemble(s:Complex<Double>, drive:Complex<Double>, snapshot:NetworkSnapshot) -> (matrix:[Double], rhs:[Double]) {

        let nN = snapshot.nodeCount
        let nS = snapshot.segmentCount
        let nx = snapshot.unknownCount

        var a = [Double](repeating: 0.0, count: 2 * nx * nx)
        var rhs = [Double](repeating: 0.0, count: 2 * nx)

        // Column-major complex accessors. Kept local and inlined rather than
        // exposed, because the interleaving is an implementation detail of
        // this one function.
        func set(_ row:Int, _ col:Int, _ value:Complex<Double>) {

            let i = 2 * (col * nx + row)
            a[i] = value.real
            a[i + 1] = value.imaginary
        }

        func add(_ row:Int, _ col:Int, _ value:Complex<Double>) {

            let i = 2 * (col * nx + row)
            a[i] += value.real
            a[i + 1] += value.imaginary
        }

        func get(_ row:Int, _ col:Int) -> Complex<Double> {

            let i = 2 * (col * nx + row)
            return Complex(a[i], a[i + 1])
        }

        // --- Node block: s*C'*V - Abar*I = 0 -------------------------------
        for col in 0..<nN {

            for row in 0..<nN {

                let c = snapshot.capacitance[col * nN + row]

                if c != 0.0 {

                    set(row, col, s * Complex(c))
                }
            }
        }

        // Abar enters with a MINUS sign (it is on the left-hand side), so the
        // signs here are the opposite of Abar's own:
        //     Abar[i, belowSeg] = +1   ->   matrix entry -1
        //     Abar[i, aboveSeg] = -1   ->   matrix entry +1
        for node in 0..<nN {

            let incidence = snapshot.nodeIncidence[node]

            if incidence.belowSegment >= 0 {

                add(node, nN + incidence.belowSegment, Complex(-1.0))
            }
            if incidence.aboveSegment >= 0 {

                add(node, nN + incidence.aboveSegment, Complex(1.0))
            }
        }

        // A floating node gets a very large resistance to ground. In the time
        // domain DifferentialFormula subtracts V_i/Rs from the right-hand
        // side; algebraically that is +1/Rs on the diagonal of the node block.
        // At the default Rs = 1e50 this is numerically a no-op, and it is
        // included for fidelity with the RK45 path rather than because it does
        // anything.
        for node in snapshot.floatingNodes {

            add(node, node, Complex(1.0 / snapshot.floatingResistance))
        }

        // --- Segment block: -B*V + (s*M + Z)*I = 0 -------------------------
        let omega = s.imaginary
        let frequency = snapshot.resistanceFrequencyOverride ?? (abs(omega) / (2.0 * π))

        for segment in 0..<nS {

            let incidence = snapshot.segmentIncidence[segment]

            // -B, so again the signs invert relative to B itself.
            if incidence.belowNode >= 0 {

                add(nN + segment, incidence.belowNode, Complex(-1.0))
            }
            if incidence.aboveNode >= 0 {

                add(nN + segment, incidence.aboveNode, Complex(1.0))
            }
        }

        for col in 0..<nS {

            for row in 0..<nS {

                let m = snapshot.inductance[col * nS + row]

                if m != 0.0 {

                    add(nN + row, nN + col, s * Complex(m))
                }
            }
        }

        // The frequency-dependent resistance, evaluated at THIS frequency.
        // Note it is a function of the real frequency omega/2pi, not of the
        // full complex s: R comes from a diffusion process whose depth is set
        // by the oscillation rate, and the contour's small real offset sigma
        // is a numerical device, not a physical damping of the conductor.
        for segment in 0..<nS {

            add(nN + segment, nN + segment, Complex(snapshot.resistances[segment].EffectiveResistanceAt(newFreq: frequency)))
        }

        // --- Boundary-condition row surgery --------------------------------
        //
        // Order matters. Merges are folded in FIRST, because folding row
        // `eliminated` into row `kept` would corrupt `kept` if it had already
        // been replaced by a Dirichlet row. SimulationModel's init guarantees
        // a merged pair never involves a grounded or impulsed node (any such
        // group is absorbed into groundedNodes/impulsedNodes and dropped from
        // finalConnectedNodes there), so this ordering is safe - but the
        // assertion below makes the dependency explicit rather than implicit.

        func clearRow(_ row:Int) {

            for col in 0..<nx {

                set(row, col, Complex(0.0))
            }
            rhs[2 * row] = 0.0
            rhs[2 * row + 1] = 0.0
        }

        for merge in snapshot.mergedNodes {

            // Fold the eliminated node's entire equation into the kept node's,
            // so charge is conserved across the jumper.
            for col in 0..<nx {

                add(merge.kept, col, get(merge.eliminated, col))
            }
            rhs[2 * merge.kept] += rhs[2 * merge.eliminated]
            rhs[2 * merge.kept + 1] += rhs[2 * merge.eliminated + 1]

            // Replace the eliminated node's row with the constraint
            // V_eliminated - V_kept = 0.
            //
            // Note this ties the VOLTAGES, not their derivatives. The RK45
            // path could only impose d(V_from - V_to)/dt = 0, which pins the
            // difference to whatever it was at t = 0 and lets it drift from
            // there. Here the constraint is algebraic and exact at every
            // frequency, so no drift is possible.
            clearRow(merge.eliminated)
            set(merge.eliminated, merge.eliminated, Complex(1.0))
            set(merge.eliminated, merge.kept, Complex(-1.0))
        }

        for node in snapshot.groundedNodes {

            clearRow(node)
            set(node, node, Complex(1.0))
        }

        for node in snapshot.impulsedNodes {

            clearRow(node)
            set(node, node, Complex(1.0))
            rhs[2 * node] = drive.real
            rhs[2 * node + 1] = drive.imaginary
        }

        return (a, rhs)
    }

    // MARK: - The capacitive initial distribution

    /// Computes `alpha`, the per-unit voltage distribution the winding takes
    /// on at t = 0+, before any current has flowed.
    ///
    /// This is the s -> infinity limit of the network described in the file
    /// header, and it is what makes the numerical inversion converge. It is
    /// also a quantity worth looking at in its own right: it is the classical
    /// "initial distribution" of impulse theory, and its steepness at the line
    /// end is the traditional first indicator of inter-disc stress.
    ///
    /// It is obtained by assembling the system at a purely real, very large s
    /// and reading off V. Doing it that way rather than building a separate
    /// electrostatic matrix means alpha is guaranteed to come from EXACTLY the
    /// same assembly code, with exactly the same sign conventions and row
    /// surgery, as the frequencies it is subtracted from - a separate
    /// assembly could drift out of agreement and the resulting error would be
    /// invisible.
    ///
    /// - returns: alpha, length nN, or nil if the solve failed.
    static func CapacitiveDistribution(snapshot:NetworkSnapshot) async -> [Double]? {

        // Large enough that the inductive branch is negligible (I ~ 1/s), but
        // far short of anything that would strain the conditioning: the ratio
        // between the capacitive and inductive terms scales as s^2, so 1e12
        // already suppresses the inductive contribution by ~1e24 while the
        // matrix entries themselves stay well inside Double's range.
        let s = Complex(1.0E12, 0.0)

        let (matrix, rhs) = Assemble(s: s, drive: Complex(1.0), snapshot: snapshot)

        guard let solution = Solve(matrix: matrix, rhs: rhs, size: snapshot.unknownCount) else {

            return nil
        }

        return (0..<snapshot.nodeCount).map { solution[$0].real }
    }

    // MARK: - The linear solve

    /// Solves one assembled complex system, `A x = b`, with LAPACK's `zgesv_` (LU with partial pivoting, then the two triangular
    /// solves - the same `zgetrf_` + `zgetrs_` that `PchMatrix.Solve` makes, in one call).
    ///
    /// `matrix` is nx x nx and `rhs` is nx x 1, both column-major with each complex entry as two consecutive Doubles (re, im) -
    /// which is exactly LAPACK's `double complex` layout, so the buffers are handed over as they are. On return `rhs`'s copy holds
    /// x in the same layout.
    ///
    /// WHY THIS DOES NOT GO THROUGH `PchMatrix` ANY MORE, AND WHY IT FORCES SINGLE-THREADED LAPACK (2026-11-02). The sweep runs
    /// one of these per core, concurrently, on Swift's cooperative thread pool, which has exactly one thread per core. Accelerate's
    /// default threading model may split a factorization into sub-jobs and then BLOCK the calling thread on a dispatch group until
    /// they finish. Whether it splits depends on the chip: on an M4 Pro (14 cores) it does at the size of S0749's system, every
    /// pool thread ends up parked in `_dispatch_group_wait_slow` under `zgetrf`, the sub-jobs never get a thread, and the sweep
    /// hangs at 0% CPU forever. The same build, same file, same macOS on a plain M4 never splits and runs fine. Nothing is lost by
    /// turning it off here: the parallelism is already across frequency points, one per core, so LAPACK's own threads could only
    /// oversubscribe the machine.
    ///
    /// `BLASSetThreading` is THREAD-LOCAL (`thread_api.h`: "saved in a thread local variable"). That is why the solve is a
    /// synchronous call with no `await` in it: an actor method - `PchMatrix` is an actor - can run on any pool thread, and a task
    /// can resume on a different thread after every suspension point, so a setting made anywhere else is not guaranteed to be in
    /// force on the thread that actually reaches LAPACK. Set and called back to back on one thread, it is. The previous model is
    /// restored afterwards so the pool thread goes back to whatever else uses it (the FE package, for one) as it was found.
    ///
    /// Going direct also removes four actor hops and three buffer copies per frequency point.
    static func Solve(matrix:[Double], rhs:[Double], size:Int) -> [Complex<Double>]? {

        guard size > 0, matrix.count == 2 * size * size, rhs.count == 2 * size else {

            DLog("Solve was handed a \(matrix.count)-Double matrix and a \(rhs.count)-Double right-hand side for nx = \(size)")
            return nil
        }

        let previousThreading = BLASGetThreading()
        _ = BLASSetThreading(BLAS_THREADING_SINGLE_THREADED)
        defer { _ = BLASSetThreading(previousThreading) }

        var a = matrix
        var b = rhs
        var n = __LAPACK_int(size)
        var nrhs = __LAPACK_int(1)
        var lda = n
        var ldb = n
        var ipiv = [__LAPACK_int](repeating: 0, count: size)
        var info:__LAPACK_int = 0

        a.withUnsafeMutableBufferPointer { A in

            b.withUnsafeMutableBufferPointer { B in

                zgesv_(&n, &nrhs, OpaquePointer(A.baseAddress!), &lda, &ipiv, OpaquePointer(B.baseAddress!), &ldb, &info)
            }
        }

        // info > 0: U(info, info) is exactly zero, so the system is singular at this frequency. PchMatrix threw for the same case.
        guard info == 0 else {

            DLog("zgesv_ failed with info = \(info) (nx = \(size))")
            return nil
        }

        return (0..<size).map { Complex(b[2 * $0], b[2 * $0 + 1]) }
    }

    // MARK: - The frequency sweep

    /// Solve the whole transient.
    ///
    /// # Sequence
    ///
    ///   1. Compute `alpha`, the capacitive initial distribution (one solve).
    ///   2. Solve the network at every contour point (the expensive part,
    ///      run in parallel).
    ///   3. Subtract the analytic asymptote from the nodal voltages, leaving
    ///      W(s) = V(s) - alpha*U(s).
    ///   4. Invert W and I numerically.
    ///   5. Add the analytic part back: v(t) = alpha*u(t) + w(t).
    ///
    /// # Why the parallelism is bounded
    ///
    /// Each in-flight solve holds an nx-by-nx complex matrix. At nx = 400
    /// that is 2.5 MB, so launching all ~2000 contour points at once would
    /// need several GB of live matrices. The group is therefore kept to one
    /// task per core: primed with `width` tasks, then topped up as each
    /// completes. Peak memory becomes width * 2.5 MB instead of 2000 * 2.5 MB.
    ///
    /// - returns: Results on a uniform grid over `0 ... T/2`, or nil on
    ///   failure. Returns nil on cancellation too - callers distinguish with
    ///   `Task.isCancelled`.
    static func Sweep(snapshot:NetworkSnapshot, waveForm:SimulationModel.WaveForm, grid:LaplaceGrid, progress:AsyncStream<SimulationModel.ProgressUpdate>.Continuation? = nil) async -> [SimulationModel.SimulationStepResult]? {

        let nN = snapshot.nodeCount
        let nS = snapshot.segmentCount
        let nx = snapshot.unknownCount
        let points = grid.frequencyCount

        progress?.yield(SimulationModel.ProgressUpdate(fractionComplete: 0.0, phase: "Initial distribution"))

        guard let alpha = await CapacitiveDistribution(snapshot: snapshot) else {

            DLog("Could not compute the capacitive initial distribution")
            return nil
        }

        // spectra[signal][m]. Signals 0..<nN are the nodal voltage residuals
        // W, signals nN..<nx are the segment currents I.
        var spectra = [[Complex<Double>]](repeating: [Complex<Double>](repeating: Complex(0.0), count: points), count: nx)

        // Diagnostics gathered during the sweep, checked once at the end so a
        // warning is emitted once rather than thousands of times. The residual
        // is kept together with the contour point that produced it: the whole
        // point of the measure is that it varies with frequency, so a number
        // without its index cannot be interpreted.
        var worstResidual:ResidualReport? = nil
        var worstResidualIndex = 0
        var bandEdgeMagnitude = 0.0
        var peakMagnitude = 0.0

        let width = max(1, min(points, ProcessInfo.processInfo.activeProcessorCount))

        struct PointResult:Sendable {

            let index:Int
            let solution:[Complex<Double>]
            let drive:Complex<Double>

            /// nil at the contour points where the check was not sampled.
            let residual:ResidualReport?
        }

        func solvePoint(_ m:Int) async -> PointResult? {

            let s = grid.s(at: m)
            let drive = waveForm.U(s)
            let (matrix, rhs) = Assemble(s: s, drive: drive, snapshot: snapshot)

            guard let solution = Solve(matrix: matrix, rhs: rhs, size: nx) else {

                return nil
            }

            // The residual is O(nx^2) per point, far too expensive to run on
            // every one of a few thousand solves. A sparse sample is enough:
            // an assembly bug is present at every frequency, not just some, so
            // checking a handful catches it just as surely as checking all.
            let residual = (m % 512 == 0) ? Residual(matrix: matrix, rhs: rhs, solution: solution, size: nx) : nil

            return PointResult(index: m, solution: solution, drive: drive, residual: residual)
        }

        var failed = false
        var completed = 0

        await withTaskGroup(of: PointResult?.self) { group in

            var next = 0

            while next < min(width, points) {

                let m = next
                group.addTask { await solvePoint(m) }
                next += 1
            }

            while let result = await group.next() {

                guard let result else {

                    failed = true
                    break
                }

                if Task.isCancelled {

                    failed = true
                    break
                }

                // Step 3: peel off the analytic part of the nodal voltages.
                // W is identically zero at impulsed and grounded nodes (the
                // Dirichlet rows make V exactly alpha*U there), which is a
                // useful thing to see if this is ever dumped for debugging.
                for node in 0..<nN {

                    spectra[node][result.index] = result.solution[node] - Complex(alpha[node]) * result.drive
                }

                for segment in 0..<nS {

                    spectra[nN + segment][result.index] = result.solution[nN + segment]
                }

                // Ranked on the backward error, since that is the measure being
                // tested; the other two numbers are then reported from the same
                // contour point so the three are mutually consistent.
                if let report = result.residual, report.backwardError > (worstResidual?.backwardError ?? -1.0) {

                    worstResidual = report
                    worstResidualIndex = result.index
                }

                // Track how much amplitude is left at the top of the band. If
                // this is not small compared with the peak, the bandwidth is
                // too low and content is aliasing down into the answer.
                var magnitude = 0.0
                for node in 0..<nN {

                    let w = result.solution[node]
                    magnitude = max(magnitude, (w.real * w.real + w.imaginary * w.imaginary).squareRoot())
                }

                peakMagnitude = max(peakMagnitude, magnitude)

                if result.index == points - 1 {

                    bandEdgeMagnitude = magnitude
                }

                completed += 1

                // Throttled to roughly what a progress bar can show, matching
                // the convention SimulateRK45 uses. Unlike the RK45 bar, this
                // one is genuinely linear in wall-clock time: every contour
                // point costs the same.
                if completed % max(1, points / 200) == 0 {

                    progress?.yield(SimulationModel.ProgressUpdate(fractionComplete: 0.9 * Double(completed) / Double(points), phase: "Solving \(points) frequencies"))
                }

                if next < points {

                    let m = next
                    group.addTask { await solvePoint(m) }
                    next += 1
                }
            }

            group.cancelAll()
        }

        guard !failed else {

            return nil
        }

        // --- Diagnostics ---------------------------------------------------
        //
        // Both of these are left in permanently. They are the checks that
        // distinguish "the answer is wrong" from "the answer is right", and
        // neither is visible in the output waveform itself.

        // The residual check is reported unconditionally, not only when it
        // trips. DLog compiles away outside DEBUG, and the three numbers
        // together are what make the warning interpretable when it does fire:
        // a high `relativeToDrive` with a low `backwardError` and a large
        // `scaleRatio` is a well-solved badly-scaled system, which is the
        // normal state of affairs for a real winding.
        if let worstResidual {

            let frequency = grid.s(at: worstResidualIndex).imaginary / (2.0 * π)

            DLog(String(format: "Residual check: worst normwise backward error %.3e at contour point %d (%.4g Hz); ||Ax-b||/||b|| there is %.3e, with ||A||*||x||/||b|| = %.3e.",
                        worstResidual.backwardError, worstResidualIndex, frequency, worstResidual.relativeToDrive, worstResidual.scaleRatio))

            // THRESHOLD: 1e-12, about 4500 * DBL_EPSILON.
            //
            // For a backward-stable LU the bound is eta <= c(n) * rho * eps,
            // with c(n) growing like the order and rho the pivot growth factor.
            // At the few-hundred unknowns this model runs, c(n)*rho of 1e3-1e4
            // is unremarkable, so 1e-12 sits above every healthy case while
            // still tripping long before eta approaches 1.
            //
            // Be clear about what crossing it does and does not mean. Backward
            // error is very nearly INDEPENDENT of conditioning - partial
            // pivoting is backward stable, so even a system with a condition
            // number of 1e14 solves to eta ~ eps, it just has a correspondingly
            // large FORWARD error. So this test does not detect ill
            // conditioning, and nothing here does; the guard against that is
            // the asymptote subtraction (which keeps the numerically solved
            // part small) plus agreement with RK45. What a raised eta means is
            // catastrophic pivot growth, a matrix that reached LAPACK in the
            // wrong layout, or non-finite entries having crept into the
            // assembly - all of them outright breakage rather than accuracy
            // creep.
            //
            // The value this replaced was 1e-9 measured against
            // `relativeToDrive`, calibrated on the synthetic 5-node/4-segment
            // ladder used for the ngspice validation. That system is tiny,
            // per-unit and well scaled, and scored 3.1e-16; a real winding
            // scores ~1e-8 on the same measure purely from `scaleRatio`, so the
            // old test fired on every production run.
            if worstResidual.backwardError > 1.0E-12 {

                DLog("WARNING: the normwise backward error is \(worstResidual.backwardError), far above rounding. The system is not being solved accurately - suspect pivot growth, a layout error in the handoff to LAPACK, or non-finite entries in the assembly. Note this does NOT test the physics: run Simulate > Compare Solvers (Debug) to check the assembly against RK45.")
            }
        }

        if peakMagnitude > 0.0, bandEdgeMagnitude / peakMagnitude > 1.0E-3 {

            DLog("WARNING: the response is still \(bandEdgeMagnitude / peakMagnitude) of its peak at the top of the band (\(grid.maximumFrequency) Hz). Content above that limit is aliasing into the result - raise the maximum frequency.")
        }

        // --- Steps 4 and 5: invert, then restore the analytic part ---------
        progress?.yield(SimulationModel.ProgressUpdate(fractionComplete: 0.95, phase: "Transforming to the time domain"))

        var signals = [[Double]](repeating: [], count: nx)

        for signal in 0..<nx {

            guard let inverted = NumericalLaplaceTransform.Invert(spectrum: spectra[signal], grid: grid) else {

                DLog("Inversion failed for signal \(signal)")
                return nil
            }

            if inverted.imaginaryResidual > 1.0E-9 {

                DLog("WARNING: signal \(signal) inverted with imaginary residual \(inverted.imaginaryResidual); the spectrum may not be conjugate-symmetric.")
            }

            signals[signal] = inverted.values
        }

        // Only the first half of the record is returned. The second half is
        // the disposable margin that absorbs wraparound and the worst of the
        // exp(+sigma*t) amplification - see LaplaceGrid.DefaultGrid.
        let usable = grid.sampleCount / 2
        var results:[SimulationModel.SimulationStepResult] = []
        results.reserveCapacity(usable)

        for k in 0..<usable {

            let t = grid.time(at: k)

            // v(t) = alpha*u(t) + w(t). The first term is exact - u(t) comes
            // straight from WaveForm.V(t) in closed form - so all the
            // numerical error in the answer lives in the second, which is the
            // whole point of having split it this way.
            let applied = waveForm.V(t)
            let volts = (0..<nN).map { alpha[$0] * applied + signals[$0][k] }
            let amps = (0..<nS).map { signals[nN + $0][k] }

            results.append(SimulationModel.SimulationStepResult(volts: volts, amps: amps, time: t))
        }

        progress?.yield(SimulationModel.ProgressUpdate(fractionComplete: 1.0, phase: "Done"))

        return results
    }

    // MARK: - Residual check

    /// What one sampled residual check produces.
    ///
    /// Three numbers rather than one, because the obvious normalization is the
    /// wrong one here and reporting all three makes that visible rather than
    /// merely confusing.
    struct ResidualReport:Sendable {

        /// The Rigal-Gaches normwise backward error,
        ///
        ///     eta = ||A*x - b||_inf / ( ||A||_inf * ||x||_inf + ||b||_inf )
        ///
        /// This is the smallest `eta` for which the computed `x` is the EXACT
        /// solution of some perturbed system `(A + dA) x = b + db` with
        /// `||dA|| <= eta*||A||` and `||db|| <= eta*||b||`. It is the quantity
        /// LU-with-partial-pivoting actually bounds, and being a ratio of like
        /// to like it is invariant under rescaling of the system - which is why
        /// it, and not `relativeToDrive`, is what gets tested.
        let backwardError:Double

        /// `||A*x - b||_inf / ||b||_inf`.
        ///
        /// The historical measure, kept because it is informative about SCALING
        /// even though it says nothing about accuracy. `Assemble` writes a
        /// nonzero right-hand side only at the impulsed nodes, so `||b||_inf`
        /// is exactly `|U(s)|` - and `U(s)` falls off as 1/s^2, by ~3e4 across
        /// a 10 MHz band. Dividing by a collapsing denominator makes this climb
        /// with frequency no matter how well the solve went.
        let relativeToDrive:Double

        /// `||A||_inf * ||x||_inf / ||b||_inf`, the factor by which the two
        /// measures above differ. Large values are the signature of a badly
        /// scaled (not badly solved) system: the node block carries `s*C` while
        /// the segment block carries `s*M`, nothing equilibrates the resulting
        /// row-norm spread, and `||b||` is only the drive.
        let scaleRatio:Double
    }

    /// Multiplies the assembled system by a candidate solution and measures how
    /// well it was solved.
    ///
    /// Left in the code deliberately. This is the check that catches a system
    /// that is not being solved at all - catastrophic pivot growth, a matrix
    /// that reached LAPACK in the wrong layout, non-finite entries.
    ///
    /// Note the two things it does NOT catch. Ill conditioning is the first:
    /// partial pivoting is backward stable, so a system with a condition number
    /// of 1e14 still solves to a backward error of ~eps and passes here, while
    /// carrying a forward error 1e14 times larger. An assembly error - a
    /// flipped incidence
    /// sign, a row-surgery step applied in the wrong order, a block written at
    /// the wrong offset - produces a perfectly well-conditioned system with a
    /// perfectly clean solution to the WRONG equations. The backward error of
    /// that solve sits at machine precision and this check passes. Only
    /// `CompareSolvers` (the independent RK45 route through the same matrices)
    /// can find that class of bug. What this check buys is the converse: a
    /// backward error that is NOT at machine precision proves something is
    /// wrong before any physics is examined.
    ///
    /// Cost is O(size^2) - the same as the solve's right-hand side, but far
    /// cheaper than its O(size^3) factorization - and `Sweep` only samples it
    /// at every 512th contour point regardless.
    static func Residual(matrix:[Double], rhs:[Double], solution:[Complex<Double>], size:Int) -> ResidualReport {

        func modulus(_ z:Complex<Double>) -> Double {

            return (z.real * z.real + z.imaginary * z.imaginary).squareRoot()
        }

        var worst = 0.0         // ||A*x - b||_inf
        var driveNorm = 0.0     // ||b||_inf
        var matrixNorm = 0.0    // ||A||_inf, the largest absolute row sum
        var solutionNorm = 0.0  // ||x||_inf

        for col in 0..<size {

            solutionNorm = max(solutionNorm, modulus(solution[col]))
        }

        for row in 0..<size {

            var sum = Complex<Double>(0.0)
            var rowSum = 0.0

            for col in 0..<size {

                let i = 2 * (col * size + row)
                let a = Complex(matrix[i], matrix[i + 1])

                sum = sum + a * solution[col]
                rowSum += modulus(a)
            }

            matrixNorm = max(matrixNorm, rowSum)

            let b = Complex(rhs[2 * row], rhs[2 * row + 1])
            let difference = sum - b

            worst = max(worst, modulus(difference))
            driveNorm = max(driveNorm, modulus(b))
        }

        // The denominator cannot vanish for any system that has both a matrix
        // and a solution, so the guards are only defending against a degenerate
        // all-zero case rather than anything that happens in practice.
        let backwardScale = matrixNorm * solutionNorm + driveNorm

        return ResidualReport(backwardError: backwardScale > 0.0 ? worst / backwardScale : worst,
                              relativeToDrive: driveNorm > 0.0 ? worst / driveNorm : worst,
                              scaleRatio: driveNorm > 0.0 ? matrixNorm * solutionNorm / driveNorm : 0.0)
    }
}
