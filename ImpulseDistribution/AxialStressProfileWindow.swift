//
//  AxialStressProfileWindow.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-08-11.
//
//  The disc-to-disc stress profile of one coil: stress against height, with the allowable drawn across it.
//
//  This is the picture a disc winding is actually designed against. The ranked table says which gap is worst and the radial
//  profiles say what is happening between coils; this says how the axial stress is distributed along one coil - where the impulse
//  piles up, how fast it decays into the winding, and how much room is left under the allowable everywhere else.
//
//  IT IS AN ENVELOPE, exactly as StressProfileWindow's curves are: each point is the worst that gap saw at any instant of the run,
//  not one frame of the transient. The gaps do not peak together (the ones near the line end peak at t = 0+, the ones deep in the
//  winding peak later), so no single instant is the profile.
//
//  THE POINTS ARE PER GAP, AND THE LINE BETWEEN THEM IS INTERPOLATION. There is one value per disc-to-disc gap - that is the
//  resolution the node network has - plotted at the middle of its own gap and joined by straight lines. The line is drawn because
//  a profile reads as a shape and a scatter of dots does not; it is not evidence of anything between two gaps.
//
//  WHY THE ALLOWABLE IS A CURVE AND NOT A CONSTANT. It is drawn as its own series rather than as a single horizontal rule, and in
//  the ordinary case - one duct size and one paper thickness the length of the coil - every point of it is the same and it draws
//  as the horizontal line it is expected to be. But a coil with a widened duct at a tapping gap, or a gap facing a static ring
//  rather than another disc, genuinely has a different allowable there (the allowable falls with the governing layer's own
//  thickness - see docs/dielectric-stress.md), and a single rule drawn at the smallest of them would understate the margin
//  everywhere else. Where it does vary, the annotation says so out loud.
//
//  Both curves come from the SAME findings as the table and the radial graphs - AppController.StressChecks() - so the three can
//  never disagree about a model. Nothing is recomputed here: the allowable at a point is recovered from the check itself as
//  averageField / averageUtilization, and the allowable ΔV as deltaV / averageUtilization. Both are exact rather than a second
//  evaluation of the allowable, because the field is LINEAR in the driving voltage (the property DielectricStress.Scan is built
//  on): scaling ΔV by 1/utilization is precisely the ΔV that would put the governing layer at its allowable.
//
//  The drawing is StressProfileView, which this window shares with StressProfileWindow's radial profiles - see the header of that
//  file for why it is not CoilResultsDisplayView. This file's job is the physics: which findings belong to which coil, what the
//  allowable at a point is, and what the annotation says.
//

import Cocoa
import PchBasePackage

@MainActor
class AxialStressProfileWindow:NSWindowController {

    /// One coil's profile.
    struct Profile {

        let name:String
        /// Sorted by height. Heights in metres, stresses in V/m, voltages in volts.
        let points:[Point]

        /// The worst gap in this coil - the point the annotation is about. Chosen by UTILIZATION, not by raw stress: a gap whose
        /// allowable is lower (a wider duct, or one facing a static ring) can be the one in trouble at a lower field, which is the
        /// same argument the table's ranking rests on.
        var worst:Point? {

            return points.max { $0.utilization < $1.utilization }
        }

        /// True where every gap in the coil has the same allowable, which is the ordinary case and the one in which the allowable
        /// really is a horizontal line.
        var allowableIsConstant:Bool {

            guard let first = points.first else { return true }

            return points.allSatisfy { abs($0.allowableStress - first.allowableStress) <= 1.0E-9 * max(1.0, first.allowableStress) }
        }
    }

    /// One gap.
    struct Point {

        /// The middle of the gap, in metres from the bottom yoke.
        let z:Double
        /// The average field in the governing layer, V/m.
        let stress:Double
        /// What that layer is allowed, V/m, with the design margin applied.
        let allowableStress:Double
        /// The driving voltage across the gap at its worst instant, in volts.
        let deltaV:Double
        /// The driving voltage that would put the governing layer exactly at its allowable, in volts.
        let allowableDeltaV:Double
        /// stress / allowableStress. 1.0 means the design margin is exactly used up.
        let utilization:Double
    }

    private let profiles:[Profile]
    /// The design file's name, for the saved workbook. Nil where the model did not come from a file.
    private let designName:String?

    private let graphView = StressProfileView()
    private let profilePicker = NSPopUpButton()
    private let noteLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save as Excel…", target: nil, action: nil)

    /// - Returns: nil if the findings hold no disc-to-disc gaps at all, which is what a model with no disc windings looks like.
    init?(checks:[DielectricStress.StressCheck], title:String, designName:String? = nil) {

        var grouped:[String:[DielectricStress.StressCheck]] = [:]

        for check in checks {

            // The axial half of the profile metadata. Turn-to-turn checks are not gaps between discs and carry no height, and the
            // radial checks belong to the other graph - see StressCheckKind.isRadial.
            guard check.kind == .discToDisc, let name = check.profileName, check.profileHeight != nil else {

                continue
            }

            grouped[name, default: []].append(check)
        }

        guard !grouped.isEmpty else {

            return nil
        }

        var built:[Profile] = []

        for (name, group) in grouped {

            let points:[Point] = group.sorted { ($0.profileHeight ?? 0.0) < ($1.profileHeight ?? 0.0) }.compactMap { check in

                // A utilization of zero would mean a field of zero, which Evaluate cannot produce (it refuses a site with no
                // volts across it), but the division below is not worth risking on that.
                guard let z = check.profileHeight, check.averageUtilization > 0.0 else {

                    return nil
                }

                return Point(z: z,
                             stress: check.averageField,
                             allowableStress: check.averageField / check.averageUtilization,
                             deltaV: abs(check.deltaV),
                             allowableDeltaV: abs(check.deltaV) / check.averageUtilization,
                             utilization: check.averageUtilization)
            }

            guard !points.isEmpty else {

                continue
            }

            built.append(Profile(name: name, points: points))
        }

        guard !built.isEmpty else {

            return nil
        }

        built.sort { $0.name < $1.name }

        self.profiles = built
        self.designName = designName

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentMinSize = NSSize(width: 520.0, height: 360.0)

        super.init(window: window)

        BuildContent()

        // Open on the coil with the worst gap in it, not on the first one alphabetically. The picker stays in name order, which is
        // predictable to scroll through, but the first thing shown should be the coil the designer has to do something about -
        // the same worst-first discipline the report table is ranked on.
        let worstCoil = built.indices.max { (built[$0].worst?.utilization ?? 0.0) < (built[$1].worst?.utilization ?? 0.0) } ?? 0

        profilePicker.selectItem(at: worstCoil)
        ShowProfile(at: worstCoil)

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

        profilePicker.translatesAutoresizingMaskIntoConstraints = false
        profilePicker.addItems(withTitles: profiles.map { $0.name })
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged(_:))

        noteLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = NSColor.secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 0
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        graphView.translatesAutoresizingMaskIntoConstraints = false

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(handleSaveAsExcel(_:))
        saveButton.toolTip = "Save every coil's profile - the numbers and a chart of each - as an Excel workbook"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(profilePicker)
        contentView.addSubview(noteLabel)
        contentView.addSubview(graphView)
        contentView.addSubview(saveButton)

        NSLayoutConstraint.activate([

            profilePicker.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            profilePicker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            profilePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            noteLabel.topAnchor.constraint(equalTo: profilePicker.bottomAnchor, constant: 8),
            noteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            graphView.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            graphView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            graphView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            graphView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -8),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        window.contentView = contentView
    }

    @objc private func profileChanged(_ sender:Any) {

        ShowProfile(at: profilePicker.indexOfSelectedItem)
    }

    private func ShowProfile(at index:Int) {

        guard index >= 0, index < profiles.count else {

            return
        }

        let profile = profiles[index]

        graphView.plot = StressProfileView.Plot(points: profile.points.map { StressProfileView.Point(z: $0.z, value: $0.stress, allowable: $0.allowableStress, utilization: $0.utilization) },
                                                quantity: .stress,
                                                peakTestVoltage: 0.0,
                                                annotation: AxialStressProfileWindow.Annotation(for: profile),
                                                markers: [],
                                                markerName: "")

        noteLabel.stringValue = AxialStressProfileWindow.Note(for: profile)
    }

    /// The annotation block's rows, which the saved workbook repeats word for word.
    ///
    /// kV/mm throughout, matching the y axis and every allowable in DielectricStress. Two units in one window is how a stress gets
    /// misread by a factor of a thousand - see the unit note in AxisScale.UnitScale.
    private static func Annotation(for profile:Profile) -> [(label:String, value:String)] {

        guard let worst = profile.worst else {

            return []
        }

        return [(label: "Maximum stress:", value: String(format: "%.2f kV/mm", worst.stress / 1.0E6)),
                (label: "At height:", value: String(format: "%.0f mm", worst.z * 1000.0)),
                (label: "ΔV there:", value: String(format: "%.2f kV", worst.deltaV / 1000.0)),
                (label: "Allowable ΔV there:", value: String(format: "%.2f kV  (at %.2f kV/mm)", worst.allowableDeltaV / 1000.0, worst.allowableStress / 1.0E6)),
                (label: "Utilization:", value: String(format: "%.0f%% of allowable", worst.utilization * 100.0))]
    }

    private static func Note(for profile:Profile) -> String {

        var note = "Envelope: the worst disc-to-disc stress each gap saw at any instant of the run, one point per gap, joined by straight lines. Allowables are DelVecchio ch. 13 impulse breakdown levels at the governing layer's own thickness, times the design margin set in Preferences."

        if !profile.allowableIsConstant {

            note += " The allowable is not the same the length of this coil — where the gap or its insulation changes, so does what that gap is allowed — so it is drawn as a curve rather than as one rule."
        }

        return note
    }

    @objc private func handleSaveAsExcel(_ sender:Any) {

        guard let window = self.window else {

            return
        }

        ProfileWorkbook.Save(self, from: window)
    }
}

// MARK: Saving as Excel

extension AxialStressProfileWindow:ProfileWorkbookSource {

    /// One sheet per coil: the gaps as a table, and the window's graph redrawn from it as an Excel chart.
    ///
    /// Every coil rather than only the one on screen - the picker is how the window shows more than one coil at a time, and a
    /// workbook has tabs for that. It opens on the coil that is on screen.
    func WorkbookSheets() -> [ProfileWorkbook.Sheet] {

        return profiles.map { profile in

            let points = profile.points
            let range = ProfileWorkbook.HeightRange(points.map { $0.z })

            let columns = [ProfileWorkbook.Column(heading: "Height above bottom yoke (mm)", decimals: 1, values: points.map { .number($0.z * 1000.0) }),
                           ProfileWorkbook.Column(heading: "Average stress (kV/mm)", decimals: 3, values: points.map { .number($0.stress / 1.0E6) }),
                           ProfileWorkbook.Column(heading: "Allowable stress (kV/mm)", decimals: 3, values: points.map { .number($0.allowableStress / 1.0E6) }),
                           ProfileWorkbook.Column(heading: "ΔV across gap (kV)", decimals: 2, values: points.map { .number($0.deltaV / 1000.0) }),
                           ProfileWorkbook.Column(heading: "Allowable ΔV (kV)", decimals: 2, values: points.map { .number($0.allowableDeltaV / 1000.0) }),
                           ProfileWorkbook.Column(heading: "Utilization (%)", decimals: 1, values: points.map { .number($0.utilization * 100.0) })]

            var series = [ProfileWorkbook.Series(name: "Average stress", source: .columns(x: 0, y: 1), look: .line(color: ProfileWorkbook.Colour.value, width: 1.5, dashed: false)),
                          ProfileWorkbook.Series(name: "Allowable", source: .columns(x: 0, y: 2), look: .line(color: ProfileWorkbook.Colour.allowable, width: 1.5, dashed: true))]

            if let worst = profile.worst {

                series.append(ProfileWorkbook.Series(name: "Worst gap", source: .points([ProfileWorkbook.XY(x: worst.z * 1000.0, y: worst.stress / 1.0E6)]), look: .dot(color: ProfileWorkbook.Colour.value), inLegend: false))
            }

            let chart = ProfileWorkbook.Chart(title: "Disc-to-disc stress — \(profile.name)",
                                              xTitle: "Height above bottom yoke (mm)",
                                              yTitle: "Average stress (kV/mm)",
                                              xMinimum: range?.minimum,
                                              xMaximum: range?.maximum,
                                              xMajorUnit: 100.0,
                                              series: series)

            let info = ProfileWorkbook.StandardInfo(designName: designName)
                     + ProfileWorkbook.Info(AxialStressProfileWindow.Annotation(for: profile))
                     + [ProfileWorkbook.InfoRow(label: "Note:", value: AxialStressProfileWindow.Note(for: profile))]

            return ProfileWorkbook.Sheet(name: profile.name,
                                         title: "Disc-to-Disc Stress vs. Height — \(profile.name)",
                                         info: info,
                                         columns: columns,
                                         charts: [chart])
        }
    }

    var workbookActiveSheet:Int { profilePicker.indexOfSelectedItem }

    var workbookFileName:String { [designName, "Axial Stress Profiles"].compactMap { $0 }.joined(separator: " ") }
}
