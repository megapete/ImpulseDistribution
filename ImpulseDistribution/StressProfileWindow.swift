//
//  StressProfileWindow.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-08-05.
//
//  Voltage-difference-versus-height profiles for the radial checks of the dielectric stress screen.
//
//  This is the picture that answers the unequal-height coil problem: when a tapping winding sits outside a main winding and is not
//  the same height, the radial voltage difference between them is not remotely uniform, and the worst of it is at the short coil's
//  end. A ranked table says which height is worst; this says why, by showing the whole profile with the coil ends marked.
//
//  It plots an ENVELOPE, not an instant. Each point is the largest radial difference that height saw at any time in the run, so one
//  curve covers the whole transient. An animation over time was considered and rejected: the radial peak at one height and the peak
//  at another happen at different instants, so no single frame of an animation shows the thing being looked for.
//
//  The plotting is StressProfileView, shared with AxialStressProfileWindow: same axes, same dashed allowable, same annotation
//  block, so the radial picture and the axial one can be read side by side without a difference in the FURNITURE being taken for a
//  difference in the data. It used to draw into CoilResultsDisplayView, whose x axis carries only end labels ("bottom"/"top") and
//  which has no second series - so this graph could show where the worst height was but not what it was allowed there.
//
//  EITHER QUANTITY IS JUDGED AGAINST ITS OWN ALLOWABLE. Voltage difference is compared with the ΔV that would put the governing
//  layer at its limit, average stress with the limit itself; both come out of the finding as a division by its utilization (see
//  the header of StressProfileView), so the two views of the same profile carry the same margin and cannot disagree about it.
//

import Cocoa
import PchBasePackage

@MainActor
class StressProfileWindow:NSWindowController {

    /// One profile: a named series of points against height.
    struct Profile {

        let name:String
        /// Sorted by height. Height in metres, voltages in volts, fields in V/m.
        let points:[Point]
        /// The heights at which the screen flagged that a coil ends, where the field stops being one-dimensional.
        let endMarkers:[Double]

        /// The point the annotation is about, chosen by UTILIZATION rather than by raw value - the hilo stack varies from coil
        /// pair to coil pair, so neither the largest voltage difference nor the largest field is reliably the worst place.
        var worst:Point? {

            return points.max { $0.utilization < $1.utilization }
        }
    }

    /// One sampled height.
    struct Point {

        let z:Double
        /// The radial voltage difference at this height at its worst instant, in volts.
        let deltaV:Double
        /// The difference that would put the governing layer exactly at its allowable, in volts.
        let allowableDeltaV:Double
        /// The average field in the governing layer, V/m.
        let averageField:Double
        /// What that layer is allowed, V/m, with the design margin applied.
        let allowableField:Double
        /// averageField / allowableField, which is also deltaV / allowableDeltaV.
        let utilization:Double
    }

    /// What the y axis shows. Both are worth having: the voltage difference is what a designer reads directly and compares against
    /// a withstand level, while the stress is what the insulation actually cares about and is not proportional to it - the hilo
    /// stack varies from coil pair to coil pair, so the largest voltage difference is not always the worst stress.
    private enum Quantity:Int {

        case voltageDifference
        case averageStress
    }

    private let profiles:[Profile]
    private let peakTestVoltage:Double
    /// The design file's name, for the saved workbook. Nil where the model did not come from a file.
    private let designName:String?

    private let graphView = StressProfileView()
    private let profilePicker = NSPopUpButton()
    private let quantityPicker = NSPopUpButton()
    private let noteLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save as Excel…", target: nil, action: nil)

    init?(checks:[DielectricStress.StressCheck], peakTestVoltage:Double, title:String, designName:String? = nil) {

        // Assemble the profiles from the SAME findings the table shows, so the two can never disagree.
        var grouped:[String:[DielectricStress.StressCheck]] = [:]

        for check in checks {

            // RADIAL checks only. The disc-to-disc sites carry a profile name and a height as well, for the axial graph
            // (AxialStressProfileWindow); without this filter they would appear in this window's picker, under a y axis whose
            // note calls them radial.
            guard check.kind.isRadial, let name = check.profileName, check.profileHeight != nil else {

                continue
            }

            grouped[name, default: []].append(check)
        }

        guard !grouped.isEmpty else {

            return nil
        }

        var built:[Profile] = []

        for (name, group) in grouped {

            let sorted = group.sorted { ($0.profileHeight ?? 0.0) < ($1.profileHeight ?? 0.0) }

            // The allowables are recovered from the finding, not evaluated a second time: dividing by the utilization is exact,
            // because the field is linear in the driving voltage. See the header of StressProfileView.
            let points:[Point] = sorted.compactMap { check in

                guard let z = check.profileHeight, check.averageUtilization > 0.0 else {

                    return nil
                }

                return Point(z: z,
                             deltaV: abs(check.deltaV),
                             allowableDeltaV: abs(check.deltaV) / check.averageUtilization,
                             averageField: check.averageField,
                             allowableField: check.averageField / check.averageUtilization,
                             utilization: check.averageUtilization)
            }

            guard !points.isEmpty else {

                continue
            }

            // A location string carrying the beyond-the-end note is where the inner coil stops.
            let markers = sorted.filter { $0.location.contains("beyond end of") }.compactMap { $0.profileHeight }

            built.append(Profile(name: name, points: points, endMarkers: markers))
        }

        built.sort { $0.name < $1.name }

        self.profiles = built
        self.peakTestVoltage = peakTestVoltage
        self.designName = designName

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.setFrameAutosaveName("StressProfileWindow")

        super.init(window: window)

        BuildContent()

        // Open on the coil pair with the worst point in it, not on the first one alphabetically - the same worst-first discipline
        // the report table is ranked on, and the same choice AxialStressProfileWindow makes.
        let worstProfile = built.indices.max { (built[$0].worst?.utilization ?? 0.0) < (built[$1].worst?.utilization ?? 0.0) } ?? 0

        profilePicker.selectItem(at: worstProfile)
        ShowProfile(at: worstProfile)
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

        quantityPicker.translatesAutoresizingMaskIntoConstraints = false
        quantityPicker.addItems(withTitles: ["Voltage difference", "Average stress"])
        quantityPicker.target = self
        quantityPicker.action = #selector(profileChanged(_:))

        noteLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = NSColor.secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        // No line limit, and low compression resistance: the note now grows a clause when the allowable varies, and a label pinned
        // to both edges of the content view otherwise sets the window's minimum width to its whole string. See StressReportWindow.
        noteLabel.maximumNumberOfLines = 0
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        graphView.translatesAutoresizingMaskIntoConstraints = false

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(handleSaveAsExcel(_:))
        saveButton.toolTip = "Save every profile - the numbers, and a chart of both the voltage difference and the stress - as an Excel workbook"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(profilePicker)
        contentView.addSubview(quantityPicker)
        contentView.addSubview(noteLabel)
        contentView.addSubview(graphView)
        contentView.addSubview(saveButton)

        NSLayoutConstraint.activate([

            profilePicker.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            profilePicker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            profilePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            quantityPicker.centerYAnchor.constraint(equalTo: profilePicker.centerYAnchor),
            quantityPicker.leadingAnchor.constraint(equalTo: profilePicker.trailingAnchor, constant: 12),
            quantityPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),

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

        guard !profile.points.isEmpty else {

            return
        }

        let quantity = Quantity(rawValue: quantityPicker.indexOfSelectedItem) ?? .voltageDifference
        let showingVolts = quantity == .voltageDifference

        // The two views of one profile differ only in which pair of numbers is plotted; the heights, the marked coil ends and the
        // point picked as worst are the same either way, so switching the picker cannot move the worst place.
        let points = profile.points.map {

            StressProfileView.Point(z: $0.z,
                                    value: showingVolts ? $0.deltaV : $0.averageField,
                                    allowable: showingVolts ? $0.allowableDeltaV : $0.allowableField,
                                    utilization: $0.utilization)
        }

        // peakTestVoltage sets the major-tick interval of a voltage axis only - a stress axis is always labelled in kV/mm.
        graphView.plot = StressProfileView.Plot(points: points,
                                                quantity: showingVolts ? .voltage : .stress,
                                                peakTestVoltage: showingVolts ? peakTestVoltage : 0.0,
                                                annotation: StressProfileWindow.Annotation(for: profile, showingVolts: showingVolts),
                                                markers: profile.endMarkers,
                                                markerName: "inner coil ends")

        noteLabel.stringValue = StressProfileWindow.Note(for: profile, what: showingVolts ? "radial voltage difference" : "average radial stress")
    }

    /// The annotation block's rows, which the saved workbook repeats word for word (the voltage version, whose rows carry the
    /// stress as well).
    private static func Annotation(for profile:Profile, showingVolts:Bool) -> [(label:String, value:String)] {

        var annotation:[(label:String, value:String)] = []

        if let worst = profile.worst {

            // The third row carries whichever quantity is NOT being plotted, so the block says something new on every line: with
            // volts on the axis it is the stress there, and with stress on the axis it is the ΔV.
            annotation = [(label: showingVolts ? "Maximum ΔV:" : "Maximum stress:",
                           value: showingVolts ? String(format: "%.2f kV", worst.deltaV / 1000.0) : String(format: "%.2f kV/mm", worst.averageField / 1.0E6)),
                          (label: "At height:", value: String(format: "%.0f mm", worst.z * 1000.0)),
                          (label: showingVolts ? "Stress there:" : "ΔV there:",
                           value: showingVolts ? String(format: "%.2f kV/mm", worst.averageField / 1.0E6) : String(format: "%.2f kV", worst.deltaV / 1000.0)),
                          (label: "Allowable ΔV there:", value: String(format: "%.2f kV  (at %.2f kV/mm)", worst.allowableDeltaV / 1000.0, worst.allowableField / 1.0E6)),
                          (label: "Utilization:", value: String(format: "%.0f%% of allowable", worst.utilization * 100.0))]
        }

        return annotation
    }

    /// The note under the pickers. `what` names the quantity on the y axis.
    private static func Note(for profile:Profile, what:String) -> String {

        var note = "Envelope: the largest \(what) each height saw at any time during the run, against what that height is allowed."

        if !profile.endMarkers.isEmpty {

            let heights = profile.endMarkers.map { String(format: "%.0f", $0 * 1000.0) }.joined(separator: ", ")
            note += " The inner coil ends near \(heights) mm (marked) — beyond that the field is genuinely two-dimensional and the plotted value is indicative only."
        }

        let allowables = profile.points.map { $0.allowableField }

        if let first = allowables.first, !allowables.allSatisfy({ abs($0 - first) <= 1.0E-9 * max(1.0, first) }) {

            note += " The allowable varies over this profile — the layer thickness governing it is not the same at every height — so it is drawn as a curve rather than as one rule."
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

extension StressProfileWindow:ProfileWorkbookSource {

    /// One sheet per profile, with BOTH of the window's graphs on it - the voltage difference and the stress - since the table
    /// carries both and the quantity picker is only how the window fits them into one plot.
    func WorkbookSheets() -> [ProfileWorkbook.Sheet] {

        return profiles.map { profile in

            let points = profile.points
            let range = ProfileWorkbook.HeightRange(points.map { $0.z })

            let columns = [ProfileWorkbook.Column(heading: "Height above bottom yoke (mm)", decimals: 1, values: points.map { .number($0.z * 1000.0) }),
                           ProfileWorkbook.Column(heading: "ΔV (kV)", decimals: 2, values: points.map { .number($0.deltaV / 1000.0) }),
                           ProfileWorkbook.Column(heading: "Allowable ΔV (kV)", decimals: 2, values: points.map { .number($0.allowableDeltaV / 1000.0) }),
                           ProfileWorkbook.Column(heading: "Average stress (kV/mm)", decimals: 3, values: points.map { .number($0.averageField / 1.0E6) }),
                           ProfileWorkbook.Column(heading: "Allowable stress (kV/mm)", decimals: 3, values: points.map { .number($0.allowableField / 1.0E6) }),
                           ProfileWorkbook.Column(heading: "Utilization (%)", decimals: 1, values: points.map { .number($0.utilization * 100.0) })]

            /// One of the two graphs. `value` and `allowable` are table columns; `scale` turns a point's SI value into them.
            func Chart(title:String, yTitle:String, valueName:String, value:Int, allowable:Int, scale:(Point) -> (value:Double, allowable:Double)) -> ProfileWorkbook.Chart {

                var series = [ProfileWorkbook.Series(name: valueName, source: .columns(x: 0, y: value), look: .line(color: ProfileWorkbook.Colour.value, width: 1.5, dashed: false)),
                              ProfileWorkbook.Series(name: "Allowable", source: .columns(x: 0, y: allowable), look: .line(color: ProfileWorkbook.Colour.allowable, width: 1.5, dashed: true))]

                // The coil-end rules run to the top of the data the way the window's run to the top of its plot.
                let top = (points.map { max(scale($0).value, scale($0).allowable) }.max() ?? 0.0) * 1.08

                for marker in profile.endMarkers {

                    series.append(ProfileWorkbook.VerticalRule(at: marker * 1000.0, top: top, name: String(format: "Inner coil ends (%.0f mm)", marker * 1000.0)))
                }

                if let worst = profile.worst {

                    series.append(ProfileWorkbook.Series(name: "Worst point", source: .points([ProfileWorkbook.XY(x: worst.z * 1000.0, y: scale(worst).value)]), look: .dot(color: ProfileWorkbook.Colour.value), inLegend: false))
                }

                return ProfileWorkbook.Chart(title: title,
                                             xTitle: "Height above bottom yoke (mm)",
                                             yTitle: yTitle,
                                             xMinimum: range?.minimum,
                                             xMaximum: range?.maximum,
                                             xMajorUnit: 100.0,
                                             series: series)
            }

            let charts = [Chart(title: "Radial voltage difference — \(profile.name)", yTitle: "ΔV (kV)", valueName: "ΔV", value: 1, allowable: 2,
                                scale: { ($0.deltaV / 1000.0, $0.allowableDeltaV / 1000.0) }),
                          Chart(title: "Average radial stress — \(profile.name)", yTitle: "Average stress (kV/mm)", valueName: "Average stress", value: 3, allowable: 4,
                                scale: { ($0.averageField / 1.0E6, $0.allowableField / 1.0E6) })]

            var info = ProfileWorkbook.StandardInfo(designName: designName)
                     + [ProfileWorkbook.InfoRow(label: "Peak test voltage:", value: String(format: "%.1f kV", peakTestVoltage / 1000.0))]
                     + ProfileWorkbook.Info(StressProfileWindow.Annotation(for: profile, showingVolts: true))

            if !profile.endMarkers.isEmpty {

                info.append(ProfileWorkbook.InfoRow(label: "Grey rules:", value: "where the inner coil ends"))
            }

            info.append(ProfileWorkbook.InfoRow(label: "Note:", value: StressProfileWindow.Note(for: profile, what: "radial voltage difference and average radial stress")))

            return ProfileWorkbook.Sheet(name: profile.name,
                                         title: "Radial Voltage Difference and Stress vs. Height — \(profile.name)",
                                         info: info,
                                         columns: columns,
                                         charts: charts)
        }
    }

    var workbookActiveSheet:Int { profilePicker.indexOfSelectedItem }

    var workbookFileName:String { [designName, "Radial Stress Profiles"].compactMap { $0 }.joined(separator: " ") }
}
