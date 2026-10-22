//
//  SimulationModel.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2024-01-30.
//

import Foundation
import Cocoa
import Accelerate
import ComplexModule
import RealModule
import PchBasePackage
import PchMatrixPackage

extension PchMatrix {
    
    func ZeroRow(row:Int) {

        if row < 0 || row >= self.rows {

            ALog("ZeroRow: row \(row) is outside 0..<\(self.rows).")
            return
        }
        
        for col in 0..<self.columns {
            
            if self.numType == .Double {
                
                // self[row, col] = 0.0
                self.SetDoubleValue(value: 0.0, row: row, col: col)
            }
            else if self.numType == .Complex {
                
                // self[row, col] = Complex<Double>.zero
                self.SetComplexValue(value: Complex<Double>.zero, row: row, col: col)
            }
            else {

                ALog("ZeroRow: the matrix numType is \(self.numType), which is neither .Double nor .Complex - row \(row) has been left partly zeroed (columns 0..<\(col)).")
                return
            }
        }
    }

    func AddRow(fromIndex:Int, toIndex:Int) {

        if fromIndex < 0 || fromIndex >= self.rows || toIndex < 0 || toIndex >= self.rows {

            ALog("AddRow: fromIndex \(fromIndex) and/or toIndex \(toIndex) is outside 0..<\(self.rows).")
            return
        }
        
        for col in 0..<self.columns {
            
            if self.numType == .Double {
                
                guard let toValue:Double = self[toIndex, col], let fromValue:Double = self[fromIndex, col] else {

                    ALog("AddRow: could not read Double values at [\(toIndex), \(col)] and/or [\(fromIndex), \(col)] of a \(self.rows) x \(self.columns) matrix - row \(toIndex) is now partly summed (columns 0..<\(col)).")
                    return
                }
                
                let newValue = toValue + fromValue
                // self[toIndex, col] = newValue
                self.SetDoubleValue(value: newValue, row: toIndex, col: col)
            }
            else if self.numType == .Complex {
                
                guard let toValue:Complex<Double> = self[toIndex, col], let fromValue:Complex<Double> = self[fromIndex, col] else {

                    ALog("AddRow: could not read Complex values at [\(toIndex), \(col)] and/or [\(fromIndex), \(col)] of a \(self.rows) x \(self.columns) matrix - row \(toIndex) is now partly summed (columns 0..<\(col)).")
                    return
                }
                
                let newValue = toValue + fromValue
                // self[toIndex, col] = newValue
                self.SetComplexValue(value: newValue, row: toIndex, col: col)
            }
            else {

                ALog("AddRow: the matrix numType is \(self.numType), which is neither .Double nor .Complex - row \(toIndex) is now partly summed (columns 0..<\(col)).")
                return
            }
        }
    }
}

private extension Array<Double> {
    
    static func *(scalar:Double, rhs:[Double]) -> [Double] {
        
        return rhs.map({scalar * $0})
    }
    
    static func *(lhs:[Double], scalar:Double) -> [Double] {
        
        return lhs.map({$0 * scalar})
    }
    
    static func +(lhs:[Double], rhs:[Double]) -> [Double] {
        
        // from https://stackoverflow.com/questions/41453942/add-elements-of-two-arrays-in-swift-without-appending-together
        return zip(lhs,rhs).map(+)
    }
    
    static func -(lhs:[Double], rhs:[Double]) -> [Double] {
        
        // from https://stackoverflow.com/questions/41453942/add-elements-of-two-arrays-in-swift-without-appending-together
        return zip(lhs,rhs).map(-)
    }
}

actor SimulationModel {
    
    struct WaveForm {
        
        // Only the Full Wave option is actually usable
        enum Types:String, CaseIterable {
            
            case FullWave = "Full Wave (1.2 x 50 µs)"
            case ChoppedWave = "Chopped Wave (1.2 x 3.0 µs)"
            case Switching = "Switching (100 x 1000 µs)"
        }
        
        let pkVoltage:Double
        let type:Types
        
        var timeToPeak:Double {
            
            get {
                
                switch self.type {
                    
                case .FullWave:
                    return 1.2E-6
                    
                case .ChoppedWave:
                    return 1.2E-6
                    
                case .Switching:
                    return 100.0E-6
                }
            }
        }
        
        var timeToZero:Double {
            
            get {
                
                switch self.type {
                    
                case .FullWave:
                    return 100.0E-6
                    
                case .ChoppedWave:
                    return 50.0E-6
                    
                case .Switching:
                    return 1000.0E-6
                }
            }
        }
            
        init(type:Types, pkVoltage:Double) {
            
            self.type = type
            self.pkVoltage = pkVoltage
        }
        
        func V(_ t:Double) -> Double
        {
            if (self.type == Types.FullWave)
            {
                let k1 = 14285.0
                let k2 = 3.3333333E6
                
                let v0 = 1.03 * pkVoltage
                
                return v0 * (e(-k1*t) - e(-k2*t))
            }

            ALog("WaveForm.V(t): no closed form for waveform type '\(self.type)' - only .FullWave is implemented. Returning 0, which will look like a dead source.")
            return 0.0
        }
        
        func dV(_ t:Double) -> Double
        {
            if (self.type == Types.FullWave)
            {
                let k1 = 14285.0
                let k2 = 3.3333333E6

                let v0 = 1.03 * pkVoltage

                let result = v0 * (k2 * e(-k2 * t) - k1 * e(-k1 * t))

                return result
            }

            ALog("WaveForm.dV(t): no closed form for waveform type '\(self.type)' - only .FullWave is implemented. Returning 0, which will look like a dead source.")
            return 0.0
        }

        /// The Laplace transform U(s) of `V(t)`.
        ///
        /// For the full wave, V(t) = v0*(exp(-k1*t) - exp(-k2*t)), and the
        /// transform of exp(-a*t) is 1/(s+a), so
        ///
        ///     U(s) = v0 * ( 1/(s+k1) - 1/(s+k2) )
        ///
        /// This is EXACT - there is no numerical transform of the source
        /// anywhere in the frequency-domain path, and therefore no error from
        /// representing it.
        ///
        /// Note the frequency-domain solver drives the impulsed node with this
        /// (the voltage) rather than with `dV` (its derivative), which is what
        /// the RK45 path integrates. Imposing the voltage algebraically is
        /// both simpler and drift-free.
        ///
        /// Combining over a common denominator gives
        /// v0*(k2-k1)/((s+k1)*(s+k2)), which shows the 1/s^2 decay at large s
        /// that forces `FrequencyDomainSolver` to subtract the asymptote
        /// before inverting - see that file's header.
        func U(_ s:Complex<Double>) -> Complex<Double> {

            if self.type == Types.FullWave {

                let k1 = 14285.0
                let k2 = 3.3333333E6

                let v0 = 1.03 * pkVoltage

                return Complex(v0) * (Complex(1.0) / (s + Complex(k1)) - Complex(1.0) / (s + Complex(k2)))
            }

            ALog("WaveForm.U(s): no Laplace transform for waveform type '\(self.type)' - only .FullWave is implemented. Returning 0, which will make the whole frequency-domain solve return zeros.")
            return Complex(0.0)
        }
    }
    
    /// The inductance matrix in CHOLESKY-FACTORIZED form. Used by the RK45
    /// path, which only ever solves with it.
    let M:PchMatrix

    /// The inductance matrix itself, unfactorized.
    ///
    /// The frequency-domain solver needs the actual matrix, not a
    /// factorization of it, because it builds `s*M + Z(s)` as a new system at
    /// every frequency rather than solving against M. Reading `M` here instead
    /// would silently assemble the Cholesky factor as though it were the
    /// inductance - a mistake that produces a plausible-looking but entirely
    /// wrong answer.
    let unfactoredM:PchMatrix

    let baseC:PchMatrix
    var modelC:PchMatrix
    
    // The A and B matrices store their 1's and -1's in the column-major banded-matrix form defined in the BLAS
    let A:[Double] = []
    let B:[Double] = []
    
    /// vDropInd is the voltage drop across a segment represented as an array with the segment index as the index into the COIL-SEGMENT array, and a 2-element tuple as the value. The tuple holds the node indices: (i-1, i), where 'i' is as defined in DelVecchio
    var vDropInd:[(belowNode:Int, aboveNode:Int)] = []
    /// iDrop is the current drop at a node represented as an array with the node index as the index into the NODE array, and a 2-element tuple as the value. The tuple holds the segment indices: (j, j+1), where 'j' is as defined in Delvecchio
    var iDropInd:[(belowSeg:Int, aboveSeg:Int)] = []
    
    /// `Sendable` so that `NetworkSnapshot` can carry it out of the actor and
    /// into the parallel frequency sweep. Every stored property is a `Double`,
    /// so the conformance is unconditional.
    struct Resistance:Sendable {

        let dc:Double
        let effRadius:Double
        let eddyPURadial:Double
        let eddyPUAxial:Double
        let strandRadial:Double
        let strandAxial:Double

        /// The effective AC resistance of the segment at a given frequency.
        ///
        /// # The model
        ///
        /// Three additive contributions, each scaled from its 60 Hz value by a
        /// dimensionless Dowell shape ratio (see `ConductorImpedance` for the
        /// functions themselves and for why this replaced DelVecchio 12.103 &
        /// 12.104):
        ///
        ///     R(f) = R_dc * [   F_R(xi_r(f))  / F_R(xi_r(60))
        ///                     + eddyPURadial * G_R(xi_ax(f)) / G_R(xi_ax(60))
        ///                     + eddyPUAxial  * G_R(xi_ra(f)) / G_R(xi_ra(60)) ]
        ///
        /// # Which strand dimension pairs with which eddy component
        ///
        /// This preserves the pairing of the original implementation exactly:
        ///
        ///     eddyPURadial  <->  strandAxial     (radial eddy loss is driven
        ///                                         by the AXIAL leakage field,
        ///                                         which diffuses across the
        ///                                         strand's axial dimension)
        ///     eddyPUAxial   <->  strandRadial    (and vice versa)
        ///
        /// The crossed pairing looks like a bug and is not - it is the same as
        /// the original code, where `eddyRadialFactor` divided by `bAx` and
        /// `eddyAxialFactor` divided by `bRa`. Do not "fix" it without
        /// checking the design-file convention first.
        ///
        /// # Anchoring at 60 Hz
        ///
        /// At f = 60 every ratio is exactly 1, so this returns
        /// `dc * (1 + eddyPURadial + eddyPUAxial)` - precisely the resistance
        /// the Excel design file describes. Everything else is scaled from
        /// that anchor, so no absolute magnitude calibration is involved.
        ///
        /// # Guarantees
        ///
        /// The result is always >= `dc` and always finite for any input
        /// frequency, including zero and negative ones. The NaN path that the
        /// old implementation had (a negative frequency reaching `sqrt`) does
        /// not exist here.
        ///
        /// - parameter newFreq: The frequency of interest, in Hz.
        func EffectiveResistanceAt(newFreq:Double) -> Double {

            let skin = ConductorImpedance.SkinFactorRatio(thickness: effRadius, frequency: newFreq)

            let eddyRadial = eddyPURadial == 0.0 ? 0.0 : eddyPURadial * ConductorImpedance.EddyFactorRatio(thickness: strandAxial, frequency: newFreq)
            let eddyAxial = eddyPUAxial == 0.0 ? 0.0 : eddyPUAxial * ConductorImpedance.EddyFactorRatio(thickness: strandRadial, frequency: newFreq)

            return dc * (skin + eddyRadial + eddyAxial)
        }
    }
    
    var R:[Resistance] = []

    /// The single frequency at which the RK45 cross-check evaluates every
    /// segment's resistance. From DelVecchio 3E 12.11.2 (between eqs 12.103
    /// and 12.104).
    ///
    /// A time-marching solver can only carry ONE resistance per segment for
    /// the whole run - R cannot vary with frequency in the time domain without
    /// a convolution. That limitation is why the old `DoSimulate` ran the
    /// entire simulation twice: once to produce currents, then an FFT of those
    /// currents to guess a per-segment "fundamental frequency", then again
    /// with the guesses.
    ///
    /// That whole scheme is gone. The frequency-domain solver evaluates R at
    /// each frequency exactly, so nothing needs to be estimated. What remains
    /// here is a fixed frequency for the RK45 path only.
    ///
    /// **Comparing the two solvers:** they will not agree unless both use the
    /// same R. Pin the frequency-domain solver to a constant resistance with
    /// `NetworkSnapshot.resistanceFrequencyOverride` set to this value; then
    /// the two are solving identical equations and any disagreement is a real
    /// numerical difference rather than a modelling one.
    static let defaultEddyFreq = 0.15E6


    var impulsedNodes:Set<Node> = []
    var groundedNodes:Set<Node> = []
    var floatingNodes:Set<Node> = []
    
    /// The very large resistance to ground that stands in for "this lead goes nowhere" (DelVecchio 3E, just after eq. 14.5).
    ///
    /// # It is deliberately inert, and it is not the fix for a node that reads zero
    ///
    /// At 1e50 the conductance it adds is 1e-50, which is nothing next to any admittance in the matrix. That is on purpose. The
    /// reason DelVecchio adds Rs at all is that a node with no galvanic path leaves a time-domain formulation with nothing to
    /// determine it; here every node carries its own row of the nodal capacitance matrix, and a floating lead is coupled to the
    /// rest of the winding and to ground capacitively whether anything is tied to it or not. The system is non-singular without
    /// Rs, and `Assemble` includes the term only so that the frequency-domain and RK45 paths are solving identical equations.
    ///
    /// So if a lead comes back at exactly zero, Rs is not what to reach for: an exact zero is what the Dirichlet row surgery
    /// writes, which means the model has that node in `groundedNodes`. Ask `PhaseModel.ResolveNodeConnectivity` why - it is the
    /// one place that decides, and `SelfTest`'s node-classification table prints its answer for every node in the model.
    ///
    /// Lowering this to something physical (a bleed resistor, say) would be a modelling change and not a numerical one: it would
    /// put a real conductance on the node and move every result. Leave it alone unless that is what is wanted.
    var floatingResistanceToGround = 1.0E50
    
    var finalConnectedNodes:[Node:Set<Node>] = [:]
    
    /// Initialize the simulation model using the PhaseModel
    /// - parameter model: A properly set-up phase model, complete with grounding and impulsed nodes
    init?(model:PhaseModel) async {
        
        guard await !model.nodes.isEmpty, await !model.segments.isEmpty, await model.M != nil, await model.unfactoredM != nil, await model.C != nil else {

            DLog("Model is not complete!")
            return nil
        }

        // C is indexed by node number, so a C built for a different numbering is not merely the wrong size: every row past the
        // first renumbered node belongs to a different node, and the row surgery below silently skips what falls off the end.
        guard await model.C!.rows == model.nodes.count else {

            ALog("The capacitance matrix is \(await model.C!.rows) square but the model has \(await model.nodes.count) nodes - C was not rebuilt after the nodes were renumbered.")
            return nil
        }

        self.M = await model.M!
        self.unfactoredM = await model.unfactoredM!

        // THESE MUST BE COPIES. PchMatrix IS AN ACTOR, THEREFORE A REFERENCE TYPE.
        //
        // 'model.C' is documented as the basic, UNMODIFIED capacitance matrix, and the whole rebuild-every-run guarantee rests on
        // it staying that way: doCreateSimulationModel() re-reads it and redoes the row surgery below against the terminations and
        // jumpers as they now stand. Assigning it here without copying handed this init the PhaseModel's own matrix, and the
        // surgery - ZeroRow, AddRow, the 1/-1 pair that ties a merged node to the one it was kept for - was written straight into
        // it. The next run then started from the previous run's result, so every Dirichlet row and every merge ever applied
        // survived the connector that asked for it. A jumper between two leads left them shorted (V equal, difference identically
        // zero) for the rest of the session even after it was deleted, and the only way to get a correct answer for a new
        // connection scheme was to make it the FIRST scheme simulated after the matrices were recalculated.
        //
        // Two separate copies: 'baseC' is the pristine network - the SPICE/NetworkSnapshot export and the RK45 sizing read it -
        // and 'modelC' is the one the surgery is done on.
        self.baseC = await PchMatrix(srcMatrix: model.C!)
        self.modelC = await PchMatrix(srcMatrix: model.C!)

        // WHO IS AT GROUND POTENTIAL IS THE MODEL'S QUESTION, NOT THIS ROUTINE'S.
        //
        // PhaseModel.ResolveNodeConnectivity resolves every jumper and returns the classification: which nodes are held at the
        // impulse, which at ground, which are genuinely floating, and which remain shorted to each other without being tied to
        // either. This used to be done here, with an ad-hoc reduction of the jumper graph that was not a union-find and produced
        // OVERLAPPING groups for a chain of three or more nodes - see the long note on NodeConnectivity for what that did to the
        // row surgery. It is a property of the model, several things besides this one need the answer, and there is exactly one
        // right answer, so there is exactly one place that computes it.
        let connectivity:PhaseModel.NodeConnectivity

        do {

            connectivity = try await model.ResolveNodeConnectivity()
        }
        catch {

            // A jumper that does not land on a node at both ends means the node topology does not match the connectors, which in
            // practice means a Segment was replaced without its connections being remapped (see UpdateConnectors). Fail the whole
            // init rather than carry on: a simulation model built around a connection it cannot resolve returns a plausible
            // wrong answer, and ALog only traps in DEBUG so a Release build would not even complain.
            ALog("Cannot build the simulation model: \(error.localizedDescription)")
            return nil
        }

        if connectivity.shortedSource {

            DLog("An impulsed node is shorted to ground through the jumpers - the group has been taken as grounded.")
        }

        let nodesByNumber = await Dictionary(uniqueKeysWithValues: model.nodes.map({ ($0.number, $0) }))

        func nodeSet(_ numbers:some Sequence<Int>) -> Set<Node> {

            return Set(numbers.compactMap({ nodesByNumber[$0] }))
        }

        impulsedNodes = nodeSet(connectivity.impulsed)
        groundedNodes = nodeSet(connectivity.grounded)
        floatingNodes = nodeSet(connectivity.floating)

        finalConnectedNodes = [:]

        for nextGroup in connectivity.mergedGroups {

            guard let kept = nodesByNumber[nextGroup.kept] else {

                continue
            }

            finalConnectedNodes[kept] = nodeSet(nextGroup.eliminated)
        }

        guard !impulsedNodes.isEmpty && !groundedNodes.isEmpty else {

            DLog("Model requires at least one impulsed and one grounded node!")
            return nil
        }

        if !floatingNodes.isEmpty {

            DLog("There are floating nodes in the model!")
        }

        for nextSegment in await model.CoilSegments() {

            let nextRes = await Resistance(dc: nextSegment.resistance(), effRadius: nextSegment.turnEffectiveRadius(), eddyPURadial: nextSegment.eddyLossRadialPU, eddyPUAxial: nextSegment.eddyLossAxialPU, strandRadial: nextSegment.strandRadial, strandAxial: nextSegment.strandAxial)
            R.append(nextRes)
        }

        vDropInd = await Array(repeating: (-1,-1), count: model.CoilSegments().count)
        iDropInd = await Array(repeating: (-1,-1), count: model.nodes.count)
        
        // Populate the xDrop arrays. Note that after this loop, any tuple entry with a '-1' in it should be ignored (there shouldn't be any in vDropInd, but there will be some in iDropInd)
        for nextNode in await model.nodes {
            
            if let belowSegment = nextNode.belowSegment, !belowSegment.isStaticRing, !belowSegment.isRadialShield {
                
                do {
                    
                    let belowSegIndex = try await model.SegmentIndex(segment: belowSegment)
                    vDropInd[belowSegIndex].aboveNode = nextNode.number
                    iDropInd[nextNode.number].belowSeg = belowSegIndex
                }
                catch {
                    
                    await NSAlert.init(error: error).runModal()
                    
                    /*Task {
                        
                        await PCH_ErrorAlert(message: error.localizedDescription)
                    }*/
                    return nil
                }
            }
            
            if let aboveSegment = nextNode.aboveSegment, !aboveSegment.isStaticRing, !aboveSegment.isRadialShield {
                
                do {
                    
                    let aboveSegIndex = try await model.SegmentIndex(segment: aboveSegment)
                    vDropInd[aboveSegIndex].belowNode = nextNode.number
                    iDropInd[nextNode.number].aboveSeg = aboveSegIndex
                }
                catch {
                    
                    await NSAlert.init(error: error).runModal()
                    
                    /*Task {
                        
                        await PCH_ErrorAlert(message: error.localizedDescription)
                    }*/
                    return nil
                }
            }
        }
        
        // Now we finally have enough data to create the modified (C') capacitance matrix
        DLog("Modifying C-matrix")
        let fixedNodes = impulsedNodes.union(groundedNodes)
        for nextNode in fixedNodes {
            
            let nextNodeIndex = nextNode.number
            await modelC.ZeroRow(row: nextNodeIndex)
            // modelC[nextNodeIndex, nextNodeIndex] = 1.0
            await modelC.SetDoubleValue(value: 1.0, row: nextNodeIndex, col: nextNodeIndex)
        }
        
        for (nextNode, connNodes) in finalConnectedNodes {
            
            for nextConnNode in connNodes {
                
                let toIndex = nextNode.number
                let fromIndex = nextConnNode.number
                
                await modelC.AddRow(fromIndex: fromIndex, toIndex: toIndex)
                await modelC.ZeroRow(row: fromIndex)
                // modelC[fromIndex, fromIndex] = 1.0
                await modelC.SetDoubleValue(value: 1.0, row: fromIndex, col: fromIndex)
                // modelC[fromIndex, toIndex] = -1.0
                await modelC.SetDoubleValue(value: -1.0, row: fromIndex, col: toIndex)
            }
        }
        
        // model.fixedC = modelC
        await model.SetFixedC(newFixedC: modelC)
        
        DLog("Sparsity of C': \(await modelC.Sparsity())")
        do {
            
            let sparseC = try await modelC.asSparseMatrix()
            modelC = sparseC
        }
        catch {
            
            let alert = await NSAlert(error: error)
            let _ = await alert.runModal()
            return nil
        }
    }
    
    struct SimulationStepResult {

        let volts:[Double]
        let amps:[Double]
        let time:Double
    }

    /// A progress report emitted by a running simulation. The 'fractionComplete' value covers the _entire_ DoSimulate() call (ie: both RK45 passes), so it advances monotonically from 0 to 1 over the whole run.
    struct ProgressUpdate:Sendable {

        let fractionComplete:Double
        let phase:String
    }

    /// Extract everything the frequency-domain sweep needs, once.
    ///
    /// See `NetworkSnapshot` for why this exists rather than the sweep
    /// reaching back into the actor: the sweep runs thousands of independent
    /// solves in parallel, and every actor hop inside that loop would
    /// serialise it.
    ///
    /// - returns: The snapshot, or nil if a matrix is not in the layout the
    ///   snapshot assumes.
    func Snapshot() async -> NetworkSnapshot? {

        // The buffers are handed over wholesale rather than read entry by
        // entry, which is only valid for a `.general` matrix: PchMatrix stores
        // `.symmetric` and `.positiveDefinite` matrices as an upper triangle
        // with a different index mapping, so taking the raw buffer of one of
        // those would silently produce a garbled matrix. Checked rather than
        // assumed.
        guard await baseC.matrixType == .general else {

            DLog("The capacitance matrix is \(await baseC.matrixType), expected .general")
            return nil
        }

        guard await unfactoredM.matrixType == .general else {

            DLog("The inductance matrix is \(await unfactoredM.matrixType), expected .general")
            return nil
        }

        guard await unfactoredM.factorizationType == .none else {

            DLog("The inductance matrix is already factorized as \(await unfactoredM.factorizationType) - the solver needs the matrix itself")
            return nil
        }

        // finalConnectedNodes maps a kept node to the set of nodes shorted to
        // it. SimulationModel's init has already guaranteed that no member of
        // any such group is grounded or impulsed (those groups are absorbed
        // into groundedNodes/impulsedNodes and removed there), which is the
        // invariant FrequencyDomainSolver.Assemble relies on when it applies
        // the merges before the Dirichlet rows.
        var merged:[(kept:Int, eliminated:Int)] = []
        let fixed = Set(groundedNodes.map({ $0.number })).union(impulsedNodes.map({ $0.number }))

        for (kept, group) in finalConnectedNodes {

            for eliminated in group {

                guard !fixed.contains(kept.number), !fixed.contains(eliminated.number) else {

                    DLog("A merged node group contains a grounded or impulsed node - assembly order would be wrong")
                    return nil
                }

                merged.append((kept: kept.number, eliminated: eliminated.number))
            }
        }

        return await NetworkSnapshot(nodeCount: baseC.rows,
                                     segmentCount: unfactoredM.rows,
                                     capacitance: baseC.GetDoubleBuffer(),
                                     inductance: unfactoredM.GetDoubleBuffer(),
                                     nodeIncidence: iDropInd.map({ (belowSegment: $0.belowSeg, aboveSegment: $0.aboveSeg) }),
                                     segmentIncidence: vDropInd.map({ (belowNode: $0.belowNode, aboveNode: $0.aboveNode) }),
                                     impulsedNodes: impulsedNodes.map({ $0.number }),
                                     groundedNodes: groundedNodes.map({ $0.number }),
                                     floatingNodes: floatingNodes.map({ $0.number }),
                                     mergedNodes: merged,
                                     resistances: R,
                                     floatingResistance: floatingResistanceToGround)
    }

    /// Run the simulation in the frequency domain - the current path.
    ///
    /// Replaces `DoSimulate`. There is no `epsilon`, no time step, and no
    /// two-pass frequency estimation: the integration is exact and every
    /// frequency component sees its own resistance.
    ///
    /// - parameter waveForm: The applied impulse.
    /// - parameter displaySpan: The time span of interest, in seconds. The
    ///   solver internally computes twice this and returns the first half -
    ///   see `LaplaceGrid.DefaultGrid`.
    /// - parameter maximumFrequency: Bandwidth, in Hz. This is a real accuracy
    ///   knob, not a free parameter - see the discussion in `DefaultGrid`.
    /// - parameter progress: Optional progress continuation. Not finished by
    ///   this routine; the caller owns it.
    /// - returns: Results on a UNIFORM time grid, or an empty array on failure
    ///   or cancellation. As with `DoSimulate`, check `Task.isCancelled` at
    ///   the call site to tell the two apart.
    func SolveFrequencyDomain(waveForm:WaveForm, displaySpan:Double, maximumFrequency:Double, progress:AsyncStream<ProgressUpdate>.Continuation? = nil) async -> [SimulationStepResult] {

        guard let snapshot = await Snapshot() else {

            return []
        }

        let grid = LaplaceGrid.DefaultGrid(displaySpan: displaySpan, maximumFrequency: maximumFrequency)

        return await FrequencyDomainSolver.Sweep(snapshot: snapshot, waveForm: waveForm, grid: grid, progress: progress) ?? []
    }

    /*
    /// Call to simulate the impulse shot using the given parameters and 'self'
    /// - Note: !!!!!!!! Do not use this call, preference should be given to SimulateRK45() !!!!!!!!!!!!!!!!!!!!!
    func Simulate(waveForm:WaveForm, startTime:Double, endTime:Double, deltaT:Double) -> [SimulationStepResult] {
        
        // var result:[SimulationStepResult] = []
        var currentTime = startTime
        // Arrays that need to be updated at every time step of the simulation
        var V:[Double] = Array(repeating: 0.0, count: baseC.rows)
        var voltageDrop:[Double] = Array(repeating: 0.0, count: M.rows)
        
        var I:[Double] = Array(repeating: 0.0, count: M.rows)
        var currentDrop:[Double] = Array(repeating: 0.0, count: baseC.rows)
        var result:[SimulationStepResult] = [SimulationStepResult(volts: V, amps: I, time: currentTime)]
        
        
        
        let rkFactor:[Double] = [0.0, 0.5, 0.5, 1.0, 0.0]
        
        while currentTime < endTime {
            
            // variables used by RK4
            var interimI = I
            var interimV = V
            
            var kV:[[Double]] = Array(repeating: Array(repeating: 0.0, count: baseC.rows), count: 4)
            var kI:[[Double]] = Array(repeating: Array(repeating: 0.0, count: M.rows), count: 4)
            
            // RK4 algorithm
            for interimStep in 0..<4 {
                
                // Solve for dV/dt
                for i in 0..<currentDrop.count {
                    
                    let indexBase = iDropInd[i]
                    let Ij:Double = indexBase.belowSeg < 0 ? 0 : interimI[indexBase.belowSeg]
                    let Ij1:Double = indexBase.aboveSeg < 0 ? 0 : interimI[indexBase.aboveSeg]
                    currentDrop[i] = Ij - Ij1
                }
                
                // Set the grounded node rhs values to 0
                for nextGround in groundedNodes {
                    
                    let index = nextGround.number
                    currentDrop[index] = 0.0
                }
                
                // Set the impulsed node rhs values to the derivative of the impulse equation at the current time
                for nextImpulse in impulsedNodes {
                    
                    let index = nextImpulse.number
                    currentDrop[index] = waveForm.dV(currentTime + deltaT * rkFactor[interimStep])
                }
                
                // Add the currentDrops of connected terminals to the "parent" terminal and then set the connected-terminal's currentDrop to 0
                for (nextNode, connNodes) in finalConnectedNodes {
                    
                    let toNode = nextNode.number
                    for nextConnNode in connNodes {
                        
                        let fromNode = nextConnNode.number
                        currentDrop[toNode] += currentDrop[fromNode]
                        currentDrop[fromNode] = 0.0
                    }
                }
                
                let Crhs = PchMatrix(vectorData: currentDrop)
                guard let dVdt = modelC.SolveSparse(B: Crhs) else {
                    
                    DLog("Sparse solve failed!")
                    return []
                }
                
                // we use the method of the paper "rungekutta_adaptive_stepsize" (multiplying the k's by 'h' here instead of later)
                kV[interimStep] = QuickScalarVectorMultiply(scalar: deltaT, vector: dVdt.buffer)
                
                // Solve for dI/dt
                // Start by getting the voltage drops ('BV')
                for i in 0..<voltageDrop.count {
                    
                    let indexBase = vDropInd[i]
                    voltageDrop[i] = interimV[indexBase.belowNode] - interimV[indexBase.aboveNode]
                }
                
                let Mrhs = QuickVectorSubtract(lhs: voltageDrop, rhs: QuickRI(I: interimI, frequency: SimulationModel.defaultEddyFreq))
                guard let dIdt = M.SolvePositiveDefinite(B: PchMatrix(vectorData: Mrhs)) else {
                    
                    DLog("Pos/Def Solve failed!")
                    return []
                }
                
                kI[interimStep] = QuickScalarVectorMultiply(scalar: deltaT, vector: dIdt.buffer)
                
                interimI = QuickVectorAdd(lhs: I, rhs: QuickScalarVectorMultiply(scalar: rkFactor[interimStep + 1], vector: kI[interimStep]))
                interimV = QuickVectorAdd(lhs: V, rhs: QuickScalarVectorMultiply(scalar: rkFactor[interimStep + 1], vector: kV[interimStep]))
                
            } // interimStep (end RK4)
            
            V = QuickVectorAdd(lhs: V, rhs: QuickScalarVectorMultiply(scalar: 1 / 6, vector: kV[0]))
            V = QuickVectorAdd(lhs: V, rhs: QuickScalarVectorMultiply(scalar: 1 / 3, vector: kV[1]))
            V = QuickVectorAdd(lhs: V, rhs: QuickScalarVectorMultiply(scalar: 1 / 3, vector: kV[2]))
            V = QuickVectorAdd(lhs: V, rhs: QuickScalarVectorMultiply(scalar: 1 / 6, vector: kV[3]))
            
            I = QuickVectorAdd(lhs: I, rhs: QuickScalarVectorMultiply(scalar: 1 / 6, vector: kI[0]))
            I = QuickVectorAdd(lhs: I, rhs: QuickScalarVectorMultiply(scalar: 1 / 3, vector: kI[1]))
            I = QuickVectorAdd(lhs: I, rhs: QuickScalarVectorMultiply(scalar: 1 / 3, vector: kI[2]))
            I = QuickVectorAdd(lhs: I, rhs: QuickScalarVectorMultiply(scalar: 1 / 6, vector: kI[3]))
            
            result.append(SimulationStepResult(volts: V, amps: I, time: currentTime))
            
            currentTime += deltaT
            
        } // done simulation
        
        return result
    }
    */
    
    /// Run both solvers on the same problem and report how far apart they are.
    ///
    /// # Why this exists
    ///
    /// An exact method fails silently. If an incidence sign is flipped or a
    /// row-surgery step lands in the wrong order, the frequency-domain solver
    /// produces a perfectly conditioned system, solves it to machine
    /// precision, and returns a smooth, plausible, wrong answer. Nothing in
    /// its own diagnostics can catch that, because they check the solve rather
    /// than the physics.
    ///
    /// RK45 catches it, because it reaches the answer by a completely
    /// different route - marching the ODEs in time rather than solving them
    /// algebraically per frequency - while sharing the same matrices and
    /// incidence arrays. Agreement between the two is strong evidence both are
    /// right; disagreement localises the problem immediately.
    ///
    /// # Matching the two
    ///
    /// Both are pinned to the SAME constant resistance
    /// (`defaultEddyFreq`) via `resistanceFrequencyOverride`. Without that
    /// they solve different equations - the frequency-domain path varies R
    /// with frequency and RK45 cannot - and any disagreement would be
    /// meaningless. So this compares the two *numerical methods*, not the two
    /// resistance models.
    ///
    /// - returns: The worst absolute nodal voltage difference, the peak
    ///   voltage it should be judged against, and the time it occurred - or
    ///   nil if either solver failed.
    func CompareSolvers(waveForm:WaveForm, displaySpan:Double, maximumFrequency:Double) async -> (worstDifference:Double, peakVoltage:Double, atTime:Double)? {

        guard var snapshot = await Snapshot() else {

            return nil
        }

        snapshot.resistanceFrequencyOverride = SimulationModel.defaultEddyFreq

        let grid = LaplaceGrid.DefaultGrid(displaySpan: displaySpan, maximumFrequency: maximumFrequency)

        guard let frequencyResult = await FrequencyDomainSolver.Sweep(snapshot: snapshot, waveForm: waveForm, grid: grid), !frequencyResult.isEmpty else {

            DLog("The frequency-domain solver failed")
            return nil
        }

        // 200 V per 0.05 us step, the tolerance the old UI used to pass.
        let rk45Result = await SimulateRK45(waveForm: waveForm, startTime: 0.0, endTime: displaySpan, epsilon: 200.0 / 0.05E-6)

        guard !rk45Result.isEmpty else {

            DLog("RK45 failed or was cancelled")
            return nil
        }

        // RK45 lands on adaptive times that will not coincide with the uniform
        // grid, so its output is interpolated onto the grid. Linear is enough:
        // its steps are orders of magnitude finer than the grid spacing, so
        // the interpolation error is far below the difference being measured.
        var worst = 0.0
        var worstAt = 0.0
        var peak = 0.0
        var rkIndex = 0

        for step in frequencyResult {

            while rkIndex + 1 < rk45Result.count - 1, rk45Result[rkIndex + 1].time < step.time {

                rkIndex += 1
            }

            guard rkIndex + 1 < rk45Result.count else { break }

            let before = rk45Result[rkIndex]
            let after = rk45Result[rkIndex + 1]
            let span = after.time - before.time
            let weight = span > 0.0 ? (step.time - before.time) / span : 0.0

            for node in 0..<min(step.volts.count, before.volts.count) {

                let interpolated = before.volts[node] + weight * (after.volts[node] - before.volts[node])
                let difference = abs(step.volts[node] - interpolated)

                peak = max(peak, abs(interpolated))

                if difference > worst {

                    worst = difference
                    worstAt = step.time
                }
            }
        }

        DLog("Solver comparison: worst nodal difference \(worst) V against a peak of \(peak) V (\(peak > 0 ? worst / peak : 0) relative) at t = \(worstAt * 1.0E6) µs")

        return (worst, peak, worstAt)
    }

    /// Use the RK45 method (with adaptive timesteps) to simulate the impulse shot. Note that the 'deltaT' argument is only used as a startng point. It has a default value of 0.05E-6
    /// - parameter waveForm: A valid WaveForm to use for the simulation
    /// - parameter startTime: The beginning time of the simulation, usually 0
    /// - parameter endTime: The ending time of the simulation
    /// - parameter epsilon: The acceptable error value of a single time step, in V/s. For example, to limit the voltage error in a single step to approximately 100V, pass 100/∆t for this value
    /// - parameter deltaT: The suggested time-step in seconds. The routine uses this to start, then refines the value as necessary. This value defaults to 0.05E-6.
    /// - parameter Vstart: An optional set of initial voltages at time 'startTime'. If 'nil', then it is assumed that initial voltages are 0
    /// - parameter Istart: An optional set of initial currents at time 'startTime'. If 'nil', then it is assumed that initial currents are 0
    /// - returns: An array of SimulationStepResults
    /// - parameter progress: An optional AsyncStream continuation that receives ProgressUpdates as the run advances
    /// - parameter progressRange: The sub-range of the overall (0...1) progress that this call is responsible for
    /// - parameter phase: The text that identifies this pass in the emitted ProgressUpdates
    /// - Note: Only the voltage is used to determine whether the calculation is within tolerance (ie: current is not used)
    /// - Note: Returns an empty array if the enclosing Task is cancelled
    func SimulateRK45(waveForm:WaveForm, startTime:Double, endTime:Double, epsilon:Double, deltaT:Double = 0.05E-6, Vstart:[Double]? = nil, Istart:[Double]? = nil, progress:AsyncStream<ProgressUpdate>.Continuation? = nil, progressRange:Range<Double> = 0.0..<1.0, phase:String = "") async -> [SimulationStepResult] {

        guard startTime < endTime else {

            DLog("Start must be less than end!")
            return []
        }

        var V:[Double] = await Vstart == nil ? Array(repeating: 0.0, count: baseC.rows) : Vstart!
        var I:[Double] = await Istart == nil ? Array(repeating: 0.0, count: M.rows) : Istart!

        var result:[SimulationStepResult] = [SimulationStepResult(volts: V, amps: I, time: startTime)]

        var currentTime = startTime
        var h = deltaT
        var unusedSteps = 0
        var consecutiveRejections = 0

        // See the failure exit at the bottom of the loop for why this exists.
        let hMin = (endTime - startTime) * 1.0E-12

        // Progress is reported as the fraction of the simulated time-span that has been covered. Note that the adaptive time-step makes this decidedly non-linear in wall-clock time: h is small early on (when dV/dt at the impulse front is large) and grows as the wave flattens out, so the indicator crawls at first and then accelerates. It is monotonic, though - a rejected step simply doesn't advance currentTime.
        let timeSpan = endTime - startTime
        let progressSpan = progressRange.upperBound - progressRange.lowerBound
        var lastReportedPU = -1.0

        progress?.yield(ProgressUpdate(fractionComplete: progressRange.lowerBound, phase: phase))

        while currentTime < endTime {

            // Cancellation is cooperative, so bail out here rather than at the (throttled) progress-report site below - a long run of rejected steps would otherwise never reach that site.
            if Task.isCancelled {

                DLog("Simulation cancelled at time \(currentTime * 1.0E6) µs")
                return []
            }

            h = min(h, endTime - currentTime)

            // This all comes from the pdf document "rungekutta_adaptive_timestep"
            guard let f1 = await DifferentialFormula(waveForm: waveForm, t: currentTime, V: V, I: I) else {

                DLog("Derivative evaluation 1 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk1 = h * f1.dVdt
            let dIk1 = h * f1.dIdt
            
            guard let f2 = await DifferentialFormula(waveForm: waveForm, t: currentTime + h / 4, V: V + (0.25 * dVk1), I: I + (0.25 * dIk1)) else {

                DLog("Derivative evaluation 2 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk2 = h * f2.dVdt
            let dIk2 = h * f2.dIdt
            var dV = 3.0/32.0 * dVk1
            dV = dV + 9.0/32.0 * dVk2
            var dI = 3.0/32.0 * dIk1
            dI = dI + 9.0/32.0 * dIk2
            
            guard let f3 = await DifferentialFormula(waveForm: waveForm, t: currentTime + 3 * h / 8, V: V + dV, I: I + dI) else {

                DLog("Derivative evaluation 3 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk3 = h * f3.dVdt
            let dIk3 = h * f3.dIdt
            dV = 1932.0/2197.0 * dVk1 
            dV = dV - 7200.0/2197.0 * dVk2
            dV = dV + 7296.0/2197.0 * dVk3
            dI = 1932.0/2197.0 * dIk1
            dI = dI - 7200.0/2197.0 * dIk2
            dI = dI + 7296.0/2197.0 * dIk3
            
            guard let f4 = await DifferentialFormula(waveForm: waveForm, t: currentTime + 12 * h / 13, V: V + dV, I: I + dI) else {

                DLog("Derivative evaluation 4 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk4 = h * f4.dVdt
            let dIk4 = h * f4.dIdt
            dV = 439.0/216.0 * dVk1 
            dV = dV - 8.0 * dVk2
            dV = dV + 3680.0/513.0 * dVk3
            dV = dV - 845.0/4104.0 * dVk4
            dI = 439.0/216.0 * dIk1 
            dI = dI - 8.0 * dIk2
            dI = dI + 3680.0/513.0 * dIk3
            dI = dI - 845.0/4104.0 * dIk4
            
            guard let f5 = await DifferentialFormula(waveForm: waveForm, t: currentTime + h, V: V + dV, I: I + dI) else {

                DLog("Derivative evaluation 5 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk5 = h * f5.dVdt
            let dIk5 = h * f5.dIdt
            dV = -8.0/27.0 * dVk1
            dV = dV + 2.0 * dVk2
            dV = dV - 3544.0/2565.0 * dVk3
            dV = dV + 1859.0/4104.0 * dVk4
            dV = dV - 11.0/40.0 * dVk5
            dI = -8.0/27.0 * dIk1
            dI = dI + 2.0 * dIk2
            dI = dI - 3544.0/2565.0 * dIk3
            dI = dI + 1859.0/4104.0 * dIk4
            dI = dI - 11.0/40.0 * dIk5
            guard let f6 = await DifferentialFormula(waveForm: waveForm, t: currentTime + h / 2, V: V + dV, I: I + dI) else {

                DLog("Derivative evaluation 6 failed at t = \(currentTime * 1.0E6) µs")
                return []
            }
            let dVk6 = h * f6.dVdt
            // f6.dIdt is computed by DifferentialFormula whether or not it is
            // used, so the current error estimate below is free.
            let dIk6 = h * f6.dIdt

            var newV = V + 25.0/216.0 * dVk1
            newV = newV + 1408.0/2565.0 * dVk3
            newV = newV + 2197.0/4104.0 * dVk4
            newV = newV - 1.0/5.0 * dVk5
            
            var newI = I + 25.0/216.0 * dIk1
            newI = newI + 1408.0/2565.0 * dIk3
            newI = newI + 2197.0/4104.0 * dIk4
            newI = newI - 1.0/5.0 * dIk5
            
            var checkV = V + 16.0/135.0 * dVk1
            checkV = checkV + 6656.0/12825.0 * dVk3
            checkV = checkV + 28561.0/56430.0 * dVk4
            checkV = checkV - 9.0/50.0 * dVk5
            checkV = checkV + 2.0/55.0 * dVk6
            var checkI = I + 16.0/135.0 * dIk1
            checkI = checkI + 6656.0/12825.0 * dIk3
            checkI = checkI + 28561.0/56430.0 * dIk4
            checkI = checkI - 9.0/50.0 * dIk5
            checkI = checkI + 2.0/55.0 * dIk6

            // Error per unit step for both state blocks. V and I are coupled -
            // an unchecked error in I feeds straight back into dV/dt through
            // 'currentDrop' on the next step - so controlling only V, as this
            // routine used to, controls half of a coupled system.
            let vR = (1.0 / h) * (checkV - newV).map(abs)
            let iR = (1.0 / h) * (checkI - newI).map(abs)

            guard let max_vR = vR.max(), let max_iR = iR.max() else {

                DLog("Could not get max value - a derivative evaluation probably failed")
                return []
            }

            // The two blocks are in different units and differ by many orders
            // of magnitude, so they cannot share one absolute tolerance. The
            // current tolerance is scaled by the ratio of the two states'
            // magnitudes, which keeps the two checks comparably strict without
            // needing a second user-facing number.
            //
            // This is deliberately cruder than the frequency-domain path needs
            // to be. SimulateRK45 is now a cross-check, not the production
            // solver, and a defensible tolerance is enough for that job.
            let iScale = max(1.0E-12, I.map(abs).max() ?? 1.0) / max(1.0E-12, V.map(abs).max() ?? 1.0)
            let epsilonI = epsilon * iScale

            // Burden & Faires' step-size factor, CLAMPED. Unclamped, a near-zero
            // error estimate sends this to infinity (and h with it), while a
            // persistent failure lets h collapse without bound.
            let rawDelta = min(0.84 * pow(epsilon / max(max_vR, 1.0E-300), 0.25),
                               0.84 * pow(epsilonI / max(max_iR, 1.0E-300), 0.25))
            let delV = min(max(rawDelta, 0.1), 4.0)

            if max_vR <= epsilon && max_iR <= epsilonI {

                currentTime += h
                V = newV
                I = newI
                
                let nextStepResult = SimulationStepResult(volts: V, amps: I, time: currentTime)
                result.append(nextStepResult)
                consecutiveRejections = 0

                // Only report when the indicator would actually move. A 100pt-wide bar has about 100 useful positions, so 0.2% granularity is already generous, and a run of 10^5+ steps would otherwise swamp the main actor with updates.
                let pu = (currentTime - startTime) / timeSpan
                if pu - lastReportedPU >= 0.002 {

                    lastReportedPU = pu
                    progress?.yield(ProgressUpdate(fractionComplete: progressRange.lowerBound + pu * progressSpan, phase: phase))

                    // Guarantees the loop stays preemptible (and cancellable) even if none of the awaits above ever actually suspend
                    await Task.yield()
                }
            }
            else {
                
                DLog("Error too great at time \(currentTime * 1.0E6) µs; Step: \(h * 1.0E6) µs. Adjusting step and trying again!")
                unusedSteps += 1
                consecutiveRejections += 1
            }

            h = delV * h

            // Bail out rather than spin forever.
            //
            // Without this the routine had no lower bound on h and no failure
            // exit: if the tolerance could not be met, h shrank without limit,
            // and once it underflowed to where currentTime + h == currentTime
            // in floating point the `while currentTime < endTime` loop could
            // never terminate. Cancelling the task was the only way out.
            //
            // hMin is tied to the span rather than being an absolute constant
            // so it scales with the problem: 10^-12 of the run is far below
            // any step a converging solution needs, and comfortably above the
            // point where currentTime stops advancing.
            if h < hMin {

                DLog("Step size collapsed to \(h) s at t = \(currentTime * 1.0E6) µs after \(consecutiveRejections) consecutive rejections. Giving up.")
                return []
            }

            if consecutiveRejections > 25 {

                DLog("25 consecutive rejected steps at t = \(currentTime * 1.0E6) µs. Giving up.")
                return []
            }
        }
        
        // The throttle above can swallow the last report if the final (clamped) step is a small one, so pin the indicator to the end of this pass's range explicitly
        progress?.yield(ProgressUpdate(fractionComplete: progressRange.upperBound, phase: phase))

        DLog("Total number of recalculated steps: \(unusedSteps)")
        return result
    }
    
    
    private func DifferentialFormula(waveForm:WaveForm, t:Double, V:[Double], I:[Double]) async -> (dVdt:[Double], dIdt:[Double])? {
        
        var voltageDrop:[Double] = await Array(repeating: 0.0, count: M.rows)
        var currentDrop:[Double] = await Array(repeating: 0.0, count: baseC.rows)
        
        // Solve for dV/dt
        for i in 0..<currentDrop.count {
            
            let indexBase = iDropInd[i]
            let Ij:Double = indexBase.belowSeg < 0 ? 0 : I[indexBase.belowSeg]
            let Ij1:Double = indexBase.aboveSeg < 0 ? 0 : I[indexBase.aboveSeg]
            currentDrop[i] = Ij - Ij1
        }
        
        // Set the grounded node rhs values to 0
        for nextGround in groundedNodes {
            
            let index = nextGround.number
            currentDrop[index] = 0.0
        }
        
        // Set the impulsed node rhs values to the derivative of the impulse equation at the current time
        for nextImpulse in impulsedNodes {
            
            let index = nextImpulse.number
            currentDrop[index] = waveForm.dV(t)
        }
        
        // Add a huge resistance (Rs) to ground for any "floating nodes". According to DelVecchio 3E (in the paragraph immediately after equation 14.5), the value Vi/Rs is added to the left-hand side (so, subtracted from the RHS)
        for nextFloater in floatingNodes {
            
            let index = nextFloater.number
            let Rs = self.floatingResistanceToGround
            currentDrop[index] -= (V[index] / Rs)
        }
        
        // Add the currentDrops of connected terminals to the "parent" terminal and then set the connected-terminal's currentDrop to 0
        for (nextNode, connNodes) in finalConnectedNodes {
            
            let toNode = nextNode.number
            for nextConnNode in connNodes {
                
                let fromNode = nextConnNode.number
                currentDrop[toNode] += currentDrop[fromNode]
                currentDrop[fromNode] = 0.0
            }
        }
        
        do {
            let Crhs = PchMatrix(vectorData: currentDrop)
            async let dVdt = try await modelC.Solve(B: Crhs)
            
            // Solve for dI/dt
            // Start by getting the voltage drops ('BV')
            for i in 0..<voltageDrop.count {
                
                let indexBase = vDropInd[i]
                voltageDrop[i] = V[indexBase.belowNode] - V[indexBase.aboveNode]
            }
            
            let Mrhs = QuickVectorSubtract(lhs: voltageDrop, rhs: QuickRI(I: I, frequency: SimulationModel.defaultEddyFreq))
            async let dIdt = try await M.Solve(B: PchMatrix(vectorData: Mrhs))
            
            let resultV = try await dVdt.GetDoubleBuffer()
            let resultI = try await dIdt.GetDoubleBuffer()

            // A short buffer here would be just as corrupting as the empty one
            // the error path used to return, and just as invisible - see the
            // note on the catch block below.
            guard resultV.count == currentDrop.count, resultI.count == voltageDrop.count else {

                DLog("A solve returned \(resultV.count)/\(resultI.count) values, expected \(currentDrop.count)/\(voltageDrop.count)")
                return nil
            }

            return (resultV, resultI)
        }
        catch {

            // Returns nil rather than ([], []).
            //
            // The old empty-array return was silently destructive: the vector
            // operators in this file are built on `zip`, which TRUNCATES to the
            // shorter operand rather than trapping. An empty derivative
            // therefore turned V and I into empty arrays, every subsequent
            // stage quietly produced empty arrays too, and the caller
            // eventually failed several steps later at `vR.max()` with the
            // misleading message "Could not get max value!" - miles from the
            // actual failure. Making the type Optional forces the caller to
            // deal with it at the point it happens.
            DLog("A derivative solve failed: \(error)")
            return nil
        }
    }
    
    /// Multiply all values in a buffer (vector) by a scalar
    func QuickScalarVectorMultiply(scalar:Double, vector:[Double]) -> [Double] {
        
        var result:[Double] = Array(repeating: 0.0, count: vector.count)
        
        for i in 0..<vector.count {
            
            result[i] = scalar * vector[i]
        }
        
        return result
    }
    
    func QuickVectorAdd(lhs:[Double], rhs:[Double]) -> [Double] {
        
        var result:[Double] = Array(repeating: 0.0, count: lhs.count)
        
        for i in 0..<lhs.count {
            
            result[i] = lhs[i] + rhs[i]
        }
        
        return result
    }
    
    /// Subtract one vector from another. Note that this routine does no dimension checking (or any checking of any kind)
    func QuickVectorSubtract(lhs:[Double], rhs:[Double]) -> [Double] {
        
        var result:[Double] = Array(repeating: 0.0, count: lhs.count)
        
        for i in 0..<lhs.count {
            
            result[i] = lhs[i] - rhs[i]
        }
        
        return result
    }
    
    /// Multiply the (diagonal) R matrix by the vector I. Note that this routine does no dimension checking (or any checking of any kind, for that matter)
    ///
    /// Every segment is evaluated at the SAME frequency - see
    /// `defaultEddyFreq` for why a time-domain solver has no other option, and
    /// what that means when comparing against the frequency-domain path.
    func QuickRI(I:[Double], frequency:Double) -> [Double] {

        var result:[Double] = Array(repeating: 0.0, count: I.count)
        for i in 0..<I.count {

            result[i] = R[i].EffectiveResistanceAt(newFreq: frequency) * I[i]
        }

        return result
    }
}
