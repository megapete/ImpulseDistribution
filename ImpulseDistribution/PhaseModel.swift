//
//  PhaseModel.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2021-10-13.
//

import Foundation
import AppKit
import Accelerate
import ComplexModule
import RealModule
import PchBasePackage
import PchMatrixPackage

actor PhaseModel /*:Codable */ {
    
    /// The segments that make up the model. This array is kept sorted by the LocStruct of the segments (radial first, then axial).
    private var segmentStore:[Segment]
    
    /// read-only access to the segment store
    var segments:[Segment] {
        get {
            return segmentStore
        }
    }
    
    /// The set of nodes in the model
    private var nodeStore:[Node] = []
    
    /// read-only access to the node store
    var nodes:[Node] {
        get {
            return nodeStore
        }
    }
    
    /// The core for the model. This is a var because the leg centers grow when a coil is built up to carry wound-in shields - see
    /// ApplyRadialBuildUp. Only that routine writes it.
    private(set) var core:Core

    /// The core exactly as the design file described it, before any radial build-up was applied
    private let pristineCore:Core

    /// An array of arrays where the first index is the segment number and the second index (i) is J[i] for the segment (used for DelVecchio only)
    // var J:[[Double]] = []
    
    /// An array of Eslamian Vahidi segments. Ultimately, there will probably be no reason to keep this around and it should be removed from the class.
    //var evSegments:[EslamianVahidiSegment] = []
    
    /// The A-matrix as defined in DelVecchio, with rows corresponding to nodes and columns corresponding to sections
    var A:PchMatrix? = nil
    
    /// The B-matrix as defined in DelvVecchio, with rows corresponding to sections and columns corresponding to nodes.
    /// This matrix is multiplied by the voltage vector to yield the voltage drop across each section. The matrix is made up of 1's and -1's to achieve this.
    var B:PchMatrix? = nil
    
    /// The inductance for the model in unfactored form. 
    var unfactoredM:PchMatrix? = nil
    
    /// The inductance matrix for the model. **NOTE: This matrix is in Cholesky-factorized form
    var M:PchMatrix? = nil
    
    /// Set the inductance matrices
    func SetInductanceMatrices(unfactoreM:PchMatrix? = nil, M:PchMatrix? = nil) {
        
        self.unfactoredM = unfactoreM
        self.M = M
    }
    
    /// The basic (unmodified) capacitance matrix for the model
    var C:PchMatrix? = nil
    
    /// The 'fixed' capacitance matrix (used by the actual simulation)
    var fixedC:PchMatrix? = nil
    
    func SetFixedC(newFixedC:PchMatrix) {

        self.fixedC = newFixedC
    }

    /// Throw the fixed capacitance matrix away.
    ///
    /// Unlike `C`, which the recalculation pipeline recomputes unconditionally, `fixedC` is written by
    /// `SimulationModel.init` and by nothing else - so a geometry change that discards the simulation model would otherwise leave
    /// it here, belonging to a network that no longer exists. It is only read by the Save Fixed C Matrix command, which would
    /// silently write the wrong file. Called from `AppController.DiscardResultsForChangedModel()`.
    func ClearFixedC() {

        self.fixedC = nil
    }
    /// The window height to actually use
    var useWindowHeight:Double {
        
        return self.core.adjustedWindHt
    }
    
    /// The real window height of the core
    var realWindowHeight:Double {
        
        return self.core.realWindowHeight
    }
    
    // value needed for calculation of outermost coil shunt capacitances. A var for the same reason as 'core' above.
    private(set) var tankDepth:Double

    /// The tank depth exactly as the design file described it, before any radial build-up was applied
    private let pristineTankDepth:Double

    /// The working volts per turn of the transformer, taken from the design file. This is only needed by calculations that have to
    /// know the actual operating voltage of a section rather than a per-unit one - at the moment, sizing the paper on a wound-in
    /// shield wire (see Segment.WoundInShieldWire.Standard). It is zero until AppController.updateModel derives it.
    private(set) var voltsPerTurn:Double = 0.0

    func SetVoltsPerTurn(_ voltsPerTurn:Double) {

        self.voltsPerTurn = voltsPerTurn
    }

    /// How many neighbouring phases the outermost coil sees, for the phase-to-phase term of `OuterShuntCapacitance`.
    ///
    /// **Two by default, which is the CENTRE leg of a three-legged core, and that is deliberate**: it is the highest C_g the
    /// geometry can produce, so the highest alpha = sqrt(C_g/C_s), so the steepest initial distribution and the largest departure
    /// from the final linear one. Both of the things this program exists to find - the line-end turn-to-turn gradient and the
    /// mid-winding oscillation envelope - get worse with alpha, so modelling the centre leg is the conservative choice, and a
    /// design tool should be conservative by default rather than by remembering to be.
    ///
    /// One qualification, so that "worst case" is not overclaimed. The tank term of `OuterShuntCapacitance` uses `tankDepth/2`,
    /// which is the distance to the FRONT AND BACK walls and is the same for every leg; the tank's END walls, which only an outer
    /// leg is near, are not modelled at all. So an outer leg is missing a term that the centre leg genuinely does not have. That
    /// term is much smaller than a whole phase-to-phase gap - an end wall is a few hundred millimetres away where the adjacent
    /// phase is tens - so the centre leg still comes out worst, but it is worst by less than the arithmetic here suggests.
    ///
    /// Set to 0 for a single-phase unit, which has no neighbour at all. `AppController.recalculateModel` derives this from the
    /// design file's phase count; before it does, the default stands.
    private(set) var adjacentPhaseCount:Int = 2

    func SetAdjacentPhaseCount(_ count:Int) {

        self.adjacentPhaseCount = max(0, count)
    }

    /// Errors that can be thrown by some routines
    struct PhaseModelError:LocalizedError
    {
        /// The different error types that are available
        enum errorType
        {
            case UnknownError
            case UnimplementedInductanceMethod
            case EmptyModel
            case IllegalMatrix
            case CoilDoesNotExist
            case NotADiscCoil
            case IllegalAxialGap
            case SegmentExists
            case SegmentNotInModel
            case ShieldingElementExists
            case OnlyOneStaticRingAllowed
            case NoRoomForShieldingElement
            case NotAShieldingElement
            case ArgAIsNotAMultipleOfArgB
            case OldSegmentCountIsNotOne
            case UnequalBasicSectionsPerSet
            case ArgumentIsZeroCount
            case IllegalLocation
            case IllegalConnector
            case TooManyConnectors
            case CapacitanceNotCalculated
            case NodeHasNoSegments
            case SameCoilTwice
            case SegmentIsShieldingElement
            case UnresolvableConnector
        }
        
        /// Specialized information that can be added to the descritpion String (can be the empty string)
        let info:String
        /// The error type
        let type:errorType
        
        /// The error string to return with the error
        var errorDescription: String?
        {
            get
            {
                if self.type == .EmptyModel
                {
                   return "There are no segments in the model!"
                }
                else if self.type == .IllegalMatrix {
                    
                    return "The inductance matrix is not positive-definite!"
                }
                else if self.type == .UnimplementedInductanceMethod {
                    
                    return "DelVecchio inductance calculation method is not implemented!"
                }
                else if self.type == .CoilDoesNotExist {
                    
                    return "The coil '\(info)' does not exist!"
                }
                else if self.type == .NotADiscCoil {
                    
                    return "Expected a disc coil!"
                }
                else if self.type == .IllegalAxialGap {
                    
                    return "The axial gap is illegal. \(info)"
                }
                else if self.type == .SegmentExists {
                    
                    return "A segment already exists at location \(info)!"
                }
                else if self.type == .SegmentNotInModel {
                    
                    return "The segment does not exist in the model"
                }
                else if self.type == .ShieldingElementExists {
                    
                    return "A \(info) already exists adjacent to the segment!"
                }
                else if self.type == .NoRoomForShieldingElement {
                    
                    return "There is no room for a \(info) adjacent to the segment!"
                }
                else if self.type == .NotAShieldingElement {
                    
                    return "The selected segment is not a \(info)"
                }
                else if self.type == .ArgAIsNotAMultipleOfArgB {
                    
                    return "The count of the larger of the arrays must be a multiple of the count of the other!"
                }
                else if self.type == .ArgumentIsZeroCount {
                    
                    return "At least one of the arrays passed to the routine have a count equal to zero."
                }
                else if self.type == .OldSegmentCountIsNotOne {
                    
                    return "Can only split one segment at a time"
                }
                else if self.type == .UnequalBasicSectionsPerSet {
                    
                    return "The number of basic sections in each segment must be the same!"
                }
                else if self.type == .IllegalLocation {
                    
                    return "The new segment is at an illegal location: \(info)"
                }
                else if self.type == .TooManyConnectors {
                    
                    return "The segment at \(info) has too many connectors associated with it!"
                }
                else if self.type == .OnlyOneStaticRingAllowed {
                    
                    return "At this time, only one static ring is allowed to be adjacent to a disc (winding discs are not implemented). \(info)"
                }
                else if self.type == .CapacitanceNotCalculated {
                    
                    return "The capacitance for coil \(info) has not been calculated!"
                }
                else if self.type == .NodeHasNoSegments {
                    
                    return "The node \(info) has no Segments associated with it!"
                }
                else if self.type == .SameCoilTwice {
                    
                    return "The same coil has been used for both parameters (they must be different)."
                }
                else if self.type == .SegmentIsShieldingElement {

                    return "The segment specified is a static ring or radial shield."
                }
                else if self.type == .UnresolvableConnector {

                    return "The node topology does not match the connectors: \(info)"
                }
                
                let extraInfo = info != "" ? " Added info: \(info)" : ""
                return "An unknown error occurred.\(extraInfo)"
            }
        }
    }
    
    /// Designated initializer.
    /// - Parameter segments: The segments that make up the basis for the model
    /// - Parameter core: The core (duh)
    init(segments:[Segment], core:Core, tankDepth:Double) {
        
        self.segmentStore = segments.sorted(by: { lhs, rhs in
            
            if lhs.radialPos != rhs.radialPos {
                
                return lhs.radialPos < rhs.radialPos
            }
            
            return lhs.axialPos < rhs.axialPos
        })
        
        self.core = core
        self.pristineCore = core

        self.tankDepth = tankDepth
        self.pristineTankDepth = tankDepth
    }
    
    /// Get the array of segments excluding shielding elements
    func CoilSegments() -> [Segment] {
        
        var result = self.segmentStore
        
        result.removeAll(where: {$0.radialPos < 0 || $0.axialPos < 0})
        
        return result
    }
    
    /// The extra radial build that each coil needs in order to carry its wound-in shields, keyed by radial position. Coils with no
    /// shields do not appear.
    ///
    /// A coil's figure is the MAXIMUM over its Segments, not a per-Segment value. A coil has to stay cylindrical so that it can be
    /// stacked and clamped, so its widest disc sets the radial build for the whole coil and every other disc is built up with
    /// insulation to match. That is also why the cost of a graded shielding scheme is max(n) rather than sum(n): once the widest
    /// pair is fixed, putting shields into more pairs costs copper and labour but no further window.
    func RadialBuildUpByCoil() async -> [Int:Double] {

        var result:[Int:Double] = [:]

        for nextSegment in self.segmentStore {

            guard nextSegment.radialPos >= 0, nextSegment.axialPos >= 0 else {

                continue
            }

            guard let woundInShield = await nextSegment.woundInShield else {

                continue
            }

            result[nextSegment.radialPos] = max(result[nextSegment.radialPos] ?? 0.0, woundInShield.radialBuildAdder)
        }

        // A coil can be held wider than its own shields require - see radialBuildUpFloor. A floor rather than an addition, so
        // that it composes with the shields above it the same way one Segment's requirement composes with another's: the widest
        // demand wins, and applying it twice changes nothing.
        for (coil, floor) in self.radialBuildUpFloor {

            result[coil] = max(result[coil] ?? 0.0, floor)
        }

        return result
    }

    /// A per-coil minimum radial build-up, keyed by radial position, applied by `ApplyRadialBuildUp` exactly as though wound-in
    /// shields had asked for it.
    ///
    /// **This exists to make a comparison honest, and it is the only thing it is for.** Fitting a wound-in shield does two
    /// separate things to a coil: it adds the shield turns, and it makes the disc radially wider. The second is not a side effect
    /// to be ignored - a wider disc has more face area, so its disc-to-disc capacitance rises with it (C_dd goes as
    /// R_out² − R_in²), and on the STME-0999 fixture a 6-turn shield widened the HV by 22%, worth 24% more face area. So a shielded
    /// coil measured against an unshielded one of the ORIGINAL width is being credited for both effects at once, and there is no
    /// way to tell from the result how much of the gain was the shield.
    ///
    /// Setting this to a shield's `radialBuildAdder` on a coil that carries no shield puts the plain and interleaved cases at the
    /// shielded case's geometry, so the only thing left different between them is the electrical treatment.
    ///
    /// It is deliberately **not** something the UI can set. A design does not get to be wider because someone wanted a fairer
    /// comparison; this is a research knob, reached from `SelfTest` only.
    private(set) var radialBuildUpFloor:[Int:Double] = [:]

    func SetRadialBuildUpFloor(_ floor:[Int:Double]) {

        self.radialBuildUpFloor = floor
    }

    /// Rebuild the radial geometry of the entire model from the pristine design-file layout plus the current set of wound-in
    /// shields, and grow the core and tank to suit.
    ///
    /// Every coil that carries shields is widened by the amount RadialBuildUpByCoil gives it, and everything outside that coil is
    /// pushed straight out by the same amount. That preserves the hilos, which is the physically right answer: a hilo is a minimum
    /// clearance chosen from the coil voltages, not whatever space happens to be left over, so a coil that grows moves the NEXT
    /// coil's ID rather than eating into the gap. The tank and the leg centers grow by twice the total for the same reason.
    ///
    /// The routine is idempotent and exactly reversible because it recomputes absolute positions from the Segments' pristine radii
    /// (see Segment.SetRadialGeometry) rather than nudging whatever is there now. Remove the shields, call it again, and the model
    /// is bit-for-bit back to the geometry the design file described. It is cheap, so the sane thing is to call it unconditionally
    /// at the top of any recalculation instead of trying to track when it is needed - that also repairs the geometry after a
    /// combine/split/interleave, which rebuilds Segments from their pristine BasicSections.
    ///
    /// - Returns: The total radial growth of the model, ie: how much further out the outermost coil's OD now sits.
    @discardableResult
    func ApplyRadialBuildUp() async -> Double {

        let buildUp = await self.RadialBuildUpByCoil()
        let coilCount = self.CoilCount()

        guard coilCount > 0 else {

            return 0.0
        }

        var shift = 0.0

        for coil in 0..<coilCount {

            let extra = buildUp[coil] ?? 0.0

            // A radial shield sits in the hilo UNDER its coil. Its position is captured as a GAP to that coil rather than
            // recomputed from a pristine radius, because a shield is created after the model is loaded (possibly after a build-up
            // has already been applied), so its BasicSection's radii are not necessarily pristine. Holding the gap constant is both
            // the right physics and what keeps this routine idempotent.
            let shieldPos = coil == 0 ? Segment.negativeZeroPosition : -coil
            let radialShield = self.segmentStore.first(where: { $0.radialPos == shieldPos })

            var shieldGap = 0.0
            var shieldWidth = 0.0

            if let shield = radialShield, let coilBottom = self.segmentStore.first(where: { $0.radialPos == coil }) {

                shieldGap = await coilBottom.r1 - shield.r2
                shieldWidth = await shield.r2 - shield.r1
            }

            var newCoilR1 = 0.0
            var newCoilWidth = 0.0

            // The coil's own discs first. A static ring shares its neighbour's radial extent exactly, but it is created from that
            // neighbour's LIVE rect (Segment.StaticRing copies adjacentSegment.rect), so its BasicSection radii are only pristine if
            // it happened to be added before any build-up. Give it the coil's computed geometry rather than deriving it, which is
            // both simpler and immune to the order the user does things in.
            for nextSegment in self.segmentStore {

                guard nextSegment.radialPos == coil, nextSegment.axialPos >= 0 else {

                    continue
                }

                newCoilR1 = nextSegment.pristineR1 + shift
                newCoilWidth = nextSegment.pristineWidth + extra
                await nextSegment.SetRadialGeometry(r1: newCoilR1, width: newCoilWidth)
            }

            for nextSegment in self.segmentStore {

                guard nextSegment.radialPos == coil, nextSegment.axialPos < 0 else {

                    continue
                }

                await nextSegment.SetRadialGeometry(r1: newCoilR1, width: newCoilWidth)
            }

            if let shield = radialShield {

                await shield.SetRadialGeometry(r1: newCoilR1 - shieldGap - shieldWidth, width: shieldWidth)
            }

            shift += extra
        }

        self.core = Core(diameter: self.pristineCore.diameter, realWindowHeight: self.pristineCore.realWindowHeight, legCenters: self.pristineCore.legCenters + 2.0 * shift)
        self.tankDepth = self.pristineTankDepth + 2.0 * shift

        return shift
    }

    /// The number of coils in the model
    func CoilCount() -> Int {
        
        guard let finalSegment = self.segmentStore.last(where: {$0.radialPos >= 0 || $0.axialPos >= 0}) else {
            
            DLog("No coils!")
            return -1
        }
        
        return finalSegment.radialPos + 1
    }
    
    /// Get the range of the segments that make up the given coil, as a closed range of the indices into the inductance matrix, with lowerbound equal to the lowest disc and upperbound equal to the highest
    func SegmentRange(coil:Int) async throws -> ClosedRange<Int> {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        // Taken from the ordering of CoilSegments() itself rather than computed from axial positions. GetHighestSection returns an
        // axial COORDINATE, and coordinate and ordinal only coincide while every Segment holds exactly one BasicSection - see the
        // note in SegmentIndex. Callers subscript CoilSegments() with this range (doShowCoilResults does), so an ordinal is what it
        // has to be.
        let coilSegments = self.CoilSegments()

        guard let lowBound = coilSegments.firstIndex(where: {$0.radialPos == coil}), let highBound = coilSegments.lastIndex(where: {$0.radialPos == coil}) else {

            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }

        return ClosedRange(uncheckedBounds: (lowBound, highBound))
    }
    
    /// Return the index into the inductance matrix for the given Segment
    func SegmentIndex(segment:Segment) async throws -> Int {
        
        guard self.segments.contains(segment) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        guard !segment.isStaticRing && !segment.isRadialShield else {
            
            throw PhaseModelError(info: "Illegal Segment!", type: .SegmentIsShieldingElement)
        }
        
        // The Segment's POSITION in CoilSegments(), which is what every consumer of this index means by it: SimulationModel sizes
        // vDropInd by CoilSegments().count and fills it with these, and the capacitance assembly below indexes the same ordering.
        //
        // This used to be summed from GetHighestSection(coil:) plus segment.axialPos. Both of those are axial COORDINATES - the
        // pristine design-file disc index, never renumbered - and they equal the ordinal only while every Segment holds exactly one
        // BasicSection. After interleaving 8 discs into 4 Segments the coordinates are 0/2/4/6, so this returned duplicated and
        // out-of-range indices for the very Segments it was asked about.
        guard let result = self.CoilSegments().firstIndex(of: segment) else {

            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }

        return result
    }
    
    /// Function to check if two Segments are adjacent in the current model. This function assumes that the segmentStore is sorted according to location.
    func SegmentsAreAdjacent(segment1:Segment, segment2:Segment) -> Bool {
        
        guard segment1.radialPos == segment2.radialPos else {
            
            return false
        }
        
        guard let seg1index = self.segments.firstIndex(of: segment1), let seg2index = self.segments.firstIndex(of: segment2) else {
            
            return false
        }
        
        return abs(seg1index - seg2index) == 1
    }
    
    /// Return an array of non-axially-adjacent connections (and tapping gap connections added by the user - these will be adjacent, but for the purposes of the simulation they will not be)  that come to one of the segment's terminals. This is useful when "fixing" the C-array since the axial-adjacent connections are taken care of _implicitly_ in the array, while connections to other coils, non-adjacent discs, or impulse/ground need to be _explicity_ handled
    func NonAdjacentConnections(segment:Segment) async -> [Segment.Connection] {
        
        var result:[Segment.Connection] = []
        
        for nextConnection in await segment.connections {
            
            if let connSegID = nextConnection.segmentID {
                
                // 'continue', not 'return'. A dangling serial number is one bad connection, and returning here silently dropped every
                // REMAINING connection on the segment as well - turning one inconsistency into an arbitrary number of missing
                // jumpers, with the simulation model quietly built around the gap. With UpdateConnectors' remap repaired this
                // should no longer happen at all, so it is worth saying out loud when it does.
                guard let connSeg = self.segmentStore.first(where: { $0.serialNumber == connSegID }) else {

                    DLog("Segment \(segment.serialNumber) has a connection to segment \(connSegID), which is not in the model - skipping it. This means a Segment was replaced without its connections being remapped (see UpdateConnectors).")
                    continue
                }
                // If the segments aren't adjacent or they are a tapping gap, add the connection
                // Note that the 'await'-able call has to go first in an 'or' statement (??)
                if await self.IsTappingGap(segment1: segment, segment2: connSeg) || !SegmentsAreAdjacent(segment1: segment, segment2: connSeg) {
                    
                    result.append(nextConnection)
                }
            }
        }
        
        return result
    }
    
    /// Is the boundary between these two axially adjacent Segments a tapping/DV gap - a break in the winding rather than a series
    /// connection?
    ///
    /// # Why a centre LOCATION counts, whatever it is tied to
    ///
    /// The obvious test, and the one this used to make on its own, is for a *floating* lead facing across the boundary from each
    /// side: a gap is cut by giving both sides a lead that goes nowhere. That test is destroyed by the user doing the ordinary
    /// thing with those leads. `Segment.AddConnector` REPLACES a floating lead with a ground or an impulse, so a designer who ties
    /// the two centre leads of a double-stacked winding together and grounds them - which is what a centre-grounded tap winding
    /// IS - leaves neither side floating. `SetNodes` then saw the bridging jumper as a series connection, gave the two sides one
    /// shared node, and `NodeAt` - which resolves a centre connector only to a DANGLING node - could not find the node its own
    /// connector described. That failure is what `SelfTest`'s S0738 scenario provokes.
    ///
    /// The repair is to recognise a gap the way `NodeAt` already does, by the LOCATION rather than by the termination.
    /// `outside_center` and `inside_center` are created in exactly two places, both of them at a break in the winding -
    /// AppController's segment-building loop, at a tapping/DV gap, and `RemoveConnection`, when the user cuts a series
    /// connection (an LTC break) - and `Connector.AlternatingLocation` only ever pairs a centre location with another centre location, while
    /// a real series connection always maps an upper location to a lower one. So a centre connection means "gap", permanently,
    /// and nothing the user does to the lead can take that back.
    ///
    /// Both sides are still required to agree, and that is not belt-and-braces: the Segment ABOVE a gap carries a centre lead
    /// facing down, so testing either side alone would report the boundary above *it* as a gap too.
    func IsTappingGap(segment1:Segment, segment2:Segment) async -> Bool {

        // take care of the case where these are not even adjacent, which is handled differently
        guard SegmentsAreAdjacent(segment1: segment1, segment2: segment2) else {

            return false
        }

        // sort the segments by their axial positions
        var segments = [segment1, segment2]
        segments.sort(by: {$0.axialPos < $1.axialPos})

        var lowerFacesGap = false

        for nextConnection in await segments[0].connections {

            if nextConnection.connector.fromIsCenter || (!nextConnection.connector.fromIsLower && nextConnection.connector.toLocation == .floating) {

                lowerFacesGap = true
                break
            }
        }

        guard lowerFacesGap else {

            return false
        }

        for nextConnection in await segments[1].connections {

            if nextConnection.connector.fromIsCenter || (!nextConnection.connector.fromIsUpper && nextConnection.connector.toLocation == .floating) {

                return true
            }
        }

        return false
    }
    
    /// Remove a connection, the way *Remove Connector* mode does, and if it was the SERIES connection between two axially adjacent
    /// Segments of a coil, cut the winding there: each side gets a floating lead of its own, so the break is a gap like any other.
    ///
    /// # Why removing a series jumper has to leave leads behind
    ///
    /// A delta winding feeding an on-load tap changer is broken in the middle so that the two leads there can go to the LTC, which
    /// either ties them together or puts some or all of a separate tapping winding in series between them. Nothing in the design
    /// file says so - the coil is an ordinary continuous winding - so the user makes the break by removing the series jumper
    /// between the two centremost discs. `Segment.RemoveConnection` on its own deletes the jumper and nothing else, which leaves
    /// both discs with NO connector at the break: there is nothing drawn there and so nothing to click, and the two new ends of
    /// the winding cannot be connected to anything.
    ///
    /// So the break is turned into exactly what `AppController`'s segment-building loop makes at a tapping gap: a floating lead
    /// at `outside_center` (or `inside_center`, on the side the crossover was) on each of the two Segments. That makes it a gap to
    /// every routine that knows about gaps - `IsTappingGap` (and so `SetNodes` and `NonAdjacentConnections`), `Wiring.InternalGaps`
    /// and `.gapLead`, `AppController.SelectionSpansTappingGap` - and bridging it again with a jumper between the two leads is the
    /// LTC's "no taps in circuit" position, which the solver ties up explicitly like any bridged gap.
    ///
    /// # When a centre lead would be ambiguous
    ///
    /// `NodeAt` resolves a centre location to "the dangling node of this Segment". A Segment whose other end is the end of its coil
    /// has two of those, and `NodeAt` tells them apart because a coil end is never a break. A Segment with a BREAK on its far side
    /// as well cannot be told apart that way, so there the lead goes on at the crossover's own upper/lower location instead, which
    /// `NodeAt` resolves unambiguously and which `IsTappingGap` still reads as facing a gap while it floats.
    ///
    /// - Returns: The serial numbers of every Segment whose connections changed, for the view to redraw.
    func RemoveConnection(from segment:Segment, connection:Segment.Connection) async -> [Int] {

        let seriesBreak = await self.SeriesBreak(from: segment, connection: connection)

        var result = await segment.RemoveConnection(segments: self.segments, connection: connection)

        guard let seriesBreak else {

            return result
        }

        // The jumper may have been one of several between the two Segments (a cross-product copy of something else). If anything
        // still ties them, the winding is not broken and there is nothing to cut.
        if await seriesBreak.below.connections.contains(where: { $0.segmentID == seriesBreak.above.serialNumber }) {

            return result
        }

        let centreLocation:Connector.Location = seriesBreak.isInside ? .inside_center : .outside_center

        for (gapSegment, crossoverLocation, farEndBelow) in [(seriesBreak.below, seriesBreak.belowLocation, true), (seriesBreak.above, seriesBreak.aboveLocation, false)] {

            let connections = await gapSegment.connections
            let alreadyCarriesCentre = connections.contains(where: { $0.connector.fromIsCenter })
            let farEndIsBreak = await self.EndIsInternalBreak(of: gapSegment, below: farEndBelow)

            let leadLocation = alreadyCarriesCentre || farEndIsBreak ? crossoverLocation : centreLocation

            if connections.contains(where: { $0.segmentID == nil && $0.connector.fromLocation == leadLocation }) {

                continue
            }

            await gapSegment.AppendConnection(connection: Segment.Connection(segmentID: nil, connector: Connector(fromLocation: leadLocation, toLocation: .floating)))

            if !result.contains(gapSegment.serialNumber) {

                result.append(gapSegment.serialNumber)
            }
        }

        return result
    }

    /// If `connection` on `segment` is the series connection between two axially adjacent Segments of the same coil, the two
    /// Segments and the crossover's location on each; otherwise nil. A series connection always runs from an UPPER location on
    /// the Segment below to a LOWER location on the Segment above (see AppController's segment-building loop), and a boundary that
    /// is already a gap is not a series connection whatever is jumpered across it.
    private func SeriesBreak(from segment:Segment, connection:Segment.Connection) async -> (below:Segment, above:Segment, belowLocation:Connector.Location, aboveLocation:Connector.Location, isInside:Bool)? {

        guard let otherID = connection.segmentID, let other = self.CoilSegments().first(where: { $0.serialNumber == otherID }), self.CoilSegments().contains(segment), self.SegmentsAreAdjacent(segment1: segment, segment2: other) else {

            return nil
        }

        guard let segmentIndex = self.segments.firstIndex(of: segment), let otherIndex = self.segments.firstIndex(of: other) else {

            return nil
        }

        let segmentIsBelow = segmentIndex < otherIndex
        let below = segmentIsBelow ? segment : other
        let above = segmentIsBelow ? other : segment
        // the connector as seen from the Segment below
        let connector = segmentIsBelow ? connection.connector : connection.connector.Inverse()

        guard connector.fromIsUpper && connector.toIsLower else {

            return nil
        }

        guard await !self.IsTappingGap(segment1: below, segment2: above) else {

            return nil
        }

        let isInside = connector.fromLocation == .inside_upper

        return (below, above, connector.fromLocation, connector.toLocation, isInside)
    }

    /// Whether the end of `segment` facing `below` (or above, when false) is a break in the winding inside the coil - NOT the end
    /// of the coil, which `NodeAt` can tell apart from a break. This is the same decision SetNodes makes for that boundary.
    private func EndIsInternalBreak(of segment:Segment, below:Bool) async -> Bool {

        let coilSegments = self.CoilSegments().filter({ $0.radialPos == segment.radialPos })

        guard let index = coilSegments.firstIndex(of: segment) else {

            return false
        }

        let neighbourIndex = below ? index - 1 : index + 1

        guard neighbourIndex >= 0, neighbourIndex < coilSegments.count else {

            return false
        }

        let neighbour = coilSegments[neighbourIndex]

        if await self.IsTappingGap(segment1: segment, segment2: neighbour) {

            return true
        }

        return await !segment.connections.contains(where: { $0.segmentID == neighbour.serialNumber })
    }

    /// The serial-number-using version of NodeAt() [see next function]
    func NodeAt(segmentID:Int, useFrom:Bool, connector:Connector) -> Node? {
        
        guard let segment = self.segments.first(where: {$0.serialNumber == segmentID}) else {
            
            return nil
        }
        
        return self.NodeAt(segment: segment, useFrom: useFrom, connector: connector)
    }
    
    /// A function to return the node that is connected to the given segment at the given location.
    /// - Parameter segment: The segment that connects to the node
    /// - Parameter useFrom: If true, use the 'from...' field of 'connector', otherwise use the 'to...' field
    /// - Parameter connector: The connector to check
    /// - Returns: If the node exists, the Node; otherwise nil
    func NodeAt(segment:Segment, useFrom:Bool, connector:Connector) -> Node? {
        
        
        let connIsUpper = useFrom ? connector.fromIsUpper : connector.toIsUpper
        let connIsLower = useFrom ? connector.fromIsLower : connector.toIsLower
        
        // A centre location (outside_center / inside_center) is only ever made at a break in the winding, and it resolves to the
        // Segment's dangling node on that side. The location does not say WHICH side, so it is found: a Segment can dangle at both
        // ends - most simply when every disc from the break to the end of the coil has been combined into it - and then the
        // dangling node at the END OF THE COIL is never the one, because a coil end is not a break. Taking the first dangling node
        // in the store, as this used to, gave the coil's bottom node to a centre lead on a folded lower half.
        if !(connIsLower || connIsUpper) {
            
            let danglingNodes = nodeStore.filter({ $0.belowSegment == segment && $0.aboveSegment == nil || $0.aboveSegment == segment && $0.belowSegment == nil })
            
            guard danglingNodes.count > 1 else {
                
                return danglingNodes.first
            }
            
            let coilSegments = self.CoilSegments().filter({ $0.radialPos == segment.radialPos })
            let isCoilBottom = coilSegments.first == segment
            let isCoilTop = coilSegments.last == segment
            
            // A Segment between two internal breaks is still ambiguous; Wiring.FindLead refuses that geometry, and
            // RemoveConnection never makes it (it falls back to the crossover's own location there).
            return danglingNodes.first(where: { !(isCoilBottom && $0.belowSegment == nil) && !(isCoilTop && $0.aboveSegment == nil) }) ?? danglingNodes.first
        }
        
        for nextNode in nodeStore {
            
            if nextNode.aboveSegment == segment {
                
                if connIsLower {
                    
                    return nextNode
                }
            }
            else if nextNode.belowSegment == segment {
                
                if connIsUpper {
                    
                    return nextNode
                }
            }
        }
        
        return nil
    }
    
    func NodeAt_old(fromSegment:Segment, toSegment:Segment?, connection:Segment.Connection) -> Node? {
        
        for nextNode in nodes {
            
            if nextNode.aboveSegment != fromSegment && nextNode.belowSegment != fromSegment {
                
                continue
            }
            else if nextNode.aboveSegment == fromSegment {
                
                if !connection.connector.fromIsLower {
                    
                    continue
                }
                
                if let otherSegment = toSegment {
                    
                    if nextNode.belowSegment == otherSegment && connection.connector.toIsUpper {
                        
                        return nextNode
                    }
                }
            }
            else if nextNode.belowSegment == fromSegment {
                
                if !connection.connector.fromIsUpper {
                    
                    continue
                }
                
                if let otherSegment = toSegment {
                    
                    if nextNode.aboveSegment == otherSegment && connection.connector.toIsLower {
                        
                        return nextNode
                    }
                }
            }
            
            // at this point, if fromSegment and toSegment are axially adjacent and the connection parameter was such that the only possible node was the "shared" node, that node would already have been returned
            
            if toSegment != nil {


            }
            else {
                
                // This is a bit ugly. We will return the first node that connects to fromSegment and matches all the connector criteria.
                if nextNode.aboveSegment == fromSegment {
                    
                    if !connection.connector.fromIsUpper {
                        
                        return nextNode
                    }
                }
                else {
                    
                    if !connection.connector.fromIsLower {
                        
                        return nextNode
                    }
                }
            }
            
        }
        
        return nil
    }
    
    /// Function to determine if there is a shared node between two segments (as in when two adjacent discs are actually connected together)
    /// - Parameter segment1: The first segment to consider
    /// - Parameter segment2: The other segment to consider
    /// - returns: True if a shared node exists, otherwise false
    /// - Note: If segment1 and segment2 are not adjacent, this function returns false
    func SharedNodeExists(segment1:Segment, segment2:Segment) -> Bool {
        
        guard SegmentsAreAdjacent(segment1: segment1, segment2: segment2) else {
            
            return false
        }
        
        var segments = [segment1, segment2]
        segments.sort(by: {$0.axialPos < $1.axialPos})
        
        let aboveNodeLowerSegment = AdjacentNodes(to: segments[0]).above
        let belowNodeUpperSegment = AdjacentNodes(to: segments[1]).below
        
        return aboveNodeLowerSegment == belowNodeUpperSegment
    }
    
    /// Function to return the shared node between two axially-adjacent segments, if any
    /// - Parameter segment1: The first segment to consider
    /// - Parameter segment2: The other segment to consider
    /// - returns: An optional value equal to the shared node (if it exists), otherwise nil
    /// - Note: If segment1 and segment2 are not adjacent, this function returns nil
    func SharedNode(segment1:Segment, segment2:Segment) -> Node? {
        
        if SharedNodeExists(segment1: segment1, segment2: segment2) {
            
            var segments = [segment1, segment2]
            segments.sort(by: {$0.axialPos < $1.axialPos})
            
            let aboveNodeLowerSegment = AdjacentNodes(to: segments[0]).above
            return self.nodeStore[aboveNodeLowerSegment]
        }
        
        return nil
    }
    
    /// Function return the nodes directly associated with a segment . The nodes are returned as integer indices into the voltage matrix
    /// - Parameter to: A segment in the model (this must not be a shielding element, otherwise an error occurs)
    /// - Note: The segment passed to the routine must not be either a static ring or a radial shield. It is an error to pass a shielding element.
    func AdjacentNodes(to:Segment) -> (below:Int, above:Int) {
        
        guard !to.isStaticRing && !to.isRadialShield else {

            ALog("AdjacentNodes was passed segment \(to.serialNumber), which is a \(to.isStaticRing ? "static ring" : "radial shield") at (radial: \(to.radialPos), axial: \(to.axialPos)). Shielding elements are not circuit elements and have no nodes - the caller should have filtered them out (CoilSegments() does).")
            return (-1, -1)
        }
        
        guard let belowNode = nodes.first(where: { $0.aboveSegment == to }), let aboveNode = nodes.first(where: { $0.belowSegment == to }) else {
            
            DLog("No nodes match the segment!")
            return (-1, -1)
        }
        
        return (belowNode.number, aboveNode.number)
    }
    
    /// Function to return the axially adjacent Segments below and above the given Segment
    func AxiallyAdjacentSegments(to:Segment) async throws -> (below:Segment?, above:Segment?) {

        do {

            // SegmentIndex returns an ordinal into CoilSegments(), so CoilSegments() is the array it has to index. Subscripting
            // 'segments' - the full store, shielding elements included - with it went off by the number of static rings and
            // radial shields sorted ahead of the Segment, and could hand back a shielding element as an "adjacent Segment".
            let coilSegments = self.CoilSegments()
            let segmentIndex = try await self.SegmentIndex(segment: to)

            var belowSegment:Segment? = segmentIndex > 0 ? coilSegments[segmentIndex - 1] : nil
            var aboveSegment:Segment? = segmentIndex + 1 < coilSegments.count ? coilSegments[segmentIndex + 1] : nil

            // The Segment after the top of one coil is the bottom of the next, which is not axially adjacent to anything.
            if belowSegment?.radialPos != to.radialPos {

                belowSegment = nil
            }

            if aboveSegment?.radialPos != to.radialPos {

                aboveSegment = nil
            }

            return (belowSegment, aboveSegment)
        }
        catch {

            throw error
        }
    }
    
    /// Calculate the A matrix, save it to Aand return it. NOTE: In practice, I doubt that it is actually worth creating this matrix and multiplying it by the I (current) vector. It is probably better to simply maintain a current-drop vector - TBD.
    /*
    func GetAmatrix() throws -> PchMatrix {
        
        guard !nodes.isEmpty && !segments.isEmpty else {
            
            throw PhaseModelError(info: "", type: .EmptyModel);
        }
        
        let newA = PchMatrix(matrixType: .general, numType: .Double, rows: UInt(nodes.count), columns: UInt(segments.count))
        
        for nextNode in nodes {
            
            if let belowSegment = nextNode.belowSegment {
                
                do {
                    
                    let column = try SegmentIndex(segment: belowSegment)
                    newA[nextNode.number, column] = 1.0
                }
                catch {
                    
                    throw error
                }
            }
            
            if let aboveSegment = nextNode.aboveSegment {
                
                do {
                    
                    let column = try SegmentIndex(segment: aboveSegment)
                    newA[nextNode.number, column] = -1.0
                }
                catch {
                    
                    throw error
                }
            }
        }
        
        self.A = newA
        return newA
    } */
    
    /// Calculate the B matrix, save it to B and return it. NOTE: In practice, I doubt that it is actually worth creating this matrix and multiplying it by the Voltage vector. It is probably better to simply maintain a voltage-drop vector - TBD.
    func GetBmatrix() async throws -> PchMatrix {
        
        // Rows are indexed by SegmentIndex, which is an ordinal into CoilSegments() - so that, and not the full store, is what
        // sizes the matrix. Using segments.count left one empty row per shielding element at the bottom of it.
        let coilSegmentCount = self.CoilSegments().count

        guard coilSegmentCount > 0 else {

            throw PhaseModelError(info: "", type: .EmptyModel);
        }

        let newB = PchMatrix(matrixType: .general, numType: .Double, rows: UInt(coilSegmentCount), columns: UInt(nodes.count));
        
        for nextNode in nodes {
            
            if let aboveSeg = nextNode.aboveSegment {
                
                do {
                    
                    let row = try await SegmentIndex(segment: aboveSeg)
                    await newB.SetDoubleValue(value: 1.0, row: row, col: nextNode.number)
                    // newB[row, nextNode.number] = 1.0
                }
                catch {
                    
                    throw error
                }
            }
            
            if let belowSegment = nextNode.belowSegment {
                
                do {
                    
                    let row = try await SegmentIndex(segment: belowSegment)
                    await newB.SetDoubleValue(value: -1.0, row: row, col: nextNode.number)
                    // newB[row, nextNode.number] = -1.0
                }
                catch {
                    
                    throw error
                }
            }
        }
        
        self.B = newB
        return newB
    }
    
    /// Every node in the model, classified by what it is electrically tied to, with the jumpers resolved.
    ///
    /// # Why this exists, and why nothing may re-derive it
    ///
    /// A ground applied to one lead grounds everything jumpered to that lead. There are two possible places to record that: in
    /// the connector store, by writing a `.ground` connector onto each of the other leads as well, or here, by closing the
    /// directly-terminated nodes over the jumpers at the moment the answer is wanted.
    ///
    /// It used to be the first, and that is a cache with no invalidation. `TransformerView.mouseDownWithAddGround` wrote a ground
    /// onto every Segment `ConnectionDestinations` reached, and those grounds had no link back to the jumper that justified them,
    /// so **removing the jumper left them behind**. A designer re-wiring S0738's double-stacked tap winding from series to
    /// parallel - ground the HV neutral in its own right, then pull the old jumper that used to carry it through the tap winding -
    /// was left with a tap winding whose two outer ends were still grounded, held at exactly zero for the whole run, with nothing
    /// on screen at the HV neutral to explain it. Doing the same two edits in the other order gave a different model from the same
    /// picture, which is the tell for derived state that outlives its source. `SelfTest`'s `S0738-parallel-edited` and
    /// `-edited-2` scenarios are those two orders, and they now agree node for node.
    ///
    /// So the connector store holds only what the user actually did, and this routine is the one place that answers "what is at
    /// ground potential". It is a pure function of the connections - idempotent, order-independent, and impossible to leave stale.
    ///
    /// # The grouping is a union-find, and that is not a detail
    ///
    /// `SimulationModel.init` used to reduce the jumper graph itself with a single pass that absorbed, into each key, only those
    /// other keys whose sets named that key. One hop of transitivity is enough for a star (a lead jumpered to three others, which
    /// is what the cross-product in `TransformerView.CompleteAddConnection` produces) and is NOT enough for a path: A-B, B-C came out as the two
    /// OVERLAPPING groups `A:{B,C}` and `C:{B}`. `FrequencyDomainSolver.Assemble` then folded rows in dictionary order, and an
    /// order exists in which a node's charge equation is added to a row that has already been replaced by a constraint - the
    /// group's charge balance is then simply wrong, silently, with a plausible answer at the end of it. Proper components make
    /// each node an `eliminated` exactly once and never make a `kept` node an `eliminated`, which is the invariant that assembly
    /// relies on.
    struct NodeConnectivity {

        /// Node numbers held at the applied impulse voltage, including through jumpers.
        let impulsed:Set<Int>
        /// Node numbers held at ground, including through jumpers.
        let grounded:Set<Int>
        /// Node numbers carrying a floating lead and nothing else - not grounded, not impulsed, and not jumpered to any other
        /// node. These are the only nodes for which "floating" says anything the network does not already say.
        let floating:Set<Int>
        /// The remaining jumpered groups: nodes shorted to each other but tied to neither ground nor impulse. Disjoint, and no
        /// member of any group appears in `impulsed` or `grounded`.
        let mergedGroups:[(kept:Int, eliminated:[Int])]
        /// True if some group carries both an impulse and a ground - the impulse source shorted out. The group is reported as
        /// grounded so that the model still solves, but the answer is not one to trust.
        let shortedSource:Bool
    }

    /// Resolve every jumper in the model and classify every node. See `NodeConnectivity`.
    ///
    /// - throws: `.UnresolvableConnector` if a jumper names a node that `SetNodes` did not create - the same failure
    ///   `VerifyNodeTopology` catches, arriving here when a Segment has been replaced without its connections being remapped.
    func ResolveNodeConnectivity() async throws -> NodeConnectivity {

        let directImpulse = Set(await NodesOfType(connType: .impulse).map({ $0.number }))
        let directGround = Set(await NodesOfType(connType: .ground).map({ $0.number }))
        let directFloating = Set(await NodesOfType(connType: .floating).map({ $0.number }))

        // Union-find over node numbers. The nodes are numbered 0..<nodeStore.count and that number is also the index into the
        // capacitance matrix, so a flat array is the whole data structure.
        var parent = Array(0..<self.nodeStore.count)

        func find(_ node:Int) -> Int {

            var root = node

            while parent[root] != root {

                root = parent[root]
            }

            // Path compression, so that a long chain of jumpers does not turn this into a quadratic walk.
            var walk = node

            while parent[walk] != root {

                let next = parent[walk]
                parent[walk] = root
                walk = next
            }

            return root
        }

        func union(_ a:Int, _ b:Int) {

            let rootA = find(a)
            let rootB = find(b)

            if rootA != rootB {

                parent[rootB] = rootA
            }
        }

        // The jumper edges. NonAdjacentConnections is the predicate SetNodes agrees with - it returns the connections that are
        // NOT taken care of implicitly by two Segments sharing a node, which is exactly the set of jumpers - so taking the edges
        // from anywhere else would put this routine and the node topology back out of step.
        var jumpered:Set<Int> = []

        for nextSegment in self.CoilSegments() {

            for nextConnection in await NonAdjacentConnections(segment: nextSegment) {

                guard let destinationID = nextConnection.segmentID else {

                    continue
                }

                guard let fromNode = self.NodeAt(segment: nextSegment, useFrom: true, connector: nextConnection.connector),
                      let toNode = self.NodeAt(segmentID: destinationID, useFrom: false, connector: nextConnection.connector) else {

                    throw PhaseModelError(info: "segment \(nextSegment.serialNumber) has a jumper \(nextConnection.connector.fromLocation) -> \(nextConnection.connector.toLocation) to segment \(destinationID) that does not land on a node at both ends.", type: .UnresolvableConnector)
                }

                jumpered.insert(fromNode.number)
                jumpered.insert(toNode.number)
                union(fromNode.number, toNode.number)
            }
        }

        // Close the direct terminations over the components.
        var impulsedRoots:Set<Int> = []
        var groundedRoots:Set<Int> = []

        for node in directImpulse {

            impulsedRoots.insert(find(node))
        }

        for node in directGround {

            groundedRoots.insert(find(node))
        }

        // Ground wins a component that carries both, so that the classification is at least deterministic. It is reported rather
        // than silently resolved: an impulse lead shorted to ground is a wiring mistake, not a modelling choice.
        let shorted = !impulsedRoots.intersection(groundedRoots).isEmpty
        impulsedRoots.subtract(groundedRoots)

        var impulsed:Set<Int> = []
        var grounded:Set<Int> = []
        var groups:[Int:[Int]] = [:]

        for node in 0..<self.nodeStore.count {

            let root = find(node)

            if groundedRoots.contains(root) {

                grounded.insert(node)
            }
            else if impulsedRoots.contains(root) {

                impulsed.insert(node)
            }
            else if jumpered.contains(node) {

                groups[root, default: []].append(node)
            }
        }

        // One representative per group keeps its own row (the summed charge equation) and every other member's row becomes the
        // constraint V_member - V_kept = 0. A group of one cannot happen - a node only reaches here by carrying a jumper - but it
        // would be harmless if it did.
        var mergedGroups:[(kept:Int, eliminated:[Int])] = []

        for (_, members) in groups {

            let sorted = members.sorted()

            guard let kept = sorted.first, sorted.count > 1 else {

                continue
            }

            mergedGroups.append((kept: kept, eliminated: Array(sorted.dropFirst())))
        }

        // Sorted so that the assembly is bit-for-bit reproducible from one run to the next. A Set's iteration order is not, and a
        // regression report that changes in the last digit because a dictionary rehashed is a report nobody reads twice.
        mergedGroups.sort { $0.kept < $1.kept }

        // A node is only meaningfully floating if nothing at all is tied to it. One that is jumpered to another node is described
        // by the merge, and one whose group reached a ground or an impulse is described by that.
        let floating = directFloating.subtracting(grounded).subtracting(impulsed).subtracting(jumpered)

        return NodeConnectivity(impulsed: impulsed, grounded: grounded, floating: floating, mergedGroups: mergedGroups, shortedSource: shorted)
    }

    /// Function to return all nodes in the model that are _directly_ connected to one of impulse, ground, or floating via a Segment.connection to one of those locations.
    ///
    /// - Note: DIRECTLY. This does not follow jumpers, so it is not the answer to "what is at ground potential" - see
    ///   `ResolveNodeConnectivity`, which is. Callers that mean the latter and use this instead will miss every node that is
    ///   grounded through a jumper rather than by its own lead.
    func NodesOfType(connType:Connector.Location) async -> [Node] {
        
        var result:[Node] = []
        
        for nextNode in nodes {
            
            if let aboveSegment = nextNode.aboveSegment, let belowSegment = nextNode.belowSegment {
                
                var addedNode = false
                // in this case, only ground and impulse are possible
                if connType == .impulse || connType == .ground {
                    
                    for nextConnection in await aboveSegment.connections {
                        
                        if nextConnection.connector.fromIsLower && nextConnection.connector.toLocation == connType {
                            
                            result.append(nextNode)
                            addedNode = true
                            break
                        }
                    }
                    
                    if !addedNode {
                        
                        for nextConnection in await belowSegment.connections {
                            
                            if nextConnection.connector.fromIsUpper && nextConnection.connector.toLocation == connType {
                                
                                result.append(nextNode)
                                break
                            }
                        }
                    }
                    
                }
            }
            else if let aboveSegment = nextNode.aboveSegment {
                
                // belowSegment is nil
                for nextConnection in await aboveSegment.connections {
                    
                    if !nextConnection.connector.fromIsUpper && nextConnection.connector.toLocation == connType {
                        
                        result.append(nextNode)
                        break
                    }
                }
            }
            else if let belowSegment = nextNode.belowSegment {
                
                // aboveSegment is nil
                for nextConnection in await belowSegment.connections {
                    
                    if !nextConnection.connector.fromIsLower && nextConnection.connector.toLocation == connType {
                        
                        result.append(nextNode)
                        break
                    }
                }
            }
        }
        
        return result
    }
    
    /// A routine to change the connectors in the model when newSegment(s) take(s) the place of oldSegment(s). It is assumed that the Segment arrays are contiguous and in order. The count of oldSegments must be a multiple of newSegments or the count of newSegmenst must be a multiple of oldSegments.  If both arguments only have a single Segment, it is assumed that the one in newSegment replaces the one in oldSegment. It is further assumed that the new Segments have _NOT_ been added to the model yet, but will be soon after calling this function. Any connector references to oldSegments that should be set to newSegments will be replaced in the model - however, the model itself (ie: the array of Segments in segmentStore) will not be changed.
    ///  - Note: If there is only a single oldSegment, only adjacent-segment connections are retained, and connections to non-Segments (like ground, etc) are trashed.
    func UpdateConnectors(oldSegments:[Segment], newSegments:[Segment]) async throws {
        
        guard oldSegments.count > 0 && newSegments.count > 0 else {
            
            throw PhaseModelError(info: "", type: .ArgumentIsZeroCount)
        }
        
        var segmentMap:[Int:Segment] = [:]
        
        if newSegments.count <= oldSegments.count {
            
            if oldSegments.count % newSegments.count != 0 {
                
                throw PhaseModelError(info: "", type: .ArgAIsNotAMultipleOfArgB)
            }
            
            let oldSectionsPerNew = oldSegments.count / newSegments.count

            // Connections that the fold strands, paired with the old Segment they were attached to. See the long note below.
            var strandedConnections:[(oldSerialNumber:Int, connection:Segment.Connection)] = []

            for newIndex in 0..<newSegments.count {

                let currentOldSegments = oldSegments[newIndex * oldSectionsPerNew..<newIndex * oldSectionsPerNew + oldSectionsPerNew]
                let firstOldSeg = currentOldSegments.first!
                let lastOldSeg = currentOldSegments.last!

                let newSeg = newSegments[newIndex]

                // EVERY old Segment folded into this new one gets an entry, not just the two ends. At two-old-per-new (interleave,
                // wound-in-shield pairing) first and last are the only two and the distinction does not arise, but combining three
                // or more discs used to leave the middle ones out of the map, so anything that referred to them stayed dangling.
                for nextOldSegment in currentOldSegments {

                    segmentMap[nextOldSegment.serialNumber] = newSeg
                }

                // A fold DESTROYS every node inside the group: the new Segment is one series branch with exactly two terminals, the
                // bottom of the first old Segment and the top of the last. Only connections attached at those two points can be
                // inherited; everything else was attached to a node that no longer exists.
                //
                // This used to be `firstOldSeg.connections + lastOldSeg.connections` wholesale, which kept the interior ones too -
                // and NodeAt resolves a connection by upper/lower alone, so an interior connection inherited from the first old
                // Segment (an UPPER location) came back attached to the new Segment's TOP node and one from the last old Segment (a
                // LOWER location) to its BOTTOM node. A single jumper is stored as one connection per Segment meeting the node it
                // was dropped on (TransformerView.CompleteAddConnection adds the whole cross-product), so folding those two Segments into one put
                // the two halves of one jumper on opposite ends of the new Segment. The visible symptom was two connector lines
                // where the user drew one; the real one was in SimulationModel.init, which unions the node groups a jumper ties
                // together and so SHORTED OUT the new Segment - silently, and with a plausible answer at the end of it.
                var inheritedConnections:[Segment.Connection] = []

                if currentOldSegments.count == 1 {

                    // A one-for-one replacement destroys nothing, so everything is inherited. (Taking first + last here would have
                    // duplicated every connection on the Segment, since the two are the same object.)
                    inheritedConnections = await firstOldSeg.connections
                }
                else {

                    for nextOldSegment in currentOldSegments {

                        for nextConnection in await nextOldSegment.connections {

                            // Center locations mark a tapping gap and belong to the group's outer boundary if they belong anywhere;
                            // they are kept from the two end Segments for the same reason their upper/lower siblings are. A
                            // regrouping is never allowed to span a gap (AppController.SelectionSpansTappingGap), so a center
                            // connection cannot be interior to the group in the first place.
                            let survives = (nextOldSegment.serialNumber == firstOldSeg.serialNumber && !nextConnection.connector.fromIsUpper)
                                        || (nextOldSegment.serialNumber == lastOldSeg.serialNumber && !nextConnection.connector.fromIsLower)

                            if survives {

                                inheritedConnections.append(nextConnection)
                            }
                            else {

                                strandedConnections.append((nextOldSegment.serialNumber, nextConnection))
                            }
                        }
                    }
                }

                await newSeg.SetConnections(connections: inheritedConnections)

                // there may be old-segment references in the newSeg.connections array, get rid of them
                for nextOldSegment in currentOldSegments {

                    await newSeg.RemoveConnectionsWithID(nextOldSegment.serialNumber)
                    //newSeg.connections.removeAll(where: {$0.segment == nextOldSegment})
                }
            }

            // Both ends of a stranded connection have to go. Dropping only the new Segment's copy leaves the far Segment pointing
            // back at a terminal the connection was never attached to - which NodeAt resolves quite happily to the wrong node, so
            // the short survives from the other side. The sweep runs here, AFTER every new Segment has its connections and BEFORE
            // the remap below, because it matches on the OLD serial numbers the mirrors still carry.
            //
            // Nothing checks whether the far end is one of the old Segments of the same group (a series connection inside it): its
            // mirror was stranded too and is not in any inherited list, so the removal simply finds nothing.
            if !strandedConnections.isEmpty {

                let searchSegments = self.segments + newSegments

                for nextStranded in strandedConnections {

                    guard nextStranded.connection.segmentID != nil else {

                        // A termination (ground, impulse or a floating lead) has no far end to clean up.
                        continue
                    }

                    let mirror = nextStranded.connection.connector.Inverse()

                    for nextSegment in searchSegments {

                        await nextSegment.RemoveConnectionsMatching(segmentID: nextStranded.oldSerialNumber, connector: mirror)
                    }
                }
            }

            // Old serial -> new serial. Segment.serialNumber is a 'let', so reading it needs no await.
            let serialMap = segmentMap.mapValues({ $0.serialNumber })

            // Both halves of the model have to be rewritten: the new Segments, which inherited connections still naming the old
            // Segments they replaced, and the Segments already in the store, whose connections name the replaced Segments from the
            // outside. RemoveSegments() has already run by this point and AddSegments() has not, so between them these two loops
            // cover every Segment in the model exactly once.
            //
            // These loops used to read a connection's segmentID, confirm the map had an entry for it, and then assign the SAME id
            // back - a no-op that left every reference dangling. See Segment.RemapConnectionSegmentIDs for what that cost and for
            // the two further places a serial number hides inside a Connection, neither of which was being remapped at all.
            for nextSegment in newSegments {

                await nextSegment.RemapConnectionSegmentIDs(serialMap)
            }

            for nextSegment in self.segments {

                await nextSegment.RemapConnectionSegmentIDs(serialMap)
            }
        }
        else if oldSegments.count == 1 {
            
            guard  newSegments.count % oldSegments[0].basicSections.count == 0 else {
                
                throw PhaseModelError(info: "", type: .UnequalBasicSectionsPerSet)
            }
            
            let firstNewSegment = newSegments.first!
            let lastNewSegment = newSegments.last!
            
            // now we worry about replacing the old segment connections
            var connectionsWithSegments = await oldSegments[0].connections
            connectionsWithSegments.removeAll(where: {$0.segmentID == nil})
            
            do {
                
                for nextConnection in connectionsWithSegments {
                    
                    guard let nextConnSegment = segmentStore.first(where: { $0.serialNumber == nextConnection.segmentID}) else {
                        
                        throw PhaseModelError(info: "", type: .SegmentNotInModel)
                    }
                    
                    let compPos = try await self.ComparativePosition(fromSegment: oldSegments[0], toSegment: nextConnSegment)
                    if compPos == .adjacentBelow || compPos == Segment.ComparativePosition.top {
                        
                        let prevSegment = nextConnSegment
                        for i in await 0..<prevSegment.connections.count {
                            
                            if let nextPrevConnSegID = await prevSegment.connections[i].segmentID {
                                
                                if nextPrevConnSegID == oldSegments[0].serialNumber {
                                    
                                    await prevSegment.SetSegmentIDforConnectionAt(i, newID: firstNewSegment.serialNumber)
                                    await firstNewSegment.AppendConnection(connection: nextConnection)
                                    // prevSegment.connections[i].segment = firstNewSegment
                                    // firstNewSegment.connections.append(nextConnection)
                                }
                            }
                        }
                    }
                    else if compPos == .adjacentAbove || compPos == Segment.ComparativePosition.bottom {
                        
                        guard let nextSegmentID = nextConnection.segmentID, let nextSegment = segments.first(where: { $0.serialNumber == nextSegmentID }) else {
                            
                            throw PhaseModelError(info: "", type: .SegmentNotInModel)
                        }
                        for i in await 0..<nextSegment.connections.count {
                            
                            if let nextNextConnSegID = await nextSegment.connections[i].segmentID {
                                
                                if nextNextConnSegID == oldSegments[0].serialNumber {
                                    
                                    await nextSegment.SetSegmentIDforConnectionAt(i, newID: lastNewSegment.serialNumber)
                                    await lastNewSegment.AppendConnection(connection: nextConnection)
                                    // nextSegment.connections[i].segment = lastNewSegment
                                    // lastNewSegment.connections.append(nextConnection)
                                }
                            }
                        }
                    }
                }
                
                // The logic that follows reads connections[0] as THE incoming/outgoing connector, so it only holds if each end
                // segment carries at most one. More than that means the old segment had connections this split does not know how
                // to distribute, and whatever is picked below is arbitrary.
                let firstNewCount = await firstNewSegment.connections.count
                let lastNewCount = await lastNewSegment.connections.count
                if firstNewCount > 1 || lastNewCount > 1 {

                    ALog("Splitting segment \(oldSegments[0].serialNumber) into \(newSegments.count) left the first new segment with \(firstNewCount) connection(s) and the last with \(lastNewCount); the code below assumes at most one each, so it is about to pick one arbitrarily.")
                }
                
                // At this point, there are a few possibilities:
                // firstNewSegment either has no connections or exactly one. If it has one, we can go on. Otherwise, it means that it needs a floating 'toLocation' (it is the lowest of the axial sections for the coil). The fromLocation depends on whether lastNewSegment has a fromLocation in it. If so (it may ALSO have no connections), the fromLocation for firstNewSegment can be calculated depending on the coil type and (in the case of a disc coil), whether there are an even or odd number of new segments being added to the model. Similarly, if firstNewSegmnent has a connection, then its lower fromLocation can be used to determine lastNewSegments' fromLocation connection.
                
                var newIncomingConnector:Connector? = await firstNewSegment.connections.count > 0 ? firstNewSegment.connections[0].connector : nil
                var newOutgoingConnector:Connector? = await lastNewSegment.connections.count > 0 ? lastNewSegment.connections[0].connector : nil
                
                // get all the basic sections in the newSegments array
                var newBasicSections:[BasicSection] = []
                for nextSegment in newSegments {
                    
                    newBasicSections.append(contentsOf: nextSegment.basicSections)
                }
                
                let wdgType = newSegments[0].basicSections[0].wdgData.type
                if newIncomingConnector == nil {
                    
                    if newOutgoingConnector == nil {
                        
                        if wdgType == .helical {
                            
                            newIncomingConnector = Connector(fromLocation: .center_lower, toLocation: .floating)
                        }
                        else if wdgType == .disc {
                            
                            let numDiscs = newBasicSections.count
                            if numDiscs % 2 == 0 {
                                
                                newIncomingConnector = Connector(fromLocation: .outside_lower, toLocation: .floating)
                            }
                            else {
                                
                                newIncomingConnector = Connector(fromLocation: .inside_lower, toLocation: .floating)
                            }
                        }
                        else {
                            
                            newIncomingConnector = Connector(fromLocation: .inside_lower, toLocation: .floating)
                        }
                    }
                    else { // use outGoingConnector to decide
                        
                        if wdgType == .helical {
                            
                            newIncomingConnector = Connector(fromLocation: .center_lower, toLocation: .floating)
                        }
                        else if wdgType == .disc {
                            
                            let numDiscs = newBasicSections.count
                            if numDiscs % 2 == 0 {
                                
                                newIncomingConnector = Connector(fromLocation: Connector.StandardToLocation(fromLocation: newOutgoingConnector!.fromLocation), toLocation: .floating)
                            }
                            else {
                                
                                newIncomingConnector = Connector(fromLocation: Connector.AlternatingLocation(lastLocation: newOutgoingConnector!.fromLocation), toLocation: .floating)
                            }
                        }
                        else {
                            
                            newIncomingConnector = Connector(fromLocation: .inside_lower, toLocation: .floating)
                        }
                    }
                }
                
                // at this point, newIncomingConnector is guaranteed to exist, so we move on to newOutgoingConnector
                if newOutgoingConnector == nil {
                    
                    if wdgType == .helical {
                        
                        newOutgoingConnector = Connector(fromLocation: .center_upper, toLocation: .floating)
                    }
                    else if wdgType == .disc {
                        
                        let numDiscs = newBasicSections.count
                        if numDiscs % 2 == 0 {
                            
                            newOutgoingConnector = Connector(fromLocation: Connector.StandardToLocation(fromLocation: newIncomingConnector!.fromLocation), toLocation: .floating)
                        }
                        else {
                            
                            newOutgoingConnector = Connector(fromLocation: Connector.AlternatingLocation(lastLocation: newIncomingConnector!.fromLocation), toLocation: .floating)
                        }
                    }
                    else {
                        
                        newOutgoingConnector = Connector(fromLocation: .outside_upper, toLocation: .floating)
                    }
                }
                
                // Here we now have the newIncomingConnector and newOutgoingConnector defined, we just need to add the connectors within the new Segments
                var incomingConnector = newIncomingConnector!
                var outgoingConnector = newIncomingConnector!
                let lastSegmentID = await firstNewSegment.connections.count == 0 ? nil : firstNewSegment.connections[0].segmentID
                var lastSegment = lastSegmentID == nil ? nil : segmentStore.first(where: { $0.serialNumber == lastSegmentID })
                
                for nextSegment in newSegments {
                    
                    if await (firstNewSegment.connections.count == 0 && nextSegment == firstNewSegment) || nextSegment != firstNewSegment {
                        
                        await nextSegment.AppendConnection(connection: Segment.Connection(segmentID: lastSegmentID, connector: incomingConnector))
                        // nextSegment.connections.append(Segment.Connection(segment: lastSegment, connector: incomingConnector))
                    }
                    
                    if nextSegment != firstNewSegment, let prevSegment = lastSegment {
                        
                        await prevSegment.AppendConnection(connection: Segment.Connection(segmentID: nextSegment.serialNumber, connector: outgoingConnector))
                        // prevSegment.connections.append(Segment.Connection(segment: nextSegment, connector: outgoingConnector))
                    }
                    
                    // set up the connector for the outgoing connection next time through the loop
                    let fromConnection = Connector.AlternatingLocation(lastLocation: incomingConnector.fromLocation)
                    let toConnection = Connector.StandardToLocation(fromLocation: fromConnection)
                    outgoingConnector = Connector(fromLocation: fromConnection, toLocation: toConnection)
                    incomingConnector = Connector(fromLocation: toConnection, toLocation: fromConnection)
                    
                    if await lastNewSegment.connections.count == 1 && nextSegment == lastNewSegment {
                        
                        await nextSegment.AppendConnection(connection: Segment.Connection(segmentID: nil, connector: outgoingConnector))
                        // nextSegment.connections.append(Segment.Connection(segment: nil, connector: outgoingConnector))
                    }
                    
                    lastSegment = nextSegment
                }
                
                // do a quick check - this should never happen and should be treated as a programming error
                for nextNewSegment in newSegments {
                    
                    if await nextNewSegment.connections.count > 2 {
                        
                        throw PhaseModelError(info: "\(await nextNewSegment.location)", type: .TooManyConnectors)
                    }
                }
            }
            catch {
                
                throw error
            }
            
        }
        else { // oldSegments.count < newSegments.count
            
            throw PhaseModelError(info: "", type: .OldSegmentCountIsNotOne)
            
        }
    }
    
    /// Function to check the comparative position of 'toSegment' with respect to 'fromSegment'. For instance, if 'fromSegment;' is in coil position 2, and toSegment is in coil position 1, the function will return 'adjacentInner'. The 'toSegment' parameter must exit in the current model or an error is thrown. It is not necessary that the fromSegment exists in the model, but it must have the correct location (with repsect to the current model) set in it.
    func ComparativePosition(fromSegment:Segment, toSegment:Segment) async throws -> Segment.ComparativePosition {
        
        guard self.segments.contains(toSegment) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
            
        }
        
        guard await fromSegment.location != toSegment.location else {
            
            throw PhaseModelError(info: "There is already a Segment at that axial location.", type: .IllegalLocation)
        }
        
        let fromRadial = await fromSegment.location.radial
        let toRadial = await toSegment.location.radial
        let radialDiff = fromRadial - toRadial
        
        let fromAxial = await fromSegment.location.axial
        let toAxial = await toSegment.location.axial
        
        if radialDiff > 0 {
            
            if radialDiff == 1 {
                
                return .innerAdjacent
            }
            else {
                
                return .inner
            }
        }
        else if radialDiff < 0 {
            
            if radialDiff == -1 {
                
                return .outerAdjacent
            }
            else {
                
                return .outer
            }
        }
        else {
            
            let toIndex = self.segments.firstIndex(of: toSegment)!
            let isBottom = await self.segments[toIndex - 1].location.radial < toRadial
            
            if toIndex == 0 || (toIndex > 0 && isBottom) {
                
                return .bottom
            }
            
            let isTop = await self.segments[toIndex + 1].location.radial > toRadial
            if toIndex == self.segments.endIndex - 1 || isTop {
                
                return .top
            }
            
            let prevIsTo:Bool = await self.segments[toIndex - 1].location.radial == toRadial
            let nextIsTo = await self.segments[toIndex + 1].location.radial == toRadial
            let prevIndex:Int? = toIndex > 0 && prevIsTo ? toIndex - 1 : nil
            let nextIndex:Int? = toIndex < self.segments.endIndex - 1 && nextIsTo ? toIndex + 1 : nil
            
            let axialDiff = fromAxial - toAxial
            
            if axialDiff > 0 {
                
                // 'toSegment' is below
                if let next = nextIndex {
                    
                    if await self.segments[next].location.axial > fromAxial {
                        
                        return .adjacentBelow
                    }
                    else if await self.segments[next].location.axial == fromAxial {
                        
                        throw PhaseModelError(info: "There is already a Segment at that axial location.", type: .IllegalLocation)
                    }
                }
                
                return .below
            }
            else if axialDiff < 0 {
                
                // toSegment is above
                if let prev = prevIndex {
                    
                    if await self.segments[prev].location.axial < fromAxial {
                        
                        return .adjacentAbove
                    }
                    else if await self.segments[prev].location.axial == fromAxial {
                        
                        throw PhaseModelError(info: "There is already a Segment at that axial location.", type: .IllegalLocation)
                    }
                }
                
                return .above
                
            }
            else {
                
                throw PhaseModelError(info: "There is already a Segment at that axial location.", type: .IllegalLocation)
            }
        }
    }
    
    
    /// Routine to check whether an array of Segments is contiguous. It is not necessary for the 'segments' array to be sorted.
    func SegmentsAreContiguous(segments:[Segment]) -> Bool {
        
        if segments.count == 0 {
            
            return false
        }
        
        if segments.count == 1 {
            
            return true
        }
        
        // sort the array the same way that the segmentStore property is sorted
        let sortedSegments = segments.sorted(by: { lhs, rhs in
            
            if lhs.radialPos != rhs.radialPos {
                
                return lhs.radialPos < rhs.radialPos
            }
            
            return lhs.axialPos < rhs.axialPos
        })
        
        // find the index of the first entry in the model
        if let firstIndex = self.segmentStore.firstIndex(of: sortedSegments[0]) {
            
            for i in 1..<sortedSegments.count {
                
                if firstIndex + i >= self.segmentStore.count {
                    
                    return false
                }
                
                if self.segmentStore[firstIndex + i] != sortedSegments[i] {
                    
                    return false
                }
            }
        }
        else {
            
            return false
        }
        
        // we've run the gauntlet, return true
        return true
    }
    
    /// Essentially, this function creates (overwrites) the Nodes that are attached to the top and bottom of each segment in the current model. A Node may be shared, as in when a Segment.Connection exists between two Segments, _particularly_ the top of one Segment that is connected to the bottom of the next axial Segment.Note that if there is no connection between two adjacent segments, a floating node is created on each segment. All other Connections (ie: between different coils or non-contiguous Segments) will only be handled when refining the capacitance matrix prior to impulse simulation. The function returns an array of Ints that are the index (in the Nodes array) to  the LAST (uppermost) Node for each *coil*.
    func SetNodes() async throws -> [Int] {
        
        guard self.segments.count > 0 else {
            
            throw PhaseModelError(info: "", type: .EmptyModel)
        }
        
        // clear the Node array
        self.nodeStore = []
        var result:[Int] = []
        
        // split the Segment array into coils (without shielding elements)
        var currentCoil = -1
        var coils:[[Segment]] = []
        var nextCoil:[Segment] = []
        
        for nextSegment in self.segments {
            
            if nextSegment.radialPos != currentCoil {
                
                if (currentCoil >= 0) {
                    
                    coils.append(nextCoil)
                }
                
                currentCoil = nextSegment.radialPos
                nextCoil = []
            }
            
            // don't add static rings
            if nextSegment.axialPos >= 0 {
            
                nextCoil.append(nextSegment)
            }
        }
        
        coils.append(nextCoil)
        
        var nextNodeNum = 0
        for nextCoil in coils {
            
            var prevSegment:Segment? = nil
            
            for i in 0..<nextCoil.count {
                
                let thisSegment = nextCoil[i]
                
                /*
                if thisSegment.serialNumber >= 80 && thisSegment.serialNumber <= 82 {
                    
                    print("Stop!")
                } */
                
                let nodeZ = await prevSegment == nil ? thisSegment.z1 : (prevSegment!.z2 + thisSegment.z1) / 2.0
                let newNode = Node(number: nextNodeNum, aboveSegment: thisSegment, belowSegment: prevSegment, z: nodeZ)
                nextNodeNum += 1
                self.nodeStore.append(newNode)
                
                if (i < nextCoil.count - 1) {
                    
                    let nextAxialSegment = nextCoil[i + 1]
                    
                    // Two Segments share a node only when they are genuinely in SERIES. A tapping gap is a break in the winding, so
                    // it gets a node on each side even when the user has bridged it with a jumper: the jumper is an electrical
                    // connection, not a series one, and SimulationModel ties the two nodes together explicitly through
                    // finalConnectedNodes -> mergedNodes -> the V_eliminated - V_kept = 0 row surgery in the solver's Assemble.
                    //
                    // This is the same predicate NonAdjacentConnections uses ("these will be adjacent, but for the purposes of the
                    // simulation they will not be"), so the two routines now agree by construction. They did not before: this test
                    // matched ANY connection to the next Segment, so a bridged tapping gap was treated as continuous here while
                    // NodeAt went on insisting that a center connector - which is only ever created at a tapping/DV gap - must land
                    // on a dangling node. SimulationModel's init then failed to resolve the jumper it had just been handed.
                    //
                    // Both operands are hoisted into locals because both need an await, and '||' makes its right-hand side a
                    // nonisolated autoclosure that cannot carry one.
                    let gapBetweenSegments = await self.IsTappingGap(segment1: thisSegment, segment2: nextAxialSegment)
                    let seriesConnection = await thisSegment.connections.first(where: {$0.segmentID == nextAxialSegment.serialNumber})

                    if gapBetweenSegments || seriesConnection == nil {

                        let newNode = await Node(number: nextNodeNum, aboveSegment: nil, belowSegment: thisSegment, z: thisSegment.z2)
                        nextNodeNum += 1
                        self.nodeStore.append(newNode)
                        prevSegment = nil
                    }
                    else {
                        
                        prevSegment = thisSegment
                    }
                }
                else { // topmost segment of the coil
                    
                    let topNode = await Node(number: nextNodeNum, aboveSegment: nil, belowSegment: thisSegment, z: thisSegment.z2)
                    result.append(nextNodeNum)
                    nextNodeNum += 1
                    self.nodeStore.append(topNode)
                }
            }
        }

        try await self.VerifyNodeTopology()

        return result
    }

    /// Check that every connector in the model lands on a node, and throw if one does not.
    ///
    /// # Why this check and not a count
    ///
    /// The obvious guard is arithmetic: SetNodes emits one node per Segment, one more per break and one per coil, so
    /// `nodeStore.count == CoilSegments().count + breaks + coils`. That identity is useless as a check, because `breaks` is
    /// defined by the very predicate most likely to be wrong. When SetNodes was treating a BRIDGED tapping gap as continuous, the
    /// count identity held perfectly - the node total was exactly consistent with the (wrong) break decision. A guard derived from
    /// the same loop can only ever confirm that the loop did what the loop does.
    ///
    /// What actually broke was the CONTRACT BETWEEN two routines: SetNodes decides where nodes go, NodeAt decides where a given
    /// connector expects to find one, and nothing checked that the two agreed. This does, by asking NodeAt to resolve every
    /// connector the model holds. It is independent of the break predicate, so it catches a wrong break decision - which is
    /// precisely the class of bug the count cannot see.
    ///
    /// Both ends are checked, with the asymmetry that matters: the FROM end is a physical location on the Segment and must always
    /// resolve, while the TO end is only a location when the connection targets another Segment. A termination's toLocation
    /// (`floating`, `ground`, `impulse`) is not a place on a coil and is deliberately not looked up.
    ///
    /// Cost is O(segments x connections x nodes) with a trivial comparison inside, which at a few hundred Segments is far below the
    /// capacitance assembly that follows. It throws rather than asserting so that a Release build fails honestly too - the failure
    /// this replaces surfaced hundreds of lines away in SimulationModel.init, where ALog only traps in DEBUG.
    func VerifyNodeTopology() async throws {

        for nextSegment in self.CoilSegments() {

            for nextConnection in await nextSegment.connections {

                let connector = nextConnection.connector

                guard self.NodeAt(segment: nextSegment, useFrom: true, connector: connector) != nil else {

                    throw PhaseModelError(info: "segment \(nextSegment.serialNumber) has a connector at \(connector.fromLocation) with no node there (target: \(nextConnection.segmentID.map({ String($0) }) ?? "termination \(connector.toLocation)")).", type: .UnresolvableConnector)
                }

                guard let destID = nextConnection.segmentID else {

                    continue
                }

                guard self.NodeAt(segmentID: destID, useFrom: false, connector: connector) != nil else {

                    throw PhaseModelError(info: "segment \(nextSegment.serialNumber) connects \(connector.fromLocation) -> \(connector.toLocation) to segment \(destID), which has no node at \(connector.toLocation).", type: .UnresolvableConnector)
                }
            }
        }
    }
    
    
    func CalculateCapacitanceMatrix() async throws {
        
        guard self.segments.count > 0 else {
            
            throw PhaseModelError(info: "", type: .EmptyModel)
        }
        
        do {
            
            let coilSegments = self.CoilSegments()
            // start with the series capacitances
            for i in 0..<coilSegments.count {
                
                let nextSegment = coilSegments[i]
                
                // this shouldn't happen
                if nextSegment.radialPos < 0 || nextSegment.axialPos < 0 {
                    
                    continue
                }
                
                let isBottomSegment:Bool = await nextSegment.location.axial == 0
                let topSegmentIndex = try await GetHighestSection(coil: nextSegment.location.radial)
                let isTopSegment:Bool = await nextSegment.location.axial == topSegmentIndex
                
                let endDisc:(lowest:Bool, highest:Bool)? = (isBottomSegment || isTopSegment) ? (isBottomSegment, isTopSegment) : nil
                
                let staticRingUnder = try await StaticRingBelow(segment: nextSegment)
                let staticRingOver = try await StaticRingAbove(segment: nextSegment)
                
                /*
                if staticRingOver != nil {
                    
                    print("Stop here")
                } */
                
                if staticRingOver != nil && staticRingUnder != nil {
                    
                    let extraInfo = topSegmentIndex == 0 ? "(If this is a disc or helical coil, consider splitting it into at least 2 Segments.)" : ""
                    throw PhaseModelError(info: extraInfo, type: .OnlyOneStaticRingAllowed)
                }
                
                var adjStaticRing:(above:Bool, below:Bool)? = (false, false)
                if staticRingOver != nil {
                    
                    adjStaticRing = (above:true, below:false)
                }
                else if staticRingUnder != nil {
                    
                    adjStaticRing = (above:false, below:true)
                }
                else {
                    
                    adjStaticRing = nil
                }
                
                var axialGaps:(above:Double, below:Double)? = nil
                var radialGaps:(inside:Double, outside:Double)? = nil
                
                var wdgIsDiscOrHelix = await nextSegment.wdgType == .disc
                wdgIsDiscOrHelix = await nextSegment.wdgType == .helical || wdgIsDiscOrHelix
                if wdgIsDiscOrHelix {
                    
                    axialGaps = try await self.AxialSpacesAboutSegment(segment: nextSegment)
                }
                else {
                    
                    radialGaps = try await self.RadialSpacesAboutSegment(segment: nextSegment)
                }
                
                let serCap = try await nextSegment.SeriesCapacitance(axialGaps: axialGaps, radialGaps: radialGaps, endDisc: endDisc, adjStaticRing: adjStaticRing)
                
                await nextSegment.SetSeriesCapacitance(serCap: serCap)
                // nextSegment.seriesCapacitance = serCap
            }
            
            // Now we take care of the shunt capacitances
            
            // First, we update the Nodes array. This sets up the nodes on each Segment, and returns an array of the topmost nodes (as an Int index into the self.nodeStore array) for the coils.
            let coilTopNodes = try await SetNodes()
            
            // let floatingNodes = self.NodesOfType(connType: .floating)
            
            switch PhaseModel.shuntBooking {
            case .capLink:
                try await BookShuntCapacitancesByCapLink(coilTopNodes: coilTopNodes)
            case .overlap:
                try await BookShuntCapacitancesByOverlap()
            }
            
            // At this point, all of the series and shunt capacitances have been calculated, so we can create the C-matrix. Note that at this point, the matrix has not taken into consideration any cross connections, nodal connections to ground, etc.
            
            let C = PchMatrix(matrixType: .general, numType: .Double, rows: UInt(self.nodeStore.count), columns: UInt(self.nodeStore.count))
            
            for nextNode in self.nodes {
                
                let Cj = await nextNode.belowSegment != nil ? nextNode.belowSegment!.seriesCapacitance : 0.0
                let Cj1 = await nextNode.aboveSegment != nil ? nextNode.aboveSegment!.seriesCapacitance : 0.0
                
                guard Cj > 0.0 || Cj1 > 0.0 else {
                    
                    throw PhaseModelError(info: "\(nextNode.number)", type: .NodeHasNoSegments)
                }
                
                var sumK = 0.0
                for nextShuntCap in nextNode.shuntCapacitances {
                    
                    // ground nodes are not included in the capacitance matrix, but everything else is
                    if nextShuntCap.toNode >= 0 {
                    
                        // in case there's alrady something in that cell
                        var existingCap = 0.0
                        if let cap:Double = await C[nextNode.number, nextShuntCap.toNode] {
                            
                            existingCap = cap
                        }
                        
                        // C[nextNode.number, nextShuntCap.toNode] = existingCap - nextShuntCap.capacitance
                        await C.SetDoubleValue(value: existingCap - nextShuntCap.capacitance, row: nextNode.number, col: nextShuntCap.toNode)
                    }
                    
                    sumK += nextShuntCap.capacitance
                }
                
                // C[nextNode.number, nextNode.number] = Cj + Cj1 + sumK
                await C.SetDoubleValue(value: Cj + Cj1 + sumK, row: nextNode.number, col: nextNode.number)
                
                if Cj != 0.0 {
                    
                    // C[nextNode.number, nextNode.number - 1] = -Cj
                    await C.SetDoubleValue(value: -Cj, row: nextNode.number, col: nextNode.number - 1)
                }
                
                if Cj1 != 0.0 {
                    
                    // C[nextNode.number, nextNode.number + 1] = -Cj1
                    await C.SetDoubleValue(value: -Cj1, row: nextNode.number, col: nextNode.number + 1)
                }
            }
            
            self.C = C
        }
        catch {
            
            throw error
        }
    }
    
    /// The original shunt booking: the Super Duper Shunt Capacitance Algorithm™ for coil pairs, and a uniform per-metre spread for
    /// everything booked to ground. Kept, unchanged, as one side of the `ShuntBooking` switch - see TODO item 6.
    private func BookShuntCapacitancesByCapLink(coilTopNodes:[Int]) async throws {
        
        // Init some local vars
        var innerFirstNode = 0
        var outerFirstNode = 0
        var innerCoilHt = 0.0
        var referenceZero = await self.nodeStore[0].aboveSegment!.z1
        
        // For each coil ('i' is the index of the "outer" coil)
        for i in 0..<coilTopNodes.count {
            
            // we need to find the first (ie: lowest) and last (highest) node for the outermost coil. Note that for coil '0' (the innermost coil), the core is considered to be the 'inner' coil
            outerFirstNode = i == 0 ? 0 : coilTopNodes[i - 1] + 1
            let outerLastNode = coilTopNodes[i]
            
            // get the overall height of the outer coil
            let outerCoilHt = await self.nodeStore[outerLastNode].belowSegment!.z2 - self.nodeStore[outerFirstNode].aboveSegment!.z1
            // fix the reference '0' for the coil pair (set it to the lesser of the two)
            referenceZero = await min(referenceZero, self.nodeStore[outerFirstNode].aboveSegment!.z1)
            
            ZAssert(outerCoilHt > 0.0, message: "Got negative height!")
            
            // Get the shunt capacitance between the 'i-th' coil and the i-1 coil
            let totalCapacitance = try await CoilInnerShuntCapacitance(coil: i)
            
            ZAssert(totalCapacitance > 0.0, message: "Got negative total capacitance")
            
            // choose the higher of the two heights as the reference to use
            let referenceHt = max(innerCoilHt, outerCoilHt)
            
            // come up with a rate of change for the capacitance
            let faradsPerMeter = totalCapacitance / referenceHt
            
            struct nodeCap {
                
                let nodeIndex:Int
                let z:Double
                let cap:Double
            }
            
            let currentCoil = self.nodeStore[outerFirstNode].aboveSegment!.radialPos
            let hasShieldInside = try await self.RadialShieldInside(coil: currentCoil) != nil
            var innerNodeCaps:[nodeCap] = []
            
            // What we do next depends if this is the innermost coil, or if there is a ground shield inside the coil
            if i == 0 || hasShieldInside {
                
                // take care of the special case where it's the first coil (ie: the 'inner coil' is actually the core)
                innerNodeCaps = [nodeCap(nodeIndex: -1, z: 0.0, cap: totalCapacitance / 2.0), nodeCap(nodeIndex: -1, z: referenceHt, cap: totalCapacitance / 2.0)]
            }
            else {
                
                let innerLastNode = coilTopNodes[i - 1]
                innerCoilHt = self.nodeStore[innerLastNode].z - self.nodeStore[innerFirstNode].z
                
                for j in innerFirstNode...innerLastNode {
                    
                    let lastCcum = j == innerFirstNode ? 0.0 : (self.nodeStore[j - 1].z - referenceZero) * faradsPerMeter
                    let nextCcum = j == innerLastNode ? totalCapacitance : (self.nodeStore[j + 1].z - referenceZero) * faradsPerMeter
                    
                    let nextNodeCap = nodeCap(nodeIndex: j, z: self.nodeStore[j].z, cap: (nextCcum - lastCcum) / 2.0)
                    innerNodeCaps.append(nextNodeCap)
                }
            }
            
            // At this point, the (inner -> outer) shunt capacitances are calculated; now calculate the (outer -> inner) capacitances
            
            var outerNodeCaps:[nodeCap] = []
            
            for j in outerFirstNode...outerLastNode {
                
                let lastCcum = j == outerFirstNode ? 0.0 : (self.nodeStore[j - 1].z - referenceZero) * faradsPerMeter
                let nextCcum = j == outerLastNode ? totalCapacitance : (self.nodeStore[j + 1].z - referenceZero) * faradsPerMeter
                
                let nextNodeCap = nodeCap(nodeIndex: j, z: self.nodeStore[j].z, cap: (nextCcum - lastCcum) / 2.0)
                outerNodeCaps.append(nextNodeCap)
            }
            
            // At this point, the two sets of node capacitances are set up. Take care of the trivial cases first, where the shunt capacitances from the innermost coil are to the core or a radial shield (a ground plane).
            if i == 0 || hasShieldInside {
                
                for nextNodeCap in outerNodeCaps {
                    
                    self.nodeStore[nextNodeCap.nodeIndex].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: nextNodeCap.cap))
                }
            }
            else {
                
                // Apply the Super Duper Shunt Capacitance Algorithm™ by PCH
                
                struct capLink {
                    
                    let innerNode:Int
                    let outerNode:Int
                    let aveCap:Double
                }
                
                // set the indices into the various arrays
                let inner = 0
                let outer = 1
                
                // initialize arrays & variables
                let nodeCaps = [innerNodeCaps, outerNodeCaps]
                var currentNodeIndex = [0, 0]
                var cumCap = [innerNodeCaps[0].cap, outerNodeCaps[0].cap]
                // set the reference coil as the one whose first node has the lower capacitance (ie: the most nodes - I think)
                var refCoil = nodeCaps[inner][0].cap <= nodeCaps[outer][0].cap ? inner : outer
                var otherCoil = refCoil == inner ? outer : inner
                var capLinks:[capLink] = []
                var prevAverageC = 0.0
                
                while currentNodeIndex[inner] < nodeCaps[inner].count && currentNodeIndex[outer] < nodeCaps[outer].count {
                
                    // This is where weird things like large axial gaps in tapping windings are (should) be taken care of
                    let thisAverageZ = (nodeCaps[inner][currentNodeIndex[inner]].z + nodeCaps[outer][currentNodeIndex[outer]].z) / 2.0
                    let thisAverageC = (thisAverageZ - referenceZero) / referenceHt * totalCapacitance
                    
                    let innerNode = nodeCaps[inner][currentNodeIndex[inner]].nodeIndex
                    let outerNode = nodeCaps[outer][currentNodeIndex[outer]].nodeIndex
                    
                    // capLinks.append(capLink(innerNode: nodeCaps[inner][currentNodeIndex[inner]].nodeIndex, outerNode: nodeCaps[outer][currentNodeIndex[outer]].nodeIndex, aveCap: averageC))
                     
                    let refValue = nodeCaps[refCoil][currentNodeIndex[refCoil]].cap / 2.0
                    
                    if abs(cumCap[inner] - cumCap[outer]) > refValue {
                            
                        currentNodeIndex[refCoil] += 1
                        
                        if currentNodeIndex[refCoil] >= nodeCaps[refCoil].count {
                            
                            break
                        }
                        
                        cumCap[refCoil] += nodeCaps[refCoil][currentNodeIndex[refCoil]].cap
                    }
                    else {
                        
                        currentNodeIndex[refCoil] += 1
                        currentNodeIndex[otherCoil] += 1
                        
                        if currentNodeIndex[inner] >= nodeCaps[inner].count && currentNodeIndex[outer] >= nodeCaps[outer].count {
                            
                            break
                        }
                        
                        if currentNodeIndex[refCoil] < nodeCaps[refCoil].count {
                            
                            cumCap[refCoil] += nodeCaps[refCoil][currentNodeIndex[refCoil]].cap
                        }
                        else {
                            
                            currentNodeIndex[refCoil] = nodeCaps[refCoil].count - 1
                        }
                        
                        if currentNodeIndex[otherCoil] < nodeCaps[otherCoil].count {
                            
                            cumCap[otherCoil] += nodeCaps[otherCoil][currentNodeIndex[otherCoil]].cap
                        }
                        else {
                            
                            currentNodeIndex[otherCoil] = nodeCaps[otherCoil].count - 1
                        }
                    }
                    
                    let nextAverageZ = (nodeCaps[inner][currentNodeIndex[inner]].z + nodeCaps[outer][currentNodeIndex[outer]].z) / 2.0
                    let nextAverageC = (nextAverageZ - referenceZero) / referenceHt * totalCapacitance
                    
                    let averageC = (nextAverageC - prevAverageC) / 2
                    
                    prevAverageC = thisAverageC
                    
                    capLinks.append(capLink(innerNode: innerNode, outerNode: outerNode, aveCap: averageC))
                    
                    refCoil = nodeCaps[inner][currentNodeIndex[inner]].cap <= nodeCaps[outer][currentNodeIndex[outer]].cap ? inner : outer
                    otherCoil = refCoil == inner ? outer : inner
                }
                
                // add the final shunt capacitance
                capLinks.append(capLink(innerNode: nodeCaps[inner].last!.nodeIndex, outerNode: nodeCaps[outer].last!.nodeIndex, aveCap: (totalCapacitance - prevAverageC) / 2))
                
                // convert the capLinks to shunt capacitances
                for j in 0..<capLinks.count {
                    
                    // let lowIndex = max(0, j - 1)
                    // let hiIndex = min(capLinks.count - 1, j + 1)
                    // let shuntCap = (capLinks[hiIndex].aveCap - capLinks[lowIndex].aveCap) / 2.0
                    
                    let shuntCap = capLinks[j].aveCap
                    self.nodeStore[capLinks[j].innerNode].shuntCapacitances.append(Node.shuntCap(toNode: capLinks[j].outerNode, capacitance: shuntCap))
                    self.nodeStore[capLinks[j].outerNode].shuntCapacitances.append(Node.shuntCap(toNode: capLinks[j].innerNode, capacitance: shuntCap))
                }
            }
            
            // We now need to check if there is a radial shield OUTSIDE the coil
            if let radialShieldOutside = try await self.RadialShieldOutside(coil: currentCoil) {
                
                let rsCoil = radialShieldOutside.radialPos
                let rsCapacitance = try await self.CoilInnerShuntCapacitance(coil: rsCoil)
                
                let coilLastNode = outerLastNode
                let coilFirstNode = outerFirstNode
                
                let rsFaradsPerMeter = rsCapacitance / referenceHt
                
                var rsNodeCaps:[nodeCap] = []
                for j in coilFirstNode...coilLastNode {
                    
                    let lastCcum = j == coilFirstNode ? 0.0 : (self.nodeStore[j - 1].z - referenceZero) * rsFaradsPerMeter
                    let nextCcum = j == coilLastNode ? rsCapacitance : (self.nodeStore[j + 1].z - referenceZero) * rsFaradsPerMeter
                    
                    let nextNodeCap = nodeCap(nodeIndex: j, z: self.nodeStore[j].z, cap: (nextCcum - lastCcum) / 2.0)
                    rsNodeCaps.append(nextNodeCap)
                }
                
                for nextNodeCap in rsNodeCaps {
                    
                    self.nodeStore[nextNodeCap.nodeIndex].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: nextNodeCap.cap))
                }
            }
            
            // set some variables for the next time through the loop
            innerCoilHt = outerCoilHt
            innerFirstNode = outerFirstNode
            
        }
        
        // Add the shunt capacitances to ground for the outermost coil. The tank and the adjacent phase are both ground here -
        // see OuterShuntCapacitance for what that assumes - so they are distributed as a single figure.
        let outerTerms = try await OuterShuntCapacitance()
        let outerCapacitance = outerTerms.tank + outerTerms.adjacentPhase
        let referenceHt = self.nodeStore[coilTopNodes.last!].z - self.nodeStore[innerFirstNode].z
        referenceZero = self.nodeStore[innerFirstNode].z
        let faradsPerMeter = outerCapacitance / referenceHt
        
        for j in innerFirstNode...coilTopNodes.last! {
            
            let lastCcum = j == innerFirstNode ? 0.0 : (self.nodeStore[j - 1].z - referenceZero) * faradsPerMeter
            let nextCcum = j == coilTopNodes.last! ? outerCapacitance : (self.nodeStore[j + 1].z - referenceZero) * faradsPerMeter
            
            self.nodeStore[j].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: (nextCcum - lastCcum) / 2.0))
        }
    }

    // MARK: Shunt booking (TODO items 6, 6a and 6b)

    /// The two ways `CalculateCapacitanceMatrix` can share the shunt capacitances out among the nodes.
    ///
    /// **Temporary.** The switch exists so that the two can be run on the same build and the same fixture and compared; once item
    /// 6 is settled one of them goes. It is read from the `PCH_ShuntBooking` default, which `NSUserDefaults` fills from a launch
    /// argument by itself - `-PCH_ShuntBooking overlap` - in the same way `SelfTest` gets its arguments. Anything else, including
    /// no argument at all, is `.capLink`, so a normal launch is unchanged.
    enum ShuntBooking: String, Sendable {

        /// The Super Duper Shunt Capacitance Algorithm™: per-coil totals from the analytic formulas, spread at a uniform rate per
        /// metre over the node z positions and matched up node to node across each hilo.
        case capLink
        /// Overlap-plus-decay: coupling booked disc pair by disc pair where the two conductors face each other, and decaying as
        /// exp(-π·d/g) where they do not. See `OverlapDecayCoupling`.
        case overlap
    }

    static var shuntBooking:ShuntBooking {

        return ShuntBooking(rawValue: UserDefaults.standard.string(forKey: "PCH_ShuntBooking") ?? "") ?? .capLink
    }

    /// One side of a shunt pair: an axially sorted list of electrodes, each either a Segment (with the two nodes it is booked
    /// onto) or a grounded surface (the core, a radial shield, the tank, the adjacent phase).
    struct ShuntElectrode: Sendable {

        let z1:Double
        let z2:Double
        /// The Segment's bottom and top node; nil for a grounded electrode.
        let nodes:(bottom:Int, top:Int)?
    }

    /// The overlap-plus-decay coupling between two sides of a radial gap.
    ///
    /// # The rule
    ///
    /// The per-metre capacitance `c′` across the gap is what the analytic formulas already give - DV 12.61 for coil to coil,
    /// K&K 7.15 for the tank and the adjacent phase. Every one of them is linear in the height H it is evaluated at, so
    /// `c′ = C(H)/H` exactly. What this replaces is the height: rather than a single H for the pair (the average of the two
    /// effective heights, for coil to coil), the coupling is integrated along z, and at each z it is
    ///
    ///     dC = c′ · exp(-π·(d_A(z) + d_B(z))/g) · dz,      booked to (nearest electrode of A, nearest electrode of B)
    ///
    /// where `d_A(z)` is the axial distance from z to the nearest conductor of side A (zero where A has conductor at z), and g
    /// is the radial gap. So:
    ///
    /// * where both sides have conductor at z, the weight is 1 and the coupling is DV's;
    /// * where only one does - a disc beyond the end of the other coil, or facing a gap in it - the weight is exp(-π·d/g), the
    ///   decay of the field into a two-dimensional slot of width g from the edge of one of its electrodes. Integrated over a
    ///   long overhang that is worth g/π of extra facing height per free edge;
    /// * where neither does - two ducts facing each other - the weight is exp(-π·(d_A + d_B)/g). Over a duct a few mm high in
    ///   a gap tens of mm wide that is close to 1, which is right: a disc stack seen from across the hilo is very nearly a
    ///   continuous surface, and DV counts its full height for exactly that reason. (Weighting it 0 instead would take every
    ///   duct out of the coupling of two aligned disc coils - 15-25% of the total - for no physical reason.)
    ///
    /// Item 5's 75 mm rule has no counterpart here: a small gap is counted almost in full and a large one fringes, on one rule.
    ///
    /// # What it is not
    ///
    /// An engineering estimate, not a field solution. exp(-πd/g) is the lowest mode of a uniform slot; the real gap is layered
    /// (pressboard barriers in oil), the electrodes have finite radial build, and the end faces of the discs are ignored. The
    /// electrostatic FE run proposed in 6b is the reference that calibrates the g to use.
    ///
    /// # The integration
    ///
    /// The integrand is piecewise exponential in z. Between consecutive breakpoints - every electrode edge, the midpoint of every
    /// gap between two electrodes of the same side (where "nearest" changes over), and the ends of the window - the nearest
    /// electrode on each side is fixed and each d is either 0 or linear in z, so d_A + d_B = K·z − C0 with K ∈ {−2, −1, 0, 1, 2},
    /// and the piece integrates in closed form:
    ///
    ///     K = 0:  c′·(t − s)·exp(−π·D/g),    D the (constant) sum
    ///     K ≠ 0:  c′·g/(π·K)·(exp(−π·D(s)/g) − exp(−π·D(t)/g))
    ///
    /// which is positive for either sign of K, and never evaluates a growing exponential because D ≥ 0 throughout.
    ///
    /// - Parameters:
    ///   - a, b: each side's electrodes, sorted by z and not overlapping (the Segments of one coil never do).
    ///   - gap: the radial gap g between the two sides' facing surfaces, m.
    ///   - faradsPerMetre: c′, F/m.
    ///   - zMin, zMax: the window the integration runs over - the yokes, which are grounded, end it.
    /// - Returns: the capacitance between electrode `a[i]` and `b[j]`, keyed by (i, j). Every pair that gets any coupling at all
    ///   appears; pairs that get none do not.
    static func OverlapDecayCoupling(a:[ShuntElectrode], b:[ShuntElectrode], gap g:Double, faradsPerMetre:Double, zMin:Double, zMax:Double) -> [PairIndex:Double] {

        guard !a.isEmpty, !b.isEmpty, g > 0.0, zMax > zMin else {

            return [:]
        }

        var breaks:[Double] = [zMin, zMax]

        for side in [a, b] {

            for i in 0..<side.count {

                breaks.append(side[i].z1)
                breaks.append(side[i].z2)

                if i > 0 {

                    breaks.append((side[i - 1].z2 + side[i].z1) / 2.0)
                }
            }
        }

        breaks = breaks.filter({ $0 >= zMin && $0 <= zMax }).sorted()

        // The nearest electrode of a side to z, as (index, k, e) with d(z) = k·(z − e): k = 0 inside it, +1 above it (e its top),
        // −1 below it (e its bottom). Only ever asked at the midpoint of a piece, so z is never on a breakpoint.
        func Nearest(_ side:[ShuntElectrode], _ z:Double) -> (index:Int, k:Double, e:Double) {

            if z < side[0].z1 {

                return (0, -1.0, side[0].z1)
            }

            for i in 0..<side.count {

                if z <= side[i].z2 {

                    if z >= side[i].z1 {

                        return (i, 0.0, 0.0)
                    }

                    // in the gap between i - 1 and i (i > 0, because z >= side[0].z1)
                    let midGap = (side[i - 1].z2 + side[i].z1) / 2.0
                    return z < midGap ? (i - 1, 1.0, side[i - 1].z2) : (i, -1.0, side[i].z1)
                }
            }

            return (side.count - 1, 1.0, side[side.count - 1].z2)
        }

        var result:[PairIndex:Double] = [:]

        for p in 0..<breaks.count - 1 {

            let s = breaks[p]
            let t = breaks[p + 1]

            // breakpoints closer than a micron are the same edge (see MeshBuilder.coordinateTolerance, for the same reason)
            guard t - s > 1.0e-6 else {

                continue
            }

            let mid = (s + t) / 2.0
            let nearA = Nearest(a, mid)
            let nearB = Nearest(b, mid)

            let K = nearA.k + nearB.k
            let C0 = nearA.k * nearA.e + nearB.k * nearB.e

            // the distance sum at each end of the piece; never negative, but clamp the rounding
            let Ds = max(0.0, K * s - C0)
            let Dt = max(0.0, K * t - C0)

            let pieceC:Double

            if K == 0.0 {

                pieceC = faradsPerMetre * (t - s) * exp(-π * Ds / g)
            }
            else {

                pieceC = faradsPerMetre * g / (π * K) * (exp(-π * Ds / g) - exp(-π * Dt / g))
            }

            result[PairIndex(a: nearA.index, b: nearB.index), default: 0.0] += pieceC
        }

        return result
    }

    struct PairIndex: Hashable, Sendable {

        let a:Int
        let b:Int
    }

    /// The shunt booking by overlap-plus-decay (TODO item 6b, step 1). Books, for every radial gap in the phase:
    ///
    /// 1. **coil i to whatever is inside it** - the core for coil 0, a radial shield if there is one, otherwise coil i − 1 - at
    ///    `c′ = CoilInnerShuntCapacitance(i) / CapacitiveHeightInner(i)` across `HiloUnder(i)`;
    /// 2. **coil i to a radial shield outside it**, the same way from the shield's side;
    /// 3. **the outermost coil to the tank and to the adjacent phase**, as two separate walks, because their gaps differ by a
    ///    factor of several and the gap sets the decay. `c′` is each term of `OuterShuntCapacitance` over the outermost coil's
    ///    `EffectiveHeight`, which is the H that function evaluates at; the gaps are the coil's OD to the tank wall and to the
    ///    midplane between the phases.
    ///
    /// The core, a shield, the tank and the adjacent phase are grounded electrodes; the core, tank and phase run the full window
    /// height. Each Segment-to-Segment capacitance is split a quarter onto each of the four pairs of their end nodes, and a
    /// Segment-to-ground one half onto each end node - the π split `CalculateCapacitanceMatrix` already uses (TODO item 4).
    ///
    /// The per-metre values come from exactly the functions the `.capLink` booking uses, so where the two disagree it is the
    /// distribution and the height that differ, not the physics of the gap.
    private func BookShuntCapacitancesByOverlap() async throws {

        // Segment serial number -> its bottom and top node
        var bottomNode:[Int:Int] = [:]
        var topNode:[Int:Int] = [:]

        for nextNode in self.nodeStore {

            if let above = nextNode.aboveSegment {

                bottomNode[above.serialNumber] = nextNode.number
            }

            if let below = nextNode.belowSegment {

                topNode[below.serialNumber] = nextNode.number
            }
        }

        let nodesOf = (bottom: bottomNode, top: topNode)
        let coilSegments = self.CoilSegments()

        func CoilElectrodes(_ coil:Int) async throws -> [ShuntElectrode] {

            var result:[ShuntElectrode] = []

            for nextSegment in coilSegments where nextSegment.radialPos == coil {

                guard let bottom = nodesOf.bottom[nextSegment.serialNumber], let top = nodesOf.top[nextSegment.serialNumber] else {

                    throw PhaseModelError(info: "segment \(nextSegment.serialNumber) has no node at one of its ends", type: .UnresolvableConnector)
                }

                result.append(ShuntElectrode(z1: await nextSegment.z1, z2: await nextSegment.z2, nodes: (bottom, top)))
            }

            return result.sorted(by: { $0.z1 < $1.z1 })
        }

        func ShieldElectrodes(_ radialPos:Int) async -> [ShuntElectrode] {

            var result:[ShuntElectrode] = []

            for nextSegment in self.segmentStore where nextSegment.radialPos == radialPos && !nextSegment.isStaticRing {

                result.append(ShuntElectrode(z1: await nextSegment.z1, z2: await nextSegment.z2, nodes: nil))
            }

            return result.sorted(by: { $0.z1 < $1.z1 })
        }

        let window = [ShuntElectrode(z1: 0.0, z2: self.core.realWindowHeight, nodes: nil)]

        func Book(_ a:[ShuntElectrode], _ b:[ShuntElectrode], gap:Double, faradsPerMetre:Double) {

            let coupling = PhaseModel.OverlapDecayCoupling(a: a, b: b, gap: gap, faradsPerMetre: faradsPerMetre, zMin: 0.0, zMax: self.core.realWindowHeight)

            for (pair, capacitance) in coupling where capacitance > 0.0 {

                switch (a[pair.a].nodes, b[pair.b].nodes) {

                case (let aNodes?, let bNodes?):

                    for aNode in [aNodes.bottom, aNodes.top] {

                        for bNode in [bNodes.bottom, bNodes.top] {

                            self.nodeStore[aNode].shuntCapacitances.append(Node.shuntCap(toNode: bNode, capacitance: capacitance / 4.0))
                            self.nodeStore[bNode].shuntCapacitances.append(Node.shuntCap(toNode: aNode, capacitance: capacitance / 4.0))
                        }
                    }

                case (let aNodes?, nil):

                    self.nodeStore[aNodes.bottom].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: capacitance / 2.0))
                    self.nodeStore[aNodes.top].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: capacitance / 2.0))

                case (nil, let bNodes?):

                    self.nodeStore[bNodes.bottom].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: capacitance / 2.0))
                    self.nodeStore[bNodes.top].shuntCapacitances.append(Node.shuntCap(toNode: -1, capacitance: capacitance / 2.0))

                case (nil, nil):

                    break
                }
            }
        }

        let coils = Array(Set(coilSegments.map({ $0.radialPos }))).sorted()

        for coil in coils {

            let outer = try await CoilElectrodes(coil)

            // 1. coil to whatever is inside it
            let inner:[ShuntElectrode]

            if let innerShield = try await self.RadialShieldInside(coil: coil) {

                inner = await ShieldElectrodes(innerShield.radialPos)
            }
            else if coil == 0 {

                inner = window
            }
            else {

                inner = try await CoilElectrodes(coil - 1)
            }

            let innerC = try await self.CoilInnerShuntCapacitance(coil: coil)
            let innerH = try await self.CapacitiveHeightInner(coil: coil)
            let innerGap = try await self.HiloUnder(coil: coil)

            Book(inner, outer, gap: innerGap, faradsPerMetre: innerC / innerH)

            // 2. coil to a radial shield outside it
            if let outerShield = try await self.RadialShieldOutside(coil: coil) {

                let rsCoil = outerShield.radialPos
                let shieldC = try await self.CoilInnerShuntCapacitance(coil: rsCoil)
                let shieldH = try await self.CapacitiveHeightInner(coil: rsCoil)
                let shieldGap = try await self.HiloUnder(coil: rsCoil)

                Book(outer, await ShieldElectrodes(rsCoil), gap: shieldGap, faradsPerMetre: shieldC / shieldH)
            }
        }

        // 3. the outermost coil to the tank and to the adjacent phase
        guard let lastCoil = coils.last, let lastCoilSeg = coilSegments.last else {

            throw PhaseModelError(info: "", type: .EmptyModel)
        }

        let outermost = try await CoilElectrodes(lastCoil)
        let outerTerms = try await self.OuterShuntCapacitance()
        let outerH = try await self.EffectiveHeight(coil: lastCoil)
        let R = await lastCoilSeg.r2

        Book(outermost, window, gap: self.tankDepth / 2.0 - R, faradsPerMetre: outerTerms.tank / outerH)

        if outerTerms.adjacentPhase > 0.0 {

            Book(outermost, window, gap: self.core.legCenters / 2.0 - R, faradsPerMetre: outerTerms.adjacentPhase / outerH)
        }
    }

    /// The outermost coil's shunt capacitance to everything outside it: the tank, and the outermost coil of the adjacent phase
    /// (per Kulkarni 7.15).
    ///
    /// **Returned split rather than summed**, because the two terms are not the same kind of thing and the split is routinely
    /// surprising. On a design with generous leg centres the tank term dominates, as one would expect; on a tight one the
    /// phase-to-phase term does, and by a lot. Both go into the same 1/acosh(s/R), but the tank sits half a tank-depth away while
    /// the adjacent phase sits half a leg-centre away, and acosh is steep near 1 - on the STME-0999 fixture (760 mm leg centres,
    /// 693.9 mm outermost OD, so 66 mm between phases) acosh(1.0953) = 0.433 against acosh(1.936) = 1.279, and the phase-to-phase
    /// term comes out **62%** of the total. A hand calculation of "coil to tank" that is checked against the sum will look wrong
    /// by a factor of 2.6 when nothing is wrong at all.
    ///
    /// Both are booked to ground by the caller, which assumes the adjacent phases are at ground potential. That is the standard
    /// impulse-test condition - the untested phases are grounded - so it is right for what this program computes, but it is an
    /// assumption and not a geometric fact.
    ///
    /// - Note: The phase-to-phase term is for **`adjacentPhaseCount`** neighbours - 2 by default, the centre leg of a three-legged
    /// core, which is the worst case. See that property for why, and for what "worst case" does and does not cover.
    func OuterShuntCapacitance() async throws -> (tank:Double, adjacentPhase:Double) {

        guard let lastCoilSeg = self.CoilSegments().last else {

            throw PhaseModelError(info: "Outermost coil", type: .CoilDoesNotExist)
        }

        do {

            let sTank = self.tankDepth / 2
            let tSolidTank = 0.25 * 0.0254
            let tOilTank = await sTank - lastCoilSeg.r2 - tSolidTank
            let H = try await EffectiveHeight(coil: lastCoilSeg.radialPos)

            // Kulkarni 7.15 is built on the cylinder-to-ground-plane result D.30, C = 2πε0/cosh⁻¹(s/R) per unit length, where R is the
            // radius of the cylinder whose SURFACE carries the charge. A winding is a conducting shell, so from the outside it presents
            // its outer radius - not its mean radius, which would understate C by inflating cosh⁻¹(s/R). Both ratios below are safely
            // greater than 1: the tank cannot be inside the coil, and adjacent phases cannot overlap.
            let R = await lastCoilSeg.r2

            // The (t_oil + t_solid)/(t_oil/ε_oil + t_solid/ε_solid) factor is 7.15's effective relative permittivity for the series
            // oil/barrier stack filling the gap.
            let firstTermTank = 2 * π * ε0 * H / acosh(sTank / R)
            let secondTermTank = (tOilTank + tSolidTank) / ((tOilTank / εOil) + (tSolidTank / εBoard))

            let Ctank = firstTermTank * secondTermTank

            let sCoils:Double = self.core.legCenters / 2
            let tSolidCoils = 2 * tSolidTank
            let tOilCoils:Double = await self.core.legCenters - (lastCoilSeg.r2 * 2) - tSolidCoils

            let firstTermCoils = 2 * π * ε0 * H / acosh(sCoils / R)
            let secondTermCoil = (tOilCoils + tSolidCoils) / ((tOilCoils / εOil) + (tSolidCoils / εBoard))

            // Kulkarni, immediately below 7.15: the capacitance between the outermost windings of two phases is HALF the value given by
            // 7.15, with s equal to half the distance between the two winding axes (which is what sCoils is). Appendix D says the same
            // thing directly - the two-cylinder result D.28 is πε0/cosh⁻¹(s/R), exactly half the cylinder-to-plane D.30 used above.
            //
            // Once per neighbouring phase. Each side is its own gap between its own pair of cylinders, so the two sides of a centre
            // leg add rather than sharing anything - and a single-phase unit, with adjacentPhaseCount 0, gets no such term at all.
            let Ccoils = Double(self.adjacentPhaseCount) * 0.5 * firstTermCoils * secondTermCoil

            return (tank: Ctank, adjacentPhase: Ccoils)
        }
        catch {

            throw error
        }

    }
    
    func CoilInnerShuntCapacitance(coil:Int) async throws -> Double {
        
        guard let bottomCoilSeg = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        let bs = bottomCoilSeg.basicSections[0];
        
        do {
            
            // start with the inner radius
            var prevIR:Double = 0.0
            if coil == 0 {
                
                // check if there's a shield OVER the core (can't imagine why this would be needed, but...)
                if let coreShield = await self.SegmentAt(location: LocStruct(radial: Segment.negativeZeroPosition, axial: 0)) {
                    
                    prevIR = await coreShield.r2
                }
                else {
                    
                    prevIR = self.core.radius
                }
            }
            else if let innerShield = await self.SegmentAt(location: LocStruct(radial: -coil, axial: 0)) {
                
                prevIR = await innerShield.r2
            }
            else {
                
                guard let prevCoilSeg = await self.SegmentAt(location: LocStruct(radial: coil - 1, axial: 0)) else {
                    
                    throw PhaseModelError(info: "\(coil-1)", type: .CoilDoesNotExist)
                }
                
                prevIR = await prevCoilSeg.r2
            }
            
            let hilo = try await HiloUnder(coil: coil)
            let rGap = prevIR + hilo / 2.0
            
            // TODO: This should probably be dependent on whether 'coil' is actually a radial shield
            let Ns = Double(bs.wdgData.discData.numAxialColumns)
            // assume 3/4" sticks
            let ws = 0.75 * 0.0254
            let fs = Ns * ws / (2 * π * rGap)
            let H = try await CapacitiveHeightInner(coil: coil)
            // assume standard radial spacers & tube thicknesses
            let Npress = round(hilo / 0.0084 - 0.5)
            let tPress = 0.08 * 0.0254 * Npress
            let tStick = hilo - tPress
            
            let firstTerm = fs / ((tPress / εBoard) + (tStick / εBoard))
            let secondTerm = (1 - fs) / ((tPress / εBoard) + (tStick / εOil))
            
            let Cinner = ε0 * 2 * π * rGap * H * (firstTerm + secondTerm)
            
            return Cinner
        }
        catch {
            
            throw error
        }
    }
    
    // Calculate the height that will be used for the shunt capacitance calculation to the coil/shield/core that is radially "inside" to the given coil.
    func CapacitiveHeightInner(coil:Int) async throws -> Double {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        do {
            
            let effCapHeight = try await EffectiveHeight(coil: coil)
            let hasRadialShieldInside = try await RadialShieldInside(coil: coil) != nil
            
            if (coil == 0 || hasRadialShieldInside) {
                
                return effCapHeight
            }
            
            let innerCoilEffCapHeight = try await EffectiveHeight(coil: coil - 1)
            
            return (effCapHeight + innerCoilEffCapHeight) / 2
        }
        catch {
            
            throw error
        }
    }
    
    // The "effective height" of a coil is simply its electrical height minus any axial gaps that are larger than 75mm (yes, that is aribtrary).
    func EffectiveHeight(coil:Int) async throws -> Double {
        
        let MAX_GAP = 0.075
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        // Static rings share their coil's radialPos and must not stretch its height, but a radial shield is asked for by its own
        // (negative) radialPos - CalculateCapacitanceMatrix does exactly that through RadialShieldOutside - so it has to be found
        // here. CoilSegments() drops both kinds, and on a shield came back empty and trapped on coilSections[0].
        let coilSections = self.segmentStore.filter({ $0.radialPos == coil && !$0.isStaticRing })
        let coilBottom = await coilSections[0].z1
        let coilTop = await coilSections.last!.z2
        let coilHeight = coilTop - coilBottom
        
        var sumAxialGaps = 0.0
        for i in 0..<coilSections.count - 1 {
            
            let nextGap = await coilSections[i+1].z1 - coilSections[i].z2
            if nextGap > MAX_GAP {
                
                sumAxialGaps += nextGap
            }
        }
        
        return coilHeight - sumAxialGaps
    }
    
    /// This is (currently) a simple (ie: useless) calculation of series capacitance (simple because it does not consider things like interconnections, line in the middle, etc.). It gives the same result as the Excel-design sheet.
    func CoilSeriesCapacitance(coil:Int) async throws -> Double {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        guard let _ = self.C else {
            
            throw PhaseModelError(info: "\(coil)", type: .CapacitanceNotCalculated)
        }
        
        
        var result = 0.0
        
        for i in 0..<self.segments.count {
            
            let nextSegment = self.segments[i]
            
            if nextSegment.radialPos == coil && nextSegment.axialPos >= 0 {
                
                // print("\(nextSegment.seriesCapacitance)")
                await result += 1.0 / nextSegment.seriesCapacitance
            }
        }
        
        return 1 / result
        
    }
    
    
    /// Insert a new Segment into the correct spot in the model to keep the segmentStore array sorted. If there is an existing Segment with the same LocStruct as the new one, this function throws an error.
    func InsertSegment(newSegment:Segment) async throws {
        
        // use binary search method to insert (probably unnecessary, but what the hell)
        var lo = 0
        var hi = self.segmentStore.count - 1
        while lo <= hi {
            
            let mid = (lo + hi) / 2
            if await self.segmentStore[mid].location < newSegment.location {
                
                lo = mid + 1
            }
            else if await newSegment.location < self.segmentStore[mid].location {
                
                hi = mid - 1
            }
            else {
                
                // The location already exists, throw an error
                throw PhaseModelError(info: "\(await newSegment.location)", type: .SegmentExists)
            }
        }
        
        self.segmentStore.insert(newSegment, at: lo)
    }
    
    /// Check if there is a radial shield inside the given coil and if so, return it as a Segment
    func RadialShieldInside(coil:Int) async throws -> Segment? {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        let radialPos = coil == 0 ? Segment.negativeZeroPosition : -coil
        
        return await self.SegmentAt(location: LocStruct(radial: radialPos, axial: 0))
    }
    
    /// Check if there a radial shield  outside the given coil and if so, return it as a Segment
    func RadialShieldOutside(coil:Int) async throws -> Segment? {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil + 1)", type: .CoilDoesNotExist)
        }
        
        return await self.SegmentAt(location: LocStruct(radial: -(coil + 1), axial: 0))
    }
    
    /// Get the Hilo under the given coil (or shield)
    func HiloUnder(coil:Int) async throws -> Double {
        
        guard let segment = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        let coilInnerRadius = await segment.r1
        
        if coil < 0 {
            
            guard let innerSegment = await self.SegmentAt(location: LocStruct(radial: (-coil) - 1, axial: 0)) else {
                
                throw PhaseModelError(info: "\(coil - 1)", type: .CoilDoesNotExist)
            }
            
            return await coilInnerRadius - innerSegment.r2
        }
        else if segment.radialPos == 0 {
            
            if let coreShield = await SegmentAt(location: LocStruct(radial: Segment.negativeZeroPosition, axial: 0)) {
                
                return await coilInnerRadius - coreShield.r2
            }
            
            return coilInnerRadius - self.core.radius
        }
        // check for a radial shield inside the coil
        else if let innerShield = await self.SegmentAt(location: LocStruct(radial: -coil, axial: 0)) {
            
            return await coilInnerRadius - innerShield.r2
        }
        else {
            
            guard let innerSegment = await self.SegmentAt(location: LocStruct(radial: coil - 1, axial: 0)) else {
                
                throw PhaseModelError(info: "\(coil - 1)", type: .CoilDoesNotExist)
            }
            
            return await coilInnerRadius - innerSegment.r2
        }
    }
    
    /// Return the radial spaces inside and outside the given segment. If the segment is not in the model, throw an error.
    func RadialSpacesAboutSegment(segment:Segment) async throws -> (inside:Double, outside:Double) {
        
        guard let _ = self.segmentStore.firstIndex(of: segment) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        do {
            
            let insideResult:Double = try await self.HiloUnder(coil: segment.location.radial)
            var outsideResult:Double = -1.0
            
            if let nextCoilSegment = await self.SegmentAt(location: LocStruct(radial: segment.radialPos + 1, axial: 0)) {
                
                outsideResult = try await self.HiloUnder(coil: nextCoilSegment.radialPos)
            }
            
            return (insideResult, outsideResult)
        }
        catch {
            
            throw error
        }
    }
    
    /// Return the spaces above and below the given segment. If the segment is not in the model, throw an error.
    func AxialSpacesAboutSegment(segment:Segment) async throws -> (above: Double, below: Double) {
        
        guard let segIndex = self.segmentStore.firstIndex(of: segment) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        var aboveResult:Double = -1.0
        var belowResult:Double = -1.0
        
        do {
            
            if let staticRingAbove = try await self.StaticRingAbove(segment: segment) {

                aboveResult = await staticRingAbove.z1 - segment.z2
            }

            if let staticRingBelow = try await self.StaticRingBelow(segment: segment) {
                
                belowResult = await segment.z1 - staticRingBelow.z2
            }
            
            if aboveResult < 0.0 {
                
                let highest = try await self.GetHighestSection(coil: segment.radialPos)
                if segment.axialPos == highest {
                    
                    aboveResult = await segment.realWindowHeight - segment.z2
                }
                else {
                    
                    aboveResult = await self.segmentStore[segIndex + 1].z1 - segment.z2
                }
            }
            
            if belowResult < 0.0 {
                
                if segment.axialPos == 0 {
                    
                    belowResult = await segment.z1
                }
                else {
                    
                    belowResult = await segment.z1 - self.segmentStore[segIndex - 1].z2
                }
            }
            
            return (aboveResult, belowResult)
        }
        catch {

            throw error
        }
    }

    // MARK: Geometry for the dielectric stress screen

    /// One point of a coil's voltage-versus-height profile: an axial position and the index into a simulation step's `volts` array
    /// that gives the potential there.
    struct CoilProfilePoint:Sendable {

        /// The axial position of the node, measured from the top of the bottom yoke, in metres.
        let z:Double
        /// The node's number, which doubles as the index into the voltage vector.
        let nodeIndex:Int
    }

    /// The nodes of a coil, in ascending order of height, as a profile that can be interpolated to give V(z).
    ///
    /// This is what lets the stress screen compare two coils that are NOT the same height - the case that produces real failures
    /// when, say, an external tapping winding is shorter than the main winding beside it. Two such coils have no common node
    /// numbering and their discs do not line up, so the only way to ask "what is the radial voltage difference at height z" is to
    /// interpolate each coil's own profile at that z and subtract. The caller samples on the UNION of the two coils' node heights so
    /// that no node of either coil is missed, and treats a z beyond a coil's own extent as outside that coil - which is exactly the
    /// region where the short coil's end faces the tall coil, and exactly what has to be flagged.
    ///
    /// Interpolation between the returned points is piecewise linear, which is the same assumption the lumped model itself makes:
    /// the voltage within a Segment is not resolved by the network, so linear between its two nodes is all the information there is.
    ///
    /// Note that `Node.z` is used directly rather than being recomputed from the Segments. The nodes already carry the heights that
    /// SetNodes assigned them, including the separate nodes on either side of a tapping gap, so rebuilding the heights here would
    /// risk disagreeing with the model about where a break is.
    func CoilVoltageProfile(coil:Int) async throws -> [CoilProfilePoint] {

        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {

            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }

        let coilSegments = self.CoilSegments().filter { $0.radialPos == coil }

        guard !coilSegments.isEmpty else {

            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }

        // Collect every node touching this coil. A node is shared by the Segment below it and the Segment above it, so gathering
        // both ends of every Segment and de-duplicating by node number gives each node exactly once.
        var seen:Set<Int> = []
        var result:[CoilProfilePoint] = []

        for nextSegment in coilSegments {

            let adjacent = self.AdjacentNodes(to: nextSegment)

            for nodeNumber in [adjacent.below, adjacent.above] {

                guard nodeNumber >= 0, !seen.contains(nodeNumber) else {

                    continue
                }

                guard let node = self.nodes.first(where: { $0.number == nodeNumber }) else {

                    continue
                }

                seen.insert(nodeNumber)
                result.append(CoilProfilePoint(z: node.z, nodeIndex: nodeNumber))
            }
        }

        result.sort { $0.z < $1.z }

        return result
    }

    /// The dielectric layers filling the hilo under the given coil, for the stick column and the oil column, together with the
    /// radius the stack starts at and the stick fraction of the circumference.
    ///
    /// This mirrors what `CoilInnerShuntCapacitance` measures, deliberately: the barrier count comes from the same shop heuristic
    /// (`Npress = round(hilo/0.0084 − 0.5)` tubes of 0.08"), the stick count is borrowed from the disc's key-spacer columns in the
    /// same way, and 3/4" sticks are assumed. Those substitutions are recorded as deviation 3 in TODO.md; the point here is that the
    /// stress and the capacitance must at least be measuring the SAME hilo, so the heuristic is shared rather than re-invented.
    ///
    /// One thing is added that the capacitance model leaves out. A coil's r1/r2 are over-paper, exactly as a disc's z1/z2 are, so
    /// the hilo returned by `HiloUnder` is the clearance between INSULATED surfaces. The capacitance can ignore the turn paper
    /// because it barely moves the total; the stress cannot, because the whole question is how much field the oil is carrying and
    /// the paper takes a share of the volts. So the two half-wraps are put back on, the same way DiscToDiscLayerStack does it.
    ///
    /// THE OIL COLUMN IS RETURNED DUCT BY DUCT, NOT AS ONE LUMP, AND THAT DISTINCTION IS THE WHOLE POINT OF THIS ROUTINE.
    ///
    /// The capacitance model lumps the barriers and the oil (`CoilInnerShuntCapacitance` does exactly that) and is right to: a
    /// series reduction is Σ(ℓ/ε), which is order-independent and does not care how a material is subdivided. The WITHSTAND is not
    /// invariant that way. `StressAllowable.Strike` is a function of the layer's own thickness - `50·d^−0.36` for oil - so a hilo
    /// handed over as a single thick oil gap is judged at an allowable it never has to meet. On this program's own STME-0999
    /// fixture the 35.5 mm HV/LV hilo came out as one 27.4 mm oil layer at 15.2 kV/mm where the real 5.5 mm duct earns 27.1, and
    /// the reported utilization was **1.78× the truth**. Every coil-to-coil finding on that report was manufactured by the lumping.
    ///
    /// So the gap is built the way it is stacked in the tank: `Npress` barriers of 0.08" with **oil against both winding surfaces**,
    /// hence `Npress + 1` ducts sharing the remaining radial space. Ordering matters here too, though far less - `CoaxialField`
    /// reports each layer's field at its own inner radius, so an oil duct placed at the wrong radius is wrong by the curvature
    /// alone, a few percent across a hilo.
    ///
    /// The stick column stays a single solid layer, and that is not an oversight: where a stick bridges the gap the path is
    /// pressboard from one winding to the other - barrier and stick alike - so its allowable belongs at the full hilo thickness.
    /// Splitting it would hand the parts an allowable that the whole path does not earn.
    func HiloLayerStack(coil:Int) async throws -> (stick:[DielectricLayer], oil:[DielectricLayer], innerRadius:Double, stickFraction:Double) {

        guard let bottomCoilSeg = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {

            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }

        let hilo = try await HiloUnder(coil: coil)

        guard hilo > 0.0 else {

            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }

        let innerRadius = await bottomCoilSeg.r1 - hilo

        // The same barrier/stick split CoilInnerShuntCapacitance uses. The 0.0084 m pitch is 0.08" of board plus 0.25" of oil.
        let Npress = max(0.0, round(hilo / 0.0084 - 0.5))
        let tPress = min(hilo, 0.08 * meterPerInch * Npress)
        let tStick = hilo - tPress

        // Oil against both winding surfaces, so the barriers sit BETWEEN the ducts and there is one more duct than barrier.
        let ductCount = Npress + 1.0
        let tDuct = tStick / ductCount

        let bs = bottomCoilSeg.basicSections[0]
        let rGap = innerRadius + hilo / 2.0
        let Ns = Double(bs.wdgData.discData.numAxialColumns)
        let ws = 0.75 * meterPerInch
        let stickFraction = min(1.0, Ns * ws / (2 * π * rGap))

        // The half-wrap of the coil on each side of the gap. Whatever is inside may be a core, a shield or a tank rather than a
        // winding, and none of those carries turn paper, so only this coil's own wrap is certain - the inner one is added by the
        // caller when the inner object is a coil.
        let outerPaper = DielectricLayer.Paper(bs.wdgData.turn.turnInsulation / 2.0)

        // Where a stick bridges the gap the whole hilo is solid pressboard, so it is one layer of the full thickness.
        var stick:[DielectricLayer] = [DielectricLayer.Pressboard(hilo)]

        // Oil, barrier, oil, ... , barrier, oil - running outward from the inner surface.
        var oil:[DielectricLayer] = []

        for i in 0..<Int(ductCount) {

            if tDuct > 0.0 {

                oil.append(DielectricLayer.Oil(tDuct))
            }

            if i < Int(Npress), tPress > 0.0 {

                oil.append(DielectricLayer.Pressboard(tPress / Npress))
            }
        }

        stick.append(outerPaper)
        oil.append(outerPaper)

        return (stick, oil, innerRadius, stickFraction)
    }

    /// Try to add a radial shield inside the given coil and return it as a Segment. If unsuccessful, the function throws an error.
    func AddRadialShieldInside(coil:Int, hiloToShield:Double) async throws -> Segment {
        
        guard let segment = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        // check if there is already a radial shield under the coil
        let radPos = coil == 0 ? Segment.negativeZeroPosition : -coil
        guard await self.SegmentAt(location: LocStruct(radial: radPos, axial: 0)) == nil else {
            
            throw PhaseModelError(info: "Radial Shield", type: .ShieldingElementExists)
        }
        
        do {
            
            let requiredSpace = hiloToShield + 0.002
            let availableSpace = try await self.HiloUnder(coil: coil)
            
            if requiredSpace >= availableSpace {
                
                throw PhaseModelError(info: "Radial Shield", type: .NoRoomForShieldingElement)
            }
            
            let highestSegmentIndex = try await self.GetHighestSection(coil: coil)
            guard let highestSegment = await self.SegmentAt(location: LocStruct(radial: coil, axial: highestSegmentIndex)) else {
                
                throw PhaseModelError(info: "", type: .SegmentNotInModel)
            }
            
            let height = await highestSegment.z2 - segment.z1
            
            let radialShield = try await Segment.RadialShield(adjacentSegment: segment, hiloToSegment: hiloToShield, elecHt: height)
            
            return radialShield
            
        }
        catch {
            
            throw error
        }
    }
    
    /// Try to add a static ring either above or below the adjacent Segment. If unsuccessful, this function throws an error. Note that this rountien does not actually add the static ring to the model's segmentStore
    func AddStaticRing(adjacentSegment:Segment, above:Bool, staticRingThickness:Double? = nil, gapToStaticRing:Double? = nil) async throws -> Segment {
        
        guard let _ = self.segmentStore.firstIndex(of: adjacentSegment) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        do {
            
            // check if there is already a static ring above/below the adjacent segment
            if above {

                if let _ = try await StaticRingAbove(segment: adjacentSegment) {

                    throw PhaseModelError(info: "Static Ring", type: .ShieldingElementExists)
                }

            }
            else {

                if let _ = try await StaticRingBelow(segment: adjacentSegment) {

                    throw PhaseModelError(info: "Static Ring", type: .ShieldingElementExists)
                }
            }

            // ...and refuse it here if it would leave a Segment with a ring on BOTH sides. CalculateCapacitanceMatrix throws
            // .OnlyOneStaticRingAllowed on that configuration - DelVecchio 12.78-81 makes the two discs either side of a ring
            // electrostatically coupled THROUGH it, which a scalar Segment.seriesCapacitance cannot carry (see TODO.md) - and
            // finding that out only at the next recalculation leaves the user with a ring in the model, no undo, and nothing that
            // will compute until they take it out again. Note this covers the neighbour as well as the selected Segment: a ring
            // above Segment k is a ring below Segment k+1, and the lookups now say so from both sides.
            let opposite = above ? try await StaticRingBelow(segment: adjacentSegment) : try await StaticRingAbove(segment: adjacentSegment)

            if opposite != nil {

                throw PhaseModelError(info: "(There is already one on the other side of that segment.)", type: .OnlyOneStaticRingAllowed)
            }

            let axialSpaces = try await self.AxialSpacesAboutSegment(segment: adjacentSegment)
            let gapToRing = await gapToStaticRing != nil ? gapToStaticRing! : try self.StandardAxialGap(coil: adjacentSegment.location.radial) / 2
            let srThickness = staticRingThickness != nil ? staticRingThickness! : Segment.stdStaticRingThickness
            let requiredSpace = gapToRing + srThickness

            if (above && requiredSpace >= axialSpaces.above) || (!above && requiredSpace >= axialSpaces.below) {

                throw PhaseModelError(info: "Static Ring", type: .NoRoomForShieldingElement)
            }

            // There is room for the static ring, so try creating it. The axial coordinate comes from the model rather than from
            // the neighbour's own: it is an identity and nothing more - see NextStaticRingAxialPosition and NearestStaticRing.
            let newRing = try await Segment.StaticRing(adjacentSegment: adjacentSegment, gapToSegment: gapToRing, staticRingIsAbove: above, staticRingThickness: srThickness, axialPosition: self.NextStaticRingAxialPosition(coil: adjacentSegment.radialPos))
            
            // if we get here, we know that the call was succesful
            return newRing
        }
        catch {
            
            throw error
        }
    }
    
    /// Two faces closer together than this are treated as touching. A static ring sits a gap away from its neighbour, so the
    /// only thing this absorbs is the rounding in `z1`/`z2`, which are sums of `NSRect` members.
    private static let staticRingFacingTolerance = 1.0e-9

    /// The static ring immediately above the given Segment, or nil if there is none. Throws if the Segment is not in the model.
    ///
    /// See `NearestStaticRing` for why this asks the geometry rather than the locations.
    func StaticRingAbove(segment:Segment) async throws -> Segment? {

        return try await self.NearestStaticRing(to: segment, above: true)
    }

    /// The static ring immediately below the given Segment, or nil if there is none. Throws if the Segment is not in the model.
    ///
    /// See `NearestStaticRing` for why this asks the geometry rather than the locations.
    func StaticRingBelow(segment:Segment) async throws -> Segment? {

        return try await self.NearestStaticRing(to: segment, above: false)
    }

    /// The nearest static ring on one side of a Segment, provided nothing else of the same coil stands between the two.
    ///
    /// **The lookup is geometric, and that is the whole design.** A static ring used to be tied to its neighbour by its axial
    /// coordinate - `axial = -adjacentSegment.axialPos` - and adjacency was recovered by inverting that arithmetic. Three
    /// things were wrong with it, all of which this replaces rather than repairs:
    ///
    /// - **A restructure breaks the arithmetic.** `axialPos` is a pristine design-file disc index that is never renumbered
    ///   (see the note on `Segment.axialPos`), so interleaving 2n discs leaves the coordinates at 0/2/4/..., a combine leaves
    ///   only the lowest one, and a ring booked against a coordinate that no longer belongs to any Segment simply stopped
    ///   being found. It stayed in the model, kept its space and kept being drawn, while the discs on either side of it
    ///   computed their gaps as though it were not there.
    /// - **"Above segment k" and "below segment k+1" are the same ring**, but the two sides recovered it by different routes,
    ///   so only one of them ever saw it. `CalculateCapacitanceMatrix` took the *gap* from `AxialSpacesAboutSegment` (which
    ///   looked at the neighbour as well) and the static-ring *flag* from a lookup that did not, so a disc could be handed a
    ///   5 mm gap and told there was no ring in it - and then build the dielectric stack for a plain disc-to-disc gap.
    /// - **The encoding cannot represent a ring on both sides of the same Segment.** Both wanted the same coordinate, so the
    ///   second one collided in `InsertSegment` with `.SegmentExists`. It is still refused, but by `AddStaticRing` with
    ///   `.OnlyOneStaticRingAllowed` and its explanation, which is the honest answer: the configuration is unsupported
    ///   physics (DV 12.78-81, see TODO.md), not an unrepresentable location.
    ///
    /// Nothing else here needs a ring's axial coordinate to mean anything; it only has to be negative and unique. See
    /// `NextStaticRingAxialPosition`.
    ///
    /// A coil Segment found nearer than any ring *blocks*: a ring on the far side of another disc is in that disc's gap, not
    /// in this one. That falls out of taking the nearest thing on the side of interest and keeping it only if it is a ring.
    private func NearestStaticRing(to segment:Segment, above:Bool) async throws -> Segment? {

        guard self.segmentStore.contains(where: { $0 === segment }) else {

            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }

        // A shielding element is not part of the series chain, so nothing is above or below it in the sense meant here.
        guard !segment.isStaticRing && !segment.isRadialShield else {

            return nil
        }

        let coil = segment.radialPos

        // The sweep below is O(coil) and CalculateCapacitanceMatrix asks twice per Segment, so a coil with no rings on it - which
        // is every coil in most models - should not pay for the search at all.
        guard self.segmentStore.contains(where: { $0.radialPos == coil && $0.isStaticRing }) else {

            return nil
        }

        let face = above ? await segment.z2 : await segment.z1

        var nearest:Segment? = nil
        var nearestDistance = Double.greatestFiniteMagnitude

        for nextSegment in self.segmentStore {

            guard nextSegment.radialPos == coil, !(nextSegment === segment), !nextSegment.isRadialShield else {

                continue
            }

            let nextFace = above ? await nextSegment.z1 : await nextSegment.z2
            let distance = above ? nextFace - face : face - nextFace

            guard distance >= -PhaseModel.staticRingFacingTolerance, distance < nearestDistance else {

                continue
            }

            nearestDistance = distance
            nearest = nextSegment
        }

        return (nearest?.isStaticRing ?? false) ? nearest : nil
    }

    /// A free axial coordinate for a new static ring in the given coil.
    ///
    /// The value is an **identity, not a position**. It has to be negative, which is how `CoilSegments()`,
    /// `ApplyRadialBuildUp` and `CoilCount` tell a shielding element from a disc, and it has to be unique within the coil,
    /// which is what `InsertSegment` insists on. Where the ring physically sits is answered by `StaticRingAbove` /
    /// `StaticRingBelow`, from the geometry, so this does not have to encode a neighbour and deliberately does not try to.
    private func NextStaticRingAxialPosition(coil:Int) -> Int {

        let used = self.segmentStore.filter({ $0.radialPos == coil && $0.axialPos < 0 }).map({ $0.axialPos })

        return (used.min() ?? 0) - 1
    }
    
    /// Function to remove a radial shield
    func RemoveRadialShield(radialShield:Segment) throws {
        
        guard let rsIndex = self.segmentStore.firstIndex(of: radialShield) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        guard radialShield.isRadialShield else {
            
            throw PhaseModelError(info: "Radial Shie;d", type: .NotAShieldingElement)
        }
        
        self.segmentStore.remove(at: rsIndex)
    }
    
    /// Function to remove a static ring
    func RemoveStaticRing(staticRing:Segment) throws {
        
        guard let srIndex = self.segmentStore.firstIndex(of: staticRing) else {
            
            throw PhaseModelError(info: "", type: .SegmentNotInModel)
        }
        
        guard staticRing.isStaticRing else {
            
            throw PhaseModelError(info: "Static Ring", type: .NotAShieldingElement)
        }
        
        self.segmentStore.remove(at: srIndex)
    }
    
    /// Function to add a collection of Segments to the store. The array can be in any order - the routine will ensure that the Segments are inserted at the correct place in the store. If a Segment cannot be inserted, an error is thrown. The routine will reset the model to whatever it was before the call was attempted (which may or may not be a stable model).
    func AddSegments(newSegments:[Segment]) async throws {
        
        do {
            
            for nextSegment in newSegments {
            
                try await self.InsertSegment(newSegment: nextSegment)
            }
        }
        catch {
            
            self.RemoveSegments(badSegments: newSegments)
            
            throw error
        }
    }
    
    /// Function to remove a collection of Segments from the store. Any Segments that are not actually in the store are ignored
    func RemoveSegments(badSegments:[Segment]) {
        
        for nextSegment in badSegments {
            
            guard let nsegIndex = self.segmentStore.firstIndex(of: nextSegment) else {
                
                continue
            }
            
            self.segmentStore.remove(at: nsegIndex)
        }
    }
    
    
    /// The Segment at the given location, or nil if there is none.
    ///
    /// **This searches the WHOLE store, shielding elements included, and it has to.** A static ring lives at
    /// `(radial: itsCoil, axial: <negative>)` and a radial shield at `(radial: <negative>, axial: 0)`, so every routine that
    /// goes looking for one - `StaticRingAbove`/`StaticRingBelow`, `RadialShieldInside`/`RadialShieldOutside`, the duplicate
    /// guards in `AddStaticRing`/`AddRadialShieldInside`, and the shield branches of `HiloUnder` and
    /// `CoilInnerShuntCapacitance` - asks for it through here. Restricting this to `CoilSegments()` (which is exactly what
    /// filters those locations out) therefore did not hide shielding elements from *some* callers: it made every one of
    /// those lookups return nil unconditionally, so no static ring or radial shield in the model was ever found by anything.
    /// Static rings stopped reaching the capacitance calculation, and the "there is already one there" guards stopped firing,
    /// which turned a second static ring on the same Segment into a `.SegmentExists` throw out of `InsertSegment`.
    ///
    /// Nothing is lost by searching the whole store. A coil Segment's axial coordinate is >= 0 and its radial is >= 0, so a
    /// lookup for an ordinary `(coil, disc)` location cannot match a shielding element to begin with.
    func SegmentAt(location:LocStruct) async -> Segment? {

        for nextSegment in self.segmentStore {

            let nextLoc = await nextSegment.location
            if nextLoc == location {

                return nextSegment
            }
        }

        return nil
    }
    
    /// Get the axial index of the highest (max Z) section for the given coil
    /// - note: This returns the axial position equal to: highestDiscNumber - lowestDiscNumber for the coil in question
    func GetHighestSection(coil:Int) async throws -> Int {
        
        guard let _ = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        // I believe that this is in order but it should be tested
        let coilSections = self.segmentStore.filter({$0.radialPos == coil && !$0.isStaticRing && !$0.isRadialShield})
        
        return coilSections.last!.axialPos
    }
    
    
    /// Get the gap between the bottom-most section of a coil and the next adjacent section.  If the coil at the given radial position is not a disc coil, an error is thrown.
    func StandardAxialGap(coil:Int) async throws -> Double {
        
        guard let bottomMostDisc = await self.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else {
            
            throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
        }
        
        var wdgTypeIsDiscOrHelix = await bottomMostDisc.wdgType == .disc
        wdgTypeIsDiscOrHelix = await bottomMostDisc.wdgType == .helical || wdgTypeIsDiscOrHelix
        if !wdgTypeIsDiscOrHelix {

            throw PhaseModelError(info: "", type: .NotADiscCoil)
        }

        // The gap between the coil's two lowest DISCS. That is not the same question as "the gap between its two lowest
        // Segments", because the discs of a combined, interleaved or shield-paired Segment are inside it - so the first disc
        // gap of an interleaved coil is a gap this routine can only see by looking at BasicSections.
        //
        // This used to ask for the Segment at axial 1. `axialPos` is a pristine design-file disc index that is never
        // renumbered, so interleaving 2n discs leaves the coordinates at 0/2/4/... and there is no Segment at 1 at all: the
        // lookup came back nil and the coil was reported as not existing. That is reachable straight from the UI - AddStaticRing
        // calls this for its default gap - so adding a static ring to an interleaved coil failed with "coil 1 does not exist".
        var result = 0.0

        if bottomMostDisc.basicSections.count > 1 {

            result = bottomMostDisc.basicSections[1].z1 - bottomMostDisc.basicSections[0].z2
        }
        else {

            let coilSegments = self.CoilSegments().filter({ $0.radialPos == coil })

            guard coilSegments.count > 1 else {

                throw PhaseModelError(info: "\(coil)", type: .CoilDoesNotExist)
            }

            result = await coilSegments[1].z1 - bottomMostDisc.z2
        }

        if result < 0.0 {
            
            throw PhaseModelError(info: "It is negative", type: .IllegalAxialGap)
        }
        
        return result
    }
    
    /*
    /// Get the current density of the given coil at the given height, using equation 9.10 of DelVecchio
    func J(radialPos:Int, realZ:Double) -> Double {
        
        let coilJ = self.CoilJ(radialPos: radialPos)
        let z = realZ + segments[0].zWindHtAdder
        let L = segments[0].L
        
        var result = coilJ[0]
        
        // var gotFirst = false
        // var lastHarmonic = 0.0
        
        for n in 1...PCH_IMPULSEDISTRIBUTION_IterationCount {
            
            let nn = Double(n)
            let nextHarmonic = coilJ[n] * cos(nn * π * z / L)
            
            /* if gotFirst {
                
                if abs(nextHarmonic) / abs(lastHarmonic) > 1.0 {
                    print("NOT CONVERGING!")
                }
            }
            else {
                gotFirst = true
            } */
            
            result += nextHarmonic
            // lastHarmonic = nextHarmonic
        }
        
        return result
    } */
    
    /*
    /// Get the Fourier series representation of the current density for the coil (DelVecchio)
    func CoilJ(radialPos:Int) -> [Double]
    {
        var result:[Double] = Array(repeating: 0.0, count: PCH_IMPULSEDISTRIBUTION_IterationCount + 1)
        
        for nextSegment in self.segments {
            
            if nextSegment.radialPos == radialPos {
                
                for i in 0...PCH_IMPULSEDISTRIBUTION_IterationCount {
                    
                    result[i] += self.J[nextSegment.serialNumber][i]
                }
            }
        }
        
        return result
    } */
}
