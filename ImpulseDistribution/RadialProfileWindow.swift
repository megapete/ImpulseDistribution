//
//  RadialProfileWindow.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-08-13.
//
//  The conductor-to-conductor voltage across the radial build of a sheet or layer winding: one value per gap, innermost gap first,
//  with the paper-impulse allowable drawn across it.
//
//  WHY THIS EXISTS. The two stress-profile windows plot against HEIGHT, because a disc winding's problem is distributed along the
//  coil. A sheet or layer winding's is distributed across it - the turns run out along a radius, not around a disc - so the picture
//  that answers it has a different x axis and a different unit of resolution. Nothing else in the program looks at either winding
//  type this way: DielectricStress.AppendTurnToTurnSites takes `.disc` and skips everything else, so until this window there was no
//  turn-to-turn or layer-to-layer number for a sheet or layer coil anywhere in the report.
//
//  IT IS ONE INSTANT, NOT AN ENVELOPE, and that is the difference from the other two profile windows. The gaps of a sheet winding
//  are a series chain and the layers of a layer winding are one network, so every gap here is driven by the SAME coil voltage - they
//  all peak together, at the instant that coil's terminals are furthest apart. There is no envelope to take. Which instant that is
//  appears in the annotation, and it is the coil's own worst instant rather than the model's: see AppController.WorstInstant for why
//  the difference matters, and for why t = 0+ is one of the candidates.
//
//  WHAT THE SHAPE MEANS is not the same for the two winding types, and the note under the picker says which is on screen:
//
//   - A SHEET winding is a pure series chain, because every turn is a full-height cylinder that completely screens the next from
//     everything outside the coil. What the chain does depends entirely on whether the coil has COOLING DUCTS in it. With none, the
//     only thing that varies is the gap capacitance's growth with radius - C ∝ r makes ΔV ∝ 1/r, so the innermost gap is worst by
//     exactly the ratio of the radii, a gentle and entirely predictable slope of a few per cent. Put an oil duct in a gap and that
//     is swamped: a 6 mm duct beside 0.2 mm of paper has some fifty times the reduced thickness, so it takes some fifty times the
//     volts, and the profile becomes a flat floor with a spike standing on every ducted gap. Both shapes are real and the picture
//     says which one this coil has.
//
//   - A LAYER winding is a solved network and its profile carries real information: how much more than its share the layer at the
//     line end takes at the wavefront. The reference line in the annotation is the textbook figure, twice the volts per layer, which
//     is what a designer reaches for; the whole point of the solve is to say where the coil departs from it.
//
//  The drawing is StressProfileView, shared with the two stress-profile windows so that a reader moving between them is not misled
//  by a change in the furniture. What this window adds to it is the ordinal x axis - see StressProfileView.XAxis.
//

import Cocoa
import PchBasePackage

@MainActor
class RadialProfileWindow:NSWindowController {

    /// One radial gap: between two turns of a sheet winding, or between two layers of a layer winding.
    struct GapPoint {

        /// 0 is the innermost gap. Plotted 1-based, because a designer counts gaps from one.
        let index:Int
        /// The radius at which the gap sits, in metres.
        let radius:Double
        /// The voltage across the gap, in volts.
        let deltaV:Double
        /// The voltage that would put the governing layer exactly at its allowable, in volts, or nil where the gap could not be
        /// evaluated - no insulation in it, or no volts across it.
        let allowableDeltaV:Double?
        /// deltaV / allowableDeltaV. 1.0 means the design margin is exactly used up.
        let utilization:Double
        /// The height at which the worst voltage occurs, in metres. Nil for a sheet winding, where a gap carries the same voltage
        /// over its whole height.
        let worstHeight:Double?
        /// The material carrying the governing field, for the annotation.
        let material:String
        /// Whether this gap holds a cooling duct. A ducted gap and a plain one are not comparable: the duct is some fifty times the
        /// reduced thickness of the insulation beside it, so it takes some fifty times the volts AND is allowed a great deal more,
        /// and the annotation reports the worst of each kind rather than making the reader guess which kind the worst gap was.
        let hasDuct:Bool
    }

    /// The worst pair of axially adjacent turns within one layer of a layer winding, already evaluated against the turn insulation.
    ///
    /// The gaps this window plots are LAYER-to-layer. This is the other site in the same winding, turn-to-turn, and it is not on the
    /// graph because it is not per gap - it is one number for the coil. Nil for a sheet winding, whose plotted gaps already are its
    /// turn-to-turn sites.
    ///
    /// READ AT THE SAME SINGLE INSTANT AS THE GAPS, with the same caveat the header note gives: that instant is the one where this
    /// coil's terminals are furthest apart (t = 0+ is one of the candidates), and it is not necessarily the instant of the steepest
    /// turn-to-turn gradient, which in a real winding lives at the wavefront. It is a reading at a stated instant, not an envelope.
    struct TurnToTurnPoint {

        let deltaV:Double
        /// The voltage that would put the turn paper exactly at its allowable, or nil where it could not be evaluated.
        let allowableDeltaV:Double?
        let utilization:Double
        /// 0 is the innermost layer.
        let layer:Int
        /// Where the pair sits, in metres from the top of the bottom yoke.
        let height:Double
        /// The paper in the gap between the two turns, in metres. This is the TWO-SIDED turn insulation: half of it belongs to each
        /// of the two turns, so the two halves together are exactly one turn's figure.
        let insulation:Double
        let material:String
    }

    /// A sheet winding's gaps under a client's EQUAL-SPACING convention: the build less the copper divided equally over the N − 1
    /// gaps, ducts and all. See Segment.SheetGapCapacitancesEqualSpacing.
    ///
    /// A COMPARISON, NOT A SECOND ANSWER. It is drawn beside the placed-duct profile because some clients specify their turn-to-turn
    /// voltages this way, and it is driven by the same coil voltage at the same instant, so the two curves differ ONLY in how the
    /// ducts are treated. The placed-duct curve is the physics; this one is the convention. Neither the stress report nor Cs sees it.
    struct EqualSpacingComparison {

        /// The common spacing between turns, in metres.
        let spacing:Double
        /// The voltage across each gap, innermost first, in volts - gap for gap with Contents.points.
        let deltaV:[Double]
        /// The largest of those, and its 0-based gap index.
        let worstIndex:Int
        let worstDeltaV:Double
        /// The worst ΔV evaluated across the insulation that is REALLY between two turns where there is no duct - the plain gap of
        /// the placed-duct model - since the equal spacing s is a notional dimension with oil smeared into it and has no material
        /// that could be judged. Nil where there is no plain gap or it could not be evaluated.
        let allowableDeltaV:Double?
        let utilization:Double
        let material:String
    }

    /// Everything one of these windows draws. Built by AppController.BuildRadialProfile, so that the menu command and the scripted
    /// self-test produce the same window from the same numbers.
    struct Contents {

        let coil:Int
        let isSheet:Bool
        /// Innermost gap first.
        let points:[GapPoint]
        /// The worst gap over the reference below, or nil where there is no reference to be over - a coil grounded at both ends
        /// has none, and still has voltage across its gaps.
        let enhancement:Double?
        /// What a simple assumption gives for every gap, in volts - an even division for a sheet winding, twice the volts per layer
        /// for a layer one.
        let reference:Double
        /// How many of the gaps hold a cooling duct. Nothing else about the picture changes as much: a ducted gap carries some
        /// fifty times the volts of a gap holding only turn insulation, so the note under the graph says which shape is on screen.
        let ductedGapCount:Int
        /// The classical alpha/tanh(alpha) line-end gradient from the coil's lumped Cs and Cg, for a layer winding. Nil for a
        /// sheet winding, whose model is a closed-form series chain with no alpha in it at all.
        ///
        /// NOTE THAT ITS BASIS IS NOT THIS MODEL'S. Cs comes through CoilSeriesCapacitance and so through LayerToLayerCapacitance,
        /// which still SPREADS the ducts evenly over the gaps rather than placing them. The two therefore describe slightly
        /// different windings, and on a ducted coil they no longer have to agree closely - see TODO.md.
        let screenEstimate:Double?
        /// The worst turn-to-turn pair of a layer winding. Nil for a sheet winding.
        let turnToTurn:TurnToTurnPoint?
        /// Rows for the annotation block, as (label, value) pairs.
        let notes:[(label:String, value:String)]
        /// The equal-spacing comparison, for a sheet winding. Nil for a layer winding, and for a sheet winding whose spacing could
        /// not be formed.
        var equalSpacing:EqualSpacingComparison? = nil
    }

    private let points:[GapPoint]
    private let isSheet:Bool
    private let enhancement:Double?
    private let reference:Double
    private let screenEstimate:Double?
    private let ductedGapCount:Int
    private let turnToTurn:TurnToTurnPoint?
    private let notes:[(label:String, value:String)]
    private let equalSpacing:EqualSpacingComparison?
    private let peakTestVoltage:Double

    private let graphView = StressProfileView()
    private let noteLabel = NSTextField(labelWithString: "")

    init(contents:Contents, peakTestVoltage:Double) {

        self.points = contents.points.sorted { $0.index < $1.index }
        self.isSheet = contents.isSheet
        self.enhancement = contents.enhancement
        self.reference = contents.reference
        self.screenEstimate = contents.screenEstimate
        self.ductedGapCount = contents.ductedGapCount
        self.turnToTurn = contents.turnToTurn
        self.notes = contents.notes
        self.equalSpacing = contents.equalSpacing
        self.peakTestVoltage = peakTestVoltage

        let coil = contents.coil
        let isSheet = contents.isSheet

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Radial Voltage Profile — coil \(coil), \(isSheet ? "sheet" : "layer") winding"
        window.contentMinSize = NSSize(width: 520.0, height: 360.0)

        super.init(window: window)

        BuildContent()
        ShowProfile()

        window.center()
    }

    required init?(coder: NSCoder) {

        fatalError("init(coder:) has not been implemented")
    }

    private func BuildContent() {

        guard let window = self.window else {

            return
        }

        let contentView = NSView()

        noteLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = NSColor.secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 0
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        graphView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(noteLabel)
        contentView.addSubview(graphView)

        NSLayoutConstraint.activate([

            noteLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            noteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            graphView.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            graphView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            graphView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            graphView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        window.contentView = contentView
    }

    /// A voltage for the annotation block.
    ///
    /// %.1f everywhere would be tidier, but a coil grounded at both ends has a few NANOVOLTS across it rather than exactly zero,
    /// and its gaps still carry a real distribution driven by the coil beside it. Printing those as "0.0 V" next to a perfectly
    /// good enhancement ratio reads as a broken number. Anything below a volt therefore goes to scientific notation, where it is
    /// obviously negligible rather than obviously wrong.
    static func Volts(_ value:Double) -> String {

        return abs(value) >= 1.0 ? String(format: "%.1f V", value) : String(format: "%.3g V", value)
    }

    /// The worst gap of a group, by UTILIZATION rather than by raw volts - the same ranking the report table uses, and for the same
    /// reason: a gap with a duct in it is allowed a great deal more than one with only paper, so the largest ΔV is not reliably the
    /// gap in trouble. Where nothing in the group could be evaluated there is no utilization to rank on and the volts are all there
    /// is, which is better than silently returning whichever gap happened to be last.
    private static func WorstOf(_ group:[GapPoint]) -> GapPoint? {

        guard group.contains(where: { $0.utilization > 0.0 }) else {

            return group.max { $0.deltaV < $1.deltaV }
        }

        return group.max { $0.utilization < $1.utilization }
    }

    private func ShowProfile() {

        // WHICH GAP IS WORST HAS TWO ANSWERS ON A DUCTED WINDING, and reporting only one of them is what this block exists to avoid.
        // The gap carrying the most VOLTS is the spike on the graph, and it is a ducted gap wherever the coil has one: an oil duct is
        // some fifty times the reduced thickness of the paper beside it, so it takes some fifty times the volts. The gap nearest its
        // ALLOWABLE is the one the design turns on, and it is usually a gap with no duct in it, because the duct is allowed most of
        // what it takes. Neither number answers the other's question, so both are reported, each against its own kind, and the one
        // that governs is marked. On a winding with no duct there is only one kind and only one block.
        let ducted = points.filter { $0.hasDuct }
        let plain = points.filter { !$0.hasDuct }
        let worstDucted = RadialProfileWindow.WorstOf(ducted)
        let worstPlain = RadialProfileWindow.WorstOf(plain)
        let split = worstDucted != nil && worstPlain != nil
        let governing = [worstPlain, worstDucted].compactMap { $0 }.max { $0.utilization < $1.utilization }

        var annotation = notes

        /// One gap as two rows: where it is and what it carries, then what that is against its allowable.
        func Describe(_ gap:GapPoint, label:String) {

            var summary = "\(gap.index + 1) of \(points.count), at r = \(String(format: "%.1f mm", gap.radius * 1000.0)) — ΔV \(RadialProfileWindow.Volts(gap.deltaV))"

            if let height = gap.worstHeight {

                summary += String(format: ", at height %.0f mm", height * 1000.0)
            }

            annotation.append((label: label, value: summary))

            guard let allowable = gap.allowableDeltaV else {

                annotation.append((label: "Utilization:", value: "not evaluated — no insulation in the gap, or no volts across it"))
                return
            }

            // Turn-to-turn in a sheet or layer winding is normally a small fraction of what the paper withstands, which puts the
            // allowable far off the top of a y axis scaled to the data - see StressProfileView's note on allowableScaleLimit. Say
            // so, so that a reader does not go looking for a dashed line that is not there.
            let offScale = allowable > StressProfileView.allowableScaleLimit * gap.deltaV
            var reading = String(format: "%.1f%% of %@ allowable (%@)", gap.utilization * 100.0, RadialProfileWindow.Volts(allowable), gap.material)

            if offScale {

                reading += " — off scale"
            }

            // Only worth saying where there are two kinds to choose between.
            if split, gap.index == governing?.index {

                reading += " — governs"
            }

            annotation.append((label: "Utilization:", value: reading))
        }

        if let worstPlain {

            Describe(worstPlain, label: split ? "Worst gap (no duct):" : "Worst gap:")
        }

        if let worstDucted {

            Describe(worstDucted, label: split ? "Worst gap (with duct):" : "Worst gap:")
        }

        // The turn-to-turn site, which is not on the graph because it is one number for the coil rather than one per gap. It is the
        // other thing a layer winding has to withstand and it is nowhere else in the program - AppendTurnToTurnSites takes .disc and
        // skips everything else.
        if let turnToTurn {

            annotation.append((label: "Worst turn-to-turn:", value: String(format: "%@ in layer %d, at height %.0f mm, across %.2f mm of paper",
                                                                           RadialProfileWindow.Volts(turnToTurn.deltaV),
                                                                           turnToTurn.layer + 1,
                                                                           turnToTurn.height * 1000.0,
                                                                           turnToTurn.insulation * 1000.0)))

            if let allowable = turnToTurn.allowableDeltaV {

                annotation.append((label: "Utilization:", value: String(format: "%.1f%% of %@ allowable (%@)",
                                                                        turnToTurn.utilization * 100.0,
                                                                        RadialProfileWindow.Volts(allowable),
                                                                        turnToTurn.material)))
            }
        }

        // The client's equal-spacing convention, beside the placed-duct answer rather than instead of it. Its utilization is taken
        // across the REAL plain-gap paper - the dimension s it was divided with has oil smeared into it and no material to judge.
        if let equalSpacing {

            annotation.append((label: "Equal spacing (blue):", value: String(format: "%.3f mm between every pair of turns, ducts smeared in", equalSpacing.spacing * 1000.0)))
            annotation.append((label: "  Worst gap:", value: String(format: "%d of %d — ΔV %@", equalSpacing.worstIndex + 1, equalSpacing.deltaV.count, RadialProfileWindow.Volts(equalSpacing.worstDeltaV))))

            if let allowable = equalSpacing.allowableDeltaV {

                annotation.append((label: "  Utilization:", value: String(format: "%.1f%% of %@ allowable (%@), across the real plain-gap paper",
                                                                          equalSpacing.utilization * 100.0,
                                                                          RadialProfileWindow.Volts(allowable),
                                                                          equalSpacing.material)))
            }
        }

        if !points.isEmpty {

            // The largest ΔV anywhere in the winding against the simple assumption - so on a ducted coil this is the ducted gap's
            // number, whichever gap governs. That is the comparison the reference exists for: it asks how far the real distribution
            // departs from an even one, not how close anything is to breaking down.
            if let enhancement {

                annotation.append((label: "Peak ΔV over reference:", value: String(format: "%.2fx", enhancement)))
            }
            else {

                // A coil grounded at both ends. Its gaps still carry voltage - the winding beside it drives them capacitively -
                // but there is no terminal voltage to measure them against, and saying so beats printing 1.00x.
                annotation.append((label: "Peak ΔV over reference:", value: "n/a — the coil has no voltage across its terminals"))
            }

            if let screenEstimate {

                annotation.append((label: "alpha screen:", value: String(format: "%.2fx (alpha/tanh alpha, from lumped Cs and Cg)", screenEstimate)))
            }
        }

        graphView.plot = StressProfileView.Plot(points: points.map { StressProfileView.Point(z: Double($0.index + 1),
                                                                                            value: $0.deltaV,
                                                                                            allowable: $0.allowableDeltaV,
                                                                                            utilization: $0.utilization) },
                                                quantity: .voltage,
                                                peakTestVoltage: peakTestVoltage,
                                                annotation: annotation,
                                                markers: [],
                                                markerName: "",
                                                xAxis: .ordinal(title: isSheet ? "Gap between turns, counted outwards from the inside" : "Gap between layers, counted outwards from the inside"),
                                                allowableMayGoOffScale: true,
                                                comparison: equalSpacing.map { comparison in

                                                    comparison.deltaV.enumerated().map { StressProfileView.Point(z: Double($0.offset + 1), value: $0.element, allowable: nil, utilization: 0.0) }
                                                } ?? [])

        if isSheet {

            var note = "Sheet winding: a series chain. Every turn is a full-height cylinder and screens the next completely, so no interior turn has a capacitance to anything outside the coil and the neighbouring coil cannot perturb the distribution — it attaches only to the two driven end turns. One instant: every gap is driven by the same coil voltage, so they all peak together."

            if ductedGapCount > 0 {

                note += " The spikes are the COOLING DUCTS. An oil duct is some fifty times the reduced thickness of the turn insulation beside it, so it takes some fifty times the volts, and it swamps the gentle 1/r slope that the radius alone would produce. Duct positions are a spacing rule, not a reading — the design file gives a count and a size only."
            }
            else {

                note += " With no duct in the winding the only thing that varies is the gap capacitance's growth with radius (C ∝ r, so ΔV ∝ 1/r), which makes the innermost gap the worst by exactly the ratio of the radii."
            }

            if equalSpacing != nil {

                note += " The BLUE curve is the equal-spacing convention some clients specify: ID to OD less the copper, divided equally over the N − 1 gaps, so every duct is smeared into every gap. Same coil voltage, same instant — the curves differ only in how the ducts are treated. The red curve is the physics."
            }

            noteLabel.stringValue = note
        }
        else {

            noteLabel.stringValue = "Layer winding: solved as a turn-level capacitive network at the stated instant — turn-to-turn along each layer, layer-to-layer between them, and out of the innermost and outermost layers to the neighbouring coils at their own potentials. Every layer is assumed to hold the same number of turns — N/L, fractions included, so the layers step axially as the boundary walks through a turn — and the cooling ducts are placed at evenly spaced gaps; the design file gives counts and sizes but neither per-layer turns nor duct positions, so both are rules rather than readings. A ducted gap has a much lower layer-to-layer capacitance and so carries much more voltage — and is allowed a great deal more of it — so the worst gap WITH a duct and the worst gap WITHOUT one are reported separately, and the one nearer its allowable is marked as governing. The last pair of rows is a different site again: the worst two axially adjacent turns within a layer, across one turn's own paper. The reference is the textbook figure, twice the volts per layer."
        }
    }
}
