//
//  Segment.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2021-10-07.
//

// This file defines the most basic segment that is used for calculations of inductance and capacitance for the model. A Segment is made up of one or more BasicSections.

import Foundation
import PchBasePackage
import os.lock

/// A Segment is, at its most basic, a collection of BasicSections. The collection MUST be from the same Winding and it must represent an axially contiguous (adjacent) collection of coils.The collection may only hold a single BasicSection, or anywhere up to all of the BasicSections that make up a coil (for disc coils, only if there are no central or DV gaps in the coil). It is the unit that is actually modeled (and displayed). Static rings and radial shields are special Segments - creation routines (class functions) are provided for each.
actor Segment: Equatable /*, Hashable */ {
    
    /// flag used during debugging to identify a Segment for a breakpoint
    var debugFlag = false
    
    /// Enum to define the comparative position(s) of 2 or more Segments
    enum ComparativePosition {
        
        case inner
        case outer
        
        case innerAdjacent
        case outerAdjacent
        
        case above
        case below
        
        case adjacentAbove
        case adjacentBelow
        
        case bottom
        case top
    }
    
    /// Function required to make Segment be Equatable. Basically, we use the serial number to decide if two Segments are equal. This allows us to use Segment as a struct instead of a class, but it means that we must be very careful about setting those serial numbers.
    static func == (lhs: Segment, rhs: Segment) -> Bool {
        
        return lhs.serialNumber == rhs.serialNumber
    }
    
    /*
    func hash(into hasher: inout Hasher) {
        
        hasher.combine(self.serialNumber)
    } */
    
    /// A locked value for storing the next serial number. NOTE: this must stay a 'let' - replacing the
    /// lock itself would not be atomic, so resetSerialNumber() mutates the value _through_ the lock.
    private static let nextSerialNumberStore: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: -1)
    
    /// Thread-safe way of getting the next available serial number
    public static var nextSerialNumber: Int {
        
        get {
            
            let value = Self.nextSerialNumberStore.withLock { value in
                value += 1
                return value
            }
            
            return value
        }
    }
    
    /*
    /// Global storage for the next serial number to assign
    private static var nextSerialNumberStore:Int = 0
    
    /// Return the next available serial number for the Segment class, then advance the counter to the next number.
    static var nextSerialNumber:Int {
        get {
            
            let nextNum = Segment.nextSerialNumberStore
            Segment.nextSerialNumberStore += 1
            return nextNum
        }
    } */
    
    // MARK: Static ring geometry (Weidmann drawing EHV00112-2 rev 2, "NOTCHED STATIC RING")
    //
    // The drawing is ~/Documents/MyProjects/Claude/EHV00112_REV_2-SHT_1(Static_Rings).pdf. It leaves ID, OD, T, T1, R1, R2, L, LR
    // and LV to the engineer; the four constants below are the house values, and they are treated as fixed rather than as
    // per-design inputs because nothing in a design file carries them.
    //
    // WHAT A STATIC RING ACTUALLY IS, because it decides what the dielectric code may assume. A pressboard core of thickness T is
    // wrapped in VERY THIN ALUMINIUM FOIL, and the foil is then covered with T1 of Kraft paper per side. So:
    //
    //  - The electrode is the FOIL, at the core's own surface. The core's pressboard is inside it and is at one potential
    //    throughout, so it never appears as a dielectric layer in any gap - only the T1 of Kraft over it does. That is what
    //    DiscToDiscLayerStack builds, and why it puts Paper(T1) and not Pressboard(T) on the far face.
    //  - The foil follows the core's edge, so the ring HAS a corner, of radius R1 = R2. It is not a smooth surface; it is simply a
    //    much more generous corner than a strand's. See DielectricStress.CornerRadius for what a strand gets.
    //  - The lead L bonds the ring to the OUTERMOST TURN of the adjacent disc, so the ring sits at that turn's potential. The
    //    voltage across a disc-to-ring gap is therefore zero at the OD and the disc's whole span at the ID.
    //
    // ID and OD match the adjacent disc, which is what Segment.StaticRing builds (it copies the disc's rect in x). LR and LV, the
    // notch dimensions for the lead, are deliberately ignored: the notch is a local feature at one azimuth and this is a
    // rotationally symmetric model.

    /// T: the thickness of the pressboard core of a static ring, inside the foil. 9.51 mm (0.374", the drawing's T).
    static let staticRingCoreThickness = 9.51E-3

    /// T1: the Kraft paper covering on ONE side of a static ring, over the foil. 3.18 mm (0.125"). Note that this is a per-side
    /// figure, unlike BasicSectionWindingData.TurnData.turnInsulation, which is a two-sided total.
    static let staticRingInsulationPerSide = 3.18E-3

    /// R1 = R2: the corner radius of a static ring's core, which the foil follows. 1.6 mm (the drawing's .063", ie: 1/16").
    /// Twice a typical strand's corner, which is the whole point of fitting a ring - but not infinite, so the corner model
    /// applies to a ring's own surface as much as to a conductor's.
    static let staticRingCornerRadius = 1.6E-3

    /// FT: the finished (wrapped) thickness of a standard static ring, T + 2·T1 = 15.87 mm, which is 5/8" to within 5 µm. This is
    /// the OVERALL dimension, so a static ring's rect covers its insulation the same way a disc's does.
    static let stdStaticRingThickness = staticRingCoreThickness + 2.0 * staticRingInsulationPerSide

    // MARK: Wound-in shields (DelVecchio ch. 12, section 12.11)

    /// The bare (over-copper) radial dimension of a wound-in-shield turn. This is fixed by shop practice, not by anything
    /// electrical: the shield is an open-circuited conductor and carries no current, so the dimension is set by how thin a wire can
    /// be handled during winding. Note that NOTHING in the capacitance depends on it - DelVecchio 12.98 is a function of the turn's
    /// AXIAL height and its insulation thickness only - so a shield's radial build is pure cost with zero capacitive benefit.
    static let woundInShieldBareRadial = 0.070 * meterPerInch

    /// The thinnest paper allowed on a shield turn, per side. Everything else here uses two-sided figures, so this gets doubled
    /// before it is compared with anything.
    ///
    /// This is a shop floor and nothing more. It does **not** normally set the shield's paper - `WoundInShieldWire.Standard`
    /// papers a shield turn like the coil turn it sits against, and this only bites on a coil whose own turn covering is thinner
    /// than 0.012" two-sided. It used to be the governing rule, which put the shield closer to the coil copper than another coil
    /// turn and inflated c_w; see `Standard` for what that did to the shield-versus-interleaving comparison.
    static let woundInShieldMinInsulationPerSide = 0.006 * meterPerInch

    /// The maximum permitted working (ie: power-frequency) stress between a shield turn and a coil turn beside it, in V/m.
    /// 2755 V/mm is about 70 V/mil, the usual working figure for kraft in oil.
    static let woundInShieldMaxWorkingStress = 2755.0 / 0.001

    /// Paper goes onto a wire in whole wraps, so a calculated insulation thickness is rounded UP to a multiple of this. Two-sided,
    /// ie: 0.001" per side.
    static let woundInShieldInsulationIncrement = 0.002 * meterPerInch

    /// The shield conductor itself. There is one of these per COIL rather than per disc pair: a coil is wound with a single shield
    /// wire, so its insulation is sized once, for the largest number of shield turns used anywhere in that coil. That matters for
    /// the '.attachedToVAtTopEnd' case, where β - and therefore the required insulation - grows with n; sizing per pair would
    /// demand a different wire for every pair of a graded scheme.
    struct WoundInShieldWire:Codable, Sendable, Equatable {

        /// How the shield is tied to the winding. DelVecchio 12.97 gives the bias voltage for each case; β below is the
        /// dimensionless form of the same thing, and it is what 12.96 is actually quadratic in.
        enum Connection:Int, Codable, Sendable, CaseIterable {

            /// The shield is left floating, so it settles at Vbias = V/2.
            case floating
            /// The shield is tied to V at its cross-over, which is at the outermost turn. Vbias = V.
            case attachedToVAtCrossover
            /// The shield is tied to V at the end (innermost) shield turn of the upper disc, i = n. Vbias = V + (n − ½)ΔV. This is
            /// the highest-capacitance option and also the hardest to build - DelVecchio calls it "harder to achieve in practice".
            case attachedToVAtTopEnd

            var description:String {

                switch self {

                case .floating: return "Floating"
                case .attachedToVAtCrossover: return "Attached to V at cross-over"
                case .attachedToVAtTopEnd: return "Attached to V at top end turn"
                }
            }

            /// DelVecchio's bias parameter, β ≡ (Vbias − V/2)/V, where V is the voltage across the DISC PAIR. Reading 12.97 with
            /// ΔV = V/2N (12.84):
            ///
            ///     floating          Vbias = V/2                 ->  β = 0
            ///     at cross-over     Vbias = V                   ->  β = 1/2
            ///     at top end turn   Vbias = V + (n − ½)ΔV       ->  β = 1/2 + (n − ½)/2N
            ///
            /// Checked against Table 12.1: fitting C = A + B·β² to the floating and cross-over entries reproduces the top-end entry
            /// at every n that was tested (3.076 vs 3.08, 6.05 vs 6.04, 10.10 vs 10.1, 15.47 vs 15.5).
            func beta(turnsPerDisc n:Int, discTurns N:Double) -> Double {

                switch self {

                case .floating: return 0.0
                case .attachedToVAtCrossover: return 0.5
                case .attachedToVAtTopEnd: return 0.5 + (Double(n) - 0.5) / (2.0 * N)
                }
            }

            /// The largest voltage that appears between a shield turn and one of the coil turns next to it.
            ///
            /// DelVecchio 12.11.4 works this out to (β + ½)·V, where V is the voltage across the disc pair: V/2 floating (p.359,
            /// "the maximum shield turn-coil turn voltage is V/2 ... regardless of the number of shield turns"), V for the
            /// cross-over case, and more than V for the top-end case. It is confirmed by his own circuit-model dumps - Table 12.2
            /// shows a maximum of 12.84 V against V ≈ 24.3, and Table 12.3 shows ≈ 5.3 V against V = 5.13.
            ///
            /// Note that only the top-end case depends on n. That is worth knowing when grading a coil: the other two connections
            /// let the shield count vary along the winding without changing the turn insulation anywhere.
            func maxTurnToShieldVoltage(turnsPerDisc n:Int, discTurns N:Double, voltsPerTurn:Double) -> Double {

                // the pair spans 2N turns, so this is the working voltage across it
                let vPair = 2.0 * N * voltsPerTurn

                return (self.beta(turnsPerDisc: n, discTurns: N) + 0.5) * vPair
            }
        }

        let connection:Connection

        /// The bare (over-copper) radial dimension of the wire
        let bareRadial:Double

        /// The TWO-SIDED paper thickness on the wire, following the same convention as
        /// BasicSectionWindingData.TurnData.turnInsulation. See Segment.CapacitanceTurnToTurn for why that convention matters.
        let insulation:Double

        /// The radial dimension a shield turn actually occupies inside the disc
        var overPaperRadial:Double {

            return self.bareRadial + self.insulation
        }

        /// Build the shield wire for a coil.
        ///
        /// **A shield turn is papered like the coil turn it sits against, and never less.** That is the governing rule, and the
        /// withstand calculation below is a check on top of it rather than the thing that sets the thickness. A wound-in shield is
        /// an open-circuited wire buried in the middle of a disc, at up to half the pair voltage against the turns either side of
        /// it; nobody wraps that in less paper than the conductor it is shielding, whatever a stress calculation permits.
        ///
        /// The gap between the shield copper and the coil copper is one half-wrap of each. With the two-sided convention used
        /// throughout this file, that gap is exactly ½(τp + τw) - which is also the quantity DelVecchio substitutes for τp when he
        /// forms c_w (p.352), so the same number does both jobs. Hence:
        ///
        ///     gap = Vmax / Emax    and    gap = ½(τp + τw)    ->    τw = 2·gap − τp
        ///
        /// and the answer is the largest of that, the coil turn's own covering, and the shop minimum.
        ///
        /// **This is not a cosmetic choice - it decides whether shields or interleaving come out ahead.** c_w/c_t is exactly
        /// τp/½(τp + τw), so τw = τp makes a shield-to-turn interface identical to a turn-to-turn one and c_w = c_t. Setting τw to
        /// the shop minimum instead makes the shield sit CLOSER to the coil copper than another coil turn would, and c_w/c_t rises
        /// towards 2. On the STME-0999_2 fixture (τp = 1.638 mm, CTC) the old minimum-paper rule gave τw = 0.305 mm and
        /// c_w/c_t = 1.55, which was enough to put a 5-turn shield *ahead* of a fully interleaved winding - because at n ≈ N/2 the
        /// two methods are within 7% on interface count alone (4.557 against 4.875 at N = 10.75), so c_w/c_t decides the ranking
        /// outright. Interleaving is the higher-capacitance method, and with τw = τp the model says so again.
        ///
        /// - Parameter maxTurnsPerDisc: The LARGEST number of shield turns per disc anywhere in this coil (see the note on the type)
        /// - Parameter discTurns: N, the number of turns in one disc
        /// - Parameter voltsPerTurn: The working volts per turn of the transformer
        /// - Parameter turnInsulation: τp, the two-sided paper thickness of a COIL turn
        static func Standard(connection:Connection, maxTurnsPerDisc:Int, discTurns:Double, voltsPerTurn:Double, turnInsulation:Double) -> WoundInShieldWire {

            let vMax = connection.maxTurnToShieldVoltage(turnsPerDisc: maxTurnsPerDisc, discTurns: discTurns, voltsPerTurn: voltsPerTurn)
            let requiredGap = vMax / Segment.woundInShieldMaxWorkingStress

            // The three demands, in order of how often they govern: match the conductor, satisfy the working stress, clear the
            // shop minimum. The stress term only bites on a coil whose own turn paper is already thin for its volts per turn.
            var tw = max(turnInsulation, 2.0 * requiredGap - turnInsulation)
            tw = max(tw, 2.0 * Segment.woundInShieldMinInsulationPerSide)

            // Round up to a whole number of wraps. The epsilon keeps a thickness that is already an exact multiple from being
            // pushed up a whole increment by floating-point noise - which matters more now than it did, because the common case is
            // now tw == τp exactly, and a coil turn's covering is itself a whole number of wraps.
            let increment = Segment.woundInShieldInsulationIncrement
            tw = ((tw / increment) - 1.0E-9).rounded(.up) * increment

            return WoundInShieldWire(connection: connection, bareRadial: Segment.woundInShieldBareRadial, insulation: tw)
        }
    }

    /// The wound-in shields carried by a single Segment.
    struct WoundInShield:Codable, Sendable, Equatable {

        /// The wire, which is a property of the whole coil rather than of this Segment
        let wire:WoundInShieldWire

        /// The number of shield turns per disc, with ONE ENTRY PER DISC PAIR of the owning Segment. A shield spans two discs and
        /// crosses over at the outermost turn, so the pair is the unit DelVecchio's 12.96 describes and a Segment of 2k
        /// BasicSections has k entries here.
        ///
        /// An entry of 0 means that pair carries no shield. That is deliberate rather than merely tolerated: a graded shielding
        /// scheme has to be able to say it, and it costs nothing, because 12.96 at n = 0 reduces to c_t·(N−1)/(2N²), which is
        /// identically two plain discs' Ctt(N−1)/N² in series. The two formulations agree exactly at the boundary, so a graded
        /// profile has no artificial step in capacitance where the shields stop.
        let turnsPerDisc:[Int]

        init(wire:WoundInShieldWire, turnsPerDisc:[Int]) {

            self.wire = wire
            self.turnsPerDisc = turnsPerDisc
        }

        /// Convenience initializer for the uniform case, which is what the "add shields" dialog produces.
        init(wire:WoundInShieldWire, turnsPerDisc:Int, pairCount:Int) {

            self.init(wire: wire, turnsPerDisc: Array(repeating: turnsPerDisc, count: pairCount))
        }

        /// The most shield turns in any one disc of the owning Segment
        var maxTurnsPerDisc:Int {

            return self.turnsPerDisc.max() ?? 0
        }

        /// The extra radial build that the widest disc of this Segment needs. Note that this is driven by the MAXIMUM, not by the
        /// per-pair count: the coil has to stay cylindrical, so the widest disc sets the build for the whole winding and every
        /// other disc is filled out to match.
        var radialBuildAdder:Double {

            return Double(self.maxTurnsPerDisc) * self.wire.overPaperRadial
        }
    }

    /// This segment's serial number
    // private var serialnumberStore:Int
    
    /// Segment serial number (needed to make the "==" operator code simpler.
    let serialNumber:Int
    
    /// The first (index = 0) entry  has the lowest Z and the last entry has the highest.
    let basicSections:[BasicSection]
        
    /// A Boolean to indicate whether the segment is interleaved
    var interleaved:Bool

    func IsInterleaved() -> Bool {

        return interleaved
    }

    /// The wound-in shields on this Segment, or nil if it has none. A Segment cannot be both interleaved and shielded - they are
    /// two different ways of solving the same problem and the capacitance formulas for them are unrelated.
    var woundInShield:WoundInShield? = nil

    func SetWoundInShield(_ woundInShield:WoundInShield?) {

        self.woundInShield = woundInShield
    }

    func HasWoundInShield() -> Bool {

        return self.woundInShield != nil
    }

    /// A constant used to identify the RADIAL location of a radial shield that sits inside coil 0 (the negative of 0 being no use
    /// as a marker). Static rings no longer use it: their axial coordinate is handed out by
    /// `PhaseModel.NextStaticRingAxialPosition` and carries no meaning beyond "negative, and not already taken".
    static let negativeZeroPosition = -2048
    
    /// A Boolean to indicate whether the segment is actually a static ring
    let isStaticRing:Bool
    
    /// A Boolean to indicate whether the segment is actually a radial shield
    let isRadialShield:Bool
    
    /// The type of the coil that owns this segment
    var wdgType:BasicSectionWindingData.WdgType {
        
        return self.basicSections[0].wdgData.type
    }
    
    /// The series current through a single turn in the segment
    let I:Double
    
    /// The radial position of the segment (0 = closest to core)
    nonisolated var radialPos:Int {
        get {
            return self.basicSections[0].location.radial
        }
    }
    
    /// The axial position of the Segment. In the case where a Segment is made up of more than one BasicSection, the lowest BasicSection's axial position is used.
    nonisolated var axialPos:Int {
        
        get {
            return self.basicSections[0].location.axial
        }
    }
    
    var strandRadial:Double {
        
        get {
            
            return self.basicSections[0].wdgData.turn.strandRadial
        }
    }
    
    var strandAxial:Double {
        
        get {
            
            return self.basicSections[0].wdgData.turn.strandAxial
        }
    }
    
    var location:LocStruct {
        get {
            return LocStruct(radial: self.radialPos, axial: self.axialPos)
        }
    }
    
    /// The _actual_ window height for the core
    let realWindowHeight:Double
    
    /// The window height that is used for DelVecchio inductance modeling
    let useWindowHeight:Double
    
    /// The rectangle that the segment occupies in the core window, with the origin at (LegCenter, BottomYoke)
    var rect:NSRect
    
    /// Simple struct for connections. These work as follows: if the 'segmentID' property is nil, the connector property should have a 'fromLocation' at the actual location on self, and a 'toConnector' of one of the special connectors (floating, impulse, or ground). If, on the other hand, 'segmentID' is non-nil, then the fromLocation is still at the actual location on self, and toLocation is the actual location on the segment with serial number segmentID
    struct Connection:Codable, Equatable, Hashable, Sendable {
        
        static func == (lhs: Segment.Connection, rhs: Segment.Connection) -> Bool {
            
            guard lhs.connector.fromLocation == rhs.connector.fromLocation && lhs.connector.toLocation == rhs.connector.toLocation else {
                
                return false
            }
            
            if let lSegment = lhs.segmentID {
                
                guard let rSegment = rhs.segmentID else {
                    
                    return false
                }
                
                return lSegment == rSegment
            }
            else if rhs.segmentID != nil {
                
                return false
            }
            
            return true
        }
        
        func hash(into hasher: inout Hasher) {
            
            hasher.combine(self.segmentID)
            hasher.combine(self.connector)
        }
        
        // var segment:Segment?
        var segmentID:Int?
        var connector:Connector
        
        struct EquivalentConnection:Codable, Equatable, Hashable {
            
            let parent:Int
            let connection:Connection
        }
        
        var equivalentConnections:Set<EquivalentConnection> = []
    }
    
    /// The connections to the Segment
    var connections:[Connection] = []
    
    func SetConnections(connections:[Connection]) {
        
        self.connections = connections
    }
    
    func RemoveConnectionsWithID(_ segID:Int) {

        self.connections.removeAll(where: { $0.segmentID == segID })
    }

    /// Remove every connection that names `segmentID` through exactly `connector`, and return how many went.
    ///
    /// This is the narrow version of RemoveConnectionsWithID, and the difference matters wherever the far end of a jumper has to be
    /// taken out without touching the series connection that runs to the same Segment: two axially adjacent Segments in the same
    /// coil are joined by a series connection AND may carry a jumper to each other, and the serial number alone cannot tell them
    /// apart. See PhaseModel.UpdateConnectors, which uses it to clean up the mirror image of a connection that a fold discarded.
    @discardableResult func RemoveConnectionsMatching(segmentID:Int, connector:Connector) -> Int {

        let before = self.connections.count
        self.connections.removeAll(where: { $0.segmentID == segmentID && $0.connector == connector })

        return before - self.connections.count
    }

    func AppendConnection(connection:Connection) {
        
        self.connections.append(connection)
    }
    
    func SetSegmentIDforConnectionAt(_ index:Int, newID:Int) {

        self.connections[index].segmentID = newID
    }

    /// Rewrite every serial number this Segment's connections refer to, using `map` (old serial -> new serial). A serial with no
    /// entry in the map is left alone, so the call is safe to make on Segments that were not part of the change.
    ///
    /// There are THREE places a serial number hides in a Connection, and a remap that misses any of them leaves the model
    /// referring to Segments that no longer exist:
    ///
    ///   1. `segmentID` - the connection's own target;
    ///   2. `equivalentConnections[].parent` - the Segment holding the mirror-image connection, which is how RemoveConnection()
    ///      finds the other end of a jumper to take it out too;
    ///   3. `equivalentConnections[].connection.segmentID` - that mirror connection's own target, which points back at self.
    ///
    /// Only (1) was ever remapped - and even that was written as a no-op, reading the ID and assigning it straight back - so a
    /// combine or an interleave left dangling serials behind. The visible symptom was in SetNodes(), which decides whether two
    /// axially adjacent Segments SHARE a node by matching a connection's segmentID against the neighbour's serial: a stale ID
    /// never matches, so the coil was silently split into disconnected pieces at every boundary, and SimulationModel's init then
    /// failed to find the nodes its connectors described.
    ///
    /// `EquivalentConnection`'s stored properties are `let`, so the set is rebuilt rather than mutated in place.
    func RemapConnectionSegmentIDs(_ map:[Int:Int]) {

        for i in 0..<self.connections.count {

            if let oldID = self.connections[i].segmentID, let newID = map[oldID] {

                self.connections[i].segmentID = newID
            }

            guard !self.connections[i].equivalentConnections.isEmpty else {

                continue
            }

            var remapped:Set<Connection.EquivalentConnection> = []

            for nextEquivalent in self.connections[i].equivalentConnections {

                var mirror = nextEquivalent.connection

                if let oldID = mirror.segmentID, let newID = map[oldID] {

                    mirror.segmentID = newID
                }

                remapped.insert(Connection.EquivalentConnection(parent: map[nextEquivalent.parent] ?? nextEquivalent.parent, connection: mirror))
            }

            self.connections[i].equivalentConnections = remapped
        }
    }

    /// Move and/or resize the Segment radially.
    ///
    /// The Segment's rect is the live radial geometry of the model - it is what TransformerView draws, what CreateFePhase hands to
    /// the finite-element model, and what every capacitance routine measures from. The BasicSections keep the PRISTINE radii they
    /// were given when the design file was read, and are deliberately left alone: they are a 'let' (they have to be, because
    /// validateMenuItem and friends read them synchronously from the main actor), and keeping them pristine makes the built-up
    /// geometry a pure function of the design file plus the current shield set, so PhaseModel.ApplyRadialBuildUp is idempotent and
    /// exactly reversible. See that routine.
    func SetRadialGeometry(r1:Double, width:Double) {

        self.rect.origin.x = r1
        self.rect.size.width = width
    }

    /// The pristine (as-read-from-the-design-file) inner radius of the segment. Use r1 for the live geometry.
    nonisolated var pristineR1:Double {

        return self.basicSections[0].r1
    }

    /// The pristine (as-read-from-the-design-file) radial build of the segment. Use r2 - r1 for the live geometry.
    nonisolated var pristineWidth:Double {

        return self.basicSections[0].width
    }

    /// The inner radius of the segment (from the core center)
    var r1:Double {
        get {
            return self.rect.origin.x
        }
    }
    
    /// The outer radius of the segment (from the core center)
    var r2:Double {
        get {
            return Double(self.rect.origin.x + self.rect.size.width)
        }
    }
    
    /// The bottom-most axial dimension of the segment (using the REAL window height)
    var z1:Double {
        get {
            return Double(self.rect.origin.y)
        }
    }
    
    /// The top-most axial dimension of the segment (using the REAL window height)
    var z2:Double {
        get {
            return Double(self.rect.origin.y + self.rect.size.height)
        }
    }
    
    /// The axial center of the segment (using the real window height)
    var zMean:Double {
        
        return (self.z1 + self.z2) / 2
    }
    
    /// The window height that is used in the Fourier series (corresponds to the 'L' variable in  the formulas in DelVecchio
    var L:Double {
        get {
            return max(self.realWindowHeight, self.useWindowHeight)
        }
    }
    
    /// The number to add to z1 and z2 to get the axial dimensions in the "Fourrier series" window height ('L')
    var zWindHtAdder:Double {
        get {
            let result = (self.L - self.realWindowHeight) / 2.0
            
            return result
        }
    }
    
    /// The area of the segment
    var area:Double {
        get {
            return Double(self.rect.width * self.rect.height)
        }
    }
    
    /// The number of turns in the Segment
    var N:Double {
        get {
            var result = 0.0
            
            for nextSection in self.basicSections {
                
                result += nextSection.N
            }
            
            return result
        }
    }
    
    /// The current density of the section
    /*
    var ActualJ:Double {
        get {
            return self.N * self.I / self.area
        }
    }
    */
    
    /// The resistance of the segment at the given temperature (in C)
    func resistance(at temp:Double = 20.0) -> Double {
        
        let tempFactor = (234.5 + temp) / (234.5 + 20)
        let lmt = (self.r1 + self.r2) * π
        
        guard let bSect = self.basicSections.first else {
            
            return 0
        }
        
        let result = self.N * lmt * bSect.wdgData.turn.resistancePerMeter * tempFactor
        
        return result
    }
    
    func turnEffectiveRadius() -> Double {
        
        guard let bSect = self.basicSections.first else {
            
            return 0
        }
        
        return bSect.wdgData.turn.effectiveRadius
    }
    
    var eddyLossRadialPU:Double = 0.0
    var eddyLossAxialPU:Double = 0.0
    
    func SetEddyLossesPU(radial:Double, axial:Double) {
        
        eddyLossRadialPU = radial
        eddyLossAxialPU = axial
    }
    
    
    /// The series capacitance of the segment when it is considered within a coil (this property is set elsewhere)
    var seriesCapacitance:Double = 0.0
    
    func SetSeriesCapacitance(serCap:Double) {
        
        self.seriesCapacitance = serCap
    }
    
    /// A struct to define mutual inductance to other Segments (note: the self-inductance can be defined using this struc with the 'toSegment' poroperty set to 'nil')
    struct MutualInductance {
        
        let toSegment:Segment?
        let inductance:Double
    }
    
    var inductances:[MutualInductance] = []
    
    /// Constructor for a Segment. The array of BasicSections that is passed in is checked to make sure that all sections are part of the same coil, and that they are adjacent and in order from lowest Z to highest Z.
    /// - Note: This initiializer may fail and throw an error.
    /// - Parameter basicSections: An array of BasicSections. The sections must be part of the same Winding, be adjacent, and in order from lowest Z to highest Z.
    /// - Parameter interleaved: Boolean for indication of whether the Segment is interleaved or not (default: false)
    /// - Parameter isStaticRing: Boolean to indicate that the Segment is actaully a static ring (default: false)
    /// - Parameter isRadialShield: Boolean to indicate that the Segment is actually a radial sheild (default: false)
    /// - Parameter realWindowHeight: The actual window height of the core
    /// - Parameter useWindowHeight: The window height that should be used (important for some Delvecchio calculations)
    init(basicSections:[BasicSection], interleaved:Bool = false, isStaticRing:Bool = false, isRadialShield:Bool = false, realWindowHeight:Double, useWindowHeight:Double) throws
    {
        guard let first = basicSections.first, let last = basicSections.last else {
            
            throw SegmentError(info: "", type: .EmptyModel)
        }
        
        let winding = first.location.radial
        var axialIndex = first.location.axial
        var zCurrent = first.z1
        self.I = first.I
        self.realWindowHeight = realWindowHeight
        self.useWindowHeight = useWindowHeight
        
        for i in 1..<basicSections.count {
            
            guard basicSections[i].location.axial == axialIndex + 1, basicSections[i].z1 > zCurrent, basicSections[i].location.radial == winding else {
                
                
                throw SegmentError(info: "\(basicSections[i].location)", type: .IllegalSection)
            }
            
            axialIndex = basicSections[i].location.axial
            zCurrent = basicSections[i].z1
        }
        
        // if we get here, we can save the array and set the properties
        self.basicSections = basicSections
        self.interleaved = interleaved
        
        self.rect = NSRect(x: first.r1, y: first.z1, width: first.width, height: last.z2 - first.z1)
        
        // EVERY Segment gets its own serial number, shielding elements included. Segments are Equatable and Hashable BY serial
        // number, so the dummy -1 that static rings and radial shields used to share made all of them equal to each other and to
        // one another: `segmentStore.firstIndex(of: aStaticRing)` found whichever shielding element came first, so removing the
        // second static ring in a model removed the first one - or a radial shield. Shielding elements carry no connectors, so a
        // real serial number costs nothing but the counter.
        self.serialNumber = Segment.nextSerialNumber
        self.isStaticRing = isStaticRing
        self.isRadialShield = isRadialShield
    }
    
    /// Errors for the Segment class
    struct SegmentError:LocalizedError {
        
        /// The different error types that are available
        enum errorType {
            
            case UnknownError
            case EmptyModel
            case IllegalSection
            case StaticRing
            case RadialShield
            case UnimplementedWdgType
            case AxialAndRadialGapsAreNil
            case AxialAndRadialGapsAreNonNil
            case IllegalWindingType
            case IllegalInterleavedType
            case IllegalWoundInShield
            case IllegalMultiStart
        }
        
        /// Specialized information that can be added to the descritpion String (can be the empty string)
        let info:String
        /// The error type
        let type:errorType
        
        /// The error string to return with the error
        var errorDescription: String? {
            
            get {
                
                if self.type == .EmptyModel {
                    
                    return "There are no BasicSections in the array!"
                }
                else if self.type == .IllegalSection {
                    
                    return "There is an illegal BasicSection (at location \(info)) in the array. All sections must be part of the same coil, must be adjacent, and in order from lowest Z to highest Z."
                }
                else if self.type == .StaticRing {
                    
                    return "The segment at location \(info) is a static ring!"
                }
                else if self.type == .RadialShield {
                    
                    return "The segment at location \(info) is a radial shield!"
                }
                else if self.type == .UnimplementedWdgType {
                    
                    return "Unimplemented winding type!"
                }
                else if self.type == .AxialAndRadialGapsAreNil {
                    
                    return "Either Axial or Radial adjacent gaps must be defined!"
                }
                else if self.type == .IllegalWindingType {
                    
                    return "The winding type does not match the adjacent gaps that are defined!"
                }
                else if self.type == .IllegalInterleavedType {

                    return "Only disc windings can be interleaved!"
                }
                else if self.type == .IllegalWoundInShield {

                    return "Illegal wound-in shield: \(info)"
                }
                else if self.type == .IllegalMultiStart {

                    return "Multi-start winding (DelVecchio 12.12): \(info)"
                }

                return "An unknown error occurred."
            }
        }
    }
    
    /// Return all the destination segments (and locations) for the given location on this Segment
    func ConnectionDestinations(fromLocation:Connector.Location) -> [(segmentID:Int?, location:Connector.Location)] {
        
        var result:[(segmentID:Int?, location:Connector.Location)] = []
        
        for nextConnection in self.connections {
            
            if nextConnection.connector.fromLocation == fromLocation {
                
                result.append((nextConnection.segmentID, nextConnection.connector.toLocation))
            }
        }
        
        return result
    }
    
    /// Add the Set of Connections as 'equivalent connections' to the given Connection. If the 'to' parameter is in the 'equ' array, it is ignored. If 'to' does not exist, the function does nothing.
    func AddEquivalentConnections(to:Connection, equ:Set<Connection.EquivalentConnection>) {
        
        guard let connIndex = self.connections.firstIndex(where: { $0 == to }) else {
            
            return
        }
        
        self.connections[connIndex].equivalentConnections.formUnion(equ)
        self.connections[connIndex].equivalentConnections.remove(Connection.EquivalentConnection(parent: self.serialNumber, connection: to))
    }
    
    /// Remove the given connection and all of it's iterations (from connected segments, etc), except for segments in the maskSegments array.. If the connection is to ground or impulse, the connection is converted to a floating connection.
    /// - Returns: An array of segment serial numbers that were affected by the operation
    func RemoveConnection(segments:[Segment], connection:Segment.Connection) async -> [Int] {
        
        var result:[Int] = []
        
        guard let connIndex = self.connections.firstIndex(where: { $0 == connection }) else {
            
            return []
        }
        
        for nextEquivalent in self.connections[connIndex].equivalentConnections {
            
            guard let segmentToRemoveFrom = segments.first(where: { $0.serialNumber == nextEquivalent.parent }) else {
                
                continue
            }
            
            let removeCheck = await segmentToRemoveFrom.DoRemoveConnection(connection: nextEquivalent.connection)
            
            if removeCheck {
                
                result.append(nextEquivalent.parent)
            }
        }
        
        if self.DoRemoveConnection(connection: connection) {
            
            result.append(self.serialNumber)
        }
        
        return result
    }
    
    /// A private function that actually removes a connection from this Segment. Calling routines should call the RemoveConnection() function to make sure all related connections are also removed. If the connection that is passed to the routine does not exist, the routine does nothing. If the connecion is to ground or impulse, it is basically converted to floating. If the connection is floating, the routine does nothing.
    /// - Returns: A Boolean, indicating whether anything was actually removed/changed
    private func DoRemoveConnection(connection:Segment.Connection) -> Bool {
        
        let toLocation = connection.connector.toLocation
        
        if toLocation == .floating {
            
            return false
        }
        
        let oldCount = self.connections.count
        self.connections.removeAll(where: { $0 == connection })
        
        if toLocation == .impulse || toLocation == .ground {
            
            let newConnection = Segment.Connection(segmentID: connection.segmentID, connector: Connector(fromLocation: connection.connector.fromLocation, toLocation: .floating))
            self.connections.append(newConnection)
            
            return true
        }
        
        return self.connections.count < oldCount
    }
    
    /// Private function to actually add a new connection (required due to actor status)
    private func DoAddConnection(connection:Segment.Connection) {
        
        self.connections.append(connection)
    }
    
    
    /// Add a connector to the segment at the given fromLocation. The toLocation parameter depends on the toSegment parameter:
    /// If toSegment is not nil, then toLocation refers to the location on the toSegment. This routine will also add the inverse connector to the toSegment
    /// If toSegment is nil, then the behaviour of the routine is as follows:
    /// If toLocation is .ground or .impulse and self.connection has a connection with a fromLocation the same as the parameter, and a toLocation equal to .floating, that connector is changed to the new connector definition.
    /// If toLocation is .ground, or .impulse, or .floating, and self.connection does not have a corresponding .floating connector, then the new connector is added to self.connections.
    /// - Returns: If toSegment is non-nil, the function returns tuple of the one or two equivalent connections that were created; otherwise it returns both nil
    @discardableResult func AddConnector(segments:[Segment], fromLocation:Connector.Location, toLocation:Connector.Location, toSegmentID:Int?) async -> (from:Segment.Connection?, to:Segment.Connection?) {
        
        if let otherSegmentID = toSegmentID {
            
            // don't create a connector to self
            if otherSegmentID == self.serialNumber {
                
                return (nil, nil)
            }
            
            let newSelfConnection = Connection(segmentID: otherSegmentID, connector: Connector(fromLocation: fromLocation, toLocation: toLocation))
            self.connections.append(newSelfConnection)
            let newOtherConnection = Connection(segmentID: self.serialNumber, connector: Connector(fromLocation: toLocation, toLocation: fromLocation))
            
            if let otherSegment = segments.first(where: {$0.serialNumber == otherSegmentID})  {
                
                await otherSegment.DoAddConnection(connection: newOtherConnection)
                
                self.AddEquivalentConnections(to: newSelfConnection, equ: [Connection.EquivalentConnection(parent: otherSegmentID, connection: newOtherConnection)])
                await otherSegment.AddEquivalentConnections(to: newOtherConnection, equ: [Connection.EquivalentConnection(parent: self.serialNumber, connection: newSelfConnection)])
            }
            
            return (newSelfConnection, newOtherConnection)
        }
        else if let existingFloatingIndex = self.connections.firstIndex(where: {$0.connector.fromLocation == fromLocation && $0.connector.toLocation == .floating}) {
            
            self.connections.remove(at: existingFloatingIndex)
            let newSelfConnection = Connection(segmentID: nil, connector: Connector(fromLocation: fromLocation, toLocation: toLocation))
            self.connections.append(newSelfConnection)
            return (newSelfConnection, nil)
        }
        else if (toLocation == .ground || toLocation == .impulse) && (self.connections.first(where: {$0.connector.toLocation == .ground}) != nil || self.connections.first(where: {$0.connector.toLocation == .impulse}) != nil) {
            
            // already grounded or impulsed, ignore and return
            return (nil, nil)
        }
        else {
            
            // add a new termination at a non-floating location
            let newSelfConnection = Connection(segmentID: nil, connector: Connector(fromLocation: fromLocation, toLocation: toLocation))
            self.connections.append(newSelfConnection)
            return (newSelfConnection, nil)
        }
    }
    
    /// One "unit" of a Segment for series-capacitance purposes: the span of BasicSections that gets its own capacitance before the
    /// units are combined in series.
    struct SeriesCapacitanceUnit {

        /// The span of BasicSections, as an index range into the Segment's own array
        let range:Range<Int>
        /// The number of shield turns per disc for this unit, or 0 if it carries none
        let shieldTurns:Int
    }

    /// Split this Segment into the units that SeriesCapacitance combines in series.
    ///
    /// A unit is a single disc normally, and a double disc when the two discs are wound as one thing: interleaved, or spanned by a
    /// wound-in shield (a shield crosses over at the outermost turn of a PAIR, which is why DelVecchio 12.96 is written for a pair).
    ///
    /// The spans are deliberately not a fixed stride. A shielded pair whose shield count is zero is emitted as two ordinary single
    /// discs instead of as a pair, so that it keeps the Stein / end-disc / static-ring treatment of the plain disc path. That costs
    /// nothing in accuracy - 12.96 at n = 0 is identically two plain discs in series (see WoundInShieldSeriesCapacitance) - and it
    /// is what lets a graded shielding scheme taper down to zero without a discontinuity.
    func SeriesCapacitanceUnits() -> [SeriesCapacitanceUnit] {

        var result:[SeriesCapacitanceUnit] = []
        let count = self.basicSections.count

        if let woundInShield = self.woundInShield {

            var index = 0
            var pairIndex = 0

            while index + 1 < count {

                let shieldTurns = pairIndex < woundInShield.turnsPerDisc.count ? woundInShield.turnsPerDisc[pairIndex] : 0

                if shieldTurns > 0 {

                    result.append(SeriesCapacitanceUnit(range: index..<(index + 2), shieldTurns: shieldTurns))
                }
                else {

                    result.append(SeriesCapacitanceUnit(range: index..<(index + 1), shieldTurns: 0))
                    result.append(SeriesCapacitanceUnit(range: (index + 1)..<(index + 2), shieldTurns: 0))
                }

                index += 2
                pairIndex += 1
            }

            // A shielded Segment is required to hold an even number of discs, so this cannot currently happen - but if it ever did,
            // dropping the last disc would silently lose its capacitance, so treat it as an ordinary one.
            if index < count {

                result.append(SeriesCapacitanceUnit(range: index..<(index + 1), shieldTurns: 0))
            }
        }
        else if self.interleaved {

            var index = 0

            while index + 1 < count {

                result.append(SeriesCapacitanceUnit(range: index..<(index + 2), shieldTurns: 0))
                index += 2
            }

            if index < count {

                result.append(SeriesCapacitanceUnit(range: index..<(index + 1), shieldTurns: 0))
            }
        }
        else {

            for index in 0..<count {

                result.append(SeriesCapacitanceUnit(range: index..<(index + 1), shieldTurns: 0))
            }
        }

        return result
    }

    /// The series capacitance of a single wound-in-shield disc PAIR, complete with its disc-disc energy.
    ///
    /// This does not go through Stein's formula, and that is deliberate. Stein (12.35, and 12.53/12.54 as the code uses them) solves
    /// for a voltage that traverses the disc radially ONCE. A shielded unit is a pair, and its voltage traverses radially twice, so
    /// feeding a pair to the ordinary disc branch would give a small-α limit of (2/3)(Cdd_above + Cdd_below) = (4/3)·c_d for equal
    /// gaps - twice the right answer, and with the pair's own internal gap missing entirely. DelVecchio's own treatment of the
    /// shielded pair (12.93) assumes the voltage varies linearly along the pair, and that is what is used here.
    ///
    /// Splitting his disc-disc term by gap. Let u be the radial position along a disc, 0 at the outside, 1 at the inside, and let V
    /// be the voltage across the pair. Inside the pair, the lower disc is at uV/2 and the upper at V − uV/2, so the difference
    /// across the INTERNAL gap is V(1 − u) and its energy is ½·c_d·V²∫₀¹(1−u)²du = ½·c_d·V²/3 - all of which belongs to this pair.
    /// Across an EXTERNAL gap the neighbouring pair ramps the same way, the difference is uV, and the energy is again ½·c_d·V²/3 -
    /// but that is shared with the neighbour, so this pair takes half. Setting the total equal to ½·C·V²:
    ///
    ///     C = Cs + (1/3)·Cdd_internal + (1/6)·(Cdd_below + Cdd_above)
    ///
    /// which collapses to DelVecchio's "(2/3)·c_d, embedded" when all three gaps are equal, and to his isolated-pair (1/3)·c_d when
    /// the external gaps are absent. It also generalizes his equal-gap assumption the same way the helical branch generalizes 12.41.
    ///
    /// The cost of the linear-voltage assumption, measured by VerifyWoundInShieldCapacitance() on DelVecchio's own coil: +2.96% at
    /// n = 1 (α = 1.22), +0.96% at n = 2, +0.47% at n = 3. It falls away quickly because every shield turn raises Cs and so lowers
    /// α = √(2·Cdd/Cs). At n = 0 it would be +117% (α = 6.0), which is why SeriesCapacitanceUnits sends an unshielded pair down the
    /// plain path instead of through here. Within its own range this is not an oversight - do not "fix" it by reaching for Stein.
    func WoundInShieldPairCapacitance(turnsPerDisc:Int, wire:WoundInShieldWire, axialGaps:(above:Double, below:Double), endDisc:(lowest:Bool, highest:Bool)?, adjStaticRing:(above:Bool, below:Bool)?) throws -> Double {

        guard self.basicSections.count == 2 else {

            throw SegmentError(info: "a wound-in shield spans exactly two discs", type: .IllegalWoundInShield)
        }

        let Cs = try self.WoundInShieldSeriesCapacitance(turnsPerDisc: turnsPerDisc, wire: wire)

        // The area of the gap INSIDE the pair excludes the radial depth taken by the shield turns. Kulkarni & Khaparde, p.317:
        // "there is no contribution to the energy by the capacitances between the shield turns of the two disks at same radial
        // depth, since their potentials are equal. For a precise calculation, the radial depth in the above equation should
        // correspond to the radial depth of the winding excluding that of the shield turns." A laminar gap's capacitance is
        // proportional to its area, so scaling by the coil turns' share of the radial build is exactly that correction.
        //
        // Two limits on it. His "potentials are equal" is exact only for the first shield turn - his 7.42 and 7.46 put the two
        // discs' i-th shield turns 2(i−1)ΔV apart - so this is a good approximation rather than an identity. And it applies to the
        // internal gap only: across an external gap the shield turns facing each other belong to two different pairs and are a
        // whole pair-voltage apart, so they store energy just as the coil turns there do. Hence internalCddScale and not a scale on
        // everything.
        let radialBuild = self.r2 - self.r1
        let shieldBuild = Double(turnsPerDisc) * wire.overPaperRadial
        let coilShareOfBuild = radialBuild > 0.0 ? max(0.0, min(1.0, 1.0 - shieldBuild / radialBuild)) : 1.0

        return try self.TwoDiscPairCapacitance(Cs: Cs, axialGaps: axialGaps, endDisc: endDisc, adjStaticRing: adjStaticRing, internalCddScale: coilShareOfBuild)
    }

    /// The series capacitance of a **two-disc unit** whose turn term is already known: DelVecchio's linear-voltage form
    ///
    ///     C = Cs + (1/3)·Cdd_internal + (1/6)·(Cdd_below + Cdd_above)
    ///
    /// **Both kinds of two-disc unit come through here - interleaved and wound-in-shield - and that is the point.** They are
    /// structurally the same object: two discs wound as one thing, with a gap of their own inside and one external gap on each
    /// face. Letting them get their disc-disc energy from different places is how a comparison between the two methods ends up
    /// measuring the bookkeeping instead of the physics, which is exactly what happened before 2026-08-06: the shielded pair used
    /// this form (from DelVecchio) while the interleaved pair dropped the disc-disc term entirely (from Kulkarni & Khaparde 7.3.5,
    /// "it is sufficient to consider only the interturn capacitances"). On the STME-0999_2 fixture that asymmetry alone was the
    /// whole 17% by which a half-shielded winding appeared to beat a fully interleaved one - the turn terms were a dead heat.
    ///
    /// K&K's licence to drop it is that the interdisk capacitance is "relatively low" against an interleaved winding's interturn
    /// capacitance. That is true of the designs he has in mind and not true here - it is 16% of the interleaved total on
    /// STME-0999_2 - and it costs nothing to evaluate, so it is evaluated.
    ///
    /// **Why this form and not Stein.** Stein's α/tanh α assumes ONE radial traverse and a pair makes two, which over-counts the
    /// disc-disc energy about 2× at small α and has no place at all for the pair's internal gap. The coefficients here are the
    /// per-gap split of DelVecchio's "(2/3)·c_d embedded": the internal gap is crossed by the full linear voltage ramp and takes
    /// 1/3, while each external gap is shared with the neighbouring unit and takes half of that.
    ///
    /// - Parameter Cs: the unit's turn (interturn) capacitance, already computed by whichever method applies
    /// - Parameter internalCddScale: fraction of the internal gap's area that stores energy. 1.0 for an interleaved pair, whose
    /// discs are all coil turns; less for a shielded pair - see `WoundInShieldPairCapacitance`.
    func TwoDiscPairCapacitance(Cs:Double, axialGaps:(above:Double, below:Double), endDisc:(lowest:Bool, highest:Bool)?, adjStaticRing:(above:Bool, below:Bool)?, internalCddScale:Double = 1.0) throws -> Double {

        guard self.basicSections.count == 2 else {

            throw SegmentError(info: "a two-disc unit holds exactly two discs, not \(self.basicSections.count)", type: .IllegalWoundInShield)
        }

        let staticRing = adjStaticRing ?? (above:false, below:false)

        // The gap inside the pair. Both discs have the same radii, so either one gives the same area.
        let internalGap = self.basicSections[1].z1 - self.basicSections[0].z2

        let CddInternal = internalCddScale * Segment.DiscToDiscSeriesCapacitance(belowGap: internalGap, aboveGap: 0.0, basicSection: self.basicSections[0], innerRadius: self.r1, outerRadius: self.r2, staticRing: (above:false, below:false)).below

        let CddExternal = Segment.DiscToDiscSeriesCapacitance(belowGap: axialGaps.below, aboveGap: axialGaps.above, basicSection: self.basicSections[0], innerRadius: self.r1, outerRadius: self.r2, staticRing: staticRing)

        var CddBelow = CddExternal.below
        var CddAbove = CddExternal.above

        // At a coil end with no static ring the "gap" is the clearance to the yoke. That is a capacitance to ground, not a
        // turn-to-turn one, so it stores no series energy - DelVecchio 12.7's Ca = 0, and the same rule the helical branch applies.
        if let endDiscLoc = endDisc {

            if endDiscLoc.lowest && !staticRing.below {

                CddBelow = 0.0
            }

            if endDiscLoc.highest && !staticRing.above {

                CddAbove = 0.0
            }
        }

        return Cs + CddInternal / 3.0 + (CddBelow + CddAbove) / 6.0
    }

    /// The series capacitance of the Segment. For Segments that are made up of more than one (or two, for interleaved windings) axial BasicSections, the routine calls itself for each BasicSection.
    func SeriesCapacitance(axialGaps:(above:Double, below:Double)?, radialGaps:(inside:Double, outside:Double)?, endDisc:(lowest:Bool, highest:Bool)?, adjStaticRing:(above:Bool, below:Bool)?) async throws -> Double {
        
        guard axialGaps != nil || radialGaps != nil else {
            
            throw SegmentError(info: "", type: .AxialAndRadialGapsAreNil)
        }
        
        guard axialGaps == nil || radialGaps == nil else {
            
            throw SegmentError(info: "", type: .AxialAndRadialGapsAreNonNil)
        }
        
        guard axialGaps == nil || (self.wdgType == .disc || self.wdgType == .helical) else {
            
            throw SegmentError(info: "", type: .IllegalWindingType)
        }
        
        do {
        
            if self.wdgType == .disc || self.wdgType == .helical {

                let units = self.SeriesCapacitanceUnits()

                var result = 0.0

                if units.count > 1 {

                    // Each pass handles one "unit" - the span of BasicSections that gets its own series capacitance before the units
                    // are combined in series. See SeriesCapacitanceUnits() for what a unit is; the important point here is that the
                    // spans are NOT a fixed stride, so every index has to come from the unit's own range. Deriving them by arithmetic
                    // from a loop counter is what previously made an interleaved Segment of more than one double disc read the wrong
                    // sections (and measure its gaps from the wrong faces).
                    for (i, unit) in units.enumerated() {

                        let firstIndex = unit.range.lowerBound
                        let lastIndex = unit.range.upperBound - 1

                        let unitBottom = self.basicSections[firstIndex]
                        let unitTop = self.basicSections[lastIndex]

                        let bs:[BasicSection] = Array(self.basicSections[unit.range])

                        // The outermost gaps are the ones handed to us; the interior ones are measured between this unit's outer faces
                        // and the facing section of the neighbouring unit.
                        let gapAbove = i == units.count - 1 ? axialGaps!.above : self.basicSections[lastIndex + 1].z1 - unitTop.z2
                        let gapBelow = i == 0 ? axialGaps!.below : unitBottom.z1 - self.basicSections[firstIndex - 1].z2

                        // Only the units at the two ends of this Segment can be at a coil end or next to a static ring, and each of them
                        // can only be so on its outward-facing side. Interior units see plain disc-to-disc gaps on both sides.
                        var endD:(lowest:Bool, highest:Bool)? = nil
                        var staticRing:(above:Bool, below:Bool)? = nil

                        if i == 0 {

                            endD = endDisc != nil ? (endDisc!.lowest, false) : nil
                            staticRing = adjStaticRing != nil ? (false, adjStaticRing!.below) : nil
                        }
                        else if i == units.count - 1 {

                            endD = endDisc != nil ? (false, endDisc!.highest) : nil
                            staticRing = adjStaticRing != nil ? (adjStaticRing!.above, false) : nil
                        }

                        let tmpSeg = try Segment(basicSections: bs, interleaved: self.interleaved, isStaticRing: false, isRadialShield: false, realWindowHeight: self.realWindowHeight, useWindowHeight: self.useWindowHeight)

                        // Segment.init builds its rect from the BasicSections, and those hold the PRISTINE radii from the design
                        // file - so without this, every unit of a coil that has been built up to carry shields would be measured at
                        // the radius it had before the build-up. All the discs of a Segment share its radii, so handing down our own
                        // is exactly right.
                        await tmpSeg.SetRadialGeometry(r1: self.r1, width: self.r2 - self.r1)

                        // carry this unit's share of the shield forward to the leaf
                        if unit.shieldTurns > 0, let wire = self.woundInShield?.wire {

                            await tmpSeg.SetWoundInShield(WoundInShield(wire: wire, turnsPerDisc: [unit.shieldTurns]))
                        }

                        let serCap = try await tmpSeg.SeriesCapacitance(axialGaps: (above:gapAbove, below:gapBelow), radialGaps: nil, endDisc: endD, adjStaticRing: staticRing)

                        result += 1 / serCap
                    }

                    return 1 / result
                }

                // A single unit that is a shielded disc pair is DelVecchio 12.11's own case and takes a route of its own - see the
                // routine for why Stein cannot be used on a two-disc unit.
                if let woundInShield = self.woundInShield, let shieldTurns = woundInShield.turnsPerDisc.first, shieldTurns > 0 {

                    return try self.WoundInShieldPairCapacitance(turnsPerDisc: shieldTurns, wire: woundInShield.wire, axialGaps: axialGaps!, endDisc: endDisc, adjStaticRing: adjStaticRing)
                }
            }

            var Cs = try self.BasicSectionSeriesCapacitance()
            if self.interleaved {

                Cs /= 2
            }

            if self.wdgType == .sheet {

                // No shunt term belongs here, unlike the disc case. A sheet winding is built as a single BasicSection spanning the whole
                // electrical height, so it behaves like one enormous disc whose turns run radially - it has no second disc of the same
                // winding facing it. What lies across 'radialGaps' is a different coil, at an unrelated potential, and that path is a
                // shunt capacitance handled by PhaseModel.CalculateCapacitanceMatrix, not series energy inside this winding. So Cs alone
                // is the whole story, and radialGaps is deliberately unused.
                //
                // That Cs is now the EXACT series chain 1/Σ(1/C_k) over the coil's gaps rather than a formula in one representative
                // turn-to-turn capacitance - see BasicSectionSeriesCapacitance. Nothing here has to change for it: the chain is the
                // same quantity, computed without the averaging.
                return Cs
            }
            else if self.wdgType == .multistart {

                // The whole winding is one lumped section and 12.12 already counts every interface in it, so - as for a sheet - Cs is
                // the whole answer. What lies across 'radialGaps' is another coil, a shunt path handled in PhaseModel.
                return Cs
            }
            else if self.wdgType == .helical {

                // A helical turn has Cs = 0, so Stein's formula degenerates (α → ∞) and DelVecchio's "conventional" formula 12.41 has to
                // be used instead. 12.41 (Cconv = Cs + 4/3·Cdd) is derived for EQUAL disc-disc spacings on both sides. Redoing the shunt
                // energy integral 12.25 for unequal spacings, with Ca = 2·Cdd1, Cb = 2·Cdd2, Va = V, Vb = 0 and the assumed linear
                // V(x) = V(1 − x/L) of 12.37:
                //
                //     Eshunt = (Ca/2L)∫₀ᴸ[V(x) − V]²dx + (Cb/2L)∫₀ᴸ[V(x)]²dx = (V²/3)(Cdd1 + Cdd2)
                //
                // and with E = ½CV² that gives C = Cs + 2/3·(Cdd1 + Cdd2) - i.e. 4/3 of the AVERAGE of the two, which collapses back to
                // 12.41 when they are equal. The old code used max(gap) on both sides, which is the *smaller* of the two Cdd and so
                // understated the capacitance whenever the gaps differed.
                let aboveGap = axialGaps!.above
                let belowGap = axialGaps!.below

                let srForCdd = adjStaticRing ?? (above:false, below:false)
                let Cdd = Segment.DiscToDiscSeriesCapacitance(belowGap: belowGap, aboveGap: aboveGap, basicSection: self.basicSections[0], innerRadius: self.r1, outerRadius: self.r2, staticRing: srForCdd)

                // At a coil end with no static ring, the "gap" handed to us is the clearance to the yoke. That is a capacitance to
                // ground, not a turn-to-turn one, so it stores no series energy and that side contributes nothing - the helical analogue
                // of DelVecchio 12.7, where the end disc is given Ca = 0.
                var CddBelow = Cdd.below
                var CddAbove = Cdd.above

                if let endDiscLoc = endDisc {

                    if endDiscLoc.lowest && !srForCdd.below {

                        CddBelow = 0.0
                    }

                    if endDiscLoc.highest && !srForCdd.above {

                        CddAbove = 0.0
                    }
                }

                return Cs + 2.0 / 3.0 * (CddBelow + CddAbove)
            }
            else if self.wdgType == .disc && self.interleaved {

                // An interleaved pair is a two-disc unit and takes the same route as the other one - see TwoDiscPairCapacitance
                // for why they must share it, and why neither goes through Stein.
                //
                // internalCddScale is 1.0 here: every turn in an interleaved disc is a coil turn, so the whole face of the internal
                // gap stores energy. The shielded pair is the case that reduces it.
                guard self.basicSections.count == 2 else {

                    // Not a pair after all, so there is no internal gap to speak of. Should be unreachable - an interleaved
                    // Segment is built two discs at a time and SeriesCapacitanceUnits splits a longer one into pairs - but the
                    // turn term is the honest answer if it ever happens, rather than a throw from deep inside a capacitance sum.
                    return Cs
                }

                return try self.TwoDiscPairCapacitance(Cs: Cs, axialGaps: axialGaps!, endDisc: endDisc, adjStaticRing: adjStaticRing)
            }
            else if self.wdgType == .disc {

                let aboveGap = axialGaps!.above
                let belowGap = axialGaps!.below

                let bs = self.basicSections[0]

                let Cdd = Segment.DiscToDiscSeriesCapacitance(belowGap: belowGap, aboveGap: aboveGap, basicSection: bs, innerRadius: self.r1, outerRadius: self.r2, staticRing: adjStaticRing ?? (above:false, below:false))

                // All three of the cases that used to be written out here - end disc beside a static ring, end disc without one, and an
                // interior disc - are the SAME formula (12.53) at different Ya/Yb, so they now come from one place. See
                // SteinParameters for the equivalence, and for why the static-ring test has to be made before the end-disc one.
                return Segment.SteinParameters.For(Cs: Cs, Cdd: Cdd, endDisc: endDisc, adjStaticRing: adjStaticRing).capacitance
            }
            else if self.wdgType == .layer {

                // DelVecchio has no layer-winding formula, so this is the "Huber method" noted in BasicSectionSeriesCapacitance: his disc
                // treatment turned on its side. The series capacitance runs axially, turn to turn within a layer, and the disc-to-disc
                // capacitance Cdd becomes the layer-to-layer capacitance Cll across the radial gap between layers. With that one
                // substitution 12.53 (general), 12.63 (end disc) and 12.59 (units in series) all carry over unchanged.
                //
                // Cll is a genuine series-energy term, exactly as Cdd is: the layers it connects belong to THIS winding and sit at
                // different potentials. That distinguishes it from the sheet case above, where the radial neighbours are other coils. It
                // was previously dropped altogether, which left only the single-layer Cs.
                let bs = self.basicSections[0]
                let numLayers = bs.wdgData.layers.numLayers

                guard numLayers > 1 else {

                    // One layer: there is no layer-to-layer path at all, so the turn-turn series capacitance is the whole answer.
                    return Cs
                }

                let Cll = try self.LayerToLayerCapacitance()

                // The innermost and outermost layers face another coil rather than another layer of this winding, so on that side there is
                // no same-winding shunt path: 12.7's Ca = 0 applies and the end-disc form 12.63 is used. Every interior layer sees Cll on
                // both sides, which is Stein's symmetric case (12.35).
                var endLayerC = 0.0
                var innerLayerC = 0.0

                if Cs > 0.0 {

                    let endAlpha = sqrt(2 * Cll / Cs)
                    endLayerC = Cs * endAlpha / tanh(endAlpha)

                    let alpha = sqrt(4 * Cll / Cs)
                    let firstTerm = 0.5 * alpha / tanh(alpha)
                    let secondTerm = 0.5 * alpha / sinh(alpha)
                    let thirdTerm = alpha * alpha / 4
                    innerLayerC = Cs * (firstTerm + secondTerm + thirdTerm)
                }
                else {

                    // A layer of a single turn has Cs = 0 and alpha blows up, the same degeneracy the helical branch hits. Fall back to
                    // the conventional formula 12.41 in the form derived there, Cs + 2/3*(Cll_inside + Cll_outside).
                    endLayerC = 2.0 / 3.0 * Cll
                    innerLayerC = 4.0 / 3.0 * Cll
                }

                // The layers are traversed one after the other, so their capacitances combine in series - the 12.59 analogue.
                let result = 2.0 / endLayerC + Double(numLayers - 2) / innerLayerC

                return 1.0 / result
            }
            else {
                
                throw SegmentError(info: "", type: .UnimplementedWdgType)
            }
        }
        catch {
            
            throw error
        }
        
        // throw SegmentError(info: "", type: .UnknownError)
    }

    /// The capacitance between two adjacent layers of a layer winding - the layer-oriented counterpart of the disc-to-disc capacitance
    /// Cdd, and the shunt term that DelVecchio's 12.53/12.63 need once his disc treatment is transposed to a layer winding.
    ///
    /// The gap between two layers is a radial one holding the inter-layer insulation and, where there is a cooling duct, oil held open by
    /// axial sticks. That is the same composite as the coil-to-coil gap, so this follows DelVecchio 12.60 rather than 12.52:
    ///
    ///     Cll = ε0 · 2π·Rmean · H · [ fs/((tIns/εPaper) + (tDuct/εBoard)) + (1 − fs)/((tIns/εPaper) + (tDuct/εOil)) ]
    ///
    /// with fs the stick fraction of the circumference (12.61). Two approximations worth knowing, both forced by what the design file
    /// carries: the ducts are spread evenly over the (numLayers − 1) inter-layer gaps rather than placed where they actually are, and the
    /// stick count is borrowed from the section's axial spacer columns - the same substitution CoilInnerShuntCapacitance makes for the
    /// hilo. Rmean is used for every gap instead of each boundary's own radius, consistent with the rest of this file.
    func LayerToLayerCapacitance() throws -> Double {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        guard self.wdgType == .layer else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        let bs = self.basicSections[0]
        let numLayers = bs.wdgData.layers.numLayers

        guard numLayers > 1 else {

            return 0.0
        }

        let rMean = (self.r1 + self.r2) / 2.0
        let H = bs.height

        let tIns = bs.wdgData.layers.interLayerInsulation
        let tDuct = Double(bs.wdgData.layers.ducts.numDucts) * bs.wdgData.layers.ducts.ductDimn / Double(numLayers - 1)

        let fs = Double(bs.wdgData.discData.numAxialColumns) * bs.wdgData.discData.axialColumnWidth / (2 * π * rMean)

        let solid = tIns / εPaper

        guard solid + tDuct > 0.0 else {

            throw SegmentError(info: "Layer winding has no insulation between layers", type: .IllegalWindingType)
        }

        let firstTerm = fs / (solid + (tDuct / εBoard))
        let secondTerm = (1 - fs) / (solid + (tDuct / εOil))

        return ε0 * 2 * π * rMean * H * (firstTerm + secondTerm)
    }

    // MARK: Per-gap radial geometry, for the turn ladder
    //
    // Everything above returns ONE capacitance for a whole coil, formed at the mean radius. That is right for the series-capacitance
    // sum, where only the total matters. It is exactly wrong for a turn ladder: a chain of equal capacitors divides a voltage
    // evenly, so a coil modelled that way can only ever report V/gaps per gap no matter what its geometry is. The three routines
    // below give each radial gap its own radius, which is where a sheet winding's entire non-uniformity lives and where a layer
    // winding's shunt varies. They deliberately do NOT feed SeriesCapacitance - changing that would move every existing result.

    /// How many ducts a winding with this many radial gaps can actually hold.
    ///
    /// A duct lives IN a gap, so there can be no more of them than there are gaps: a design file asking for more is asking for
    /// something that cannot be built, and the excess is dropped rather than being allowed to consume radial build that does not
    /// exist. (Nothing in the reader enforces this, so the clamp belongs here.)
    static func DuctCount(gapCount:Int, requested:Int) -> Int {

        return max(0, min(requested, gapCount))
    }

    /// Which radial gaps carry a cooling duct, spaced as evenly as the gap count allows. Gap 0 is the innermost.
    ///
    /// The rule: with `gapCount` gaps and `ductCount` ducts, one goes every `gapCount/ductCount` gaps, and the run of ducts is
    /// CENTRED in the winding rather than started from one end. Duct j (counting from 1) sits at gap round((j − ½)·gapCount/ductCount),
    /// 1-based - so 3 ducts in a 12-layer winding, which has 11 gaps, land at gaps 2, 6 and 9.
    ///
    /// The half-step is what centres it, and it is the whole difference between this and the obvious form. Placing duct j at
    /// round(j·gapCount/ductCount) also spaces them evenly, but j = ductCount then lands exactly on gapCount, so the outermost gap
    /// would carry a duct in every winding ever built while the innermost never did. The half-step leaves insulation-only gaps at
    /// both ends, which is how a winding is actually wound.
    ///
    /// The positions cannot collide once `ductCount` is clamped to `gapCount`: the step is then at least one gap, so successive
    /// rounded positions differ by at least one, and the first is at least ½ a step in from the inside so it cannot round below
    /// gap 1. The Set and the clamp below are belt and braces.
    static func DuctGaps(gapCount:Int, ductCount:Int) -> Set<Int> {

        guard gapCount > 0, ductCount > 0 else {

            return []
        }

        let ducts = DuctCount(gapCount: gapCount, requested: ductCount)
        let step = Double(gapCount) / Double(ducts)

        var result:Set<Int> = []

        for j in 1...ducts {

            // ...rounded, then back to a 0-based index, and held inside the range against any rounding surprise.
            let position = Int(((Double(j) - 0.5) * step).rounded()) - 1
            result.insert(min(max(position, 0), gapCount - 1))
        }

        return result
    }

    /// The solid insulation between two adjacent turns of a SHEET winding, in metres.
    ///
    /// IT IS A DESIGN DIMENSION, NOT A LEFTOVER. `PCH_ExcelDesignFile.Winding.interLayerInsulation` carries it for a sheet winding as
    /// well as for a layer one - a foil turn IS a layer - and `LayerGapCapacitances` has always read it. Backing it out of the radial
    /// build instead measures something else entirely: `electricalRadialBuild` is
    /// (numTurnsRadially·turnRadialDimn + numRadialDucts·radialDuctDimension)·overbuild and has NO term for the insulation between the
    /// turns, so (build − copper − ducts)/gaps returns the OVERBUILD ALLOWANCE spread over the gaps and nothing else. On the
    /// SheetAndLayer fixture that is 0.178 mm - 6% of 35.6 mm over 12 gaps - where the design file says 0.254 mm, and the two being
    /// the same order of magnitude is a coincidence of that one allowance rather than a reason to trust the derivation.
    ///
    /// The leftover survives as a FALLBACK for a file that leaves the field at zero, because a zero gap is an infinite capacitance and
    /// would take the whole series chain to zero volts with it. It takes the ducts out of the build first, since they are inside it.
    ///
    /// The build comes from the Segment's LIVE radii rather than the BasicSection's pristine `width` - standing rule 7 - so every
    /// route to a sheet winding's insulation now agrees, which they did not before: `CapacitanceTurnToTurn` used `width`.
    func SheetTurnInsulation() throws -> Double {

        guard self.wdgType == .sheet, let bs = self.basicSections.first else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        if bs.wdgData.layers.interLayerInsulation > 0.0 {

            return bs.wdgData.layers.interLayerInsulation
        }

        let turns = Int(bs.N.rounded())

        guard turns >= 2 else {

            throw SegmentError(info: "A sheet winding of one turn has no gap between turns", type: .IllegalWindingType)
        }

        let gapCount = turns - 1
        let ductCount = Segment.DuctCount(gapCount: gapCount, requested: bs.wdgData.layers.ducts.numDucts)
        let ductDimension = ductCount > 0 ? bs.wdgData.layers.ducts.ductDimn : 0.0

        let leftover = ((self.r2 - self.r1) - Double(turns) * bs.wdgData.turn.radialDimn - Double(ductCount) * ductDimension) / Double(gapCount)

        guard leftover > 0.0 else {

            throw SegmentError(info: "The sheet winding has no insulation between its turns, and its turns and ducts fill its whole radial build", type: .IllegalWindingType)
        }

        return leftover
    }

    /// The turn-to-turn capacitance of every radial gap of a SHEET winding, innermost gap first, each formed at its own radius.
    ///
    /// Each turn of a sheet winding is a full-height cylinder, so the turns screen each other completely: no interior turn has a
    /// capacitance to anything but its two radial neighbours, and the coil is a pure series chain between its two terminals. The same
    /// charge Q therefore passes through every gap and ΔV_k = Q/C_k, so the profile is set entirely by how C_k varies.
    ///
    /// Gap k is a cylindrical capacitor at its own radius r_k:
    ///
    ///     C_k = ε0·εPaper·2π·r_k·(h + 2τ)/τ                      [DelVecchio 12.47's form, with 2π·r_k for the circumference]
    ///
    /// which grows linearly with radius across the build, so the INNERMOST gap carries the most volts - by r_outer/r_inner over the
    /// outermost, about 13% for a 30 mm build at a 200 mm inner radius. Small, but it is the whole of the non-uniformity a sheet
    /// winding has, and `CapacitanceTurnToTurn`'s single mean-radius value reports none of it.
    ///
    /// Geometry: N sheets of `turn.radialDimn` stacked outwards from r1, with τ of insulation in every gap and a duct in some of
    /// them, so gap k lies between sheet k and sheet k + 1, centred at r1 + (k + 1)·t + (k + ½)·τ plus whatever ducts are below it.
    ///
    /// τ is the design file's `interLayerInsulation` - see the note on it below, and note that the `.sheet` branch of
    /// `CapacitanceTurnToTurn` does NOT use it and does not remove the ducts either, so it and this routine describe different
    /// windings. TODO.md §8c.
    ///
    /// The build is taken from the Segment's LIVE radii rather than the BasicSection's pristine `width` - see standing rule 7. It is
    /// used only for the duct-free fallback below; the walk itself is made of dimensions.
    func SheetGapCapacitances() throws -> [(radius:Double, capacitance:Double, insulation:Double, duct:Double)] {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        guard self.wdgType == .sheet, let bs = self.basicSections.first else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        let turns = Int(bs.N.rounded())

        guard turns >= 2 else {

            return []
        }

        let gapCount = turns - 1

        let t = bs.wdgData.turn.radialDimn

        // THE DUCTS ARE PLACED, not smeared: a gap either holds one or it does not, and one that does has some fifty times the
        // reduced thickness of one that does not. Smearing them - which is what dividing the leftover build by the gap count does -
        // makes all twelve gaps of the SheetAndLayer fixture identical when three of them are oil ducts.
        let ductCount = Segment.DuctCount(gapCount: gapCount, requested: bs.wdgData.layers.ducts.numDucts)
        let ductDimension = ductCount > 0 ? bs.wdgData.layers.ducts.ductDimn : 0.0
        let ductGaps = Segment.DuctGaps(gapCount: gapCount, ductCount: ductCount)

        let tau = try self.SheetTurnInsulation()

        let h = bs.height

        // The stick fraction of the circumference, where a duct is held open by axial sticks - the same substitution
        // LayerToLayerCapacitance makes for the inter-layer ducts. It is re-formed at each gap's own radius below.
        let stickWidth = Double(bs.wdgData.discData.numAxialColumns) * bs.wdgData.discData.axialColumnWidth

        var result:[(radius:Double, capacitance:Double, insulation:Double, duct:Double)] = []
        var radius = self.r1 + t

        // The walk starts at the winding ID, which is a real dimension, and accumulates real ones. Note that the stack it builds -
        // copper, insulation and ducts - need NOT come out at exactly r2: the build is the copper and the ducts plus a percentage
        // overbuild allowance, which does not have to match the insulation the designer actually specified. It is 0.9 mm short on the
        // SheetAndLayer fixture. Only the radii are affected and only in the last decimal - C goes as r, so 0.9 mm on a 260 mm radius
        // is 0.3% on the outermost gap - and putting the real dimensions in the real order beats stretching them to fit a number that
        // carries an allowance.
        for gap in 0..<gapCount {

            let duct = ductGaps.contains(gap) ? ductDimension : 0.0
            let thickness = tau + duct

            // The gap is a cylindrical capacitor at its own radius, through whatever is in it. Written as a reduced thickness
            // Σ(ℓ/ε) so that a gap holding a duct and one holding only paper come out of the same expression:
            //
            //     C = ε0 · 2π·r · (h + 2·t) · [ fs/(τ/εPaper + d/εBoard) + (1 − fs)/(τ/εPaper + d/εOil) ]
            //
            // With d = 0 and fs = 0 that is exactly ε0·εPaper·2π·r·(h + 2τ)/τ - DelVecchio 12.47's form, which is what this
            // routine and the .sheet branch of CapacitanceTurnToTurn have always used - so a coil with no ducts is unchanged to
            // the last bit. The (h + 2t) fringing term is small here either way, h being the full electrical height.
            let centre = radius + thickness / 2.0
            let fs = stickWidth > 0.0 ? stickWidth / (2 * π * centre) : 0.0

            let solid = tau / εPaper
            let stickColumn = fs / (solid + duct / εBoard)
            let oilColumn = (1 - fs) / (solid + duct / εOil)

            result.append((radius: centre,
                           capacitance: ε0 * 2.0 * π * centre * (h + 2.0 * thickness) * (stickColumn + oilColumn),
                           insulation: tau,
                           duct: duct))

            radius += thickness + t
        }

        return result
    }

    /// The gaps of a SHEET winding as a client's EQUAL-SPACING convention describes them, innermost gap first - a comparison figure,
    /// not the model.
    ///
    /// The convention: take the radial build from ID to OD, subtract the copper, and divide what is left equally over the N − 1
    /// gaps, so every turn is separated from the next by the same dimension
    ///
    ///     s = ((r2 − r1) − N·t) / (N − 1)
    ///
    /// whether that gap really holds a 0.25 mm wrap of paper or a 6 mm oil duct. It is exactly the smearing that
    /// `SheetGapCapacitances` was rewritten to stop doing (docs/dielectric-stress.md, "Cooling ducts are placed, not smeared"), and
    /// it is here only because some clients specify their turn-to-turn voltages this way. It must never feed Cs, the simulation or
    /// the stress report; `AppController.BuildRadialProfile` draws it beside the placed-duct profile and nowhere else.
    ///
    /// Gap k is centred at r1 + (k + 1)·t + (k + ½)·s, and is formed with the same expression SheetGapCapacitances uses for a gap
    /// with no duct, at thickness s:
    ///
    ///     C_k = ε0·εPaper·2π·r_k·(h + 2s)/s
    ///
    /// Every gap then has the same thickness and the same material, so in the series chain the permittivity and the (h + 2s) term
    /// cancel and ΔV_k ∝ 1/r_k: an even division V/(N − 1) with the same gentle 1/r slope a duct-free sheet coil has. The radius is
    /// kept rather than dropped because it costs nothing and makes the two curves differ ONLY in how the ducts are treated. εPaper is
    /// immaterial to the voltages and is used only so that the capacitances come out at plausible magnitudes.
    ///
    /// The build is the Segment's LIVE radii (standing rule 7) - "use the OD and ID" is what the convention says.
    ///
    /// - Returns: each gap's centre radius, its capacitance and the common spacing s, all in SI units.
    func SheetGapCapacitancesEqualSpacing() throws -> [(radius:Double, capacitance:Double, spacing:Double)] {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        guard self.wdgType == .sheet, let bs = self.basicSections.first else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        let turns = Int(bs.N.rounded())

        guard turns >= 2 else {

            return []
        }

        let gapCount = turns - 1
        let t = bs.wdgData.turn.radialDimn
        let spacing = ((self.r2 - self.r1) - Double(turns) * t) / Double(gapCount)

        guard spacing > 0.0 else {

            throw SegmentError(info: "The sheet winding's turns fill its whole radial build, so there is no spacing to divide equally", type: .IllegalWindingType)
        }

        let h = bs.height

        return (0..<gapCount).map { k in

            let centre = self.r1 + Double(k + 1) * t + (Double(k) + 0.5) * spacing

            return (radius: centre,
                    capacitance: ε0 * εPaper * 2.0 * π * centre * (h + 2.0 * spacing) / spacing,
                    spacing: spacing)
        }
    }

    /// How the turns of a LAYER winding are shared out over its layers, innermost layer first.
    ///
    /// EVERY LAYER HOLDS THE SAME NUMBER OF TURNS, N/L, AND THAT NUMBER IS NOT IN GENERAL A WHOLE ONE. 938 turns over 12 layers is
    /// twelve layers of 78.1666… turns, not eleven of 79 and a last one of 69. The winding is wound to one axial pitch over one
    /// height, so what a layer holds is set by the height and is the same for every layer; the conductor crosses into the next layer
    /// wherever the count runs out, part way through a turn if that is where it falls. The fractional part is physically real - it is
    /// the axial offset by which each layer's turns sit above the previous layer's - and rounding it into a short final layer is both
    /// wrong about the geometry and wrong about the last layer's voltage.
    ///
    /// Which whole turn ends up in which layer is then the caller's business: `TurnLadderModel.SolveLayer` assigns each turn to the
    /// layer holding its midpoint, so a layer carries floor(N/L) or ceil(N/L) whole turns and the pattern steps up the winding.
    ///
    /// The layer COUNT is a reading - `PCH_ExcelDesignFile.Winding.numRadialSections` - and the split is still an assumption in the
    /// one respect that the file cannot confirm it: a deliberately graded winding, where the layer turn counts are chosen rather than
    /// falling out of the height, will not match. Carrying the real counts needs a per-layer field in
    /// `BasicSectionWindingData.LayerData` and somewhere to fill it from.
    func LayerTurnCounts() throws -> [Double] {

        guard self.wdgType == .layer, let bs = self.basicSections.first else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        let layers = bs.wdgData.layers.numLayers
        let turns = Int(bs.N.rounded())

        guard layers >= 1, turns >= layers else {

            throw SegmentError(info: "The layer winding has \(turns) turns over \(layers) layers, which is fewer than one turn per layer", type: .IllegalWindingType)
        }

        // The rounded whole-turn total is divided, not N itself, so that the counts sum to exactly the number of turn nodes the
        // network will have.
        return [Double](repeating: Double(turns) / Double(layers), count: layers)
    }

    /// The layer-to-layer capacitance of every radial gap of a LAYER winding, innermost gap first, each formed at its own radius.
    ///
    /// This is `LayerToLayerCapacitance` gap by gap: the same DelVecchio 12.60 composite, with each gap's own radius in place of the
    /// one Rmean that routine uses for all of them. Gap k sits between layer k and layer k + 1 at r1 + (k + 1)·(build/L).
    ///
    /// The ducts are PLACED rather than smeared - see `DuctGaps` for the spacing rule. The design file gives a count and a size and
    /// no positions, so where they go is a rule rather than a reading, but spacing them evenly is much closer to a real winding than
    /// spreading a fraction of a duct into every gap: a gap holding a duct has a far lower Cll than one holding only solid
    /// insulation, and the smeared form reports neither value anywhere. `LayerToLayerCapacitance`, which feeds the series
    /// capacitance, still smears them - see TODO.md.
    func LayerGapCapacitances() throws -> [(radius:Double, capacitance:Double, insulation:Double, duct:Double)] {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        guard self.wdgType == .layer, let bs = self.basicSections.first else {

            throw SegmentError(info: "", type: .IllegalWindingType)
        }

        let layers = bs.wdgData.layers.numLayers

        guard layers > 1 else {

            return []
        }

        let gapCount = layers - 1

        let H = bs.height
        let tIns = bs.wdgData.layers.interLayerInsulation

        let ductCount = Segment.DuctCount(gapCount: gapCount, requested: bs.wdgData.layers.ducts.numDucts)
        let ductDimension = ductCount > 0 ? bs.wdgData.layers.ducts.ductDimn : 0.0
        let ductGaps = Segment.DuctGaps(gapCount: gapCount, ductCount: ductCount)

        let solid = tIns / εPaper

        guard solid + ductDimension > 0.0 else {

            throw SegmentError(info: "Layer winding has no insulation between layers", type: .IllegalWindingType)
        }

        let pitch = (self.r2 - self.r1) / Double(layers)

        var result:[(radius:Double, capacitance:Double, insulation:Double, duct:Double)] = []

        for gap in 0..<gapCount {

            let radius = self.r1 + Double(gap + 1) * pitch
            let tDuct = ductGaps.contains(gap) ? ductDimension : 0.0

            // The stick fraction is a fraction of THIS gap's circumference, so it has to be re-formed at each radius rather than
            // carried over from the mean one - the same substitution LayerToLayerCapacitance makes, evaluated in the right place.
            let fs = Double(bs.wdgData.discData.numAxialColumns) * bs.wdgData.discData.axialColumnWidth / (2 * π * radius)

            let firstTerm = fs / (solid + (tDuct / εBoard))
            let secondTerm = (1 - fs) / (solid + (tDuct / εOil))

            result.append((radius: radius, capacitance: ε0 * 2 * π * radius * H * (firstTerm + secondTerm), insulation: tIns, duct: tDuct))
        }

        return result
    }

    /// Return the Cdd values per DelVecchio equation 12.52 (3rd edition) for the gap above an below the given BasicSection.
    ///
    /// Units: metres and Farads throughout. Cdd = ε0·π·(Rout² − Rin²)·[ fks/Σ(ℓ/ε)_ks + (1 − fks)/Σ(ℓ/ε)_oil ], where Σ(ℓ/ε) is the
    /// series thickness/permittivity sum of every layer lying between the two conductors (DelVecchio 12.51 generalized past two layers).
    ///
    /// - Parameter staticRing: Which side (if either) of the BasicSection faces a static ring rather than another disc. Per DelVecchio
    /// 12.6 the disc-to-static-ring capacitance Ca plays the role of Cdd on that side, but the insulation in that gap is not the same:
    /// see the note on the solid-insulation term below.
    /// - Parameter innerRadius: The disc's inner radius. This is passed in rather than read from the BasicSection because a
    /// BasicSection holds the PRISTINE radii from the design file, while the live geometry (which is what this has to measure) is
    /// carried by the owning Segment's rect - see Segment.SetRadialGeometry. The two differ whenever a coil has been built up to
    /// carry wound-in shields.
    /// - Parameter outerRadius: The disc's outer radius, live rather than pristine, as above.
    static func DiscToDiscSeriesCapacitance(belowGap:Double, aboveGap:Double, basicSection:BasicSection, innerRadius:Double, outerRadius:Double, staticRing:(above:Bool, below:Bool) = (false, false)) -> (below:Double, above:Double) {

        let fks = Double(basicSection.wdgData.discData.numAxialColumns) * basicSection.wdgData.discData.axialColumnWidth / (π * (innerRadius + outerRadius))

        var Cdd_below = ε0 * π * (outerRadius * outerRadius - innerRadius * innerRadius)
        var Cdd_above = Cdd_below
        // calculate Cdd for the gap below the segment
        if belowGap > 0.0 {

            let stacks = Segment.DiscToDiscLayerStack(basicSection: basicSection, gap: belowGap, facesStaticRing: staticRing.below)
            let firstTerm = fks / DielectricStress.ReducedThickness(stacks.keySpacer)
            let secondTerm = (1 - fks) / DielectricStress.ReducedThickness(stacks.oil)
            Cdd_below *= (firstTerm + secondTerm)
        }
        else {

            Cdd_below = 0.0
        }

        // calculate Cdd for the gap above the segment
        if aboveGap > 0.0 {

            let stacks = Segment.DiscToDiscLayerStack(basicSection: basicSection, gap: aboveGap, facesStaticRing: staticRing.above)
            let firstTerm = fks / DielectricStress.ReducedThickness(stacks.keySpacer)
            let secondTerm = (1 - fks) / DielectricStress.ReducedThickness(stacks.oil)
            Cdd_above *= (firstTerm + secondTerm)
        }
        else {

            Cdd_above = 0.0
        }

        return (Cdd_below, Cdd_above)
    }

    /// The dielectric layers lying in a disc-to-disc gap, in physical order outwards from the copper of the disc that owns the gap,
    /// for the key-spacer column and for the oil column.
    ///
    /// This exists so that DiscToDiscSeriesCapacitance and the stress screen in DielectricStress.swift can never disagree about what
    /// is actually in a gap. The capacitance needs only the reduced thickness Σ(ℓ/ε) of each column, which is what
    /// DielectricStress.ReducedThickness makes of this; the stress needs the individual layers, in order, because it has to report
    /// the field in each one and because the corner model accumulates radii outwards from the copper.
    ///
    /// 'turnInsulation' is the TOTAL (two-sided) insulation on a turn, so a turn presents HALF of it to the gap on each of its two
    /// faces. A disc-to-disc gap therefore holds two of those halves - one from each disc - which sums to the full tp, and that is
    /// exactly why DelVecchio 12.52 uses tp for that case and not 2·tp. Do not add a factor of 2 anywhere here. The layers are
    /// emitted as the two separate halves rather than as one combined tp so that the physical order is right for the corner model;
    /// the two forms give an identical Σ(ℓ/ε), so the capacitance is unchanged.
    ///
    /// The gap passed in is measured between the *insulated* surfaces (a disc's z1/z2 are over-paper, and a static ring's rect is its
    /// overall wrapped thickness), so it is pure key spacer or oil and every solid layer has to be added in separately. Against
    /// another disc the far solid is that disc's half-wrap; against a static ring it is the ring's own T1 of Kraft, which at
    /// 3.18 mm per side is substantial and dominates the term. The ring's pressboard CORE is not in the stack because the foil
    /// under that Kraft is the electrode - see the static ring constants above.
    static func DiscToDiscLayerStack(basicSection:BasicSection, gap:Double, facesStaticRing:Bool) -> (keySpacer:[DielectricLayer], oil:[DielectricLayer]) {

        let tp = basicSection.wdgData.turn.turnInsulation

        // this disc's own half-wrap, which is where the stack starts
        let nearSolid = DielectricLayer.Paper(tp / 2.0)

        // whatever solid insulation is on the far face of the gap
        let farSolid = facesStaticRing ? DielectricLayer.Paper(Segment.staticRingInsulationPerSide) : DielectricLayer.Paper(tp / 2.0)

        return (keySpacer: [nearSolid, DielectricLayer.Pressboard(gap), farSolid],
                oil: [nearSolid, DielectricLayer.Oil(gap), farSolid])
    }

    /// Stein's parameters for one disc: the dimensionless α that DelVecchio's series-capacitance formulas are written in, and the
    /// shunt-division weights Ya/Yb that go with it.
    ///
    /// α = √(C_shunt/Cs) is the same quantity that governs the voltage distribution WITHIN the disc, which is why this is pulled out
    /// as a type of its own rather than left as three sets of local variables: the capacitance path wants `capacitance`, and the
    /// stress screen in DielectricStress.swift wants `gradientEnhancement` from the very same numbers. Two routines deriving α
    /// independently could drift, and the disagreement would be invisible.
    struct SteinParameters:Sendable {

        /// DelVecchio's α = √(C_shunt/Cs).
        let alpha:Double
        /// The fraction of the disc's shunt capacitance facing the first side.
        let Ya:Double
        /// The fraction facing the other side. Ya + Yb = 1.
        let Yb:Double
        /// The disc's own turn-to-turn series capacitance.
        let Cs:Double
        /// The disc-to-disc capacitances below and above, as handed to the formula.
        let CddBelow:Double
        let CddAbove:Double

        /// The disc's series capacitance, DelVecchio 12.53:
        ///
        ///     C = Cs·[ (Ya² + Yb²)·α/tanh α + 2·Ya·Yb·α/sinh α + Ya·Yb·α² ]
        ///
        /// The end-disc form 12.63, C = Cs·α/tanh α, is exactly this at Ya = 1, Yb = 0 - the second and third terms both carry a
        /// factor Yb and vanish. That identity is what let the three branches in SeriesCapacitance collapse into one, and it is worth
        /// re-checking if this is ever edited.
        var capacitance:Double {

            let firstTerm = (Ya * Ya + Yb * Yb) * alpha / tanh(alpha)
            let secondTerm = 2 * Ya * Yb * alpha / sinh(alpha)
            let thirdTerm = Ya * Yb * alpha * alpha

            return Cs * (firstTerm + secondTerm + thirdTerm)
        }

        /// The ratio of the PEAK turn-to-turn gradient inside the disc to the linear (mean) one.
        ///
        /// Derivation. At the capacitive limit the turn-level ladder inside one disc obeys
        ///
        ///     Cs·d²V/dx² = C_shunt·(V − V_env(x))
        ///
        /// where x is the normalized radial position across the disc and V_env is the potential of what the disc faces, weighted by
        /// Ya/Yb. Writing u = V − V_env gives u'' = α²u, whose solution with end mismatches u₀ and u₁ is
        ///
        ///     u(x) = [u₀·sinh(α(1−x)) + u₁·sinh(αx)] / sinh(α)
        ///     u'(x) = α·[u₁·cosh(αx) − u₀·cosh(α(1−x))] / sinh(α)
        ///
        /// Two limits follow immediately, and they are the ones that matter:
        ///
        ///  - If the disc's neighbours ramp in step with it (an interior disc with equal gaps above and below, Ya = Yb), then
        ///    u₀ = u₁ = 0 and the distribution is exactly LINEAR - no enhancement at all. This is the case people get wrong by
        ///    applying α/tanh α everywhere.
        ///  - If the disc faces something at a fixed or oppositely-ramping potential on one side only (an end disc, or one beside a
        ///    static ring: Ya = 1, Yb = 0), the mismatch is maximal and the peak gradient is V·α/tanh α - the same α/tanh α that
        ///    multiplies Cs in 12.63, which is not a coincidence, since the capacitance is the charge at the driven end divided by V
        ///    and that charge is proportional to the gradient there.
        ///
        /// What is returned INTERPOLATES between those two exact endpoints on the asymmetry |Ya − Yb|:
        ///
        ///     enhancement = 1 + (α/tanh α − 1)·|Ya − Yb|
        ///
        /// This is NOT a solution of the general boundary-value problem - it is exact at Ya = Yb and at (Ya, Yb) = (1, 0) and
        /// monotone between, which is what a screening pass needs. It is deliberate that the accurate answer for the first discs
        /// comes from the turn-level ladder instead (DielectricStress.TurnLadderModel); this factor's job is to say WHICH discs are
        /// worth running the ladder on. Solving the general BVP for the exact intermediate case is noted in TODO.md.
        var gradientEnhancement:Double {

            guard alpha > 0.0, alpha.isFinite else {

                return 1.0
            }

            let oneSided = alpha / tanh(alpha)

            return 1.0 + (oneSided - 1.0) * abs(Ya - Yb)
        }

        /// Build the Stein parameters for a disc from its series and disc-to-disc capacitances.
        ///
        /// The order of the tests matters and is the order the original inline code used: a disc that is BOTH an end disc and beside
        /// a static ring took the static-ring branch, so the static-ring test is made first here. Reordering them would silently
        /// change the end discs of any coil that has a static ring.
        ///
        /// The `!= (false, false)` guards are not redundant. When a Segment holds several discs, SeriesCapacitance's recursion hands
        /// each end disc a NON-nil tuple with the far side cleared - (false, adjStaticRing!.below) for the bottom disc,
        /// (adjStaticRing!.above, false) for the top - so a disc at the opposite end of the Segment from the ring arrives with both
        /// flags false. Without the test it took the DelVecchio 12.6 path anyway and got α = √((Cdd_above + 2·Cdd_below)/Cs) instead
        /// of the symmetric 12.54 α = √(2(Cdd_above + Cdd_below)/Cs), i.e. √(3/4) of the correct value for equal gaps. That was a
        /// real bug; keep the guards.
        static func For(Cs:Double, Cdd:(below:Double, above:Double), endDisc:(lowest:Bool, highest:Bool)?, adjStaticRing:(above:Bool, below:Bool)?) -> SteinParameters {

            if let staticRing = adjStaticRing, staticRing != (false, false) {

                // DelVecchio 12.6: the static ring plays the part of one neighbour, with its own Ca.
                let useCdd = staticRing.below ? Cdd.above : Cdd.below
                let Ca = staticRing.below ? Cdd.below : Cdd.above

                let Csum = Ca + 2 * useCdd

                return SteinParameters(alpha: sqrt(Csum / Cs), Ya: Ca / Csum, Yb: 2 * useCdd / Csum, Cs: Cs, CddBelow: Cdd.below, CddAbove: Cdd.above)
            }
            else if let endDiscLoc = endDisc, endDiscLoc != (false, false) {

                // DelVecchio 12.63. Ya = 1, Yb = 0 reproduces the old `Cs * alpha / tanh(alpha)` exactly through the general formula.
                let useCdd = endDiscLoc.lowest ? Cdd.above : Cdd.below

                return SteinParameters(alpha: sqrt(2 * useCdd / Cs), Ya: 1.0, Yb: 0.0, Cs: Cs, CddBelow: Cdd.below, CddAbove: Cdd.above)
            }

            // DelVecchio 12.53/12.54, the symmetric interior case.
            let sumCdd = Cdd.above + Cdd.below

            return SteinParameters(alpha: sqrt(2 * sumCdd / Cs), Ya: Cdd.below / sumCdd, Yb: Cdd.above / sumCdd, Cs: Cs, CddBelow: Cdd.below, CddAbove: Cdd.above)
        }
    }
    
    /// The series capacitance of a single BasicSection, as caused by the turns of the disc (for continuous-disc windings), double-disc (for interleaved segments) or a single layer (for layer windings). For interleaved windings, note that the value returned is the "effective" capacitance of a single disc, which is double the capacitance of the double-disc. It is up to the calling routine to treat the capacitance correctly. The methods come from (respectively) DelVecchio, Veverka, Huber (ie: me)
    func BasicSectionSeriesCapacitance() throws -> Double {
        
        guard !self.isStaticRing else {
            
            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }
        
        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        // A wound-in-shield disc pair does not fit the "Ctt times a function of N" shape below - DelVecchio 12.96 has a separate
        // shield term with its own capacitance c_w - so it gets its own routine.
        guard self.woundInShield == nil else {

            throw SegmentError(info: "use WoundInShieldSeriesCapacitance() for a shielded segment", type: .IllegalWoundInShield)
        }

        if self.wdgType == .helical {

            return 0.0
        }

        // A multi-start winding is one lumped section whose whole series capacitance is DelVecchio 12.12 - see the routine.
        if self.wdgType == .multistart {

            return try self.MultiStartSeriesCapacitance()
        }

        // A SHEET WINDING IS A SERIES CHAIN AND ITS SERIES CAPACITANCE IS EXACT, so it does not go through the "Ctt times a function
        // of N" shape below at all.
        //
        // Every turn is a full-height cylinder and screens the next completely (the argument is in docs/dielectric-stress.md), so no
        // interior turn has a capacitance to anything but its two radial neighbours and the coil is literally N − 1 capacitors in
        // series between its two terminals:
        //
        //     Cs = 1 / Σ(1/C_k)
        //
        // with C_k from SheetGapCapacitances. Nothing is assumed or averaged: the cooling ducts are carried at the gaps they are
        // actually in, and the 1/r growth of C across the build is carried gap by gap.
        //
        // WHAT THIS REPLACES, and why the obvious repair was the wrong one. This used to return DelVecchio's disc formula
        // Cs = Ctt·(N − 1)/N², with Ctt from the .sheet branch of CapacitanceTurnToTurn - which took τ = (width − N·t)/(N − 1), the
        // whole leftover build, INCLUDING the ducts. On the SheetAndLayer fixture that is 1.77 mm of notional paper in a gap holding
        // 0.254 mm. Substituting the real insulation into that formula would have been much worse than leaving it alone: the ducts
        // would then be gone entirely and Cs would come out about 9x the exact chain, where the smear was 1.33x it. The smear was
        // wrong twice in opposite directions and mostly cancelling. The chain needs no representative τ at all.
        //
        // The disc formula was never derived for this winding: it is an energy argument for N turns lying in a plane, each pair at
        // V/N, which is the right shape for a disc and merely an approximation of a series chain (Ctt(N − 1)/N² against Ctt/(N − 1),
        // 17% apart at N = 13 even with a correct τ).
        if self.wdgType == .sheet {

            let gaps = try self.SheetGapCapacitances()

            guard !gaps.isEmpty, gaps.allSatisfy({ $0.capacitance > 0.0 }) else {

                // One turn, so there is no gap and no series path through the turns. Zero is the honest answer and the callers all
                // test for it; the old expression divided by N − 1 and returned an infinity.
                return 0.0
            }

            return 1.0 / gaps.reduce(0.0) { $0 + 1.0 / $1.capacitance }
        }

        do {

            let Ctt = try self.CapacitanceTurnToTurn()
            let N = self.basicSections[0].N

            if self.wdgType == .disc && self.interleaved {

                // Kulkarni & Khaparde 7.39, the EXACT interleaved disc-pair series capacitance:
                //
                //     Cse = (Ct/4)·[ N + ((N−1)/N)²·(N−2) ]
                //
                // His 7.40, Cse = (Ct/2)(N−1), is the N ≫ 1 limit of this and is identical to Veverka 6.4, which is what this
                // used to return. The two part company exactly where it matters: 7.40 is 4.9% high at N = 19.7 and 8.6% high at
                // N = 10.75, and a CTC winding - the case that most wants a high series capacitance - has few turns per disc.
                //
                // Where the two terms come from (his derivation, above 7.39): a disc pair has 2(N−1) interturn capacitances. In a
                // fully interleaved pair, N of them span the full half-voltage V/2, because the turns either side are N electrical
                // turns apart; the remaining (N−2) span only ((N−1)/N)·(V/2), being one turn short of that. Summing ½·Ct·(ΔV)²
                // over both groups and writing the total as ½·Cse·V² gives 7.39. 7.40 drops the distinction.
                //
                // As the doc comment says, what is returned here is DOUBLE the pair's capacitance; SeriesCapacitance halves it.
                let ratio = (N - 1.0) / N
                let Cs = (Ctt / 2.0) * (N + ratio * ratio * (N - 2.0))

                return Cs
            }
            else if self.wdgType == .disc {

                // Del Vecchio method. A sheet winding used to share this branch and no longer does - see the note above.
                let Cs = Ctt * (N - 1) / (N * N)

                return Cs
            }
            else if self.wdgType == .layer {
                
                // Huber method. Basically, this uses the Del Vecchio method for discs, but turns it on its side, so that the series capacitance goes in the axial direction and the disc-disc capacitance becomes the layer-layer capacitance. 
                let turnsPerLayer = N / Double(self.basicSections[0].wdgData.layers.numLayers)
                let Cs = Ctt * (turnsPerLayer - 1) / (turnsPerLayer * turnsPerLayer)
                
                return Cs
            }
        }
        catch {
            
            throw error
        }
        
        throw SegmentError(info: "", type: .UnimplementedWdgType)
    }

    // MARK: Multi-start windings (DelVecchio 12.12)

    /// The series capacitance of a whole multi-start winding, DelVecchio 12.12, with the one refinement his text invites.
    ///
    /// THE WINDING. N_s helical windings ("starts") of n turns each, wound together as one helix and connected in series outside it,
    /// start 1's end to start 2's beginning and so on (Figure 12.21). Each revolution of the helix is a GROUP of N_s conductors lying
    /// axially side by side, one from each start, and the starts are meshed within a group in the order of Figure 12.22 -
    /// `MultiStartGroupOrder` - so that no two neighbours are more than two start-voltages apart. The program models the whole winding
    /// as ONE lumped BasicSection (docs/decisions.md §2c), so this is the series capacitance between its two terminals.
    ///
    /// THE ENERGY (12.110). With ΔV_s = V/N_s the voltage along one start and ½·c·ΔV² the energy of an adjacent pair, Figure 12.22's
    /// pattern gives, over the n groups:
    ///
    ///     (2n − 1) pairs at ΔV_s       and       n(N_s − 2) pairs at 2ΔV_s
    ///
    /// and with a single c_t for every pair, E = ½·c_t·ΔV_s²·(4nN_s − 6n − 1), so writing E = ½·C·V²
    ///
    ///     C_ms = c_t·(4nN_s − 6n − 1)/N_s²                                                    (12.111)
    ///
    /// THE REFINEMENT. DelVecchio notes that "c_t will depend on the insulation structure of the winding, that is, whether the turns are
    /// touching, paper to paper ... or whether there is an oil gap with key spacers separating them". In a multi-start helix it is BOTH,
    /// and which applies is fixed by where the pair sits. Of the (2n − 1) pairs at ΔV_s, n lie INSIDE a group (the two middle starts of
    /// the order, e.g. 3|4 in 1,3,4,2) and n − 1 lie BETWEEN groups (the last start of one revolution against the first of the next, 2|1);
    /// all n(N_s − 2) pairs at 2ΔV_s lie inside a group. So with c_g for a pair inside a group and c_k for a pair across the key spacers:
    ///
    ///     E = ½·ΔV_s²·[ c_g·n·(1 + 4(N_s − 2)) + c_k·(n − 1) ] = ½·ΔV_s²·[ c_g·n·(4N_s − 7) + c_k·(n − 1) ]
    ///
    /// which is exactly 12.110 when c_g = c_k: n(4N_s − 7) + (n − 1) = 4nN_s − 6n − 1.
    ///
    /// ONE ROUNDING OF DELVECCHIO'S IS UNDONE. A pair between groups - start 2, turn j against start 1, turn j + 1 - is n − 1 turns
    /// apart, not n: its true voltage is (1 − 1/n)·ΔV_s, and the book counts it as ΔV_s. Every pair inside a group IS exactly ΔV_s or
    /// 2ΔV_s (same turn index, one or two starts apart). With the true voltage the between-group energy is c_k·(n − 1)·(1 − 1/n)², so
    ///
    ///     C_ms = [ c_g·n·(4N_s − 7) + c_k·(n − 1)³/n² ] / N_s²
    ///
    /// This is the same choice this file makes for interleaved discs, where Kulkarni & Khaparde's exact 7.39 is used rather than its
    /// N ≫ 1 limit 7.40, and for the same reason: the rounding is worst exactly where few turns make it matter. With a single c_t,
    /// 12.111 overstates C_ms by 33% at N_s = 2, n = 2 and 8.3% at N_s = 2, n = 12; by 4.1% to 1.5% at N_s = 4 (n = 2 to 12); and by 1.5%
    /// to 0.6% at N_s = 8 - the between-group pairs carry the largest share of the energy when there are few starts and few turns.
    /// Setting (1 − 1/n)² to 1 and c_g = c_k gives back 12.111 exactly.
    ///
    /// `VerifyMultiStartCapacitance` walks the conductors one by one at their true potentials and checks the pair counts, this
    /// closed form, and the reduction to 12.111.
    ///
    /// - Parameter turnsPerStart: n. Must be at least 1.
    /// - Parameter numStarts: N_s. Must be at least 2 - a single start is an ordinary helical winding, and 12.111 goes negative there.
    /// - Parameter cWithinGroup: c_g, farads, between two touching conductors of one revolution.
    /// - Parameter cBetweenGroups: c_k, farads, between one revolution and the next across the key spacers.
    /// - Returns: C_ms, farads.
    static func MultiStartCapacitance(numStarts:Int, turnsPerStart:Int, cWithinGroup:Double, cBetweenGroups:Double) -> Double {

        let Ns = Double(numStarts)
        let n = Double(turnsPerStart)

        // (n − 1)·(1 − 1/n)² = (n − 1)³/n²: n − 1 between-group pairs, each at (1 − 1/n)·ΔV_s. Zero for a single turn per start.
        let betweenGroupPairs = (n - 1.0) * (n - 1.0) * (n - 1.0) / (n * n)

        return (cWithinGroup * n * (4.0 * Ns - 7.0) + cBetweenGroups * betweenGroupPairs) / (Ns * Ns)
    }

    /// The order in which the N_s starts lie within one revolution of a multi-start helix, bottom to top - DelVecchio Figure 12.22.
    ///
    /// His rule ("start with turn 1 from start coil 1. Put turn 1 from start coil 2 at the end of the group. Put turn 1 from start coil 3
    /// below turn 1 ...") comes out as the odd starts ascending followed by the even starts descending: 1,3,4,2 for N_s = 4, 1,3,5,4,2
    /// for 5, 1,3,5,6,4,2 for 6. That puts every pair of neighbours two starts apart except the two in the middle, and puts start 2 at the
    /// top of the group, one start below start 1 at the bottom of the next.
    static func MultiStartGroupOrder(numStarts:Int) -> [Int] {

        guard numStarts >= 1 else {

            return []
        }

        let odds = Array(stride(from: 1, through: numStarts, by: 2))
        let evens = Array(stride(from: 2, through: numStarts, by: 2)).reversed()

        return odds + evens
    }

    /// The series capacitance of this Segment's multi-start winding: `MultiStartCapacitance` with c_g and c_k formed from the geometry.
    ///
    /// c_g, TWO CONDUCTORS OF ONE REVOLUTION, touching paper to paper. This is DelVecchio's turn-to-turn capacitance 12.47,
    /// ε0·εp·π(r1 + r2)·(h + 2τ)/τ, turned on its side the way the layer branch of CapacitanceTurnToTurn does: in a helix the
    /// neighbouring conductor is ABOVE, so the face is the conductor's bare radial dimension w rather than its bare height. τ is the
    /// two-sided paper of a turn plus any extra insulation the design puts between the axial cables of a turn.
    ///
    /// c_k, ONE REVOLUTION AGAINST THE NEXT, across the key spacers. This is exactly the gap the helical branch of SeriesCapacitance
    /// already treats between the turns of an ordinary helix, and it is treated the same way: DelVecchio's disc-to-disc 12.52 over the
    /// winding's annulus, key-spacer fraction and all, which with a zero spacer collapses to plain paper to paper.
    ///
    /// THE TURN COUNT IS THE WHOLE WINDING'S. BasicSection.N is the design file's turns, and for a multi-start winding that file counts
    /// one CONDUCTOR of one start as a turn - its turn definition divides the axial dimension of the N_s cables of a revolution by N_s
    /// (TurnDefinition.axialDimension). So N is every turn in series, all starts included, and n = N/N_s. A count that does not divide
    /// by N_s is refused rather than rounded: it is the sign that a design counts its turns the other way, and n would be wrong by N_s.
    func MultiStartSeriesCapacitance() throws -> Double {

        let bs = self.basicSections[0]

        guard let multiStart = bs.wdgData.multiStart else {

            throw SegmentError(info: "the section carries no multi-start data (number of starts, spacer gap)", type: .IllegalMultiStart)
        }

        // DelVecchio's winding is a single helix. A multi-start winding of several radial layers would also have layer-to-layer energy
        // between starts at unrelated potentials, which 12.12 does not describe; say so rather than return half an answer.
        guard bs.wdgData.layers.numLayers <= 1 else {

            throw SegmentError(info: "\(bs.wdgData.layers.numLayers) radial layers; 12.12 describes a single helix", type: .IllegalMultiStart)
        }

        let Ns = multiStart.numStarts

        guard Ns >= 2 else {

            throw SegmentError(info: "\(Ns) start(s); a multi-start winding needs at least 2", type: .IllegalMultiStart)
        }

        let nExact = bs.N / Double(Ns)
        let n = nExact.rounded()

        guard n >= 1.0, abs(nExact - n) < 1.0E-6 else {

            throw SegmentError(info: "\(bs.N) turns do not divide among \(Ns) starts. The design file's turns should be every turn in series, all starts included", type: .IllegalMultiStart)
        }

        // Two-sided paper, as everywhere else in this file (docs/capacitance.md: the τ_p convention). w is the conductor's bare radial
        // dimension: the turn's over-paper radial dimension less its two-sided paper, the transposed twin of the disc branch's
        // 'height - tp'.
        let tp = bs.wdgData.turn.turnInsulation
        let tau = tp + multiStart.insulationBetweenStarts
        let w = bs.wdgData.turn.radialDimn - tp

        guard tau > 0.0, w > 0.0 else {

            throw SegmentError(info: "the turn has no paper (\(tau) m) or no bare radial copper (\(w) m)", type: .IllegalMultiStart)
        }

        let cWithinGroup = ε0 * εPaper * π * (self.r1 + self.r2) * (w + 2.0 * tau) / tau

        // DiscToDiscSeriesCapacitance reads a zero gap as "no neighbour" and returns 0, which is right for a disc at a coil end and
        // wrong here: revolutions wound with no spacer between them are touching, paper to paper, exactly like two conductors of one
        // revolution but without the extra insulation between starts. So that case is c_g's formula with τ = τ_p.
        let gap = multiStart.gapBetweenGroups
        let cBetweenGroups:Double

        if gap > 0.0 {

            cBetweenGroups = Segment.DiscToDiscSeriesCapacitance(belowGap: gap, aboveGap: gap, basicSection: bs, innerRadius: self.r1, outerRadius: self.r2).below
        }
        else {

            cBetweenGroups = ε0 * εPaper * π * (self.r1 + self.r2) * (w + 2.0 * tp) / tp
        }

        return Segment.MultiStartCapacitance(numStarts: Ns, turnsPerStart: Int(n), cWithinGroup: cWithinGroup, cBetweenGroups: cBetweenGroups)
    }

    /// Self-check for 12.12, run by hand because this program has no test target:
    ///
    ///     open -a ImpulseDistribution --args -PCH_Verify YES
    ///     defaults read com.huberistech.ImpulseDistribution MultiStartCapacitanceVerification
    ///
    /// It walks a multi-start helix conductor by conductor - every start's every turn, in the order of Figure 12.22, at its true
    /// potential - and checks three things: that the pair counts the derivation relies on are the ones the order actually produces;
    /// that the energy summed pair by pair equals `MultiStartCapacitance` to rounding error; and that the same walk with DelVecchio's
    /// rounding of the between-group pairs and a single c_t reproduces 12.111 exactly. It reports how much that rounding overstates.
    static func VerifyMultiStartCapacitance() -> [String] {

        var report:[String] = []
        var failures = 0

        // Arbitrary but unequal, so that a c_g/c_k mix-up cannot cancel; and a single c_t for the book's own form.
        let cg = 3.1E-10
        let ck = 1.7E-10
        let ct = 2.3E-10

        for Ns in 2...8 {

            for n in [1, 2, 5, 12] {

                // Conductor potentials in units of one turn's voltage: start s's turns run from (s − 1)·n + 1 to s·n.
                let order = MultiStartGroupOrder(numStarts: Ns)
                var conductors:[(potential:Double, group:Int)] = []

                for j in 1...n {

                    for s in order {

                        conductors.append((potential: Double((s - 1) * n + j), group: j))
                    }
                }

                let deltaVs = Double(n)
                var withinOnes = 0
                var withinTwos = 0
                var withinOther = 0
                var between = 0
                var exactEnergy = 0.0
                var bookEnergy = 0.0
                var bookEnergyExactVoltages = 0.0

                for i in 0..<(conductors.count - 1) {

                    let dV = abs(conductors[i + 1].potential - conductors[i].potential)

                    if conductors[i].group == conductors[i + 1].group {

                        if dV == deltaVs { withinOnes += 1 } else if dV == 2.0 * deltaVs { withinTwos += 1 } else { withinOther += 1 }

                        exactEnergy += 0.5 * cg * dV * dV
                        bookEnergy += 0.5 * ct * dV * dV
                    }
                    else {

                        between += 1
                        exactEnergy += 0.5 * ck * dV * dV
                        // DelVecchio counts every between-group pair as a full ΔV_s.
                        bookEnergy += 0.5 * ct * deltaVs * deltaVs
                    }

                    bookEnergyExactVoltages += 0.5 * ct * dV * dV
                }

                // V across the winding is N_s·n turns; C = 2E/V².
                let V = Double(Ns * n)
                let fromWalk = 2.0 * exactEnergy / (V * V)
                let closedForm = MultiStartCapacitance(numStarts: Ns, turnsPerStart: n, cWithinGroup: cg, cBetweenGroups: ck)

                let dv12_111 = ct * Double(4 * n * Ns - 6 * n - 1) / Double(Ns * Ns)
                let bookFromWalk = 2.0 * bookEnergy / (V * V)
                let exactSingleC = 2.0 * bookEnergyExactVoltages / (V * V)

                let countsOK = withinOnes == n && withinTwos == n * (Ns - 2) && withinOther == 0 && between == n - 1
                let energyOK = abs(fromWalk - closedForm) <= 1.0E-12 * closedForm
                let reduces = abs(bookFromWalk - dv12_111) <= 1.0E-12 * dv12_111
                let singleCOK = abs(MultiStartCapacitance(numStarts: Ns, turnsPerStart: n, cWithinGroup: ct, cBetweenGroups: ct) - exactSingleC) <= 1.0E-12 * exactSingleC

                let passed = countsOK && energyOK && reduces && singleCOK

                if !passed { failures += 1 }

                report.append(String(format: "%@ N_s = %d, n = %2d: pairs %d/%d/%d (within ΔVs / within 2ΔVs / between), walk vs closed form %.2e, 12.111 %@, 12.111 overstates by %+.3f%%", passed ? "PASS" : "FAIL", Ns, n, withinOnes, withinTwos, between, abs(fromWalk - closedForm) / closedForm, reduces ? "reproduced" : "NOT reproduced", 100.0 * (dv12_111 - exactSingleC) / exactSingleC))
            }
        }

        report.insert("Segment.VerifyMultiStartCapacitance: \(failures == 0 ? "all passed" : "\(failures) FAILED")", at: 0)

        return report
    }

    /// The series capacitance of one wound-in-shield DISC PAIR, per DelVecchio 12.96, but WITHOUT its disc-disc term. The caller
    /// (SeriesCapacitance) supplies the disc-disc energy, because it is the only thing that knows the gaps.
    ///
    /// A shield spans two discs and crosses over at the outermost turn, so the pair - not the disc - is the unit that 12.96
    /// describes. Writing the total capacitative energy of the pair (12.95) as ½·C·V², with V the voltage across the pair,
    /// N turns per disc, n shield turns per disc and ΔV = V/2N (12.84):
    ///
    ///     Cs_pair = n·c_w·[4β² + 1 − 1/N + 1/(2N²)]      shield-to-coil, over both discs
    ///             + c_t·(N − n − 1)/(2N²)                the turn pairs that have no shield between them
    ///
    /// The first bracket comes from summing the two energy terms of 12.90 and 12.91 over the n shield turns of each disc:
    ///
    ///     (½−β)² + (½+β)² + (½−β−δ)² + (½+β−δ)²  =  4β² + 1 − 2δ + 2δ²,   δ = ΔV/V = 1/2N
    ///
    /// The second is 12.92's 2(N − n − 1) turn-turn pairs, each holding ½·c_t·ΔV². It is NEGATIVE in n: every shield turn that goes
    /// in destroys one plain turn-to-turn interface. The effect is small (well under 1% of the shield term) but it is real, and it
    /// is what makes the formula degenerate correctly - see the note on n = 0 below.
    ///
    /// - Note: At n = 0 this returns c_t·(N−1)/(2N²), which is identically two plain discs' Ctt·(N−1)/N² in series. So an
    /// unshielded pair evaluated through here agrees exactly with the ordinary disc path, and a graded shielding scheme has no
    /// artificial capacitance step where its shields stop. (SeriesCapacitance still routes n = 0 through the ordinary path, because
    /// that path also has the correct Stein/end-disc/static-ring treatment.)
    ///
    /// VERIFICATION. Driven with DelVecchio's own test coil (12.11.3, p.357: N = 10, Rin 249 mm, cable 11.7 × 9.19 mm over 0.76 mm
    /// 2-sided paper, shield 3.55 mm over 0.51 mm 2-sided paper, 18 key spacers 44.5 × 4.19 mm, εp 1.5, εks 4.0, in air) and using
    /// the ISOLATED-pair disc-disc term (internal gap only, ie: + c_d/3), this reproduces every entry of his Table 12.1 - all of
    /// n = 3/5/7/9 across all three connections - high by a flat 4.6% to 6.0%. That residual is his own winding-looseness
    /// correction, which p.357 states "amounted to about a 5% correction": his test coil was a loose two-disc pair in air, and
    /// dividing these results by 1.055 lands on the published numbers to better than 1% everywhere. Do NOT build that factor in -
    /// it is a property of his experimental setup, not of a wound coil. The thing to check after touching this function is that
    /// the residual stays FLAT across n and across the three connections; a residual that varies is a real error.
    ///
    /// - Parameter turnsPerDisc: n, the number of shield turns in ONE disc of the pair. Must be in 0 ... N − 1.
    /// - Parameter wire: The shield wire, which supplies β through its connection type and c_w through its insulation.
    func WoundInShieldSeriesCapacitance(turnsPerDisc:Int, wire:WoundInShieldWire) throws -> Double {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        guard self.wdgType == .disc else {

            throw SegmentError(info: "only disc windings can carry wound-in shields", type: .IllegalWoundInShield)
        }

        guard self.basicSections.count == 2 else {

            throw SegmentError(info: "a wound-in shield spans exactly two discs", type: .IllegalWoundInShield)
        }

        let N = self.basicSections[0].N
        let n = Double(turnsPerDisc)

        // There are only N − 1 spaces between the turns of a disc, so that is the hard ceiling on n. It is also exactly where
        // 12.92's 2(N − n − 1) plain-turn-pair count runs out.
        guard n >= 0.0, n <= N - 1.0 else {

            throw SegmentError(info: "\(turnsPerDisc) shield turns/disc with only \(N) turns/disc", type: .IllegalWoundInShield)
        }

        do {

            let tp = self.basicSections[0].wdgData.turn.turnInsulation

            // c_t is the ordinary turn-turn capacitance; c_w is the same expression with the copper-to-copper gap ½(τp + τw) in
            // place of τp (DelVecchio p.352).
            let ct = try self.CapacitanceTurnToTurn()
            let cw = try self.CapacitanceTurnToTurn(effectiveInsulation: 0.5 * (tp + wire.insulation))

            let beta = wire.connection.beta(turnsPerDisc: turnsPerDisc, discTurns: N)

            let shieldTerm = n * cw * (4.0 * beta * beta + 1.0 - 1.0 / N + 1.0 / (2.0 * N * N))
            let turnTerm = ct * (N - n - 1.0) / (2.0 * N * N)

            return shieldTerm + turnTerm
        }
        catch {

            throw error
        }
    }

    /// The factor by which n wound-in-shield turns per disc multiply the series capacitance of a disc pair, compared with the same
    /// pair carrying no shields.
    ///
    /// This is a pure function of the turn geometry, with no Segment needed, which is what lets the "add shields" dialog show it
    /// live while the user steps n. The mean radius cancels: 12.98 is linear in π(r1 + r2) and both c_w and c_t use the same one,
    /// leaving only
    ///
    ///     c_w/c_t = (τp/τ̄)·((h + 2τ̄)/(h + 2τp)),    τ̄ = ½(τp + τw)
    ///
    /// Note that this compares the TURN-AND-SHIELD terms alone. The disc-disc energy is common to both cases and is deliberately
    /// left out, so the figure is an honest measure of what the shields themselves buy rather than one diluted by a term that was
    /// going to be there anyway.
    static func WoundInShieldCapacitanceRatio(turnsPerDisc:Int, discTurns:Double, connection:WoundInShieldWire.Connection, turnInsulation:Double, shieldInsulation:Double, bareCopperHeight:Double) -> Double {

        let N = discTurns
        let tp = turnInsulation
        let h = bareCopperHeight

        guard N > 1.0, tp > 0.0 else {

            return 1.0
        }

        let tauBar = 0.5 * (tp + shieldInsulation)
        let cwOverCt = (tp / tauBar) * ((h + 2.0 * tauBar) / (h + 2.0 * tp))

        let n = Double(turnsPerDisc)
        let beta = connection.beta(turnsPerDisc: turnsPerDisc, discTurns: N)

        let shielded = n * cwOverCt * (4.0 * beta * beta + 1.0 - 1.0 / N + 1.0 / (2.0 * N * N)) + (N - n - 1.0) / (2.0 * N * N)
        let plain = (N - 1.0) / (2.0 * N * N)

        return shielded / plain
    }

    /// The turn-turn capacitance of the mean turn of a single basic section of this Segment,
    ///
    /// - Parameter effectiveInsulation: If non-nil, the TWO-SIDED insulation thickness to use in place of the coil turn's own paper.
    /// The only caller that passes this is the wound-in-shield code, which needs c_w, the capacitance between a coil turn and a
    /// shield turn beside it. DelVecchio (p.352) forms c_w with "the same expression ... but with τp replaced by 0.5(τp + τw)",
    /// which is the physical copper-to-copper gap: one half-wrap from the coil turn and one from the shield turn.
    func CapacitanceTurnToTurn(effectiveInsulation:Double? = nil) throws -> Double {

        guard !self.isStaticRing else {

            throw SegmentError(info: "\(self.location)", type: .StaticRing)
        }

        guard !self.isRadialShield else {

            throw SegmentError(info: "\(self.location)", type: .RadialShield)
        }

        if self.wdgType == .helical {

            return 0.0
        }

        // For disc & sheet coils, this corresponds to Ctt in the DelVeccio book. For layer windings, it is the turn-turn capacitance in the axial direction (my own invention).

        if self.wdgType == .disc || self.wdgType == .layer {

            // DelVecchio 12.47 wants τp to be the TWO-SIDED paper thickness of a turn (his worked example on p.337 states "The 2-sided
            // paper thickness is 1 mm" and then uses τp = 0.001), and the design file's insulation fields are two-sided totals as well,
            // so this is used as-is. Do NOT reintroduce a factor of 2: Ctt goes as 1/τp, so doing so halves every disc capacitance in
            // the model. The 'height - tp' below is the matching assumption - it only yields the bare copper height h if tp is the
            // full two-sided figure.
            let tp = self.basicSections[0].wdgData.turn.turnInsulation

            // 'tau' is the gap between the two conductors; 'tp' is this coil turn's own paper. They are the same thing unless a
            // wound-in shield is what sits across the gap. Note that h keeps using tp in EITHER case: h is the bare copper height of
            // a COIL turn, and it does not change because the thing beside it happens to be a shield.
            let tau = effectiveInsulation ?? tp

            // the calculation of the turn thickness of layer windings does not account for ducts in the winding
            let h = self.wdgType == .disc ? self.basicSections[0].height - tp : self.basicSections[0].width / Double(self.basicSections[0].wdgData.layers.numLayers)

            var Ctt:Double = ε0 * εPaper
            Ctt *= π * (self.r1 + self.r2)
            Ctt *= (h + 2 * tau) / tau

            return Ctt
        }
        else if self.wdgType == .sheet {

            // ONE PLAIN GAP, at the mean radius. τ is the design file's insulation between the turns, through
            // `SheetTurnInsulation`, so this is now what its name says: the capacitance between two adjacent turns across their
            // paper.
            //
            // IT IS NOT THE COIL'S SERIES CAPACITANCE and must not be used as one. A sheet winding's turns are in SERIES, and three
            // of this fixture's twelve gaps hold a 6.35 mm oil duct that this value knows nothing about - the ducts are 40 times the
            // reduced thickness of the paper and they dominate the chain. `BasicSectionSeriesCapacitance` takes the exact chain over
            // `SheetGapCapacitances` instead; see the note there, including why feeding a correct τ into the disc formula was the
            // worse of the two errors.
            //
            // What this used to compute was τ = (width − N·t)/(N − 1) - the whole leftover build, ducts and overbuild allowance
            // included, 1.77 mm against a real 0.254 mm - and it was the route to Cs.
            let bs = self.basicSections[0]
            let tau = try self.SheetTurnInsulation()
            let h = bs.height

            var Ctt:Double = ε0 * εPaper
            Ctt *= π * (self.r1 + self.r2)
            Ctt *= (h + 2 * tau) / tau

            return Ctt
        }
        
        throw SegmentError(info: "", type: .UnimplementedWdgType)
    }
    
    /// Self-check for the wound-in-shield capacitance path, run by hand because this program has no test target.
    ///
    /// It builds DelVecchio's own experimental disc pair (12.11.3, p.357) and pushes it through the real SeriesCapacitance path -
    /// the unit list, the leaf routing, DiscToDiscSeriesCapacitance and 12.96 - for n = 0/3/5/7/9 across all three connections,
    /// then checks the two invariants that a transcription error would break:
    ///
    ///  1. n = 0 through the shielded formula must equal the plain two-discs-in-series result EXACTLY. 12.96's turn term is
    ///     c_t(N − n − 1)/(2N²), which at n = 0 is c_t(N − 1)/(2N²), and that is identically two plain discs' c_t(N − 1)/N² in
    ///     series. Any drift here means the turn-pair count or the pair/disc normalization has gone wrong.
    ///  2. The capacitance must be linear in n at fixed β, because 12.96 is. The second difference has to vanish.
    ///
    /// It cannot reproduce the absolute numbers in Table 12.1: that experiment was run in AIR (εp = 1.5, εks = 4.0) while this
    /// program's constants are for an oil-filled transformer (εPaper = 3.5, εBoard = 4.5). The comparison against the book was done
    /// separately and is recorded on WoundInShieldSeriesCapacitance - agreement to a flat 4.6-6.0%, which is DelVecchio's own
    /// stated winding-looseness correction.
    ///
    /// To run it, add this to AppDelegate.applicationDidFinishLaunching, build, launch the app and read the result back with
    /// `defaults read com.huberistech.ImpulseDistribution PCH_WIS_SELFCHECK`. The app is sandboxed, so it cannot write a report to /tmp and
    /// print() does not reach a shell that launched it with `open` - UserDefaults is the path of least resistance.
    ///
    ///     Task {
    ///         UserDefaults.standard.set(await Segment.VerifyWoundInShieldCapacitance().joined(separator: "\n"), forKey: "PCH_WIS_SELFCHECK")
    ///         NSApp.terminate(nil)
    ///     }
    ///
    /// Results as of 2026-08-03, all passing:
    ///
    ///     12.96 at n=0 vs two plain discs in series:  3.527474e-11 vs 3.527474e-11  rel 0.00e+00
    ///     floating linearity in n at fixed radius:    worst relative 2nd difference 4.41e-16
    ///     linear-voltage assumption vs Stein:  n=1 +2.96% (α=1.22), n=2 +0.96%, n=3 +0.47%, n=0 +117% (α=6.01)
    static func VerifyWoundInShieldCapacitance() async -> [String] {

        var report:[String] = ["Wound-in shield self-check (DelVecchio 12.11.3 geometry, this program's permittivities)"]

        // DelVecchio's test coil, p.357
        let N = 10.0
        let innerRadius = 0.249
        let cableRadial = 0.0117
        let discHeight = 0.00919
        let turnPaper = 0.00076
        let shieldPaper = 0.00051
        let keySpacer = 0.00419

        let wdgData = BasicSectionWindingData(type: .disc, discData: BasicSectionWindingData.DiscData(numAxialColumns: 18, axialColumnWidth: 0.0445), layers: BasicSectionWindingData.LayerData(numLayers: 1, interLayerInsulation: 0, ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: 0, ductDimn: 0)), turn: BasicSectionWindingData.TurnData(radialDimn: cableRadial, axialDimn: discHeight, turnInsulation: turnPaper, resistancePerMeter: 0, strandRadial: 0, strandAxial: 0))

        /// - Parameter connection: nil to build an ordinary unshielded pair, which is how the n = 0 invariant gets its reference
        /// - Parameter fixedWidth: pass true to keep the coil at its unshielded radial build. That is not what the program does -
        /// shields widen the coil, and ApplyRadialBuildUp is what makes that happen - but holding the radius still is what isolates
        /// 12.96's own linearity in n from the growth of c_t, c_w and c_d with the mean radius.
        func pairCapacitance(shieldTurns:Int, connection:WoundInShieldWire.Connection?, fixedWidth:Bool = false) async -> Double {

            let wire = WoundInShieldWire(connection: connection ?? .floating, bareRadial: Segment.woundInShieldBareRadial, insulation: shieldPaper)
            let width = cableRadial * N + (fixedWidth ? 0.0 : Double(shieldTurns) * wire.overPaperRadial)

            let lower = BasicSection(location: LocStruct(radial: 0, axial: 0), N: N, I: 0, wdgData: wdgData, rect: NSRect(x: innerRadius, y: 0.0, width: width, height: discHeight))
            let upper = BasicSection(location: LocStruct(radial: 0, axial: 1), N: N, I: 0, wdgData: wdgData, rect: NSRect(x: innerRadius, y: discHeight + keySpacer, width: width, height: discHeight))

            guard let pair = try? Segment(basicSections: [lower, upper], realWindowHeight: 1.0, useWindowHeight: 1.0) else {

                return Double.nan
            }

            if connection != nil {

                await pair.SetWoundInShield(WoundInShield(wire: wire, turnsPerDisc: [shieldTurns]))
            }

            // Zero external gaps make this the ISOLATED pair DelVecchio measured: only the gap inside the pair contributes.
            guard let result = try? await pair.SeriesCapacitance(axialGaps: (above: 0.0, below: 0.0), radialGaps: nil, endDisc: nil, adjStaticRing: nil) else {

                return Double.nan
            }

            return result
        }

        report.append("")
        report.append("n         floating     crossover       top end")

        for shieldTurns in [0, 3, 5, 7, 9] {

            var line = String(format: "%-2d", shieldTurns)

            for connection in WoundInShieldWire.Connection.allCases {

                let value = await pairCapacitance(shieldTurns: shieldTurns, connection: connection)
                line += String(format: "  %12.4f", value * 1.0E9)
            }

            report.append(line + "   nF")
        }

        // Build a bare pair (no shield set) to use as the reference for the invariants below
        let refWidth = cableRadial * N
        let refLower = BasicSection(location: LocStruct(radial: 0, axial: 0), N: N, I: 0, wdgData: wdgData, rect: NSRect(x: innerRadius, y: 0.0, width: refWidth, height: discHeight))
        let refUpper = BasicSection(location: LocStruct(radial: 0, axial: 1), N: N, I: 0, wdgData: wdgData, rect: NSRect(x: innerRadius, y: discHeight + keySpacer, width: refWidth, height: discHeight))

        report.append("")

        guard let refPair = try? Segment(basicSections: [refLower, refUpper], realWindowHeight: 1.0, useWindowHeight: 1.0) else {

            report.append("could not build the reference pair - FAIL")
            return report
        }

        let refWire = WoundInShieldWire(connection: .floating, bareRadial: Segment.woundInShieldBareRadial, insulation: shieldPaper)

        // Invariant 1: 12.96's turn term at n = 0 is c_t(N − 1)/(2N²), and two plain discs' c_t(N − 1)/N² in series is the same
        // number. This has to be compared against the formulas directly - going through SeriesCapacitance would route BOTH sides
        // down the plain path (a pair with no shield turns is emitted as two single discs) and prove nothing.
        let shieldedZero = (try? await refPair.WoundInShieldSeriesCapacitance(turnsPerDisc: 0, wire: refWire)) ?? Double.nan
        let plainSeries = ((try? await refPair.BasicSectionSeriesCapacitance()) ?? Double.nan) / 2.0
        let zeroError = abs(shieldedZero - plainSeries) / plainSeries

        report.append(String(format: "12.96 at n=0 vs two plain discs in series:  %.6e vs %.6e  rel %.2e  %@", shieldedZero, plainSeries, zeroError, zeroError < 1.0E-12 ? "PASS" : "FAIL"))

        // How much the linear-voltage assumption costs. The series capacitances agree exactly (above), so the whole difference is
        // in the DISC-DISC treatment: the shielded pair uses DelVecchio's linear-voltage split (12.93), the plain path uses Stein.
        // The Stein equivalent is recomputed here from scratch rather than called, so that this is a genuine cross-check.
        //
        // The number grows sharply as n falls, because α = √(2·Cdd/Cs) blows up once the shields stop holding Cs high, and the
        // linear assumption is only good for small α. At n = 0 it is worth well over 100% (α ≈ 6 for this coil) - which is exactly
        // why SeriesCapacitanceUnits sends an unshielded pair down the plain path instead. Do not read these as a discontinuity in
        // a graded scheme: a graded profile's shielded side is n ≥ 1, where the two agree to a few percent.
        let CddInternal = Segment.DiscToDiscSeriesCapacitance(belowGap: keySpacer, aboveGap: 0.0, basicSection: refLower, innerRadius: innerRadius, outerRadius: innerRadius + refWidth).below

        report.append("")
        report.append("linear-voltage assumption vs Stein, isolated pair, floating:")

        for shieldTurns in [0, 1, 2, 3] {

            let CsPair = (try? await refPair.WoundInShieldSeriesCapacitance(turnsPerDisc: shieldTurns, wire: refWire)) ?? Double.nan
            let linear = CsPair + CddInternal / 3.0

            // Two discs in series, each seeing Cdd on one face only (Ya = 0, Yb = 1 in 12.53), which is the isolated-pair case
            let CsDisc = 2.0 * CsPair
            let alpha = (2.0 * CddInternal / CsDisc).squareRoot()
            let stein = CsDisc * alpha / tanh(alpha) / 2.0

            report.append(String(format: "  n=%d  alpha=%6.3f   linear %.4e   Stein %.4e   %+7.2f%%", shieldTurns, alpha, linear, stein, (linear - stein) / stein * 100.0))
        }

        // Invariant 2: at a FIXED radius and fixed beta, 12.96 is exactly linear in n, so the second difference must vanish to
        // machine precision. The floating case is the one to use - beta is 0 for every n there, whereas the top-end case is
        // deliberately non-linear because its beta grows with n. The radius has to be held still because a real shielded coil
        // widens, which makes c_t, c_w and c_d all creep up with n (that is the slight super-linearity in DelVecchio's own
        // circuit-model column).
        // n starts at 1: a pair with n = 0 is deliberately evaluated by the plain path instead, so it does not lie on this line.
        var floatingValues:[Double] = []
        for shieldTurns in 1...5 {

            floatingValues.append(await pairCapacitance(shieldTurns: shieldTurns, connection: .floating, fixedWidth: true))
        }

        var worstSecondDifference = 0.0
        for i in 1..<(floatingValues.count - 1) {

            let secondDifference = floatingValues[i + 1] - 2.0 * floatingValues[i] + floatingValues[i - 1]
            worstSecondDifference = max(worstSecondDifference, abs(secondDifference) / floatingValues[i])
        }

        report.append(String(format: "floating linearity in n at fixed radius:  worst relative 2nd difference %.2e  %@", worstSecondDifference, worstSecondDifference < 1.0E-10 ? "PASS" : "FAIL"))

        return report
    }

    /// Self-check for a SHEET winding's capacitances, run from `AppDelegate` under `-PCH_Verify YES`.
    ///
    /// Three things are pinned here, all of which have been wrong at some point and none of which a graph would show:
    ///
    ///  1. **The gap insulation is READ, not derived.** A plain gap's capacitance must be exactly DelVecchio 12.47's cylindrical
    ///     form at its own radius, through the design file's τ. The routine this replaced backed τ out of the radial build, which
    ///     returns the overbuild allowance and not a dimension - see `SheetTurnInsulation`.
    ///  2. **The series capacitance is the exact chain, and it agrees with the profile.** `BasicSectionSeriesCapacitance` and
    ///     `TurnLadderModel.SolveSheet` are independent routes over the same gaps: the first says Cs = 1/Σ(1/C_k), the second says
    ///     ΔV_k = V·(1/C_k)/Σ(1/C_j). Both are statements about ONE charge Q on a series chain, so Q = Cs·V must equal C_k·ΔV_k at
    ///     every single gap. Putting the disc formula Cs = Ctt(N−1)/N² back breaks this at once, which is the point - it is the
    ///     substitution that looks harmless.
    ///  3. **The ducts are in the answer.** A coil with three oil ducts must have a far smaller series capacitance than the same
    ///     coil without them, since a chain is governed by its smallest links. The failure this catches is the tempting "fix" of
    ///     feeding the real τ into the disc formula, which drops the ducts entirely and raises Cs about ninefold.
    static func VerifySheetCapacitance() async -> [String] {

        var report:[String] = ["Sheet winding capacitance self-check"]

        // Roughly the SheetAndLayer fixture's sheet coil: 13 foil turns of 1.27 mm, 0.254 mm between them, three 6.35 mm ducts.
        let turns = 13.0
        let turnRadial = 0.00127
        let insulation = 0.000254
        let ductDimension = 0.00635
        let innerRadius = 0.17335
        let height = 0.6097

        func SheetSegment(ducts:Int, interLayerInsulation:Double) -> Segment? {

            let wdgData = BasicSectionWindingData(type: .sheet,
                                                  discData: BasicSectionWindingData.DiscData(numAxialColumns: 0, axialColumnWidth: 0.0),
                                                  layers: BasicSectionWindingData.LayerData(numLayers: 1,
                                                                                            interLayerInsulation: interLayerInsulation,
                                                                                            ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: ducts, ductDimn: ductDimension)),
                                                  turn: BasicSectionWindingData.TurnData(radialDimn: turnRadial, axialDimn: height, turnInsulation: insulation, resistancePerMeter: 0.0, strandRadial: turnRadial, strandAxial: height))

            // The build is the real stack, so that the fallback below has something sensible to divide up.
            let build = turns * turnRadial + (turns - 1.0) * insulation + Double(ducts) * ductDimension
            let section = BasicSection(location: LocStruct(radial: 0, axial: 0), N: turns, I: 0.0, wdgData: wdgData, rect: NSRect(x: innerRadius, y: 0.0, width: build, height: height))

            return try? Segment(basicSections: [section], realWindowHeight: 1.0, useWindowHeight: 1.0)
        }

        guard let ducted = SheetSegment(ducts: 3, interLayerInsulation: insulation),
              let plain = SheetSegment(ducts: 0, interLayerInsulation: insulation),
              let gaps = try? await ducted.SheetGapCapacitances(),
              let Cs = try? await ducted.BasicSectionSeriesCapacitance(),
              let CsNoDucts = try? await plain.BasicSectionSeriesCapacitance() else {

            return report + ["could not build the sheet segments - FAIL"]
        }

        // 1. A plain gap against DelVecchio 12.47 written out here, with the design file's τ and no reference to the build.
        if let firstPlain = gaps.first(where: { $0.duct == 0.0 }) {

            let expected = ε0 * εPaper * 2.0 * π * firstPlain.radius * (height + 2.0 * insulation) / insulation
            let error = abs(firstPlain.capacitance - expected) / expected

            report.append(String(format: "plain gap is 12.47 at its own radius through the design file's τ:  %.6e vs %.6e  rel %.2e  %@",
                                 firstPlain.capacitance, expected, error, error < 1.0E-12 ? "PASS" : "FAIL"))
            report.append(String(format: "  τ used: %.4f mm (the design file's), NOT the leftover build", firstPlain.insulation * 1000.0))
        }
        else {

            report.append("no plain gap in a 12-gap coil with 3 ducts - FAIL")
        }

        // 2. One charge on the chain: Cs·V against C_k·ΔV_k at every gap, through SolveSheet.
        let V = 45000.0

        if let profile = try? TurnLadderModel.SolveSheet(gapCapacitances: gaps.map { $0.capacitance }, gapRadii: gaps.map { $0.radius }, segmentVoltage: V) {

            let charge = Cs * V
            var worst = 0.0

            for gap in profile.gaps {

                worst = max(worst, abs(gaps[gap.index].capacitance * gap.deltaV - charge) / charge)
            }

            report.append(String(format: "series capacitance is the chain the profile solves:  Q = %.6e C, worst gap disagreement %.2e  %@",
                                 charge, worst, worst < 1.0E-9 ? "PASS" : "FAIL"))
        }
        else {

            report.append("the sheet profile would not solve - FAIL")
        }

        // 3. The ducts are in the answer at all.
        report.append(String(format: "three oil ducts lower the series capacitance:  %.4f nF with, %.4f nF without (%.1fx)  %@",
                             Cs * 1.0E9, CsNoDucts * 1.0E9, CsNoDucts / Cs, Cs < CsNoDucts ? "PASS" : "FAIL"))

        return report
    }

    /// Class function to create a radial shield. The Segment has its 'isRadialShield' property set to true. The radial location of the shield is equal to the _negative_ of the 'adjacentSegment' argument unless the adjacent segment is in coil '0', in which case the radial location of the shield is Segment.negativeZeroPosition. The adjacent segment must be the FIRST (lowest) Segment in the NEXT coil position from the core.  That is, the radial shield will be placed in the hilo UNDER the adjacent Segment. The thickness of the shield is fixed at 2mm. The radial shield should be set to have  the full electrical height of the coil to which adjacentSegment belongs.
    /// - Parameter adjacentSegment: The segment that is immediately outside the radial shield..
    /// - Parameter hiloToSegment: The radial gap between the shield and the adjacent Segment.
    /// - Parameter elecHt: The height of the radial shield
    static func RadialShield(adjacentSegment:Segment, hiloToSegment:Double, elecHt:Double) async throws -> Segment {
        
        // Create the special BasicSection for a radial shield
        let radialPos = adjacentSegment.radialPos == 0 ? Segment.negativeZeroPosition : -adjacentSegment.radialPos
        let rsLocation = LocStruct(radial: radialPos, axial: 0)
        let rsThickness = 0.002 // 2mm standard thickness
        let originX = await adjacentSegment.rect.origin.x - hiloToSegment - rsThickness
        let originY = await adjacentSegment.rect.origin.y
        let rsRect = NSRect(x: originX, y: originY, width: rsThickness, height: elecHt)
        // create a dummy BSdata struct
        let rsWdgData = BasicSectionWindingData(type: .disc, discData: BasicSectionWindingData.DiscData(numAxialColumns: 10, axialColumnWidth: 0.038), layers: BasicSectionWindingData.LayerData(numLayers: 1, interLayerInsulation: 0, ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: 0, ductDimn: 0)), turn: BasicSectionWindingData.TurnData(radialDimn: rsThickness, axialDimn: elecHt, turnInsulation: 0, resistancePerMeter: 0, strandRadial: 0, strandAxial: 0))
        let rsSection = BasicSection(location: rsLocation, N: 0, I: 0, wdgData: rsWdgData, rect: rsRect)
        
        do {
            
            let newSegment = try Segment(basicSections: [rsSection], interleaved: false, isStaticRing: false, isRadialShield: true, realWindowHeight: adjacentSegment.realWindowHeight, useWindowHeight: adjacentSegment.useWindowHeight)
            
            return newSegment
        }
        catch {
            
            throw error
        }
    }
    
    /// Class function to create a static ring. The Segment is marked as a static ring using its 'isStaticRing' property. The radial location of the static ring is equal to the radial location of the 'adjacentSegment' argument, and its axial location is whatever the caller hands in.
    /// - Parameter adjacentSegment: The segment that is immediately adjacent to the static ring.
    /// - Parameter gapToSegment: The axial gap (shrunk) between the adjacent segment and the static ring
    /// - Parameter staticRingIsAbove: Boolean to indicate whether the static ring is above (true) or below (false) the adjacentSegment
    /// - Parameter staticRingThickness: An optional static ring thickness (axial height). If nil, then the "standard" thickness of 5/8" is used.
    /// - Parameter axialPosition: The axial coordinate to give the ring. It must be **negative** (that is how the rest of the program tells a shielding element from a disc) and unique within the coil. It is an identity and not a position: which Segments the ring actually sits between is worked out from the geometry by `PhaseModel.StaticRingAbove`/`StaticRingBelow`. Get it from `PhaseModel.NextStaticRingAxialPosition`, which is what `PhaseModel.AddStaticRing` does. It used to be derived here as the negative of `adjacentSegment.axialPos`, which tied the ring to a disc index that a combine or an interleave could renumber out from under it.
    static func StaticRing(adjacentSegment:Segment, gapToSegment:Double, staticRingIsAbove:Bool, staticRingThickness:Double? = nil, axialPosition:Int) async throws -> Segment {

        // Create a special BasicSection as follows
        // The location is the same as the adjacent segment EXCEPT for the (negative) axial position handed in by the caller
        let srLocation = LocStruct(radial: adjacentSegment.radialPos, axial: axialPosition)
        // The rect has the same x-origin and width as the adjacent segment but is offset by the gaptoSegment and the standard static-ring axial dimension
        let srThickness = staticRingThickness == nil ? stdStaticRingThickness : staticRingThickness!
        let offsetY = await staticRingIsAbove ? adjacentSegment.rect.height + gapToSegment : -(gapToSegment + srThickness)
        var srRect = await adjacentSegment.rect
        srRect.origin.y += offsetY
        srRect.size.height = srThickness
        // we need to create a dummy cable definition for the static ring
        // turnInsulation is a two-sided total by convention, so store twice the per-side wrap. The capacitance code reads the constant
        // directly (it only ever gets handed the *disc's* BasicSection), but keep the two in step so they can never disagree.
        let srWdgData = BasicSectionWindingData(type: .disc, discData: BasicSectionWindingData.DiscData(numAxialColumns: 10, axialColumnWidth: 0.038), layers: BasicSectionWindingData.LayerData(numLayers: 1, interLayerInsulation: 0, ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: 0, ductDimn: 0)), turn: BasicSectionWindingData.TurnData(radialDimn: 0, axialDimn: 0, turnInsulation: 2.0 * Segment.staticRingInsulationPerSide, resistancePerMeter: 0, strandRadial: 0, strandAxial: 0))
        let srSection = BasicSection(location: srLocation, N: 0.0, I: 0.0, wdgData: srWdgData,  rect: srRect)
        
        do {
            
            let newSegment = try Segment(basicSections: [srSection], interleaved: false, isStaticRing: true, realWindowHeight: adjacentSegment.realWindowHeight, useWindowHeight: adjacentSegment.useWindowHeight)
                        
            return newSegment
        }
        catch {
            
            throw error
        }
    }
    
    /// Reset the value of the next Segment serial number to be assigned to 0. NOTE:  Any Segments that may have been created by the user prior to calling this function SHOULD BE DESTROYED to avoid problems when testing for equality between Segments (the equality test reiles on the the serial number).
    static func resetSerialNumber()
    {
        Segment.nextSerialNumberStore.withLock { $0 = -1 }
    }
    
    /*
    /// Create the Fourier series representation of the current density for the segment. Note that the "useWindowHeight" property of the segment is used to create the series. This is used by DelVecchio.
    func CreateFourierJ() -> [Double]
    {
        var result:[Double] = []
        
        for i in 0...PCH_IMPULSEDISTRIBUTION_IterationCount {
            
            result.append(self.J(n: i))
        }
        
        return result
    } */
    
    /*
    /// Private function to create the n-th entry into the Fourier series representation of the current density, using the max of the real and 'use'  window height as the 'L' variable.
    private func J(n:Int) -> Double
    {
        let L = self.L
        
        if n == 0 {
            
            let result = self.ActualJ * (self.z2 - self.z1) / L
            return result
        }
        
        let z1 = self.z1 + self.zWindHtAdder
        let z2 = self.z2 + self.zWindHtAdder
        
        let nn = Double(n)
        let result:Double = 2.0 * self.ActualJ / (nn * π) * (sin(nn * π * z2 / L) - sin(nn * π * z1 / L))
        
        return result
    } */
}
