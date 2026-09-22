//
//  RegulatingWindingDialog.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-09-22.
//

// Dialog for declaring a coil as a regulating winding (see RegulatingWinding.swift).
//
// Built in code on an NSAlert, like GetWoundInShieldDialog and for the same reason: the readout has to move as the user steps
// the loop count. On a double-stacked winding the thing worth seeing before committing is how many discs each loop takes and
// which crossovers that ties together, and a loop count that does not divide the stack is refused on the spot - with the counts
// that would work - rather than after the user has pressed the button.

import Cocoa

@MainActor
class RegulatingWindingDialog: NSObject {

    enum Result {

        case declare(numLoops:Int)
        case remove
    }

    private let coil:Int
    private let arrangement:RegulatingWinding.Arrangement
    private let numDiscs:Int
    private let initialLoops:Int
    private let isAlreadyDeclared:Bool

    private let loopsField = NSTextField(string: "")
    private let loopsStepper = NSStepper()
    private let discsPerLoopValue = NSTextField(labelWithString: "")
    private let connectionsValue = NSTextField(wrappingLabelWithString: "")

    private weak var declareButton:NSButton? = nil

    /// - Parameter numDiscs: the discs in the whole coil, as the model has them now.
    /// - Parameter initialLoops: what the dialog opens on - the existing declaration's count, or a default for a new one.
    init(coil:Int, arrangement:RegulatingWinding.Arrangement, numDiscs:Int, initialLoops:Int, isAlreadyDeclared:Bool) {

        self.coil = coil
        self.arrangement = arrangement
        self.numDiscs = numDiscs
        self.initialLoops = max(1, initialLoops)
        self.isAlreadyDeclared = isAlreadyDeclared

        super.init()
    }

    /// Run the dialog. Returns nil if the user cancels.
    func runModal() -> Result? {

        let alert = NSAlert()
        alert.messageText = "Regulating Winding - Coil \(self.coil)"

        switch self.arrangement {

        case .doubleStack:
            alert.informativeText = "Double-stacked, \(self.numDiscs) discs (\(self.numDiscs / 2) per stack). The two stacks are paralleled: the outer ends are tied together, the two centre leads are tied together, and every tap point is tied to its mirror image in the other stack."

        case .multiStart:
            alert.informativeText = "Multi-start. The loops are wound side by side over the whole height, and the program models the winding as a single lumped section, so the ties between one loop and the next are inside that section rather than connections of their own."

        case .singleStack:
            alert.informativeText = "Single stack, \(self.numDiscs) disc(s). Every tap lead goes out to the tap changer, so nothing inside the winding is tied together permanently."
        }

        let declareButton = alert.addButton(withTitle: self.isAlreadyDeclared ? "Update" : "Declare")
        alert.addButton(withTitle: "Cancel")

        if self.isAlreadyDeclared {

            alert.addButton(withTitle: "Remove Declaration")
        }

        self.declareButton = declareButton
        alert.accessoryView = self.BuildAccessoryView()

        self.UpdateReadout()

        alert.window.initialFirstResponder = self.loopsField

        switch alert.runModal() {

        case .alertFirstButtonReturn:
            return .declare(numLoops: self.selectedLoops)

        case .alertThirdButtonReturn:
            return .remove

        default:
            return nil
        }
    }

    private var selectedLoops:Int {

        return max(1, self.loopsStepper.integerValue)
    }

    private func BuildAccessoryView() -> NSView {

        // No real ceiling on a loop count, but a stack cannot have more loops than discs.
        let maxLoops = self.arrangement == .doubleStack ? max(self.numDiscs / 2, 1) : 999

        self.loopsStepper.minValue = 1
        self.loopsStepper.maxValue = Double(maxLoops)
        self.loopsStepper.increment = 1
        self.loopsStepper.valueWraps = false
        self.loopsStepper.integerValue = min(self.initialLoops, maxLoops)
        self.loopsStepper.target = self
        self.loopsStepper.action = #selector(self.HandleStepper(_:))

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: maxLoops)

        self.loopsField.formatter = formatter
        self.loopsField.integerValue = self.loopsStepper.integerValue
        self.loopsField.alignment = .right
        self.loopsField.target = self
        self.loopsField.action = #selector(self.HandleLoopsField(_:))
        self.loopsField.widthAnchor.constraint(equalToConstant: 52.0).isActive = true

        let loopsBox = NSStackView(views: [self.loopsField, self.loopsStepper])
        loopsBox.orientation = .horizontal
        loopsBox.spacing = 2.0

        self.connectionsValue.preferredMaxLayoutWidth = 300.0

        var rows:[[NSView]] = [[NSTextField(labelWithString: self.arrangement == .doubleStack ? "Tapping loops per stack:" : "Tapping loops:"), loopsBox]]

        if self.arrangement == .doubleStack {

            rows.append([NSTextField(labelWithString: "Discs per loop:"), self.discsPerLoopValue])
        }

        rows.append([NSTextField(labelWithString: "Permanent connections:"), self.connectionsValue])

        let grid = NSGridView(views: rows)

        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8.0
        grid.columnSpacing = 10.0

        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        container.addSubview(grid)

        NSLayoutConstraint.activate([

            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: max(460.0, grid.fittingSize.width), height: grid.fittingSize.height)

        return container
    }

    @objc private func HandleStepper(_ sender:Any) {

        self.loopsField.integerValue = self.loopsStepper.integerValue
        self.UpdateReadout()
    }

    @objc private func HandleLoopsField(_ sender:Any) {

        // the formatter bounds the field, but clamp anyway so the stepper and the field can never disagree
        self.loopsStepper.integerValue = min(max(1, self.loopsField.integerValue), Int(self.loopsStepper.maxValue))
        self.loopsField.integerValue = self.loopsStepper.integerValue
        self.UpdateReadout()
    }

    private func UpdateReadout() {

        let loops = self.selectedLoops

        switch self.arrangement {

        case .multiStart:
            self.connectionsValue.stringValue = "None to make - the winding is one lumped section."
            self.declareButton?.isEnabled = true

        case .singleStack:
            self.connectionsValue.stringValue = "None - every tap lead goes to the tap changer."
            self.declareButton?.isEnabled = true

        case .doubleStack:

            let discsPerStack = self.numDiscs / 2

            guard discsPerStack % loops == 0 else {

                self.discsPerLoopValue.stringValue = "\(discsPerStack) ÷ \(loops) is not a whole number of discs"
                self.connectionsValue.stringValue = "Every tap point has to fall on a crossover. Loop counts that work: \(RegulatingWinding.WholeDiscLoopCounts(discsPerStack: discsPerStack).map({ String($0) }).joined(separator: ", "))."
                self.declareButton?.isEnabled = false
                return
            }

            let discsPerLoop = discsPerStack / loops
            self.discsPerLoopValue.stringValue = "\(discsPerLoop)"

            var text = "\(loops + 1) jumpers: the two outer ends, the two centre leads"

            if loops > 1 {

                let taps = (1..<loops).map({ "\($0 * discsPerLoop)↔\(self.numDiscs - $0 * discsPerLoop)" })
                text += ", and the crossovers above discs \(taps.joined(separator: ", "))"
            }

            self.connectionsValue.stringValue = text + "."
            self.declareButton?.isEnabled = true
        }
    }
}
