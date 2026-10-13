//
//  GetSimDetailsDialog.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2024-02-13.
//

import Cocoa
import PchDialogBoxPackage

class SimDetailsDlog : PCH_DialogBox {
    
    @IBOutlet weak var waveFormPopUp: NSPopUpButton!
    @IBOutlet weak var voltageField: NSTextField!

    /// Solver bandwidth, in MHz.
    ///
    /// This is a genuine accuracy control, not a performance tuning knob, and
    /// it is exposed for that reason. The frequency-domain solver represents
    /// the response only up to this frequency; error near the wavefront falls
    /// as the bandwidth rises, and the cost rises in direct proportion (the
    /// number of linear systems solved is 2*f_max*T).
    ///
    /// See `LaplaceGrid.DefaultGrid` for the full discussion.
    @IBOutlet weak var bandwidthField: NSTextField!

    var waveFormStrings:[String]

    /// Default bandwidth, in MHz.
    ///
    /// 10 MHz is about 20x the standard lightning impulse's own corner
    /// frequency (k2 = 3.33e6 rad/s, roughly 530 kHz). Past that corner the
    /// applied wave rolls off as 1/omega^2, so network resonances above a few
    /// MHz receive almost no excitation and there is very little left to
    /// alias. It is also near the upper limit of where a lumped
    /// disc-by-disc model represents a real winding at all.
    ///
    /// On a typical model this is ~2000 linear solves. The solver warns in the
    /// log if the response is still significant at the top of the band, which
    /// is the signal to raise it.
    static let defaultBandwidthMHz = 10.0

    /// The crest the voltage field opens with, in kV. See AppController.ImpulsedLeadBIL.
    let defaultCrestKV:Double

    /// What the voltage field opened with before a design file could say: a placeholder, not a test level.
    static let fallbackCrestKV = 30.0

    init(waveFormStrings:[String], defaultCrestKV:Double? = nil) {

        self.waveFormStrings = waveFormStrings
        self.defaultCrestKV = defaultCrestKV ?? SimDetailsDlog.fallbackCrestKV

        super.init(viewNibFileName: "GetSimDetailsView", windowTitle: "Simulation Setup", hideCancel: false)
    }

    /// The chosen bandwidth in Hz, clamped to a sane range.
    ///
    /// The floor matters: below about 2 MHz the band no longer covers the
    /// impulse's own rise, and the result would be a smoothed wavefront that
    /// still looks entirely plausible. Rather than let a typo silently produce
    /// a wrong-but-believable answer, anything below the floor is pulled up to
    /// it.
    var bandwidthInHz:Double {

        let entered = bandwidthField.doubleValue

        guard entered.isFinite, entered > 0.0 else {

            return SimDetailsDlog.defaultBandwidthMHz * 1.0E6
        }

        return min(max(entered, 2.0), 200.0) * 1.0E6
    }

    // awakeFromNib() is 'nonisolated' on NSObject, so assume main-actor isolation explicitly (nib
    // loading always happens on the main thread) before touching any of the outlets.
    override func awakeFromNib() {

        MainActor.assumeIsolated {

            waveFormPopUp.removeAllItems()
            waveFormPopUp.addItems(withTitles: waveFormStrings)

            voltageField.formatter = NumberFormatter()
            voltageField.doubleValue = defaultCrestKV

            let bandwidthFormatter = NumberFormatter()
            bandwidthFormatter.minimumFractionDigits = 0
            bandwidthFormatter.maximumFractionDigits = 1
            bandwidthField.formatter = bandwidthFormatter
            bandwidthField.doubleValue = SimDetailsDlog.defaultBandwidthMHz
        }
    }

}
