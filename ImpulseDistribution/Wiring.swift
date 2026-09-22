//
//  Wiring.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-09-22.
//
//  Making connections from CODE rather than from a mouse click: name a point on the winding, find the lead that is actually
//  there, and put a jumper on it exactly the way TransformerView.CompleteAddConnection does.
//
//  This started life inside SelfTest, which needed to wire a model with nobody at the keyboard. It moved out when the
//  regulating-winding declaration (RegulatingWinding.swift) needed the same thing in the shipped app: a winding's permanent
//  connections are a list of jumpers between named points, and the only safe way to turn a named point into a
//  (Segment, Connector.Location) pair is the one SelfTest already used - look, never compute. SelfTest keeps its old names
//  for these types through typealiases, so its scenarios read as they always did.
//
//  Read docs/connectors-and-nodes.md before changing anything here. The cross-product in ApplyJumper and the refusal of disc
//  numbering on a folded coil are both there because of failures written up in that file and in docs/self-test.md.
//

import Foundation

enum Wiring {

    /// Which end of a coil a lead comes off.
    enum CoilEnd: Sendable {

        case bottom
        case top
    }

    /// A point on the winding that a lead comes off - the thing the user would click on in `TransformerView`.
    ///
    /// Connections are named this way rather than by (Segment, Connector.Location) because neither of those is knowable from the
    /// design file: which Segment is at the bottom of a coil depends on how many there are, and whether its lead is at
    /// `.inside_lower`, `.outside_lower` or `.center_lower` depends on the winding type and the disc count (see AppController's
    /// segment-building loop). Guessing either gives a connector `NodeAt` cannot resolve, so the lead is always *found* and never
    /// computed.
    enum LeadPoint: Sendable, Equatable {

        /// The lead at the bottom or top of a whole coil.
        case coilEnd(coil:Int, end:CoilEnd)
        /// A lead at one side of a coil's internal tapping/DV gap. `gap` counts gaps from the bottom of the coil, and `side` says
        /// which of the two leads facing across it is wanted - `.bottom` for the one on the Segment below the gap.
        case gapLead(coil:Int, gap:Int, side:CoilEnd)
        /// The crossover between two axially adjacent discs of a coil, named by the disc BELOW it, counting from 1 at the bottom
        /// of the coil. This is an interior point of the winding rather than a lead going anywhere - the series connector
        /// AppController's segment-building loop puts between every pair of discs - and it is a real place to jumper from: it is
        /// drawn, it is hit-testable, and paralleling the two halves of a double-stacked tap winding is done by tying pairs of
        /// them together.
        ///
        /// Whether a given crossover is at the OD or the ID is not a choice; it alternates disc by disc, so the caller says which
        /// disc it means and the lookup reports which side that turned out to be.
        case discCrossover(coil:Int, disc:Int)
    }

    /// A jumper between two leads - what the user makes by clicking one connector and then another.
    struct Jumper: Sendable, Equatable {

        let from:LeadPoint
        let to:LeadPoint
    }

    /// The outcome of looking for the lead a `LeadPoint` names.
    enum LeadLookup {

        case ok(segment:Segment, location:Connector.Location)
        case failed(String)
    }

    static func Describe(_ point:LeadPoint) -> String {

        switch point {

        case .coilEnd(let coil, let end):

            return "coil \(coil) \(end == .bottom ? "bottom" : "top")"

        case .gapLead(let coil, let gap, let side):

            return "coil \(coil) gap \(gap) \(side == .bottom ? "lower" : "upper") lead"

        case .discCrossover(let coil, let disc):

            return "coil \(coil) crossover \(disc)-\(disc + 1)"
        }
    }

    static func Describe(_ jumper:Jumper) -> String {

        return "\(Describe(jumper.from)) <-> \(Describe(jumper.to))"
    }

    /// Find the (Segment, location) a `LeadPoint` names, by looking at what the model actually has.
    ///
    /// Nothing here is computed from the design: a coil-end lead is whichever termination sits at the outward end of the coil's
    /// outermost Segment, and a gap lead is whichever centre-location connection sits on a Segment facing across a break.
    ///
    /// - Parameter acceptTerminated: whether a coil-end lead that has already been grounded or impulsed still counts. SelfTest
    /// leaves this false, because for its purposes a coil-end lead IS the floating termination and its removal path depends on
    /// the refusal. The regulating-winding path sets it true: a winding's permanent connections do not stop being there because
    /// the user grounded one of its ends first, and the jumper appends beside the termination rather than replacing it.
    static func FindLead(_ point:LeadPoint, model:PhaseModel, acceptTerminated:Bool = false) async -> LeadLookup {

        switch point {

        case .coilEnd(let coil, let end):

            let coilSegments = await model.CoilSegments().filter({ $0.radialPos == coil })

            guard let segment = end == .bottom ? coilSegments.first : coilSegments.last else {

                return .failed("coil \(coil) has no segments")
            }

            let wantLower = end == .bottom
            let connections = await segment.connections

            // A coil-end lead is a termination on the Segment itself (segmentID nil), at a lower location for the bottom of the
            // coil and an upper one for the top. A floating one is preferred whenever there is one.
            let atThatEnd = connections.filter({ $0.segmentID == nil && (wantLower ? $0.connector.fromIsLower : $0.connector.fromIsUpper) })

            if let lead = atThatEnd.first(where: { $0.connector.toLocation == .floating }) {

                return .ok(segment: segment, location: lead.connector.fromLocation)
            }

            if acceptTerminated, let lead = atThatEnd.first {

                return .ok(segment: segment, location: lead.connector.fromLocation)
            }

            return .failed("no floating lead at that end of segment \(segment.serialNumber)")

        case .gapLead(let coil, let gap, let side):

            let gaps = await InternalGaps(coil: coil, model: model)

            guard gap >= 0, gap < gaps.count else {

                return .failed("coil \(coil) has \(gaps.count) internal gap(s), so gap \(gap) does not exist")
            }

            let segment = side == .bottom ? gaps[gap].below : gaps[gap].above
            let locations = Set(await segment.connections.filter({ $0.connector.fromIsCenter }).map({ $0.connector.fromLocation }))

            // A Segment between two gaps would carry two centre leads with nothing in the location to say which gap each faces.
            // The disc arithmetic in AppController makes that impossible (the lower and upper tapping gaps are a quarter of the
            // coil apart), so this is a guard against a future geometry rather than a case to handle.
            guard locations.count == 1, let location = locations.first else {

                return .failed("segment \(segment.serialNumber) carries \(locations.count) centre leads, so which one faces gap \(gap) is ambiguous")
            }

            return .ok(segment: segment, location: location)

        case .discCrossover(let coil, let disc):

            let coilSegments = await model.CoilSegments().filter({ $0.radialPos == coil })

            // Disc numbering only means anything while every Segment of the coil holds exactly one BasicSection, which is what
            // the load path gives and what a combine or an interleave destroys. Refuse rather than guess: a crossover inside a
            // folded Segment is not a node at all, so there is nothing there to jumper to.
            for nextSegment in coilSegments {

                guard nextSegment.basicSections.count == 1 else {

                    return .failed("coil \(coil) has been restructured (segment \(nextSegment.serialNumber) holds \(nextSegment.basicSections.count) discs), so disc numbering is not meaningful")
                }
            }

            guard disc >= 1, disc < coilSegments.count else {

                return .failed("coil \(coil) has \(coilSegments.count) discs, so there is no crossover above disc \(disc)")
            }

            let segment = coilSegments[disc - 1]

            // The outgoing series connector - the one that goes UP out of this disc into the next. There is exactly one, and its
            // location is whichever of outside/inside the alternation landed on. Taking it from the model rather than computing
            // it is the same discipline the two cases above follow.
            guard let crossover = await segment.connections.first(where: { $0.segmentID != nil && $0.connector.fromIsUpper }) else {

                return .failed("disc \(disc) of coil \(coil) (segment \(segment.serialNumber)) has no outgoing series connector, so the crossover above it is a break and not a crossover")
            }

            return .ok(segment: segment, location: crossover.connector.fromLocation)
        }
    }

    /// The internal tapping/DV gaps of a coil, bottom to top, as the pair of Segments facing each other across each one.
    ///
    /// A centre location is created in exactly one place - AppController's segment-building loop, at a tapping/DV gap - so a
    /// Segment carrying one is a Segment facing across a gap, and two consecutive such Segments ARE a gap. The test is on the
    /// location and not on the lead still being floating, because a centre lead that has been jumpered and grounded is no longer
    /// floating and is still a gap (see `IsTappingGap` in docs/connectors-and-nodes.md).
    static func InternalGaps(coil:Int, model:PhaseModel) async -> [(below:Segment, above:Segment)] {

        let coilSegments = await model.CoilSegments().filter({ $0.radialPos == coil })

        var gaps:[(below:Segment, above:Segment)] = []

        for i in 0..<max(coilSegments.count - 1, 0) {

            let below = coilSegments[i]
            let above = coilSegments[i + 1]

            let belowHasCentre = await below.connections.contains(where: { $0.connector.fromIsCenter })
            let aboveHasCentre = await above.connections.contains(where: { $0.connector.fromIsCenter })

            if belowHasCentre && aboveHasCentre {

                gaps.append((below: below, above: above))
            }
        }

        return gaps
    }

    // MARK: Jumpers

    /// What `ApplyJumper` did.
    enum JumperOutcome {

        /// The jumper went on, as `count` connectors (the cross-product; see `ApplyJumper`).
        case made(count:Int, fromSegment:Int, fromLocation:Connector.Location, toSegment:Int, toLocation:Connector.Location)
        case failed(String)
    }

    /// Put a jumper between two leads, the way `TransformerView.CompleteAddConnection` does.
    ///
    /// This is a port of that routine's body with the hit testing and the redraw taken out, and the cross-product is the part
    /// worth keeping: a lead that already carries jumpers is at the same potential as everything on the far end of them, so a new
    /// jumper is registered on EVERY (Segment, location) pair at each of its two ends, with each copy carrying the others in its
    /// `equivalentConnections`. Doing less than that here would build a model the UI cannot produce, and the redundant copies are
    /// exactly what `PhaseModel.UpdateConnectors` and `SegmentPath.SetUpConnectors` are written to cope with.
    static func ApplyJumper(_ jumper:Jumper, model:PhaseModel, acceptTerminated:Bool = false) async -> JumperOutcome {

        let fromLookup = await FindLead(jumper.from, model: model, acceptTerminated: acceptTerminated)

        guard case .ok(let fromSegment, let fromLocation) = fromLookup else {

            if case .failed(let why) = fromLookup {

                return .failed("\(Describe(jumper.from)): \(why)")
            }

            return .failed("could not find \(Describe(jumper.from))")
        }

        let toLookup = await FindLead(jumper.to, model: model, acceptTerminated: acceptTerminated)

        guard case .ok(let toSegment, let toLocation) = toLookup else {

            if case .failed(let why) = toLookup {

                return .failed("\(Describe(jumper.to)): \(why)")
            }

            return .failed("could not find \(Describe(jumper.to))")
        }

        let allSegments = await model.segments

        // Both ends carry along everything already jumpered to them. The floating terminations are dropped (segmentID nil) - they
        // are not a place to jumper TO - and the lead itself goes in at the head of its own list.
        var startConnections = await fromSegment.ConnectionDestinations(fromLocation: fromLocation)
        startConnections.removeAll(where: { $0.segmentID == nil })
        startConnections.insert((fromSegment.serialNumber, fromLocation), at: 0)

        var endConnections = await toSegment.ConnectionDestinations(fromLocation: toLocation)
        endConnections.removeAll(where: { $0.segmentID == nil })
        endConnections.insert((toSegment.serialNumber, toLocation), at: 0)

        var equivalentConnections:Set<Segment.Connection.EquivalentConnection> = []
        var madeCount = 0

        for nextStartConnection in startConnections {

            for nextEndConnection in endConnections {

                guard let nextStartSegment = allSegments.first(where: { $0.serialNumber == nextStartConnection.segmentID }) else {

                    return .failed("segment \(nextStartConnection.segmentID.map({ String($0) }) ?? "nil") is not in the model")
                }

                let newConnections = await nextStartSegment.AddConnector(segments: allSegments,
                                                                         fromLocation: nextStartConnection.location,
                                                                         toLocation: nextEndConnection.location,
                                                                         toSegmentID: nextEndConnection.segmentID)

                // AddConnector returns (nil, nil) for one reason only: it was asked to connect a Segment to itself, which happens
                // here whenever the two ends of the cross-product land on the same Segment. That pair is simply not a jumper.
                guard let newSrcConnection = newConnections.from, let newDestConnection = newConnections.to else {

                    continue
                }

                equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextStartConnection.segmentID!, connection: newSrcConnection))
                equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextEndConnection.segmentID!, connection: newDestConnection))
                madeCount += 1
            }
        }

        for nextConnection in equivalentConnections {

            guard let nextConnParent = allSegments.first(where: { $0.serialNumber == nextConnection.parent }) else {

                return .failed("equivalent-connection parent \(nextConnection.parent) is not in the model")
            }

            await nextConnParent.AddEquivalentConnections(to: nextConnection.connection, equ: equivalentConnections)
        }

        guard madeCount > 0 else {

            return .failed("no connector was made - both ends resolved to the same Segment")
        }

        return .made(count: madeCount, fromSegment: fromSegment.serialNumber, fromLocation: fromLocation, toSegment: toSegment.serialNumber, toLocation: toLocation)
    }

    /// Whether the two leads of `jumper` are already tied DIRECTLY to each other, ie: whether applying it again would put a
    /// second, identical jumper on top of the first.
    ///
    /// Only a direct connection counts. Two leads at the same potential through a third are a different wiring from two leads
    /// jumpered together, and it is not this routine's business to decide that the third lead makes the jumper redundant.
    static func IsApplied(_ jumper:Jumper, model:PhaseModel) async -> Bool {

        guard case .ok(let fromSegment, let fromLocation) = await FindLead(jumper.from, model: model, acceptTerminated: true),
              case .ok(let toSegment, let toLocation) = await FindLead(jumper.to, model: model, acceptTerminated: true) else {

            return false
        }

        return await fromSegment.ConnectionDestinations(fromLocation: fromLocation).contains(where: { $0.segmentID == toSegment.serialNumber && $0.location == toLocation })
    }

    /// Take a jumper back out, the way `TransformerView.mouseDownWithRemoveConnector` does: find the one connection that IS this
    /// jumper and hand it to `Segment.RemoveConnection`, which sweeps its whole equivalence class - the cross-product copies with it.
    ///
    /// The connection is matched on both segments AND both locations. Matching on the segments alone is not enough: with one disc
    /// per tapping step a double-stacked winding's jumpers share Segments (the crossover above disc 1 and the one above disc 2
    /// both have disc 2 at one end), and taking the first connection that names the far Segment could take the wrong jumper.
    ///
    /// - Returns: false if the jumper is not there to remove.
    @discardableResult
    static func RemoveJumper(_ jumper:Jumper, model:PhaseModel) async -> Bool {

        guard case .ok(let fromSegment, let fromLocation) = await FindLead(jumper.from, model: model, acceptTerminated: true),
              case .ok(let toSegment, let toLocation) = await FindLead(jumper.to, model: model, acceptTerminated: true) else {

            return false
        }

        guard let victim = await fromSegment.connections.first(where: {

            $0.segmentID == toSegment.serialNumber && $0.connector.fromLocation == fromLocation && $0.connector.toLocation == toLocation

        }) else {

            return false
        }

        let affected = await fromSegment.RemoveConnection(segments: model.segments, connection: victim)

        return !affected.isEmpty
    }
}
