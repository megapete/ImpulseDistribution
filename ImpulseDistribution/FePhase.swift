//
//  FePhase.swift
//  ImpulseDistribution
//
//  The bridge between the phase model and PchAxiSymFE.
//

import Foundation
import AppKit
import ComplexModule
import PchBasePackage
import PchMatrixPackage
import PchAxiSymFE

/// The finite-element side of one phase: the axisymmetric (r, z) model of the core window, the coil sections in it, and the
/// quantities the program takes back out of it — the segment-to-segment inductance matrix, and each segment's eddy losses.
///
/// # One terminal per segment
///
/// `PchAxiSymFE` builds its flux-linkage matrix per *terminal*: `Λ_ts = b_tᵀ x_s`, one solve per terminal against a single
/// factorization. A winding-level model gives a terminal to a whole winding and gets a 2×2 or 3×3 impedance matrix out. This
/// program needs the matrix one row per **Segment**, so every section here is given its own terminal number, equal to its index
/// in `sections`. Column `s` of the matrix is then the field of one disc excited on its own, and the matrix that comes back is
/// exactly the self- and mutual-inductance matrix the impulse solver runs on.
///
/// The real excitation — every segment carrying its own share of the amp-turns — is expressible in the same model, since a
/// terminal current is set per terminal and there is one per segment. So the eddy-loss solve and the inductance sweep share one
/// mesh and one factorization; only the right-hand side differs.
///
/// # Boundary conditions
///
/// Rabin's arrangement, which is the one the program's physics is founded on:
///
/// * the core leg and both yokes are infinitely permeable, so flux enters them perpendicularly — `.fluxNormal`;
/// * the tank wall is a flux line, `u = rA_φ = 0` — `.fluxParallel`.
///
/// The tank condition is not a detail. Every column of an inductance matrix excites one section *alone*, which is a net
/// ampere-turn-unbalanced excitation, and a model with every boundary flux-normal (Andersen's arrangement, the right one for a
/// balanced short-circuit leakage run) is pure Neumann and has no solution for it: `PchAxiSymFE` rejects such an excitation
/// rather than let the gauge node absorb the imbalance and return a plausible, meaningless field. Giving the tank a Dirichlet
/// condition makes the system nonsingular, and it is also the closer reading of a real tank, whose steel is many skin depths
/// thick at power frequency and behaves as a flux barrier rather than as a permeable return path.
///
/// The domain starts at the core surface (`InnerRadialBoundary.coreSurface`) rather than at the axis, so the core leg itself is
/// not meshed — the same window the old model used, and the same one FLD8/FLD12 use.
actor FePhase {

    // MARK: Inputs

    /// One coil section of the FE model, in the order `PhaseModel.CoilSegments()` returns them. The index in this array is the
    /// section's terminal number, its index into the inductance matrix, and its `Segment` ordinal — all three are the same thing
    /// by construction, which is what lets the caller read a row of the matrix back onto a Segment without a lookup table.
    struct SectionInput: Sendable {

        let name: String
        /// Live geometry, taken from the owning Segment's `rect` (never from the pristine BasicSection radii).
        let innerRadius: Double
        let outerRadius: Double
        let zMin: Double
        let zMax: Double
        /// Series turns in the section.
        let turns: Double
        /// Strands making up one turn — every conductor in parallel, CTC strands included. Sets the metal volume the eddy-loss
        /// post-process scales its loss density by, and the copper area the DC resistance is taken over.
        let strandsPerTurn: Double
        /// Bare strand dimensions.
        let strandRadial: Double
        let strandAxial: Double
        /// Series RMS current through the section for the loss run. Signed: a winding that carries its amp-turns in the opposite
        /// sense to the reference winding gets a negative current. Plays no part in the inductance sweep, which excites one
        /// ampere at a time.
        var seriesRmsCurrent: Double
    }

    struct FePhaseError: LocalizedError {

        enum ErrorType: Sendable {
            case noSections
            case sectionOutsideWindow(String)
            case sectionOutsideTank(String, sectionOuterRadius: Double, tankRadius: Double)
            case degenerateSection(String)
            case noInductanceMatrix
        }

        let type: ErrorType

        var errorDescription: String? {

            switch type {
            case .noSections:
                return "The finite-element model has no coil sections."
            case .sectionOutsideWindow(let name):
                return "Coil section '\(name)' does not fit inside the core window."
            case .sectionOutsideTank(let name, let sectionOuterRadius, let tankRadius):
                return String(format: "Coil section '%@' reaches %.1f mm from the core centre, but the tank wall is at %.1f mm. Check the tank depth in the design file (it is twice the core-centre-to-tank distance).", name, sectionOuterRadius * 1000.0, tankRadius * 1000.0)
            case .degenerateSection(let name):
                return "Coil section '\(name)' has a zero (or negative) radial build or height."
            case .noInductanceMatrix:
                return "The inductance matrix has not been calculated."
            }
        }
    }

    /// Frequency of the loss run, Hz. The real (`σ = 0`) system does not depend on it — see `realSystemIsFrequencyIndependent` in
    /// the package's test suite — but the eddy-loss post-process does, and so does the skin-depth correction in it.
    let frequency: Double

    private(set) var sections: [SectionInput]

    let geometry: TransformerGeometry

    // MARK: Mesh sizing
    //
    // Stated physically, as the package's API demands. These are the numbers to revisit if the model is ever too coarse or too
    // slow; nothing else about the mesh is a free parameter, because the mesher is a tensor product of the geometry's own
    // coordinates. Every disc face and every duct is a mandatory grid line whatever these say, so the counts below buy
    // resolution *within* a disc and within the oil, not the resolution of the winding stack itself.

    /// Elements across a section radially and axially. Two apiece: a disc is a region of uniform current density with no
    /// internal structure to resolve, and its own field is not what the program reads — the flux density at its faces is.
    static let elementsAcrossSection = 2

    /// Largest element in oil, ducts and insulation, m (20 mm). The ducts between discs are thinner than this and are graded to
    /// match the discs either side of them; this bounds the big empty spans — the hilo, and the run out to the tank.
    static let maximumGapElementSize = 0.020

    // MARK: Derived state

    /// Built once, on first use, and reused: the matrix depends on the mesh, the materials and the frequency, none of which
    /// change over this object's life. Only the right-hand side changes between the loss run and the inductance sweep.
    private var factorization: MagnetodynamicFactorization<Double>? = nil

    /// The segment-to-segment inductance matrix, henries. `nil` until `CalculateInductanceMatrix` has run.
    private(set) var inductanceMatrix: PchMatrix? = nil

    /// Magnetic energy of the last loss run, joules (RMS phasors, so this is the time-average energy).
    private(set) var magneticEnergy: Double = 0.0

    // MARK: Initialization

    init(coreRadius: Double,
         windowHeight: Double,
         tankRadius: Double,
         frequency: Double,
         sections: [SectionInput]) throws {

        guard !sections.isEmpty else {

            throw FePhaseError(type: .noSections)
        }

        // The mesher clamps a coordinate that falls outside the domain onto it, which would turn a section that sticks out of the
        // window into a squashed or an empty region - a model that solves and quietly answers the wrong question. Catch it here,
        // where the section can still be named.
        for section in sections {

            guard section.outerRadius > section.innerRadius, section.zMax > section.zMin else {

                throw FePhaseError(type: .degenerateSection(section.name))
            }

            // The tank wall gets its own message: it comes from a single field of the design file, and when that field is wrong
            // (an exporter that writes 0) every section is outside it at once.
            guard section.outerRadius <= tankRadius else {

                throw FePhaseError(type: .sectionOutsideTank(section.name, sectionOuterRadius: section.outerRadius, tankRadius: tankRadius))
            }

            guard section.innerRadius >= coreRadius, section.zMin >= 0.0, section.zMax <= windowHeight else {

                throw FePhaseError(type: .sectionOutsideWindow(section.name))
            }
        }

        self.frequency = frequency
        self.sections = sections

        // ρ is pinned to PchBasePackage's rhoCopper so that the eddy loss the package computes and the I²R the program divides it
        // by are taken at the same resistivity. Leaving the package's own 20°C default in place would put the two about 0.2%
        // apart - harmless, but the per-unit eddy loss is a ratio of the two and there is no reason to introduce the difference.
        let coilSections = sections.enumerated().map { (index, input) in

            let strand = StrandGeometry(radialThickness: input.strandRadial,
                                        axialHeight: input.strandAxial,
                                        conductivity: 1.0 / rhoCopper)

            return CoilSection(name: input.name,
                               bounds: Rect(rMin: input.innerRadius, rMax: input.outerRadius,
                                            zMin: input.zMin, zMax: input.zMax),
                               turns: input.turns,
                               // One terminal per section - see the type comment.
                               terminal: index,
                               polarity: 1,
                               material: .strandedWinding(name: input.name, strand: strand))
        }

        self.geometry = TransformerGeometry(
            // Qualified: the program has a Core of its own (the model's core geometry), and this is the package's.
            core: PchAxiSymFE.Core(radius: coreRadius, windowBottom: 0.0, windowTop: windowHeight),
            tank: Tank(innerRadius: tankRadius, bottom: 0.0, top: windowHeight),
            sections: coilSections,
            backgroundMaterial: .oil,
            innerBoundary: .coreSurface,
            boundaryConditions: DomainBoundaryConditions(innerRadial: .fluxNormal,
                                                         tankWall: .fluxParallel,
                                                         tankBottom: .fluxNormal,
                                                         tankTop: .fluxNormal))
    }

    // MARK: Excitation

    /// Sets the series RMS current of one section for the loss run. Does not invalidate the factorization: the current is
    /// right-hand side data and the matrix does not depend on it.
    func SetSeriesRmsCurrentForSection(_ index: Int, rmsAmps: Double) {

        guard sections.indices.contains(index) else {

            DLog("Section index \(index) is out of range!")
            return
        }

        sections[index].seriesRmsCurrent = rmsAmps
    }

    func SeriesRmsCurrent(section index: Int) -> Double {

        guard sections.indices.contains(index) else {

            DLog("Section index \(index) is out of range!")
            return 0.0
        }

        return sections[index].seriesRmsCurrent
    }

    // MARK: The FE model

    /// Meshes and factorizes, or returns what was built earlier.
    private func GetFactorization() throws -> MagnetodynamicFactorization<Double> {

        if let factorization = self.factorization {

            return factorization
        }

        let sizing = MeshSizing(elementsAcrossSectionRadially: Self.elementsAcrossSection,
                                elementsAlongSectionAxially: Self.elementsAcrossSection,
                                maximumGapElementSize: Self.maximumGapElementSize,
                                gradeGapsTowardConductors: true)

        let mesh = try MeshBuilder(geometry: geometry, sizing: sizing).build(family: .t6)

        DLog("FE mesh: \(mesh.statistics)")

        // Double, not ComplexDouble: every region here is stranded, so σ = 0 in the field model everywhere and there is no jωσ
        // term to represent. The package refuses a real solve of a model that contains a solid conductor rather than silently
        // dropping the term, so this choice is checked rather than assumed. It is about four times cheaper.
        let problem = MagnetodynamicProblem<Double>(mesh: mesh, geometry: geometry)
        let result = try problem.factorize(frequency: frequency)

        self.factorization = result

        return result
    }

    /// The DC resistance of a section at 20 °C, ohms.
    ///
    /// `R = N · (mean turn length) · ρ / (copper area of one turn)`, with the mean turn length taken at the mean radius of the
    /// live geometry. Stranded windings have no `σ` in the field model by construction, so this is not something the FE solve
    /// can be asked for; it is arithmetic on the design data, and it exists here only as the denominator of the per-unit eddy
    /// loss the rest of the program works in.
    private func Resistance(section: SectionInput) -> Double {

        let turnCopperArea = section.strandsPerTurn * section.strandRadial * section.strandAxial

        guard turnCopperArea > 0 else {

            return 0.0
        }

        let meanTurnLength = π * (section.innerRadius + section.outerRadius)

        return section.turns * meanTurnLength * rhoCopper / turnCopperArea
    }

    /// Eddy loss of one section, as a fraction of that section's own I²R.
    struct EddyLossPU: Sendable {

        let radial: Double
        let axial: Double
    }

    /// Solves the whole model at the currents that have been set, and returns each section's eddy loss in per-unit of its I²R
    /// loss. Also updates `magneticEnergy`.
    ///
    /// The loss is the analytic strip formula applied element by element over each region — `σω²d²B²/12` for RMS `B`, with the
    /// radial field acting across the strand's axial height and the axial field across its radial thickness. That is the correct
    /// treatment for a stranded winding and the one FLD12 uses; the only deliberate difference from FLD12 is that the 1-D
    /// skin-depth correction is left on (it is 0.9994 for a 2 mm strand at 60 Hz, and stops being negligible for harmonics).
    func CalculateEddyLosses() throws -> [EddyLossPU] {

        let factorization = try GetFactorization()

        var currents: [Int: Double] = [:]
        for (index, section) in sections.enumerated() {

            currents[index] = section.seriesRmsCurrent
        }

        let solution = try factorization.solve(terminalCurrents: currents)
        let fields = solution.elementFields()

        self.magneticEnergy = solution.magneticEnergy(elementFields: fields)

        // Metal volume from the turn count and the strand geometry, not from a stacking factor: it is how a designer states a
        // winding, and it is the same quantity the resistance above is taken over. The package hands the closure a CoilSection,
        // which carries no index, so the strand count is looked up by name - the names are one per section and unique.
        let strandsPerTurn = Dictionary(uniqueKeysWithValues: sections.map { ($0.name, $0.strandsPerTurn) })

        let losses = EddyLoss.strandedLoss(
            solution: solution,
            elementFields: fields,
            metalFraction: { section in

                .fromTurns(turns: section.turns,
                           strandsInParallel: strandsPerTurn[section.name] ?? 1)
            })

        var result = [EddyLossPU](repeating: EddyLossPU(radial: 0, axial: 0), count: sections.count)

        for loss in losses {

            guard sections.indices.contains(loss.sectionIndex) else {

                continue
            }

            let section = sections[loss.sectionIndex]
            let current = section.seriesRmsCurrent
            let resistiveLoss = current * current * Resistance(section: section)

            // A section carrying no current has no I²R to be a fraction of, and its eddy loss is zero as well. Report zero rather
            // than the 0/0 that a per-unit of nothing actually is - a NaN here runs silently all the way into the loss display.
            guard resistiveLoss > 0 else {

                continue
            }

            result[loss.sectionIndex] = EddyLossPU(radial: loss.lossFromRadialField / resistiveLoss,
                                                   axial: loss.lossFromAxialField / resistiveLoss)
        }

        return result
    }

    /// A progress report emitted while the inductance matrix is being calculated. One section - one solve, one column of the
    /// matrix - is one unit of work, so this is an exact count rather than an estimate.
    ///
    /// It exists so that nothing outside this file has to name a `PchAxiSymFE` type. That is not tidiness: the package publishes
    /// a `Core` of its own, and importing it into `AppController` - which has a `currentCore:Core?` of the program's own Core -
    /// would make that name ambiguous throughout the file.
    struct InductanceProgress: Sendable {

        /// The number of sections whose inductances have been calculated so far.
        let completedSections: Int

        /// The total number of sections in the phase.
        let totalSections: Int

        var fractionComplete: Double {

            return totalSections > 0 ? Double(completedSections) / Double(totalSections) : 0.0
        }
    }

    /// Calculates the segment-to-segment inductance matrix and stores it in `inductanceMatrix`.
    ///
    /// One solve per segment against a single factorization. The work is done synchronously on this actor rather than being
    /// broken into child tasks: the solves share one factorization and `PchAxiSymFE` serializes them internally, so there is no
    /// parallelism to be had at this level, and the package's own checkpoints make the sweep cancellable at one-column
    /// granularity anyway.
    ///
    /// - parameter progress: an optional AsyncStream continuation that receives one update per completed column. It is *not*
    ///   finished here; the caller owns it.
    func CalculateInductanceMatrix(progress: AsyncStream<InductanceProgress>.Continuation? = nil) async throws {

        self.inductanceMatrix = nil

        let factorization = try GetFactorization()

        let l = try factorization.inductanceMatrix { update in

            progress?.yield(InductanceProgress(completedSections: update.completedTerminals,
                                               totalSections: update.totalTerminals))
        }

        let n = l.count
        let matrix = PchMatrix(matrixType: .general, numType: .Double, rows: UInt(n), columns: UInt(n))

        // `Λ = Bᵀ A⁻¹ B` is symmetric exactly, but it is *computed* column by column, so the two halves differ in the last bits.
        // Average them: the program factorizes this matrix as Cholesky and checks it for symmetry first, and neither should turn
        // on round-off.
        for i in 0..<n {

            await matrix.SetDoubleValue(value: l[i][i], row: i, col: i)

            for j in 0..<i {

                let mean = (l[i][j] + l[j][i]) / 2
                await matrix.SetDoubleValue(value: mean, row: i, col: j)
                await matrix.SetDoubleValue(value: mean, row: j, col: i)
            }
        }

        self.inductanceMatrix = matrix
    }

    /// The magnetic energy implied by the inductance matrix and the currents currently set, joules at peak current.
    ///
    /// DelVecchio (3rd ed.) eq. 4.22: `W = ½ ΣᵢΣⱼ Mᵢⱼ Îᵢ Îⱼ`. The currents held here are RMS, so they are scaled to peak first —
    /// the √2s cancel against the ½, but writing them out keeps the equation the one in the book.
    func EnergyFromInductance() async -> Double {

        guard let matrix = self.inductanceMatrix else {

            DLog("Inductance matrix not yet calculated.")
            return 0.0
        }

        var twicePeakEnergy = 0.0

        for i in sections.indices {

            let iPeak = sections[i].seriesRmsCurrent * sqrt(2)

            for j in sections.indices {

                let jPeak = sections[j].seriesRmsCurrent * sqrt(2)

                guard let m: Double = await matrix[i, j] else {

                    DLog("Could not read the inductance matrix at [\(i), \(j)]!")
                    return 0.0
                }

                twicePeakEnergy += m * iPeak * jPeak
            }
        }

        return twicePeakEnergy / 2
    }
}

/// The electrostatic side of the phase: the segment-to-segment shunt capacitance matrix, fringing included, as a reference for
/// the analytic shunt booking (TODO item 6d).
///
/// # The model
///
/// The same window as the magnetic model, with the boundaries read electrically: the core surface, both yokes and the tank wall
/// are earthed metal, so all four faces of the (r, z) domain are grounded. Every Segment the model holds - coil Segments, static
/// rings and radial shields alike - is one equipotential electrode on its live `rect`. Each hilo, and the gap from the outermost
/// coil to the tank, is filled with the relative permittivity the analytic formula for that gap uses, so that the FE and the
/// formulas differ in the geometry only. Everything else in the window is oil.
///
/// What it does not model, by construction: the adjacent phase, which is not axisymmetric and keeps its analytic term; and the
/// tank as Kulkarni has it, a plane beside a cylinder, which here is a coaxial cylinder instead. The outermost coil's capacitance
/// to the tank is therefore not expected to reproduce `OuterShuntCapacitance`, and a difference there is not a bug.
///
/// Pairs of Segments in the same coil come out of the solve as well. The caller should drop them: DelVecchio's series
/// capacitance already accounts for the field between neighbouring discs.
///
/// Like `FePhase`, nothing here names a `PchAxiSymFE` type in its interface, so that callers need not import the package and its
/// `Core`.
enum FeShuntReference {

    /// One electrode, in metres, with z measured up from the bottom yoke.
    struct ElectrodeInput: Sendable {

        let name: String
        let r1: Double
        let r2: Double
        let z1: Double
        let z2: Double
    }

    /// A region of uniform relative permittivity. Later entries win where two overlap; electrodes win over all of them.
    struct DielectricInput: Sendable {

        let name: String
        let r1: Double
        let r2: Double
        let z1: Double
        let z2: Double
        let relativePermittivity: Double
    }

    /// The capacitance matrix on one mesh.
    struct Result: Sendable {

        /// `maxwell[j][i]` is the charge on electrode `j`, coulombs, with electrode `i` at 1 V and everything else at 0 V.
        let maxwell: [[Double]]
        let nodeCount: Int
        let seconds: Double

        /// The capacitance between electrodes `i` and `j`, F.
        func Mutual(_ i: Int, _ j: Int) -> Double {

            return -0.5 * (maxwell[i][j] + maxwell[j][i])
        }

        /// Electrode `i`'s capacitance to the grounded core, yokes and tank, F.
        func ToGround(_ i: Int) -> Double {

            return maxwell[i].reduce(0.0, +)
        }

        /// `max |C_ij − C_ji| / max C_ii`: the extraction is symmetric in exact arithmetic, so this is the solver's round-off.
        var asymmetry: Double {

            var worst = 0.0
            var scale = 0.0

            for i in maxwell.indices {

                scale = max(scale, abs(maxwell[i][i]))

                for j in 0..<i {

                    worst = max(worst, abs(maxwell[i][j] - maxwell[j][i]))
                }
            }

            return scale > 0.0 ? worst / scale : 0.0
        }
    }

    /// Mesh sizing. The magnetic model's values: two elements across a section, which is all an equipotential needs (its
    /// interior is not even solved for), and 20 mm at most in the oil. Every electrode face and every dielectric boundary is a
    /// grid line whatever these say, and the gaps are graded down to the electrodes' element size at their faces.
    static let elementsAcrossSection = 2
    static let maximumGapElementSize = 0.020

    /// Solves the capacitance matrix on the base mesh and then on `refinements` successively halved ones, for a convergence
    /// check. Each level is one factorization and one solve per electrode; a level costs about four times the one before.
    ///
    /// - parameter progress: called with (level, electrodes done, electrodes in all), from whatever thread the solver is on.
    static func Solve(coreRadius: Double,
                      windowHeight: Double,
                      tankRadius: Double,
                      electrodes: [ElectrodeInput],
                      dielectrics: [DielectricInput],
                      refinements: Int = 0,
                      progress: (@Sendable (Int, Int, Int) -> Void)? = nil) throws -> [Result] {

        // An electrode is a section to the mesher - that is what puts grid lines on its faces - and its material is never read,
        // because no node inside it is solved for.
        let sections = electrodes.enumerated().map { (index, input) in

            CoilSection(name: input.name,
                        bounds: Rect(rMin: input.r1, rMax: input.r2, zMin: input.z1, zMax: input.z2),
                        turns: 1,
                        terminal: index,
                        material: Material(name: input.name))
        }

        let insulation = dielectrics.map { input in

            (name: input.name,
             bounds: Rect(rMin: input.r1, rMax: input.r2, zMin: input.z1, zMax: input.z2),
             material: Material(name: input.name, relativePermittivity: input.relativePermittivity))
        }

        // `.fluxParallel` is the mesh's name for a Dirichlet face, which here is a grounded one.
        let geometry = TransformerGeometry(
            core: PchAxiSymFE.Core(radius: coreRadius, windowBottom: 0.0, windowTop: windowHeight),
            tank: Tank(innerRadius: tankRadius, bottom: 0.0, top: windowHeight),
            sections: sections,
            insulationRegions: insulation,
            backgroundMaterial: Material(name: "oil", relativePermittivity: εOil),
            innerBoundary: .coreSurface,
            boundaryConditions: DomainBoundaryConditions(innerRadial: .fluxParallel,
                                                         tankWall: .fluxParallel,
                                                         tankBottom: .fluxParallel,
                                                         tankTop: .fluxParallel))

        let sizing = MeshSizing(elementsAcrossSectionRadially: elementsAcrossSection,
                                elementsAlongSectionAxially: elementsAcrossSection,
                                maximumGapElementSize: maximumGapElementSize,
                                gradeGapsTowardConductors: true)

        var mesh = try MeshBuilder(geometry: geometry, sizing: sizing).build(family: .t6)
        var results: [Result] = []

        for level in 0...max(0, refinements) {

            if level > 0 {

                mesh = try mesh.refined()
            }

            let start = Date()
            let solver = CapacitanceMatrixSolver(mesh: mesh, geometry: geometry)
            let matrix = try solver.solve { done, total in

                progress?(level, done, total)
            }

            results.append(Result(maxwell: matrix.maxwell, nodeCount: mesh.nodeCount, seconds: Date().timeIntervalSince(start)))
        }

        return results
    }
}
