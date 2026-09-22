//
//  AppController.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2021-10-06.
//

// Keys into User Defaults
// Key (String) so that the user doesn't have to go searching for the last folder he opened
private let LAST_OPENED_INPUT_FILE_KEY = "PCH_IMPULSEDISTRIBUTION_LastInputFile"

let PCH_IMPULSEDISTRIBUTION_IterationCount = 200

let PCH_CIR_FILETYPE = "cir"

@MainActor var rb2021_progressIndicatorWindow:PCH_ProgressIndicatorWindow? = nil

import Cocoa
import Accelerate
import UniformTypeIdentifiers
@preconcurrency import ComplexModule
import RealModule
import PchBasePackage
import PchMatrixPackage
import PchExcelDesignFilePackage
import PchDialogBoxPackage
import PchProgressIndicatorPackage

extension PchMatrix {
    
    func SubMatrix(rowRange:Range<Int>, colRange:Range<Int>) async -> PchMatrix? {
        
        guard !rowRange.isEmpty && !colRange.isEmpty else {
            
            return nil
        }
        
        // clamp the range extrema to the actual matrix dimensions
        let minRow = max(0, rowRange.lowerBound)
        let minCol = max(0, colRange.lowerBound)
        let maxRow = min(rowRange.upperBound, self.rows)
        let maxCol = min(colRange.upperBound, self.columns)
        
        let subMatrix = PchMatrix(matrixType: .general, numType: self.numType, rows: UInt(maxRow - minRow), columns: UInt(maxCol - minCol))
        
        var newI = 0
        for i in minRow..<maxRow {
            
            var newJ = 0
            for j in minCol..<maxCol {
                
                if self.numType == .Double {
                    
                    if let newValue:Double = self[i, j]  {
                        
                        await subMatrix.SetDoubleValue(value: newValue, row: newI, col: newJ)
                        // subMatrix[newI, newJ] = newValue
                    }
                }
                else {
                    
                    if let newValue:Complex = self[i, j] {
                        
                        await subMatrix.SetComplexValue(value: newValue, row: newI, col: newJ)
                        // subMatrix[newI, newJ] = newValue
                    }
                }
                
                newJ += 1
            }
            
            newI += 1
        }
        
        return subMatrix
    }
}

@MainActor
class AppController: NSObject, NSMenuItemValidation, NSWindowDelegate {
    
    
    /// The main window of the program
    @IBOutlet weak var mainWindow: NSWindow!
    
    /// The transformer view
    @IBOutlet weak var txfoView: TransformerView!
    
    /// Menu items (for valiidation)
    /// Zooming
    @IBOutlet weak var zoomInMenuItem: NSMenuItem!
    @IBOutlet weak var zoomOutMenuItem: NSMenuItem!
    @IBOutlet weak var zoomRectMenuItem: NSMenuItem!
    @IBOutlet weak var zoomAllMenuItem: NSMenuItem!
    /// Winding / Segment menus
    @IBOutlet weak var showWdgAsSingleSegmentMenuItem: NSMenuItem!
    @IBOutlet weak var combineSegmentsIntoSingleSegmentMenuItem: NSMenuItem!
    @IBOutlet weak var interleaveSelectionMenuItem: NSMenuItem!
    @IBOutlet weak var addWoundInShieldsMenuItem: NSMenuItem!
    @IBOutlet weak var removeWoundInShieldsMenuItem: NSMenuItem!
    @IBOutlet weak var splitSegmentToBasicSectionsMenuItem: NSMenuItem!
    
    /// Static RIngs
    @IBOutlet weak var staticRingOverMenuItem: NSMenuItem!
    @IBOutlet weak var staticRingBelowMenuItem: NSMenuItem!
    @IBOutlet weak var removeStaticRingMenuItem: NSMenuItem!
    /// Radial Shield
    @IBOutlet weak var radialShieldInsideMenuItem: NSMenuItem!
    @IBOutlet weak var removeRadialShieldMenuItem: NSMenuItem!
    
    /// Connections
    @IBOutlet weak var addImpulseMenuItem: NSMenuItem!
    @IBOutlet weak var addGroundMenuItem: NSMenuItem!
    @IBOutlet weak var addConnectionMenuItem: NSMenuItem!
    @IBOutlet weak var removeConnectionMenuItem: NSMenuItem!
    @IBOutlet weak var regulatingWindingMenuItem: NSMenuItem!
    
    /// Save matrices
    @IBOutlet weak var saveMmatrixMenuItem: NSMenuItem!
    @IBOutlet weak var saveUnfactoredMmatrixMenuItem: NSMenuItem!
    @IBOutlet weak var saveBmatrixMenuItem: NSMenuItem!
    
    @IBOutlet weak var saveBaseCmatrixMenuItem: NSMenuItem!
    @IBOutlet weak var saveFixedCmatrixMenuItem: NSMenuItem!
    
    /// Saving files
    @IBOutlet weak var saveAsCirFileMenuItem: NSMenuItem!
    
    /// Simulation
    @IBOutlet weak var simulateMenuItem: NSMenuItem!
    @IBOutlet weak var cancelSimulationMenuItem: NSMenuItem!
    @IBOutlet weak var compareSolversMenuItem: NSMenuItem!
    @IBOutlet weak var showWaveformsMenuItem: NSMenuItem!
    @IBOutlet weak var showCoilResultsMenuItem: NSMenuItem!
    @IBOutlet weak var showVoltageDiffsMenuItem: NSMenuItem!
    
    /// Inductance Calculations
    @IBOutlet weak var mainWdgInductanceMenuItem: NSMenuItem!
    @IBOutlet weak var mainWdgImpedanceMenuItem: NSMenuItem!
    @IBOutlet weak var cancelInductanceMenuItem: NSMenuItem!
    
    /// R and Z indication on the main window
    @IBOutlet weak var rLocationTextField: NSTextField!
    @IBOutlet weak var zLocationTextField: NSTextField!
    
    /// Mode indicator
    @IBOutlet weak var modeIndicatorTextField: NSTextField!
    
    /// Inductance calculation indicators
    @IBOutlet weak var inductanceLight: NSTextField!
    @IBOutlet weak var indCalcProgInd: NSProgressIndicator!
    @IBOutlet weak var workingLabel: NSTextField!
    
    /// Window controller to display graphs
    // var graphWindowCtrl:PCH_GraphingWindow? = nil
    
    /// The current basic sections that are loaded in memory
    var currentSections:[BasicSection] = []
    
    /// The current model that is stored in memory. This is what is actually displayed in the TransformerView and what all calculations are performed upon.
    var currentModel:PhaseModel? = nil
    
    /// Simulation calculation indicators
    @IBOutlet weak var simulationLight: NSTextField!
    @IBOutlet weak var simCalcProgInd: NSProgressIndicator!
    
    /// The current simulation model that is stored in memory.
    ///
    /// This is a **build product**, not something the user maintains. It is created on demand - by "Simulate now", which always
    /// rebuilds it, or by doGetSimulationModel() for the one command that needs a model but not a run - and it is only ever
    /// replaced through doCreateSimulationModel(), so that the outgoing state lands in `previousSimulationState` on the way out.
    private(set) var currentSimModel:SimulationModel? = nil

    /// Everything that building a new simulation model replaces.
    ///
    /// Bundled into one value because the three pieces are only meaningful together: a result belongs to the model it was computed
    /// on, and the fixed capacitance matrix in the PhaseModel belongs to whichever SimulationModel wrote it there. Restoring one
    /// without the others would leave the app displaying one model's answer for another model's network.
    struct SimulationState {

        /// The simulation model itself. Optional because the first rebuild of a session has no predecessor to save.
        let simModel:SimulationModel?

        /// The results of the last run made **on `simModel`**, if it was ever run.
        let results:SimulationResults?

        /// SimulationModel's initializer writes its Dirichlet-fixed capacitance matrix back into the PhaseModel (the
        /// `model.SetFixedC` call at the end of Assemble()), so the PhaseModel's copy is part of what a rebuild overwrites and
        /// part of what putting the previous state back has to restore. It is only used by the Save Fixed C Matrix command, but
        /// leaving it pointing at a discarded model's matrix would silently save the wrong file.
        let fixedC:PchMatrix?
    }

    /// The state that the most recent doCreateSimulationModel() replaced, if any.
    ///
    /// One deep, which is all an "Undo Simulation" command would need: the interesting case is having just rebuilt the model,
    /// realised the design was not the one that was wanted, and wanting the previous run's numbers back. Nothing calls
    /// doRestorePreviousSimulationModel() yet - see that routine for what wiring it up would take. Making it a stack instead is a
    /// matter of changing this to an array and pushing/popping in those two routines; nothing else reads it.
    private(set) var previousSimulationState:SimulationState? = nil

    /// The currently-running simulation, if any. Held so that it can be cancelled (and so that a second simulation can't be launched on top of a running one).
    var runningSimulationTask:Task<Void, Never>? = nil

    /// The currently-running inductance calculation, if any. Held so that it can be cancelled.
    var runningInductanceTask:Task<Void, Error>? = nil

    /// The recalculation currently in flight, if any. See recalculateModel() for what this is for - in short, a recalculation is
    /// minutes long and full of suspension points, so without a handle on it nothing stops a second one from being started on top
    /// of the first and clobbering every piece of state the two of them share.
    private var runningRecalculationTask:Task<Void, Never>? = nil

    struct SimulationResults {
        
        let waveForm:SimulationModel.WaveForm
        let peakVoltage:Double
        let stepResults:[SimulationModel.SimulationStepResult]
        
        var numSteps:Int {
            
            get {
                
                return stepResults.count
            }
        }
        
        var timeSpan:(begin:Double, end:Double) {
            
            get {
                
                guard let beginTime = stepResults.first?.time, let endTime = stepResults.last?.time else {
                    
                    DLog("No results!")
                    return (begin:Double.greatestFiniteMagnitude, end:-Double.greatestFiniteMagnitude)
                }
                
                return (beginTime, endTime)
            }
        }
        
        var extremeVolts:(min:Double, max:Double) {
            
            get {
                
                let nodeRange:ClosedRange<Int> = 0...stepResults[0].volts.count-1
                
                return ExtremeVoltsInSegmentRange(nodeRange: nodeRange)
            }
        }
        
        var extremeAmps:(min:Double, max:Double) {
            
            get {
                
                var result = (min:Double.greatestFiniteMagnitude, max:-Double.greatestFiniteMagnitude)
                for nextStep in stepResults {
                    
                    result.min = min(nextStep.amps.min()!, result.min)
                    result.max = max(nextStep.amps.max()!, result.max)
                }
                
                return result
            }
        }
        
        func ampsFor(segment:Int) -> [Double] {
            
            guard segment <= stepResults[0].amps.count else {
                
                DLog("Illegal segment number!")
                return []
            }
            
            var result:[Double] = []
            for nextStep in stepResults {
                
                result.append(nextStep.amps[segment])
            }
            
            return result
        }
        
        func ExtremeVoltsInSegmentRange(nodeRange:ClosedRange<Int>) -> (min:Double, max:Double) {
            
            var result = (min:Double.greatestFiniteMagnitude, max:-Double.greatestFiniteMagnitude)
            for nextStep in stepResults {
                
                let segVolts = nextStep.volts[nodeRange]
                result.min = min(segVolts.min()!, result.min)
                result.max = max(segVolts.max()!, result.max)
            }
            
            return result
        }
        
        func ExtremeAmpsInSegmentRange(range:ClosedRange<Int>) -> (min:Double, max:Double) {
            
            var result = (min:Double.greatestFiniteMagnitude, max:-Double.greatestFiniteMagnitude)
            for nextStep in stepResults {
                
                let segAmps = nextStep.amps[range]
                result.min = min(segAmps.min()!, result.min)
                result.max = max(segAmps.max()!, result.max)
            }
            
            return result
        }
        
        struct Location:Hashable {
            
            let row:Int
            let col:Int
        }
        
        // If forRange is nil, the entire simulation result is used (ie: all the results at all the time steps). The range is clamped to the size of the volts array in stepResults
        func MaximumInternodalVoltages(forRange:ClosedRange<Int>? = nil) async -> PchMatrix {
            
            guard let firstResult = stepResults.first, !firstResult.volts.isEmpty else {
                
                return PchMatrix(rows: UInt(0), columns: UInt(0))
            }
            
            let lowNode = max(0, forRange?.lowerBound ?? 0)
            let highNode = min(firstResult.volts.count - 1, forRange?.upperBound ?? firstResult.volts.count - 1)
            
            if highNode - lowNode == 0 {
                
                return PchMatrix(rows: UInt(0), columns: UInt(0))
            }
            
            let nodeRange = ClosedRange(uncheckedBounds: (lowNode, highNode))
            
            var result:[Location:Double] = [:]
            var firstTimeThrough = true
            for nextResult in stepResults {
                
                let nextInterVolts = InternodalVoltages(volts: Array(nextResult.volts[nodeRange]))
                
                if firstTimeThrough {
                    
                    result = nextInterVolts
                    firstTimeThrough = false
                }
                else {
                    
                    for (location, value) in nextInterVolts {
                        
                        let prevMax = result[location]!
                        
                        if value > prevMax {
                            
                            result[location] = value
                        }
                        
                    }
                }
            }
            
            let dimension = UInt(highNode - lowNode + 1)
            let matrix = PchMatrix(matrixType: .symmetric, numType: .Double, rows: dimension, columns:dimension)
            
            for (location, value) in result {
                
                await matrix.SetDoubleValue(value: value, row: location.row, col: location.col)
            }
            
            return matrix
        }
        
        func InternodalVoltages(volts:[Double]) -> [Location:Double] {

            var result:[Location:Double] = [:]
            for col in 0..<volts.count {
                
                // get the value in the col index just once
                let voltsCol = volts[col]
                for row in col+1..<volts.count {
                    
                    result[Location(row: row, col: col)] = abs(voltsCol - volts[row])
                }
            }
            
            return result
        }
        
    }
    
    /// Coil Results windows
    var coilResultsWindow:CoilResultsDisplayWindow? = nil

    /// The dielectric stress report and its companion profile graphs. Held so that they are not deallocated the moment the action
    /// that created them returns.
    var stressReportWindow:StressReportWindow? = nil
    var stressProfileWindow:StressProfileWindow? = nil
    var radialProfileWindow:RadialProfileWindow? = nil
    var axialStressProfileWindow:AxialStressProfileWindow? = nil

    /// The capacitive initial distribution graph, held for the same reason.
    var initialDistributionWindow:InitialDistributionWindow? = nil

    /// The most recent stress screen, kept so that the profile graphs can be built from exactly the findings the table showed
    /// rather than from a second scan.
    ///
    /// Emptied by `latestSimulationResult`'s `didSet` - see there.
    var latestStressChecks:[DielectricStress.StressCheck] = []
    // var voltageDiffsWindow:PchMatrixViewWindow? = nil

    /// The result of the latest simulation run that was executed
    var latestSimulationResult:SimulationResults? = nil {

        // The stress checks are a pure function of this result (plus the model it was run on), and StressChecks() returns its
        // cache whenever the cache is non-empty. Nothing but a preference change used to empty it, so a second run put its own
        // waveforms on screen while the stress report went on showing the FIRST run's findings - the failure is silent, because a
        // stale table of findings looks exactly like a fresh one. Hanging the invalidation off the property rather than off the
        // places that assign it means a future writer cannot forget.
        didSet {

            self.latestStressChecks = []
        }
    }

    /// The current FE model that is stored in memory (this is required becuase the inductance calcualtion takes really long and so is put into a different thread)
    var currentFePhase:FePhase? = nil
    
    /// The current core in memory
    var currentCore:Core? = nil
    
    /// The original xlFile used to create the current sections (originally, at least, the only way to create the Basic Sections is by importing an XL file.
    var currentXLfile:PCH_ExcelDesignFile? = nil

    /// Where `currentXLfile` was read from, which is what the regulating-winding declarations are filed under. Nil when the model
    /// was built without going through `doOpen` - a SelfTest run - so that a scripted run never picks up, or overwrites, what the
    /// user declared on the same design.
    var currentDesignFileURL:URL? = nil

    /// The coils declared as regulating windings and in force on the current model. See RegulatingWinding.swift. Saved to
    /// `RegulatingWindingStore` under `currentDesignFileURL` whenever it changes, and read back (and re-applied) when that design
    /// is next opened.
    var regulatingWindings:[RegulatingWinding] = []
    
    /// The theoretical depth of the tank (used for display and ground capacitance calculations)
    var tankDepth:Double = 0.0
    
    /// The current multiplier for window height (used for old-style inductance calculations)
    var currentWindowMultiplier = 1.0
    
    /// The colors of the different layers (for display purposes only), indexed by radialPos. Red and green are deliberately
    /// NOT in here: they are reserved for the impulse and ground symbols (`ViewConnector.impulseColor`/`groundColor`), which
    /// used to share `.red` with coil 0 - on a single-coil model the impulse arrow was then drawn in the winding's own ink.
    ///
    /// These are fixed sRGB values rather than the `.systemBlue` family on purpose. A colour's legibility here is its contrast
    /// against `SegmentPath.bkGroundColor`, which is hardcoded white; the system colours are dynamic and shift in Dark Mode
    /// while that white would not, so they would come out *worse* in the one case they are meant to help.
    ///
    /// Contrast ratios against white (WCAG relative luminance, 0.2126R + 0.7152G + 0.0722B on linearized sRGB): blue 8.1,
    /// orange 3.5, purple 8.9, teal 5.6, brown 7.1. The predecessors were `[.red, .blue, .orange, .purple, .yellow]`, where
    /// pure yellow measured **1.07:1** - the eye takes ~72% of its luminance signal from the green channel, so yellow (red +
    /// green, both full) is nearly the luminance of white paper and a 1-point line of it is all but invisible. Contrast on
    /// white is bought with *lightness*, not hue or saturation, which is why these are darkened rather than re-hued.
    static let segmentColors:[NSColor] = [
        NSColor(srgbRed: 0.00, green: 0.25, blue: 0.80, alpha: 1.0),    // blue
        NSColor(srgbRed: 0.80, green: 0.38, blue: 0.00, alpha: 1.0),    // orange
        NSColor(srgbRed: 0.50, green: 0.00, blue: 0.60, alpha: 1.0),    // purple
        NSColor(srgbRed: 0.00, green: 0.45, blue: 0.50, alpha: 1.0),    // teal
        NSColor(srgbRed: 0.50, green: 0.30, blue: 0.10, alpha: 1.0)     // brown
    ]
    
    /// The inductance calculation for the current model has ben done
    var inductanceIsValid:Bool = false
    
    /// The capacitance calculation for the current model has been done
    var capacitanceIsValid:Bool = false
    
    var designIsValid:Bool {
        
        get {
            
            return inductanceIsValid && capacitanceIsValid
        }
    }
    
    // MARK: Initialization
    // NSObject's awakeFromNib() is 'nonisolated' in the SDK, so this override does NOT inherit the
    // class's @MainActor. Nib loading always happens on the main thread, so assume the isolation
    // explicitly rather than leaving the UI accesses below unchecked.
    override func awakeFromNib() {

        MainActor.assumeIsolated {

            txfoView.appController = self

            rb2021_progressIndicatorWindow = PCH_ProgressIndicatorWindow()

            let formatter = NumberFormatter()
            formatter.maximumFractionDigits = 1

            self.rLocationTextField.formatter = formatter
            self.zLocationTextField.formatter = formatter

            self.rLocationTextField.doubleValue = 0
            self.zLocationTextField.doubleValue = 0

            self.inductanceLight.textColor = .red
            self.inductanceIsValid = false
            self.indCalcProgInd.isHidden = true
            // self.indCalcProgInd.minValue = 0.0
            // self.indCalcProgInd.maxValue = 100.0
            self.simulationLight.textColor = .red
            self.simCalcProgInd.isHidden = true
            self.workingLabel.isHidden = true
        }
    }
    
    func InitializeController()
    {
        
    }
    
    // MARK: Long-running function completion routine(s)
    
    /// - Parameter phase: the FePhase the finished calculation ran on. It is passed in rather than read back out of
    /// `currentFePhase` because that property says only which phase is *newest*, not which one this call is reporting on. While
    /// recalculateModel could be re-entered, those were two different things: a run that finished while a second recalculation was
    /// under way read the second run's half-built phase here, found no inductance matrix on it, turned the light red and returned
    /// before setting inductanceIsValid - having already zeroed and hidden the progress bar the still-running calculation was
    /// using. The gate in recalculateModel makes that overlap impossible; taking the phase as an argument makes it unstateable.
    func didFinishInductanceCalculation(phase fePhase:FePhase) async {

        DLog("Got inductance completion message!")
        self.inductanceLight.textColor = await fePhase.inductanceMatrix != nil ? .green : .red
        
        self.indCalcProgInd.doubleValue = 0.0
        self.indCalcProgInd.toolTip = nil
        self.indCalcProgInd.isHidden = true
        if self.latestSimulationResult != nil {
            
            self.simulationLight.textColor = .yellow
        }
        // only hide the "Working..." label if the simulation calculation is not currently running
        self.workingLabel.isHidden = self.simCalcProgInd.isHidden
        
        guard let model = self.currentModel, let feIndMatrix = await fePhase.inductanceMatrix else {
            
            DLog("Model is nil or matrix is invalid (or nil)!")
            return
        }
        
        DLog("Energy (from Inductance): \(await fePhase.EnergyFromInductance())")
        
        do {
            
            let unfactoredM = await PchMatrix(srcMatrix: feIndMatrix)
            let M = try await feIndMatrix.FactorizedAs(.Cholesky)
            await model.SetInductanceMatrices(unfactoreM: unfactoredM, M:M)
            inductanceIsValid = true
        }
        catch {
            
            let alert = NSAlert(error: error)
            let _ = alert.runModal()
            return
        }
    }
    
    func didFinishSimulationRun() async {
        
        DLog("Got simulation-run completion message!")
        
        self.simulationLight.textColor = latestSimulationResult != nil ? .green : .red

        self.simCalcProgInd.doubleValue = 0.0
        self.simCalcProgInd.toolTip = nil
        self.simCalcProgInd.isHidden = true
        self.runningSimulationTask = nil
        // only hide the "Working..." label if the inductance calculation is not currently running
        self.workingLabel.isHidden = self.indCalcProgInd.isHidden
    }
    
    // MARK: Transformer update routines
    
    /// Function to update the model. If the 'reinitialize' parameter is 'true', then the 'oldSegments' and 'newSegments' parameters are ignored and a new model is created using the xlFile. _It is assumed that oldSegments and newSegments are contiguous and in correct order_. In general, it is assumed that one of either oldSegments or newSegments has only a single member in it.
    /// - Parameter oldSegments: An array of Segments that are to be removed from the model. Must be contiguous and in order.
    /// - Parameter newSegments: An array of Segments to insert into the model. Must be contiguous and in order.
    /// - Parameter xFile: The ExcelDesignFile that was inputted. If this is non-nil and 'reinitialize' is set to true, the existing model is overwtitten using the contents of the file.
    /// - Parameter reinitialize: Boolean value set to true if the entire memory should be reinitialized. If xlFile is non-nil, the it is used to overwrite the exisitng model. Otherwise, the model is reinitialized using the BasicSections in the AppController's currentSections array.
    /// - Parameter designFile: Where `xlFile` came from, when it came from the user opening it. The regulating windings declared on
    /// that design are re-applied to the fresh model. Nil for every other caller, which leaves the model with no declarations at all.
    func updateModel(oldSegments:[Segment], newSegments:[Segment], xlFile:PCH_ExcelDesignFile?, reinitialize:Bool, designFile:URL? = nil) async {

        // Ask any recalculation already in flight to stop BEFORE the store is touched, not after. recalculateModel() supersedes it
        // anyway at the bottom of this routine, but by then the segment swap below has already happened and the old run - which
        // suspends at every await - could have woken up in the middle of it and read a store that is half old and half new.
        // Signalling first means its next checkpoint sees the cancellation instead.
        self.CancelRecalculationInFlight()

        if reinitialize {
            
            if let file = xlFile {
                
                self.tankDepth = await file.tankDepth
                
                // The idea here is to create the current model as a Core and an array of BasicSections and save it into the class' currentSections property
                self.currentCore = await Core(diameter: file.core.diameter, realWindowHeight: file.core.windowHeight, legCenters: file.core.legCenters)
                
                // replace any currently saved basic sections with the new ones
                self.currentSections = await self.createBasicSections(xlFile: file)
                
                self.currentXLfile = file
            }
            
            if self.currentSections.count == 0 {
                
                PCH_ErrorAlert(message: "There are no basic sections!", info: nil)
            }
            
            // initialize the model so that all the BasicSections are modeled
            self.currentModel = await self.initializeModel(basicSections: self.currentSections)

            // The permanent connections of any regulating winding declared on this design go on now, while every lead is still
            // floating and every coil is still one disc per Segment - and before initializeViews, so they are drawn with the rest.
            self.currentDesignFileURL = designFile
            self.regulatingWindings = []

            if let model = self.currentModel, let designFile {

                await self.ApplySavedRegulatingWindings(RegulatingWindingStore.shared.windings(for: designFile), model: model)
            }

            self.initializeViews()
        }
        else {
            
            guard let model = self.currentModel else {
                
                PCH_ErrorAlert(message: "The model does not exist!", info: "Cannot change segments")
                return
            }
            
            await model.RemoveSegments(badSegments: oldSegments)
            
            do {
                
                try await model.UpdateConnectors(oldSegments: oldSegments, newSegments: newSegments)
                
                try await model.AddSegments(newSegments: newSegments)
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
        
        await self.recalculateModel(reinitialize: reinitialize)
    }

    /// Recompute everything that depends on the model's geometry: the radial build-up, the finite-element phase, the eddy losses,
    /// the inductance matrix and the capacitance matrix - then refresh the views.
    ///
    /// This is the tail of updateModel, pulled out so that it can be reached without pretending to change any Segments.
    /// PhaseModel.UpdateConnectors throws on an empty array, so calling updateModel with two empty arrays is not an option.
    ///
    /// - Parameter includeInductance: Pass false to recompute only the capacitance, leaving the existing inductance matrix in
    /// place. The inductance is the expensive step by orders of magnitude, and it is also the one that anything exploring geometry
    /// variations (a wound-in-shield grading search, say) does not need on every trial: the geometry moves by millimetres on a coil
    /// of a hundred, so the sane pattern is to hold the inductance fixed through the search and recompute it once at the end.
    ///
    /// - important: This is the **gate**, not the work - the work is PerformRecalculation(). At most one recalculation runs at a
    /// time, and a new request supersedes whatever is in flight. Everything below the gate is single-run state: currentFePhase,
    /// runningInductanceTask, indCalcProgInd, inductanceIsValid/capacitanceIsValid, and the PhaseModel itself. AppController is
    /// @MainActor but this routine is minutes long and is `await`ed at every step of the way, so before the gate existed every one
    /// of those suspension points was an opening for a second run to start on top of the first: interleaving one coil and then
    /// interleaving a second one before the first calculation finished left two recalculations alive, each overwriting the other's
    /// fePhase and inductance-task handle (so Cancel Inductance could no longer reach either), both driving the one progress bar
    /// from their own InductanceProgress stream and each zeroing it as it began - the progress indicator appearing to restart over
    /// and over - and the older of the two finally writing an inductance matrix computed for a geometry the newer one had already
    /// replaced.
    ///
    /// Superseding rather than blocking is the right semantics because the in-flight result is *stale*, not merely late: the
    /// caller has already changed the geometry it was computed for. The user is never locked out of the editing commands.
    func recalculateModel(reinitialize:Bool, includeInductance:Bool = true) async {

        // FIRST, and synchronously: the design has already changed by the time anyone calls this, so everything computed from the
        // old one is wrong from this instant, not from whenever the recalculation gets around to running.
        await self.DiscardResultsForChangedModel()

        self.CancelRecalculationInFlight()

        let superseded = self.runningRecalculationTask

        let recalculation = Task { @MainActor in

            // Task<Void, Never>, so this cannot throw and is not itself a cancellation point - it just waits out the unwind.
            await superseded?.value

            // A request that was itself superseded while queued here never runs at all: the only work worth doing is the newest.
            guard !Task.isCancelled else {

                return
            }

            await self.PerformRecalculation(reinitialize: reinitialize, includeInductance: includeInductance)
        }

        self.runningRecalculationTask = recalculation

        await recalculation.value

        // Only clear it if we are still the newest request - a later caller has already put its own task here.
        if self.runningRecalculationTask == recalculation {

            self.runningRecalculationTask = nil
        }
    }

    /// Throw away everything that was computed from the design, because the design has changed.
    ///
    /// # Why this exists
    ///
    /// The results form a chain, and every link of it is keyed to a geometry: the inductance and capacitance matrices come from
    /// the Segments, the simulation model comes from those matrices plus the terminations, the run comes from the simulation
    /// model, and the stress screen comes from the run. Change a Segment - add a static ring, interleave a coil, move a wound-in
    /// shield - and every one of them describes a transformer that is no longer on screen. `inductanceIsValid` and
    /// `capacitanceIsValid` covered the first link only; the rest simply stayed, so a stress report opened after an edit was
    /// screening the *previous* design, and the numbers looked exactly as authoritative as correct ones would have. There is no
    /// version of this that the user can be expected to keep track of themselves, which is why it is not a warning.
    ///
    /// # Discarding rather than recomputing
    ///
    /// Only the matrices are recomputed automatically (by `PerformRecalculation`, which this routine precedes); the simulation is
    /// minutes long and needs a crest and a bandwidth from the user, so it is not something to launch on their behalf because they
    /// dragged a static ring. Everything downstream of the model is therefore nilled and the commands that display it go back to
    /// being disabled, which is the honest state: the answer is not stale, it is *absent* until asked for again.
    ///
    /// The open result windows are closed for the same reason. A window is the one piece of this that keeps asserting its numbers
    /// after the state behind it is gone, and it is the piece the user is actually looking at.
    ///
    /// - note: The undo slot goes too. It exists to get back a simulation that a *rebuild* replaced; once the design itself has
    /// moved, the model saved in it is no more valid than the one being discarded.
    func DiscardResultsForChangedModel() async {

        self.currentSimModel = nil
        self.previousSimulationState = nil
        // Clears latestStressChecks through the property's didSet.
        self.latestSimulationResult = nil

        // Written by SimulationModel.init and by nothing else, so unlike C it does not get replaced by the recalculation.
        await self.currentModel?.ClearFixedC()

        self.simulationLight.textColor = .red

        CloseResultWindows()
    }

    /// Close every window showing a result of the previous design.
    ///
    /// Only the five held windows can be reached: the waveform and max-voltage-difference windows are created and let go (AppKit
    /// keeps them alive until they are closed), so nothing here has a handle on them. That is worth fixing if it ever matters -
    /// they would need to go into an array of `NSWindowController` the way these five are properties - but they are graphs of a
    /// named run rather than a screen of the current design, so a stale one is at least self-describing.
    private func CloseResultWindows() {

        self.coilResultsWindow?.close()
        self.coilResultsWindow = nil

        self.stressReportWindow?.close()
        self.stressReportWindow = nil

        self.stressProfileWindow?.close()
        self.stressProfileWindow = nil

        self.radialProfileWindow?.close()
        self.radialProfileWindow = nil

        self.axialStressProfileWindow?.close()
        self.axialStressProfileWindow = nil

        self.initialDistributionWindow?.close()
        self.initialDistributionWindow = nil
    }

    /// Ask the recalculation currently in flight, if any, to stop. Cancellation is cooperative all the way down (the checkpoints in
    /// PerformRecalculation and, below those, the ones in the package's InductanceForMesh), so this only signals - use
    /// recalculateModel(), which waits for the unwind before it starts anything, rather than calling this and pressing on.
    ///
    /// The inductance task is cancelled explicitly as well as the wrapper because it is unstructured: the wrapper's cancellation
    /// does reach it, through the withTaskCancellationHandler in PerformRecalculation, but only once the wrapper has got that far.
    private func CancelRecalculationInFlight() {

        self.runningInductanceTask?.cancel()
        self.runningRecalculationTask?.cancel()
    }

    /// The body of recalculateModel(). Call the gate, not this - see its `important` note for why.
    private func PerformRecalculation(reinitialize:Bool, includeInductance:Bool) async {

        guard let model = self.currentModel, let excelFile = self.currentXLfile else {

            PCH_ErrorAlert(message: "The model and/or Excel file do/does not exist!", info: "Impossible to continue!")
            return
        }

        // Rebuild the radial geometry from the design file plus whatever wound-in shields are currently set. This is unconditional
        // on purpose: it is cheap, it is idempotent, and doing it here means no caller has to remember when the geometry might have
        // gone stale. It also repairs it after a combine/split/interleave, each of which rebuilds Segments from their pristine
        // BasicSections and would otherwise silently drop the build-up.
        await model.ApplyRadialBuildUp()
        self.tankDepth = await model.tankDepth

        // Nothing below this point is worth doing if a newer request is already waiting on us, and the geometry it is waiting to
        // recalculate is not the geometry the rest of this routine is about to read.
        guard !Task.isCancelled else {

            return
        }

        capacitanceIsValid = false

        if !includeInductance {

            do {

                try await model.CalculateCapacitanceMatrix()
                capacitanceIsValid = true
            }
            catch {

                let alert = NSAlert(error: error)
                let _ = alert.runModal()
            }

            if !reinitialize {

                self.updateViews()
            }

            return
        }

        inductanceIsValid = false

        guard let fePhase = await CreateFePhase(xlFile: excelFile, model: model) else {

            // A superseded run reports nothing. Its caller has already changed the geometry out from under it, so a complaint here
            // is about a model that no longer exists and the newer run is the one that gets to have an opinion. Same reasoning at
            // the FE-section-count guard below, and on the error paths at the end.
            if !Task.isCancelled {

                PCH_ErrorAlert(message: "Could not create finite element model!")
            }

            return
        }
        
        self.currentFePhase = fePhase
        
        // To calculate the eddy losses, we need to make some assumptions regarding the amp-turn distribution. The method used here should be considered _temporary_. It would be better to have the program analyze the current connections (as selected by the user) and figure out the voltages and kVA.
        // For now, we will assume the following:
        // 1. Separate windings with the same terminal number are assumed to be 'main' windings (higher kVA) and 'tapping' windings (lower kVA)
        //    1a) The tap will be the one where the tapping winding has the same current direction as the main winding (this will cause small (I think) errors depending on the actual tap selected by the user)
        //    1b) For double-stacked windings, it is assumed that they will be connected in parallel
        // 2. The nominal transformer kVA will be equal to the full kVA of terminal 2
        // 3. If there is a 3rd (or 4th...) terminal make sure that its kVA is correctly set. It is assumed that the kVA of non-Terminal-2 windings are negative with respect to Terminal 2 and that the total amp-turns equal 0.
        // 4. Volts/Turn is selected from the sum of voltages of terminal 2 divided by the sum of turns of terminal 2
        // 5. Terminal number greater than 2 have only a SINGLE COIL associated with them
        var refKVA = 0.0
        var terms:Set<Int> = []
        for nextWinding in await excelFile.windings {
            
            if nextWinding.terminal.terminalNumber == 0 {
                
                continue
            }
            
            if nextWinding.terminal.terminalNumber == 2 {
                
                refKVA += nextWinding.terminal.kVA
            }
            
            terms.insert(nextWinding.terminal.terminalNumber)
        }
        
        guard terms.count >= 2 else {
            
            PCH_ErrorAlert(message: "Not enough terminals!")
            return
        }
        
        guard refKVA > 0 else {

            PCH_ErrorAlert(message: "No winding has been assigned to terminal number 2!")
            return
        }

        // Every array from here down - turns, kvas, currents - is SIZED by terms.count but INDEXED by terminalNumber - 1, so the
        // terminal numbers have to run 1...terms.count with no gaps. A design file carrying terminals {1, 2, 4} would size them 3
        // and then index them with 3. Checking it once here makes all four of the loops below safe; the alternative is the same
        // out-of-range crash reachable from any of them. terms.count >= 2 is already guaranteed above, so the range is valid.
        guard terms == Set(1...terms.count) else {

            PCH_ErrorAlert(message: "The terminal numbers are not contiguous!", info: "Found \(terms.sorted()) - the amp-turn distribution needs 1 to \(terms.count) with no gaps.")
            return
        }

        // the index into these arrays is the terminal number minus 1
        var term2volts:Double = 0.0
        var turns:[Double] = Array(repeating: 0.0, count: terms.count)
        for nextTerm in terms {
            
            for nextWinding in await excelFile.windings {
                
                if nextWinding.terminal.terminalNumber == nextTerm {
                    
                    let wdgTurns = nextWinding.numTurns.max // / (nextWinding.isDoubleStack ? 2.0 : 1.0)
                    turns[nextTerm - 1] += wdgTurns
                    
                    if nextTerm == 2 {
                        
                        let phFactor = nextWinding.terminal.connection == .wye ? SQRT3 : 1.0
                        let wdgVolts = nextWinding.terminal.lineVolts / phFactor // / (nextWinding.isDoubleStack ? 2.0 : 1.0)
                        term2volts += wdgVolts
                    }
                }
            }
        }
        
        let voltsPerTurn = term2volts / turns[1]

        // The model needs this for anything that has to know a section's actual operating voltage rather than a per-unit one. At
        // the moment that is only the paper thickness on a wound-in-shield wire (Segment.WoundInShieldWire.Standard), which is
        // sized against the working stress between a shield turn and the coil turns beside it.
        await model.SetVoltsPerTurn(voltsPerTurn)

        // How many neighbouring phases the outermost coil is charged for. A polyphase unit is modelled as its CENTRE leg, which
        // has a neighbour on both sides and is therefore the worst case for C_g and so for alpha - see PhaseModel's
        // adjacentPhaseCount. A single-phase unit has no neighbour, and used to be charged for one anyway.
        await model.SetAdjacentPhaseCount(excelFile.numPhases > 1 ? 2 : 0)

        var kvas:[Double] = Array(repeating: 0.0, count: terms.count)
        kvas[1] = refKVA
        var otherTermskVA = refKVA
        var otherTerms = terms
        otherTerms.remove(1)
        otherTerms.remove(2)
        while otherTerms.count > 0 {
            
            let nextTerm = otherTerms.first!
                
            for nextWdg in await excelFile.windings {
                
                if nextWdg.terminal.terminalNumber == nextTerm {
                    
                    kvas[nextTerm - 1] = nextWdg.terminal.kVA
                    otherTermskVA -= nextWdg.terminal.kVA
                    otherTerms.remove(nextTerm)
                    break
                }
            }
        }
        
        kvas[0] = otherTermskVA
        var currents:[Double] = Array(repeating: 0.0, count: terms.count)
        
        for nextTerm in terms {
            
            let voltage = turns[nextTerm - 1] * voltsPerTurn
            currents[nextTerm - 1] = await kvas[nextTerm - 1] * 1000.0 / Double(excelFile.numPhases) / voltage
        }
        
        // The FE section index is a Segment's POSITION IN CoilSegments(), because that is the array CreateFePhase walked to build
        // the sections. It is not derivable from axialPos: that is the pristine design-file disc index of the Segment's lowest
        // BasicSection (Segment.axialPos) and is never renumbered, so the two agree only while every Segment holds exactly one
        // BasicSection - which the load path guarantees and a combine, an interleave or a wound-in-shield pairing destroys.
        //
        // This loop used to derive its range from GetHighestSection(coil:), which returns that axial COORDINATE rather than a
        // count. Interleaving 8 discs into 4 Segments left the coordinates at 0/2/4/6, so the range ran 7 wide over 4 sections:
        // either off the end of window.sections (the crash) or, when the interleaved coil was not the last one, silently over the
        // NEXT coil's sections, giving a plausible and entirely wrong inductance matrix. Taking the index straight from the array
        // makes the two sides impossible to disagree.
        let coilSegments = await model.CoilSegments()

        let feSectionCount = await fePhase.sections.count

        guard feSectionCount == coilSegments.count else {

            // A superseded run reaches this legitimately: the caller that superseded it added or removed Segments after fePhase was
            // built from the old store, so the two disagreeing here is the expected outcome rather than a broken model.
            if !Task.isCancelled {

                PCH_ErrorAlert(message: "The finite-element model does not match the phase model!", info: "\(feSectionCount) FE sections for \(coilSegments.count) Segments.")
            }

            return
        }

        for (segIndex, nextSegment) in coilSegments.enumerated() {

            // CreateFePhase indexes the design file's windings by radialPos in exactly this way, so a Segment whose radialPos is out
            // of range would already have failed there.
            let terminalNumber = await excelFile.windings[nextSegment.radialPos].terminal.terminalNumber

            // Terminal 0 means the winding is not assigned to a terminal, so it takes no part in the amp-turn balance - which is
            // exactly why the loop that built 'terms' skips it, and therefore why 'currents' has no entry for it. This used to walk
            // straight into currents[-1].
            //
            // Zero rather than leaving whatever CreateFePhase seeded from Winding.I: that getter is legVA/legVolts, so a winding
            // with neither kVA nor line volts evaluates 0/0 and seeds a NaN that would run silently through the whole FE solve.
            guard terminalNumber > 0 else {

                await fePhase.SetSeriesRmsCurrentForSection(segIndex, rmsAmps: 0.0)
                continue
            }

            let currentDirection = terminalNumber == 2 ? -1.0 : 1.0
            // let currentDivider = excelFile.windings[nextSegment.radialPos].isDoubleStack ? 2.0 : 1.0
            await fePhase.SetSeriesRmsCurrentForSection(segIndex, rmsAmps: currents[terminalNumber - 1] * currentDirection)
        }
        
        // One solve of the whole model at the currents just assigned, and the eddy losses read off the field it gives. This is
        // also what meshes and factorizes the model, so the inductance sweep below pays for neither.
        let eddyLossesPU:[FePhase.EddyLossPU]

        do {

            eddyLossesPU = try await fePhase.CalculateEddyLosses()
            DLog("Energy (mesh): \(await fePhase.magneticEnergy)")
        }
        catch {

            if !Task.isCancelled {

                let alert = NSAlert(error: error)
                let _ = alert.runModal()
            }

            return
        }

        // The FE solve above is the last long stretch before the inductance calculation, and none of it checks for cancellation.
        // Bail here rather than light up the progress bar and start minutes of work for a geometry that has already been replaced.
        guard !Task.isCancelled else {

            return
        }

        
        
        
        // One FE section per CoilSegments() entry, in that order - the same correspondence the current assignment above uses, and
        // for the same reason (CreateFePhase built the sections by walking that array).
        //
        // This used to run over model.segments, which is the FULL store, static rings and radial shields included. CoilSegments()
        // filters those out, so the FE array is SHORTER than the store by the number of shielding elements in the model and the
        // indexing ran off the end of it: "Index out of range", raised by the first recalculation after a static ring
        // was added. Before it overran it was also writing each coil Segment's eddy losses onto whatever Segment happened to sit
        // at that index - a static ring sorts to the FRONT of its coil's block, since its axial coordinate is negative, so the
        // misalignment started at the first shielded coil and quietly shifted every coil outside it.
        for (segIndex, nextSegment) in coilSegments.enumerated() {

            let eddyPU = eddyLossesPU[segIndex]
            await nextSegment.SetEddyLossesPU(radial: eddyPU.radial, axial: eddyPU.axial)
        }
        
        // The inductance calculation reports one update per section (ie: per row of the matrix). Same pattern as the simulation bar: '.bufferingNewest(1)' so the solver never blocks on the UI, and the stream is drained on the main actor so AppKit can actually redraw between updates.
        let (indProgressStream, indProgressContinuation) = AsyncStream<FePhase.InductanceProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))

        let indProgressTask = Task { @MainActor in

            for await nextUpdate in indProgressStream {

                self.indCalcProgInd.doubleValue = nextUpdate.fractionComplete * 100.0
                self.indCalcProgInd.toolTip = "Section \(nextUpdate.completedSections) of \(nextUpdate.totalSections)"
            }
        }

        self.inductanceLight.textColor = .red
        self.workingLabel.isHidden = false
        self.indCalcProgInd.isIndeterminate = false
        self.indCalcProgInd.minValue = 0.0
        self.indCalcProgInd.maxValue = 100.0
        self.indCalcProgInd.doubleValue = 0.0
        self.indCalcProgInd.isHidden = false

        // The calculation is wrapped in its own Task purely so that it can be cancelled - updateModel() itself is called from several places, none of which hold onto a Task we could reach.
        let inductanceTask = Task { @MainActor in

            try await fePhase.CalculateInductanceMatrix(progress: indProgressContinuation)
        }

        self.runningInductanceTask = inductanceTask

        do {

            // Task {} is UNSTRUCTURED, so inductanceTask does not inherit this task's cancellation - being superseded would
            // otherwise leave the calculation grinding away to completion with nobody waiting for the answer. The handler forwards
            // it; the Cancel Inductance menu item goes at runningInductanceTask directly and lands in the same catch below.
            try await withTaskCancellationHandler {

                try await inductanceTask.value

            } onCancel: {

                inductanceTask.cancel()
            }

            self.runningInductanceTask = nil
            indProgressContinuation.finish()
            await indProgressTask.value

            guard let indMatrix = await fePhase.inductanceMatrix else {

                PCH_ErrorAlert(message: "An impossible error has occurred!")
                return
            }

            await model.SetInductanceMatrices(unfactoreM: indMatrix, M: try await indMatrix.FactorizedAs(.Cholesky))

            await didFinishInductanceCalculation(phase: fePhase)

            try await model.CalculateCapacitanceMatrix()
            capacitanceIsValid = true
            // DLog("Coil 0 Cs: \(try model.CoilSeriesCapacitance(coil: 0))")
            // DLog("Coil 1 Cs: \(try model.CoilSeriesCapacitance(coil: 1))")
        }
        catch {

            // Tear the indicator down on the error path too, otherwise the bar is left on screen at whatever value it had reached
            self.runningInductanceTask = nil
            indProgressContinuation.finish()
            await indProgressTask.value
            await didFinishInductanceCalculation(phase: fePhase)

            // A user-requested cancellation is not a failure, so no alert. The matrix is incomplete either way, so the model has to be marked invalid - didFinishInductanceCalculation() only sets the flag on the success path, and a previous run could have left it true.
            inductanceIsValid = false

            // Task.isCancelled covers the supersede case, where the error can be anything: the package throws CancellationError
            // from its own checkpoints, but a run cut off part way can just as well surface as a mesh or solver failure. Neither is
            // something to bother the user with when the run was abandoned on purpose.
            if error is CancellationError || Task.isCancelled {

                DLog("Inductance calculation cancelled")
            }
            else {

                let alert = NSAlert(error: error)
                let _ = alert.runModal()
            }

            // Still refresh the drawing - the segment changes that triggered this update have already been applied to the model
            if !reinitialize {

                self.updateViews()
            }

            return
        }

        if !reinitialize {

            self.updateViews()
        }
    }

    @IBAction func handleCancelInductanceCalculation(_ sender: Any) {

        // Cooperative, and the mesh routines themselves don't check for cancellation - the checkpoints in the package's InductanceForMesh() mean this takes effect within roughly one section's worth of work
        self.runningInductanceTask?.cancel()
    }
    
    /// Initialize the model using the BasicSections already created. If currentXLFile is non-nil, some extra initialziation is done _USING THAT FILE_. **If this behaviour is not desired, set currentXLFile to nil before calling this function.** If there is already a model in memory, it is lost.
    func initializeModel(basicSections:[BasicSection]) async -> PhaseModel?
    {
        // a transformer needs at least two basic sections, so...
        guard basicSections.count > 1 else {
            
            return nil
        }
        
        var result:[Segment] = []
        
        Segment.resetSerialNumber()
        
        let numCoils = BasicSection.NumberOfCoils(basicSections: basicSections)
        
        guard numCoils > 0 else {
            
            return nil
        }
        
        for coil in 0..<numCoils {
            
            var coilIsDoubleStack = false
            var coilHasEmbeddedTaps = false
            
            // locations are the basicSection index immediately UNDER the pertinent gap
            var centerGapLocation = -1
            var lowerGapLocation = -1
            var upperGapLocation = -1
            
            if let xlFile = self.currentXLfile {
                
                let wdg = await xlFile.windings[coil]
                coilIsDoubleStack = wdg.isDoubleStack
                coilHasEmbeddedTaps = wdg.numTurns.max != wdg.numTurns.nom || wdg.numTurns.min != wdg.numTurns.nom
                let numDiscs = wdg.numAxialSections
                
                // use != for XOR
                if coilIsDoubleStack != coilHasEmbeddedTaps {
                    
                    centerGapLocation = numDiscs / 2 - 1
                }
                
                // only cut the upper and lower gaps if the coil is double-stacked AND has taps
                if coilIsDoubleStack && coilHasEmbeddedTaps {
                    
                    lowerGapLocation = numDiscs / 4 - 1
                    upperGapLocation = numDiscs * 3 / 4 - 1
                }
            }
            
            let axialIndices = BasicSection.CoilEnds(coil: coil, basicSections: basicSections)
            
            guard axialIndices.first >= 0, axialIndices.last >= 0 else {
                
                return nil
            }
            
            centerGapLocation = centerGapLocation >= 0 ? centerGapLocation + axialIndices.first : -1
            lowerGapLocation = lowerGapLocation >= 0 ? lowerGapLocation + axialIndices.first : -1
            upperGapLocation = upperGapLocation >= 0 ? upperGapLocation + axialIndices.first : -1
            
            // Initialize the first connector as though the coil type is a layer/sheet
            var incomingConnector = Connector(fromLocation: .inside_lower, toLocation: .floating)
            // Change the connector for the different coil types
            let wdgType = basicSections[axialIndices.first].wdgData.type
            if wdgType == .helical {
                
                incomingConnector = Connector(fromLocation: .center_lower, toLocation: .floating)
            }
            else if wdgType == .disc {
                
                let numDiscs = BasicSection.NumAxialSections(coil: coil, basicSections: basicSections)
                if numDiscs % 2 == 0 {
                    
                    incomingConnector = Connector(fromLocation: .outside_lower, toLocation: .floating)
                }
                else {
                    
                    incomingConnector = Connector(fromLocation: .inside_lower, toLocation: .floating)
                }
            }
            
            var lastSegment:Segment? = nil
            var outgoingConnector = incomingConnector
            var forceUpperConnector = false
            
            
            do {
                
                for nextSectionIndex in axialIndices.first...axialIndices.last {
                    
                    let nextSection = basicSections[nextSectionIndex]
                    
                    let newSegment = try Segment(basicSections: [nextSection],  realWindowHeight: self.currentCore!.realWindowHeight, useWindowHeight: self.currentWindowMultiplier * self.currentCore!.realWindowHeight)
                    
                    // The "incoming" connection
                    let incomingConnection = Segment.Connection(segmentID: lastSegment?.serialNumber, connector: incomingConnector, equivalentConnections: [])
                    await newSegment.AppendConnection(connection: incomingConnection)
                    // newSegment.connections.append(incomingConnection)
                    
                    // The "outgoing" connection for the previous Segment
                    if let prevSegment = lastSegment {
                        
                        let outgoingConnection = Segment.Connection(segmentID: newSegment.serialNumber, connector: outgoingConnector)
                        await prevSegment.AppendConnection(connection: outgoingConnection)
                        // prevSegment.connections.append(outgoingConnection)
                        await prevSegment.AddEquivalentConnections(to: outgoingConnection, equ: [Segment.Connection.EquivalentConnection(parent: newSegment.serialNumber, connection: incomingConnection)])
                        // The outgoingConnection of the previous section is equivalent to the incomingConnection of this section, so mark it as such
                        await newSegment.AddEquivalentConnections(to: incomingConnection, equ: [Segment.Connection.EquivalentConnection(parent: prevSegment.serialNumber, connection: outgoingConnection)])
                    }
                    
                    // set up the connector for the outgoing connection next time through the loop
                    
                    // first we need to fix things if we had offload tapping gaps on the previous pass through the loop
                    if forceUpperConnector {
                        
                        if incomingConnector.fromIsOutside {
                            
                            incomingConnector = Connector(fromLocation: .outside_lower, toLocation: incomingConnector.toLocation)
                        }
                        else {
                            
                            incomingConnector = Connector(fromLocation: .inside_lower, toLocation: incomingConnector.toLocation)
                        }
                        
                        forceUpperConnector = false
                    }
                    
                    let fromConnection = Connector.AlternatingLocation(lastLocation: incomingConnector.fromLocation)
                    let toConnection = Connector.StandardToLocation(fromLocation: fromConnection)
                    outgoingConnector = Connector(fromLocation: fromConnection, toLocation: toConnection)
                    incomingConnector = Connector(fromLocation: toConnection, toLocation: fromConnection)
                    
                    // we need to add the final outgoing connector for the last axial section (or tapping/DV gaps)
                    if nextSectionIndex == axialIndices.last || nextSectionIndex == centerGapLocation || nextSectionIndex == lowerGapLocation || nextSectionIndex == upperGapLocation {
                        
                        outgoingConnector = Connector(fromLocation: fromConnection, toLocation: .floating)
                        
                        // we need to do some fancy stuff for tapping gaps so that the view shows their terminations correctly
                        if (nextSectionIndex != axialIndices.last) {
                            
                            if outgoingConnector.fromIsOutside {
                                
                                outgoingConnector = Connector(fromLocation: .outside_center, toLocation: .floating)
                                incomingConnector = Connector(fromLocation: .outside_center, toLocation: .floating)
                            }
                            else {
                                
                                outgoingConnector = Connector(fromLocation: .inside_center, toLocation: .floating)
                                incomingConnector = Connector(fromLocation: .inside_center, toLocation: .floating)
                            }
                            
                            forceUpperConnector = true
                        }
                        
                        await newSegment.AppendConnection(connection: Segment.Connection(segmentID: nil, connector: outgoingConnector))
                        // newSegment.connections.append(Segment.Connection(segmentID: nil, connector: outgoingConnector))
                        lastSegment = nil
                    }
                    else {
                        
                        lastSegment = newSegment
                    }
                    
                    result.append(newSegment)
                }
                
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return nil
            }
            
        }

        return PhaseModel(segments: result, core: self.currentCore!, tankDepth: self.tankDepth)
    }
    
    func createBasicSections(xlFile:PCH_ExcelDesignFile) async -> [BasicSection] {
        
        // First off, we need to find the axial centers of the coils. We do this by finding the highest coil (max electrical height) and adding half that height to its bottom-edge-pack dimension. Other coils are then inserted into the model using that same center for all coils.
        var maxHeight = 0.0
        var maxHtEdgePack = 0.0
        for nextWinding in await xlFile.windings {
            
            if nextWinding.electricalHeight > maxHeight {
                maxHeight = nextWinding.electricalHeight
                maxHtEdgePack = nextWinding.bottomEdgePack
            }
        }
        
        let axialCenter = maxHtEdgePack + maxHeight / 2.0
        
        var result:[BasicSection] = []
        
        var radialPos = 0
        
        for nextWinding in await xlFile.windings {
            
            var axialPos = 0
            let wType = nextWinding.windingType
            
            // let numMainRadialSections = 1 + (wType == .layer ? nextWinding.numRadialDucts : 0)
            
            var mainGaps:[Double] = []
            var totalMainGapDimn = 0.0
            if nextWinding.bottomDvGap > 0.0 {
                mainGaps.append(nextWinding.bottomDvGap)
                totalMainGapDimn += nextWinding.bottomDvGap
            }
            if nextWinding.centerGap > 0.0 {
                mainGaps.append(nextWinding.centerGap)
                totalMainGapDimn += nextWinding.centerGap
            }
            if nextWinding.topDvGap > 0.0 {
                mainGaps.append(nextWinding.topDvGap)
                totalMainGapDimn += nextWinding.topDvGap
            }
            
            let numMainGaps = Double(mainGaps.count)
            
            // let turnInsulation = nextWinding.turnDefinition.cable.insulation
            
            // We treat disc coils and helical coils the same way (specifically, we treat helical coils as disc coils with 1 turn per disc). For now, all other coil types are treated as one huge lumped section that spans the entire radial build by the electrical height. Note that the series capacitance calculations for those types of coils should still be done properly.
            if wType == .disc || wType == .helix {
                
                let numDiscs:Double = (wType == .disc ? Double(nextWinding.numAxialSections) : nextWinding.numTurns.max)
                let turnsPerDisc:Double = (wType == .disc ? Double(nextWinding.numTurns.max) / numDiscs : 1.0)
                
                let numStandardGaps = numDiscs - 1.0 - numMainGaps
                
                let discHt = (nextWinding.electricalHeight - (numStandardGaps * nextWinding.stdAxialGap + totalMainGapDimn) * 0.98) / numDiscs
                let discPitch = discHt + nextWinding.stdAxialGap * 0.98
                
                var perSectionDiscs:[Int] = []
                if mainGaps.count == 0 {
                    
                    perSectionDiscs = [Int(numDiscs)]
                }
                else if mainGaps.count == 1 {
                    
                    let lowerSectionDiscs = Int(round(numDiscs / 2.0))
                    let upperSectionDiscs = Int(numDiscs) - lowerSectionDiscs
                    perSectionDiscs = [lowerSectionDiscs, upperSectionDiscs]
                }
                else if mainGaps.count == 2 {
                    
                    let middleSectionDiscs = Int(round(numDiscs / 2.0))
                    let lowerSectionDiscs = Int(round((numDiscs - Double(middleSectionDiscs)) / 2.0))
                    let upperSectionDiscs = Int(numDiscs) - middleSectionDiscs - lowerSectionDiscs
                    perSectionDiscs = [lowerSectionDiscs, middleSectionDiscs, upperSectionDiscs]
                }
                else {
                    let middleSectionDiscs = round(numDiscs / 2.0)
                    let mid1 = Int(round(middleSectionDiscs / 2.0))
                    let mid2 = Int(middleSectionDiscs) - mid1
                    let outerSectionDiscs = numDiscs - middleSectionDiscs
                    let low = Int(round(outerSectionDiscs / 2.0))
                    let high = Int(outerSectionDiscs) - low
                    perSectionDiscs = [low, mid1, mid2, high]
                }
                
                var gapIndex = 0
                var currentZ = axialCenter - nextWinding.electricalHeight / 2.0
                
                for nextMainSection in perSectionDiscs {
                    
                    for sectionIndex in 0..<nextMainSection {
                        
                        let nextAxialPos = axialPos + sectionIndex
                        
                        let wdgData = BasicSectionWindingData(type: wType == .disc ? .disc : .helical, discData: BasicSectionWindingData.DiscData(numAxialColumns: nextWinding.numAxialColumns, axialColumnWidth: nextWinding.spacerWidth), layers: BasicSectionWindingData.LayerData(numLayers: 1, interLayerInsulation: 0, ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: 0, ductDimn: 0)), turn: BasicSectionWindingData.TurnData(radialDimn: nextWinding.turnDefinition.radialDimension, axialDimn: nextWinding.turnDefinition.axialDimension, turnInsulation: nextWinding.turnDefinition.cable.strandInsulation + nextWinding.turnDefinition.cable.insulation, resistancePerMeter: nextWinding.turnDefinition.resistancePerMeterAt20C, strandRadial: nextWinding.turnDefinition.cable.strandRadialDimension, strandAxial: nextWinding.turnDefinition.cable.strandAxialDimension))
                        
                        let newBasicSection = BasicSection(location: LocStruct(radial: radialPos, axial: nextAxialPos), N: turnsPerDisc, I: nextWinding.I, wdgData: wdgData, rect: NSRect(x: nextWinding.innerDiameter / 2.0, y: currentZ, width: nextWinding.electricalRadialBuild, height: discHt))
                        
                        result.append(newBasicSection)
                        
                        currentZ += discPitch
                    }
                    
                    if gapIndex < mainGaps.count {
                        
                        currentZ += (mainGaps[gapIndex] - discPitch + discHt)
                        print("Gap center: \(currentZ - mainGaps[gapIndex] / 2.0)")
                        gapIndex += 1
                    }
                    
                    axialPos += nextMainSection
                }
                
            }
            else {
                
                var bsWdgType:BasicSectionWindingData.WdgType = .sheet
                if nextWinding.windingType == .layer || nextWinding.windingType == .section {
                    bsWdgType = .layer
                }
                else if nextWinding.windingType == .multistart {
                    bsWdgType = .multistart
                }
                
                let layerData = BasicSectionWindingData.LayerData(numLayers: bsWdgType == .disc ? Int(nextWinding.numTurns.max) : nextWinding.numRadialSections, interLayerInsulation: nextWinding.interLayerInsulation, ducts: BasicSectionWindingData.LayerData.DuctData(numDucts: nextWinding.numRadialDucts, ductDimn: nextWinding.radialDuctDimension))
                
                let turnData = BasicSectionWindingData.TurnData(radialDimn: nextWinding.turnDefinition.radialDimension, axialDimn: nextWinding.turnDefinition.axialDimension, turnInsulation: nextWinding.turnDefinition.cable.strandInsulation + nextWinding.turnDefinition.cable.insulation, resistancePerMeter: nextWinding.turnDefinition.resistancePerMeterAt20C, strandRadial: nextWinding.turnDefinition.cable.strandRadialDimension, strandAxial: nextWinding.turnDefinition.cable.strandAxialDimension)
                
                // A multi-start winding's starts are its axial cables, and the spacer between one revolution of the helix and the next is
                // the design file's radial spacer - the same field a disc winding's disc-to-disc gap comes from, shrunk by the same 0.98.
                // Only 12.12 reads this; see BasicSectionWindingData.MultiStartData.
                var multiStartData:BasicSectionWindingData.MultiStartData? = nil

                if bsWdgType == .multistart {

                    multiStartData = BasicSectionWindingData.MultiStartData(numStarts: nextWinding.turnDefinition.multistartLoops, insulationBetweenStarts: nextWinding.turnDefinition.axialGapBetweenCables, gapBetweenGroups: nextWinding.stdAxialGap * 0.98)
                }

                let newBasicSection = BasicSection(location: LocStruct(radial: radialPos, axial: axialPos), N: nextWinding.numTurns.max, I: nextWinding.I, wdgData: BasicSectionWindingData(type: bsWdgType, discData: BasicSectionWindingData.DiscData(numAxialColumns: nextWinding.numAxialColumns, axialColumnWidth: nextWinding.spacerWidth), layers: layerData, turn: turnData, multiStart: multiStartData), rect: NSRect(x: nextWinding.innerDiameter / 2.0, y: axialCenter - nextWinding.electricalHeight / 2.0, width: nextWinding.electricalRadialBuild, height: nextWinding.electricalHeight))
                
                result.append(newBasicSection)
            }
            
            // set up for next time through the loop
            radialPos += 1
        }
        
        return result
    }
    
    /// Function to create the finite-element model that we'll use to get the inductance matrix and eddy losses for the current PhaseModel. It is assumed that 'model' has already been updated (or created) using 'xlFile'.
    func CreateFePhase(xlFile:PCH_ExcelDesignFile, model:PhaseModel) async -> FePhase? {
        
        let coilSegments = await model.CoilSegments()
        // do some simple checks to see if the xlFile and the model match, at least in terms of the number of coils and their basic sections
        guard let lastSegment = coilSegments.last, await lastSegment.radialPos == xlFile.windings.count - 1 else {
            
            DLog("xlFile and model coil count do not match!")
            return nil
        }
        
        var totalBasicSections = 0
        for nextSegment in coilSegments {
            
            totalBasicSections += nextSegment.basicSections.count
        }
        
        var totalFileSections = 0
        for nextWinding in await xlFile.windings {
            
            let wType = nextWinding.windingType
            
            if wType == .disc {
                
                totalFileSections += nextWinding.numAxialSections
            }
            else if wType == .helix {
                
                totalFileSections += Int(nextWinding.numTurns.max)
            }
            else {
                
                totalFileSections += 1
            }
        }
        
        guard totalFileSections == totalBasicSections else {
            
            DLog("xlFile and model section count do not match!")
            return nil
        }
        
        // The FE sections below are built one per Segment, in this array's order, and everything downstream addresses them by that
        // ordinal - recalculateModel's current assignment, PhaseModel.SegmentIndex, SimulationModel's incidence arrays. All of that
        // rests on CoilSegments() coming back sorted by (radialPos, axialPos), which PhaseModel maintains through InsertSegment's
        // binary insert. Assert it here rather than let a mis-sorted store surface hundreds of lines away as a wrong inductance
        // matrix. Note the count itself needs no assertion - it is one append per iteration - so ordering is the real invariant.
        assert(zip(coilSegments, coilSegments.dropFirst()).allSatisfy({ ($0.radialPos, $0.axialPos) < ($1.radialPos, $1.axialPos) }), "CoilSegments() is not sorted by (radialPos, axialPos)!")

        // Ok, we'll assume that the two models are compatible. Create the finite element sections & window.
        //
        // The current seeded here is Winding.I, which is legVA/legVolts and is only ever a starting value: recalculateModel
        // overwrites every one of them from the amp-turn balance before it asks for a loss. It plays no part at all in the
        // inductance sweep, which excites one ampere in one section at a time.
        var feSections:[FePhase.SectionInput] = []
        for (segIndex, nextSegment) in coilSegments.enumerated() {
            
            let wdg = await xlFile.windings[nextSegment.radialPos]
            let wdgTurn = wdg.turnDefinition
            let strandsPerTurn = wdgTurn.numCablesAxial * wdgTurn.numCablesRadial * (wdgTurn.cable.conductor == .ctc ? wdgTurn.cable.numCTCstrands :  wdgTurn.cable.numStrandsAxial * wdgTurn.cable.numStrandsRadial)
            
            let newFeSection = await FePhase.SectionInput(name: "Segment \(segIndex)", innerRadius: nextSegment.r1, outerRadius: nextSegment.r2, zMin: nextSegment.z1, zMax: nextSegment.z2, turns: nextSegment.N, strandsPerTurn: Double(strandsPerTurn), strandRadial: wdgTurn.cable.strandRadialDimension, strandAxial: wdgTurn.cable.strandAxialDimension, seriesRmsCurrent: nextSegment.I)
            
            feSections.append(newFeSection)
        }
        
        let coreCenterToTank = await xlFile.tankDepth / 2.0
        let windowHt = await xlFile.core.windowHeight
        
        do {
            
            return try await FePhase(coreRadius: xlFile.core.radius, windowHeight: windowHt, tankRadius: coreCenterToTank, frequency: xlFile.frequency, sections: feSections)
        }
        catch {
            
            // The caller raises the alert ("Could not create finite element model!"), and does so only when the run has not been
            // superseded - which is the common way to get here. The specific reason goes to the log rather than to a second alert.
            DLog("Could not create the FE model: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: Testing routines
    
    // MARK: Simulation routines

    /// Build a brand-new simulation model from the current state of the PhaseModel and install it as `currentSimModel`.
    ///
    /// # Why this is unconditional
    ///
    /// There used to be a "Create Simulation Model" menu item, and simulating was a two-step affair: create, then run. That was a
    /// development convenience - it let the matrices be dumped and inspected before committing to a run - but it made the sim model
    /// a piece of user-maintained state that nothing invalidated. Every edit made after the create (a jumper moved, a static ring
    /// added, a coil interleaved) left the model built on the old geometry, and running gave a confident answer for a design that
    /// was no longer on screen. The model is cheap next to the run it precedes, so it is now simply rebuilt every time.
    ///
    /// Everything derived from the design is rebuilt with it: the base capacitance matrix is re-read from the PhaseModel, the
    /// Dirichlet row surgery is redone against the current terminations, and the node connectivity is re-resolved from the current
    /// connectors. See `SimulationModel.init(model:)`.
    ///
    /// # The undo slot
    ///
    /// Whatever is being replaced - model, results, and the PhaseModel's fixed C - is saved into `previousSimulationState` first.
    /// Nothing offers the user an undo yet; the point is that the state needed for one is no longer thrown away.
    ///
    /// - returns: The new model, or nil if it could not be built (the user has already been told why).
    @discardableResult
    func doCreateSimulationModel() async -> SimulationModel? {

        guard let phModel = self.currentModel else {

            PCH_ErrorAlert(message: "There is no model!")
            return nil
        }

        // Captured BEFORE the new model is built, because building it is what overwrites the PhaseModel's fixed C.
        let outgoing = SimulationState(simModel: self.currentSimModel, results: self.latestSimulationResult, fixedC: await phModel.fixedC)

        guard let newModel = await SimulationModel(model: phModel) else {

            // Leave the existing model, results and undo slot alone. A failed rebuild is a refusal, not a reset - there is no
            // reason to take away the answer the user already has.
            PCH_ErrorAlert(message: "Could not create simulation model!", info: "See the log for what the model is missing.")
            return nil
        }

        self.previousSimulationState = outgoing
        self.currentSimModel = newModel
        // The old results were computed on the model that was just replaced. They are not gone - they are in the undo slot - but
        // they must not be shown next to a different network, so everything that displays a result goes dark until the new one
        // runs, the open result windows included (same argument as DiscardResultsForChangedModel's).
        self.latestSimulationResult = nil
        self.simulationLight.textColor = .red
        CloseResultWindows()

        return newModel
    }

    /// The simulation model, built if there isn't one yet.
    ///
    /// For the commands that need a model but not a run - the initial distribution, the solver comparison. They used to rely on the
    /// user having chosen "Create Simulation Model" first and refused if they hadn't; with that item gone they build one themselves.
    /// An existing model is reused rather than rebuilt, so that these commands never discard a simulation result the way
    /// doCreateSimulationModel() must.
    func doGetSimulationModel() async -> SimulationModel? {

        if let existing = self.currentSimModel {

            return existing
        }

        return await doCreateSimulationModel()
    }

    /// Put the simulation state saved by the last rebuild back.
    ///
    /// **Nothing calls this yet.** It is the other half of the undo slot, written now so that adding the command later is a xib item
    /// and a `validateMenuItem` clause rather than a rework of how the simulation model is owned. To wire it up: add an "Undo
    /// Simulation" item whose action calls this in a `Task`, validate it on `previousSimulationState != nil && runningSimulationTask
    /// == nil`, and call `updateViews()` afterwards.
    ///
    /// It swaps rather than pops, so the undo is itself undoable (which is what makes a single slot tolerable) and so that the
    /// PhaseModel's fixed C never ends up belonging to a model that is no longer installed.
    ///
    /// - returns: false if there was nothing saved to go back to.
    @discardableResult
    func doRestorePreviousSimulationModel() async -> Bool {

        guard let previous = self.previousSimulationState, let phModel = self.currentModel else {

            return false
        }

        let outgoing = SimulationState(simModel: self.currentSimModel, results: self.latestSimulationResult, fixedC: await phModel.fixedC)

        self.currentSimModel = previous.simModel
        self.latestSimulationResult = previous.results

        if let fixedC = previous.fixedC {

            await phModel.SetFixedC(newFixedC: fixedC)
        }

        self.previousSimulationState = outgoing
        self.simulationLight.textColor = self.latestSimulationResult != nil ? .green : .red

        return true
    }

    /// Rebuild the simulation model from the design as it now stands, then run the impulse on it.
    ///
    /// The rebuild is not optional and not offered separately - see doCreateSimulationModel() for why. It happens inside the
    /// simulation task, after the details dialog has been accepted, so that cancelling the dialog costs nothing and leaves the
    /// previous run's results in place.
    @IBAction func handleDoSimulate(_ sender: Any) {

        guard self.currentModel != nil else {

            DLog("No model!")
            return
        }

        var waveForms:[String] = []
        SimulationModel.WaveForm.Types.allCases.forEach {

            waveForms.append($0.rawValue)
        }
        
        let simDetailsDlog = SimDetailsDlog(waveFormStrings: waveForms)
        
        if simDetailsDlog.runModal() == .OK {

            let peakVoltage = simDetailsDlog.voltageField.doubleValue * 1000
            guard abs(peakVoltage) >= 10000 else {
                
                PCH_ErrorAlert(message: "Cannot simulate with a voltage less than 10kV!")
                return
            }
            
            let bandwidth = simDetailsDlog.bandwidthInHz

            self.runningSimulationTask = Task {

                let wfIndex = simDetailsDlog.waveFormPopUp.indexOfSelectedItem
                let waveForm = SimulationModel.WaveForm(type: SimulationModel.WaveForm.Types.allCases[wfIndex], pkVoltage: peakVoltage)

                simulationLight.textColor = .red
                simCalcProgInd.isIndeterminate = false
                simCalcProgInd.minValue = 0.0
                simCalcProgInd.maxValue = 100.0
                simCalcProgInd.doubleValue = 0.0
                simCalcProgInd.isHidden = false
                workingLabel.isHidden = false

                // The bar stays determinate and sits at zero through the rebuild, which reports no progress of its own: it is one
                // pass of matrix surgery, seconds at most against a run measured in minutes. The tooltip says what is happening,
                // which is the same channel the solver's own passes use ('workingLabel' is shared with the inductance calculation).
                simCalcProgInd.toolTip = "Building the simulation model"

                let simModel = await doCreateSimulationModel()

                guard let simModel else {

                    await didFinishSimulationRun()
                    return
                }

                // The simulation reports its progress through an AsyncStream. '.bufferingNewest(1)' is the important part: the solver never blocks waiting on the UI, and whatever we read is always the most recent value.
                let (progressStream, progressContinuation) = AsyncStream<SimulationModel.ProgressUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))

                // Each iteration of this loop resumes on the main actor, which is what actually lets AppKit redraw the bar between updates.
                let progressTask = Task { @MainActor in

                    for await nextUpdate in progressStream {

                        self.simCalcProgInd.doubleValue = nextUpdate.fractionComplete * 100.0
                        // 'workingLabel' is shared with the inductance calculation, so the pass identification goes on the bar's tooltip instead of overwriting it
                        self.simCalcProgInd.toolTip = nextUpdate.phase
                    }
                }

                // The frequency-domain solver. There is no error tolerance and no time step to pass: the integration is exact, so the only accuracy control is the bandwidth, and the resistance is evaluated at each frequency rather than estimated from a first pass.
                let simResult = await simModel.SolveFrequencyDomain(waveForm: waveForm, displaySpan: waveForm.timeToZero, maximumFrequency: bandwidth, progress: progressContinuation)

                progressContinuation.finish()
                await progressTask.value

                self.runningSimulationTask = nil

                // SolveFrequencyDomain() returns an empty array for both failure and cancellation, so check which one happened before complaining to the user
                if simResult.isEmpty {

                    if !Task.isCancelled {

                        PCH_ErrorAlert(message: "Simulation failed!")
                    }

                    await didFinishSimulationRun()
                    return
                }

                self.latestSimulationResult = SimulationResults(waveForm: waveForm, peakVoltage: peakVoltage, stepResults: simResult)
                await didFinishSimulationRun()
            }
        }
    }

    /// Runs both solvers on the same problem and reports how far apart they are.
    ///
    /// This is a correctness tool, not a feature. See SimulationModel.CompareSolvers() for why an independent second method is worth keeping around: the frequency-domain solver cannot detect its own assembly errors, because a wrong system of equations still solves cleanly.
    ///
    /// Both are pinned to the same constant resistance, so what is being compared is the two numerical methods and not the two resistance models.
    @IBAction func handleCompareSolvers(_ sender: Any) {

        guard self.currentModel != nil else {

            DLog("No model!")
            return
        }

        var waveForms:[String] = []
        SimulationModel.WaveForm.Types.allCases.forEach {

            waveForms.append($0.rawValue)
        }

        let simDetailsDlog = SimDetailsDlog(waveFormStrings: waveForms)

        guard simDetailsDlog.runModal() == .OK else {

            return
        }

        let peakVoltage = simDetailsDlog.voltageField.doubleValue * 1000
        let bandwidth = simDetailsDlog.bandwidthInHz
        let wfIndex = simDetailsDlog.waveFormPopUp.indexOfSelectedItem

        guard abs(peakVoltage) >= 10000 else {

            PCH_ErrorAlert(message: "Cannot simulate with a voltage less than 10kV!")
            return
        }

        self.runningSimulationTask = Task {

            let waveForm = SimulationModel.WaveForm(type: SimulationModel.WaveForm.Types.allCases[wfIndex], pkVoltage: peakVoltage)

            simulationLight.textColor = .red
            workingLabel.isHidden = false
            simCalcProgInd.isIndeterminate = true
            simCalcProgInd.isHidden = false
            simCalcProgInd.startAnimation(nil)

            // Unlike a run, this reuses an existing model if there is one: it is a check on the two solvers, not on the design, and
            // rebuilding here would throw away the results of whatever run the user is checking.
            guard let simModel = await doGetSimulationModel() else {

                simCalcProgInd.stopAnimation(nil)
                self.runningSimulationTask = nil
                await didFinishSimulationRun()
                return
            }

            // RK45 is slow - that is the entire reason it was replaced - so this can take a while on a full-size model. Run it on something small.
            let comparison = await simModel.CompareSolvers(waveForm: waveForm, displaySpan: waveForm.timeToZero, maximumFrequency: bandwidth)

            simCalcProgInd.stopAnimation(nil)
            self.runningSimulationTask = nil
            await didFinishSimulationRun()

            guard let comparison else {

                if !Task.isCancelled {

                    PCH_ErrorAlert(message: "One of the two solvers failed - see the log for which.")
                }
                return
            }

            let relative = comparison.peakVoltage > 0 ? comparison.worstDifference / comparison.peakVoltage : 0.0

            let alert = NSAlert()
            alert.messageText = "Solver comparison"
            alert.informativeText = String(format: "Worst nodal voltage difference: %.4g V\nPeak nodal voltage: %.4g V\nRelative: %.3e\nAt t = %.3f µs\n\nBoth solvers used the same constant resistance, so this measures the numerical methods only. Agreement at the 1e-3 level or better means both are solving the same equations correctly.", comparison.worstDifference, comparison.peakVoltage, relative, comparison.atTime * 1.0E6)
            alert.alertStyle = relative < 1.0E-2 ? .informational : .warning
            let _ = alert.runModal()
        }
    }

    @IBAction func handleCancelSimulation(_ sender: Any) {

        // Cancellation is cooperative - the task tears down its own UI when SimulateRK45() returns its empty array
        self.runningSimulationTask?.cancel()
    }

    @IBAction func handleShowWaveforms(_ sender: Any) {
        
        guard let phModel = self.currentModel, self.currentSimModel != nil else {
            
            DLog("No simulation model!")
            return
        }
        
        Task {
            
            let numCoils = await phModel.CoilCount()

            // Ranges of INDICES INTO CoilSegments(), which is what doShowWaveforms slices. Not GetHighestSection(coil:), which
            // returns an axial coordinate rather than a count and overstates the segment count for any coil holding multi-disc
            // Segments - see the note on ShowWaveFormsDialog.coilRanges.
            var coilRanges:[ClosedRange<Int>] = []
            for i in 0..<numCoils {

                do {
                    try await coilRanges.append(phModel.SegmentRange(coil: i))
                }
                catch {

                    let alert = NSAlert(error: error)
                    let _ = alert.runModal()
                    return
                }
            }

            let showWaveFormDlog = ShowWaveFormsDialog(numCoils: numCoils, coilRanges: coilRanges)
            
            if showWaveFormDlog.runModal() == .OK {
                
                let segmentRange = showWaveFormDlog.segmentRange
                DLog("Segment range: \(segmentRange)")
                
                await self.doShowWaveforms(segments: segmentRange, showVoltage: showWaveFormDlog.showVoltagesCheckBox.state == .on, showCurrent: showWaveFormDlog.showCurrentsCheckBox.state == .on, showFourier: showWaveFormDlog.showFourierCheckBox.state == .on)
                
            }
        }
    }
    
    /// Show the requested waveforms. Current waveforms are displayed for the given Segments while voltage waveforms are shown for nodes located above and below the given Segments
    /// - note: If both 'showVoltage" and 'showCurrent' are false, the routine does nothing
    func doShowWaveforms(segments:Range<Int>, showVoltage:Bool, showCurrent:Bool, showFourier:Bool) async {
        
        guard let simResult = latestSimulationResult, let model = currentModel, !segments.isEmpty && (showVoltage || showCurrent || showFourier) else {

            return
        }

        // 'segments' indexes CoilSegments(), so it has to fit. The dialog derives it from SegmentRange(coil:) and cannot produce an
        // out-of-range value, but this is cheap and it is the exact subscript that used to trap: the ranges were built from
        // GetHighestSection(coil:), an axial coordinate that overstates the count once any Segment holds more than one disc.
        let coilSegmentCount = await model.CoilSegments().count

        guard segments.lowerBound >= 0, segments.upperBound <= coilSegmentCount else {

            PCH_ErrorAlert(message: "The requested segment range is not in the model!", info: "Asked for \(segments) of \(coilSegmentCount) segments.")
            return
        }
        
        if showCurrent {
            
            let dataStride = simResult.numSteps > 1000 ? simResult.numSteps / 1000 : 1
            
            let waveformWind = WaveFormDisplayWindow(windowNibName: "WaveFormDisplayWindow")
            waveformWind.windowTitle = "Current Waveforms: Segments [\(segments.first!)-\(segments.last!)]"
            waveformWind.yQuantity = .current
            waveformWind.peakTestVoltage = simResult.peakVoltage

            var maxValue = -Double.greatestFiniteMagnitude
            var minValue = Double.greatestFiniteMagnitude

            var wfData:[[NSPoint]] = []
            for nextResultIndex in stride(from: 0, to: simResult.numSteps, by: dataStride) {
                
                let nextResult = simResult.stepResults[nextResultIndex]
                
                var stepData:[NSPoint] = []
                let x = nextResult.time * 1.0E6
                for nextSegment in segments {
                    
                    let amps = nextResult.amps[nextSegment]
                    maxValue = max(amps, maxValue)
                    minValue = min(amps, minValue)
                    let newPoint = NSPoint(x: x, y: amps)
                    stepData.append(newPoint)
                }
                
                wfData.append(stepData)
            }

            DLog("Max / Min Currents: \(maxValue)A / \(minValue)A")

            waveformWind.data = wfData
            waveformWind.showWindow(self)
        }

        if showFourier {
            
            // only show the Fourier transform for the last segment in the range
            let origSignal = simResult.ampsFor(segment: segments.upperBound - 1).compactMap({ Float($0)})
            
            // get rid of the dc-component of the signal (from https://sam-koblenski.blogspot.com/2015/11/everyday-dsp-for-programmers-dc-and.html)
            var signal:[Float] = []
            
            let alpha:Float = 0.9
            var wPrev:Float = 0.0
            for x_t in origSignal {
                
                let wNew = x_t + alpha * wPrev;
                signal.append(wNew - wPrev)
                wPrev = wNew
            }
            
            let n = signal.count
            let log2n = vDSP_Length(log2(Float(n)))
            
            guard let fftSetUp = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
                                            
                DLog("Can't create FFT Setup.")
                return
            }
            
            let halfN = Int(n / 2)
            var forwardInputReal = [Float](repeating: 0, count: halfN)
            var forwardInputImag = [Float](repeating: 0, count: halfN)
            var forwardOutputReal = [Float](repeating: 0, count: halfN)
            var forwardOutputImag = [Float](repeating: 0, count: halfN)
            
            forwardInputReal.withUnsafeMutableBufferPointer { forwardInputRealPtr in
                forwardInputImag.withUnsafeMutableBufferPointer { forwardInputImagPtr in
                    forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
                        forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in
                            
                            // Create a `DSPSplitComplex` to contain the signal.
                            var forwardInput = DSPSplitComplex(realp: forwardInputRealPtr.baseAddress!,
                                                               imagp: forwardInputImagPtr.baseAddress!)
                            
                            // Convert the real values in `signal` to complex numbers.
                            signal.withUnsafeBytes {
                                vDSP.convert(interleavedComplexVector: [DSPComplex]($0.bindMemory(to: DSPComplex.self)),
                                             toSplitComplexVector: &forwardInput)
                            }
                            
                            // Create a `DSPSplitComplex` to receive the FFT result.
                            var forwardOutput = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!,
                                                                imagp: forwardOutputImagPtr.baseAddress!)
                            
                            // Perform the forward FFT.
                            fftSetUp.forward(input: forwardInput,
                                             output: &forwardOutput)
                        }
                    }
                }
            }
            
            var xFFT:[Double] = []
            var maxIndex = -1
            var maxMag = 0.0
            for i in 0..<halfN {
                
                let compVal = Complex(Double(forwardOutputReal[i]), Double(forwardOutputImag[i]))
                let mag = compVal.length
                if mag > maxMag {
                    
                    maxMag = mag
                    maxIndex = i
                }
                
                xFFT.append(mag)
            }
            
            let fs = 1.0 / (100.0E-6 / Double(n))
            let fundFreq = Double(maxIndex) * fs / Double(n)
            DLog("Fundamental frequency: \(fundFreq)")
            
            let autospectrum = [Float](unsafeUninitializedCapacity: halfN) {
                autospectrumBuffer, initializedCount in
                
                // The `vDSP_zaspec` function accumulates its output. Clear the
                // uninitialized `autospectrumBuffer` before computing the spectrum.
                vDSP.clear(&autospectrumBuffer)
                
                forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
                    forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in
                        
                        var frequencyDomain = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!,
                                                              imagp: forwardOutputImagPtr.baseAddress!)
                        
                        vDSP_zaspec(&frequencyDomain,
                                    autospectrumBuffer.baseAddress!,
                                    vDSP_Length(halfN))
                    }
                }
                
                initializedCount = halfN
            }
            
            let waveformWind = WaveFormDisplayWindow(windowNibName: "WaveFormDisplayWindow")
            waveformWind.windowTitle = "Fourier transform for segment: \(segments.upperBound - 1)"
            // the autospectrum is a magnitude in arbitrary units, so the y-axis ticks stay unlabelled
            waveformWind.yQuantity = .unitless

            var wfData:[[NSPoint]] = []

            var x = 0.5
            for nextValue in autospectrum {

                let newPoint = NSPoint(x: x, y: Double(nextValue))
                wfData.append([newPoint])
                x += 1.0
            }

            waveformWind.data = wfData
            waveformWind.showWindow(self)
            
        }
        
        if showVoltage {
            
            let dataStride = simResult.numSteps > 1000 ? simResult.numSteps / 1000 : 1
            
            // we need to convert the segment numbers passed in to their associated nodes (top and bottom) without repeats
            var nodeSet:Set<Int> = []
            let segmentsToShow = await model.CoilSegments()[segments]
            for nextNode in await model.nodes {
                
                if let belowSeg = nextNode.belowSegment {
                    
                    if segmentsToShow.contains(belowSeg) {
                        
                        nodeSet.insert(nextNode.number)
                    }
                }
                if let aboveSeg = nextNode.aboveSegment {
                    
                    if segmentsToShow.contains(aboveSeg) {
                        
                        nodeSet.insert(nextNode.number)
                    }
                }
            }
            let nodes:[Int] = Array(nodeSet).sorted(by: { $0 < $1 })
            
            let waveformWind = WaveFormDisplayWindow(windowNibName: "WaveFormDisplayWindow")
            waveformWind.windowTitle = "Voltage Waveforms: Nodes to segments [\(segments.first!)-\(segments.last!)]"
            waveformWind.yQuantity = .voltage
            waveformWind.peakTestVoltage = simResult.peakVoltage

            var maxValue = -Double.greatestFiniteMagnitude
            var minValue = Double.greatestFiniteMagnitude
            
            var wfData:[[NSPoint]] = []
            for nextResultIndex in stride(from: 0, to: simResult.numSteps, by: dataStride) {
                
                let nextResult = simResult.stepResults[nextResultIndex]
                var stepData:[NSPoint] = []
                let x = nextResult.time * 1.0E6
                for nextNode in nodes {
                    
                    let volts = nextResult.volts[nextNode]
                    maxValue = max(volts, maxValue)
                    minValue = min(volts, minValue)
                    let newPoint = NSPoint(x: x, y: volts)
                    stepData.append(newPoint)
                }
                
                wfData.append(stepData)
            }
            
            DLog("Max / Min Voltages: \(maxValue)V / \(minValue)V")

            waveformWind.data = wfData
            waveformWind.showWindow(self)
        }
    }
    
    @IBAction func handleShowMaxVoltageDiffs(_ sender: Any) {
        
        doShowMaxVoltageDiffs()
    }
    
    func doShowMaxVoltageDiffs(nodeRange:ClosedRange<Int>? = nil) {
        
        guard let simResult = self.latestSimulationResult else {
            
            PCH_ErrorAlert(message: "You must run the simulation first!")
            return
        }
        
        Task {
            
            // the routine we are calling will take care of clamping the nodeRange to acceptable values
            let maxMatrix = await simResult.MaximumInternodalVoltages(forRange: nodeRange)
            
            let maxWindow = maxMatrix.GetViewer()
            maxWindow.window?.title = "Maximum Internodal Voltages"
            maxWindow.showWindow(self)
        }
    }
    
    
    // MARK: The capacitive initial distribution

    @IBAction func handleShowInitialDistribution(_ sender: Any) {

        Task {

            await doShowInitialDistribution()
        }
    }

    /// Graph the t = 0+ capacitive distribution of the impulsed coil.
    ///
    /// Unlike the rest of the Simulate menu this needs **no simulation result** - alpha is the s -> infinity limit of the same
    /// assembly the sweep uses, so a simulation model is enough, and one extra solve produces it. That is the point of the feature:
    /// the initial distribution is what decides whether a winding needs interleaving or shields, and it is worth knowing before
    /// committing to a run rather than after. A result is used only if one is to hand, and only to put the y axis into volts.
    func doShowInitialDistribution() async {

        guard let phModel = self.currentModel, let simModel = await doGetSimulationModel() else {

            // doGetSimulationModel() has already said why if it was the one that failed.
            return
        }

        guard let snapshot = await simModel.Snapshot(), let alpha = await FrequencyDomainSolver.CapacitiveDistribution(snapshot: snapshot) else {

            PCH_ErrorAlert(message: "The initial distribution could not be solved.", info: "This is the same assembly the frequency sweep uses, so a failure here means the capacitance matrix or the boundary conditions are not usable.")
            return
        }

        // alpha is per unit of the applied crest. Scale it into volts if a run has told us what that crest is; otherwise plot it as
        // it stands and let the graph label itself per-unit.
        let peakVoltage = self.latestSimulationResult?.peakVoltage ?? 0.0
        let inVolts = peakVoltage != 0.0
        let scale = inVolts ? peakVoltage : 1.0

        // The impulsed coils: those with a node held at the impulse. On any other coil alpha is a small residual set by the
        // shunt capacitances, which would be squashed flat beside the driven coil's curve - see the file header of
        // InitialDistributionWindow.
        //
        // Resolved through the jumpers rather than read off the connectors: a coil fed from a lead on another coil is driven just
        // as hard as the one the impulse is clipped to, and leaving it out of the picker would hide it.
        let impulsedNodeNumbers = (try? await phModel.ResolveNodeConnectivity())?.impulsed ?? []
        let impulsedNodes = await phModel.nodes.filter({ impulsedNodeNumbers.contains($0.number) })

        var impulsedCoils:Set<Int> = []

        for nextNode in impulsedNodes {

            if let coil = nextNode.aboveSegment?.radialPos ?? nextNode.belowSegment?.radialPos {

                impulsedCoils.insert(coil)
            }
        }

        guard !impulsedCoils.isEmpty else {

            PCH_ErrorAlert(message: "No coil in this model is impulsed.", info: "Attach an impulse connector to a coil terminal and simulate again.")
            return
        }

        var distributions:[InitialDistributionWindow.Distribution] = []

        for coil in impulsedCoils.sorted() {

            guard let profile = try? await phModel.CoilVoltageProfile(coil: coil), profile.count > 1 else {

                continue
            }

            // CoilVoltageProfile is sorted by ascending height. The graph's x axis is depth below the top of the coil, so that the
            // top comes out on the left - see ShowDistribution() for why that orientation.
            guard let topZ = profile.last?.z else {

                continue
            }

            var points:[(depth:Double, volts:Double)] = []

            for nextPoint in profile {

                guard nextPoint.nodeIndex >= 0, nextPoint.nodeIndex < alpha.count else {

                    continue
                }

                points.append((depth: topZ - nextPoint.z, volts: alpha[nextPoint.nodeIndex] * scale))
            }

            guard points.count > 1 else {

                continue
            }

            points.sort { $0.depth < $1.depth }

            // Which end is driven. Only the two end nodes can carry the impulse lead, so this is a lookup rather than a search for
            // the largest alpha - which would give the wrong answer on a coil driven at the bottom.
            let impulseAtTop = impulsedNodeNumbers.contains(profile.last?.nodeIndex ?? -1)

            distributions.append(InitialDistributionWindow.Distribution(name: "Coil \(coil)",
                                                                        points: points,
                                                                        impulseAtTop: impulseAtTop,
                                                                        isInVolts: inVolts))
        }

        guard let distributionWindow = InitialDistributionWindow(distributions: distributions,
                                                                 peakTestVoltage: peakVoltage,
                                                                 title: "Initial Voltage Distribution") else {

            PCH_ErrorAlert(message: "There is no initial distribution to show.", info: "The impulsed coil needs at least two nodes in the model.")
            return
        }

        self.initialDistributionWindow = distributionWindow
        distributionWindow.showWindow(self)
    }

    // MARK: Dielectric stress screen

    @IBAction func handleShowStressReport(_ sender: Any) {

        Task {

            await doShowStressReport()
        }
    }

    /// The dielectric stress findings, run if they are not already cached, and **without putting anything on the screen**.
    ///
    /// Everything that wants the findings goes through here - the table, the radial profiles, anything added later - so that no
    /// caller has to open one window in order to get the numbers for another. It used to: "Show Radial Stress Profiles" called
    /// `doShowStressReport()` to fill the cache, so the first use of that menu item opened the report table as well.
    ///
    /// The screen is cheap - the geometry is measured once and the time scan is a linear combination of node voltages per site, so
    /// a full run is milliseconds - which is why there is no progress bar and no cancel handle here, unlike the inductance and
    /// simulation paths. It still caches, because the table and the profile graph must not be able to disagree.
    ///
    /// - Returns: the findings, worst first, or an empty array if there are none (having said so in an alert).
    func StressChecks() async -> [DielectricStress.StressCheck] {

        guard self.latestStressChecks.isEmpty else {

            return self.latestStressChecks
        }

        guard let phModel = self.currentModel, let simResult = self.latestSimulationResult else {

            PCH_ErrorAlert(message: "You must run the simulation first!")
            return []
        }

        // The t = 0+ capacitive distribution. The frequency-domain solver's uniform grid starts some tens of nanoseconds in, by
        // which time the steepest part of the initial distribution has begun to relax - and that distribution is exactly where the
        // turn-to-turn gradients peak. FrequencyDomainSolver.CapacitiveDistribution gets it through the same assembly as every
        // other frequency, so it costs one extra solve and is worth having.
        var capacitiveDistribution:[Double]? = nil

        if let simModel = self.currentSimModel, let snapshot = await simModel.Snapshot() {

            capacitiveDistribution = await FrequencyDomainSolver.CapacitiveDistribution(snapshot: snapshot)
        }

        let checks = await DielectricStress.Report(model: phModel,
                                                   results: simResult.stepResults,
                                                   capacitiveDistribution: capacitiveDistribution,
                                                   peakVoltage: simResult.peakVoltage)

        guard !checks.isEmpty else {

            PCH_ErrorAlert(message: "The stress screen produced no findings.", info: "This usually means the model has no disc windings, or the simulation result is empty. Note that both solvers return an empty array for cancellation as well as for failure.")
            return []
        }

        self.latestStressChecks = checks

        return checks
    }

    /// Run the dielectric stress screen if need be, and show the ranked table.
    func doShowStressReport() async {

        let checks = await self.StressChecks()

        guard !checks.isEmpty else {

            return
        }

        let reportWindow = StressReportWindow(checks: checks, title: AppController.stressReportTitle)
        self.stressReportWindow = reportWindow
        reportWindow.showWindow(self)
    }

    /// The report window's title, in one place because `handleShowPreferences` rebuilds the window too.
    static let stressReportTitle = "Dielectric Stress Report"

    @IBAction func handleShowRadialStressProfiles(_ sender: Any) {

        Task {

            // The findings, without the table: this menu item is about the graph. They are cached, so the graph and the table
            // cannot disagree about a model.
            let checks = await self.StressChecks()

            guard !checks.isEmpty else {

                return
            }

            guard let simResult = self.latestSimulationResult else {

                return
            }

            guard let profileWindow = StressProfileWindow(checks: checks,
                                                          peakTestVoltage: simResult.peakVoltage,
                                                          title: "Radial Voltage Difference vs. Height") else {

                PCH_ErrorAlert(message: "There are no radial profiles to show.", info: "Radial profiles are built from the coil-to-coil, coil-to-core and coil-to-tank checks, which need at least one coil with nodes in the model.")
                return
            }

            self.stressProfileWindow = profileWindow
            profileWindow.showWindow(self)
        }
    }

    @IBAction func handleShowAxialStressProfile(_ sender: Any) {

        Task {

            let checks = await self.StressChecks()

            guard !checks.isEmpty else {

                return
            }

            guard let profileWindow = AxialStressProfileWindow(checks: checks, title: "Disc-to-Disc Stress vs. Height") else {

                PCH_ErrorAlert(message: "There is no axial stress profile to show.", info: "The profile is built from the disc-to-disc checks, which need at least one disc or helical winding with a node above and below it.")
                return
            }

            self.axialStressProfileWindow = profileWindow
            profileWindow.showWindow(self)
        }
    }

    @IBAction func handleShowTurnLadder(_ sender: Any) {

        Task {

            await doShowTurnLadder()
        }
    }

    /// Solve the turn-level capacitive distribution for the selected disc and report it.
    ///
    /// This is the accurate counterpart to the alpha screen in the stress report: the screen says which discs are worth looking at,
    /// and this says what is actually happening inside one of them. It is driven from the selection rather than run automatically
    /// because it is the answer to a question you ask about one or two specific discs.
    ///
    /// The neighbouring discs enter as boundary potentials taken from the lumped model, which is what makes the problem well posed
    /// - see the header of TurnLadderModel for why a whole group cannot be solved this way.
    func doShowTurnLadder() async {

        guard let phModel = self.currentModel else {

            PCH_ErrorAlert(message: "There is no model!")
            return
        }

        guard self.latestSimulationResult != nil else {

            PCH_ErrorAlert(message: "You must run the simulation first!", info: "The turn ladder needs the disc's terminal voltages, which come from the simulation.")
            return
        }

        let selected = self.txfoView.currentSegments.map { $0.segment }

        guard let segment = selected.first else {

            PCH_ErrorAlert(message: "Select a disc first.")
            return
        }

        do {

            // The scope this model claims. It was documented from the start - in the header of TurnLadderModel, in TODO.md §8 and in
            // docs/decisions.md §8 - but never enforced, so a sheet, layer, interleaved or wound-in-shield Segment was quietly run
            // through the continuous-disc ladder and given a confident answer about a winding order the ladder does not model.
            // A sheet or layer winding now has a command of its own; the other two are refused, as the decision record says.
            guard await segment.wdgType == .disc, await !segment.interleaved, await segment.woundInShield == nil, await segment.basicSections.count == 1 else {

                throw TurnLadderModel.LadderError.notContinuousDisc
            }

            let turnCount = Int((await segment.N).rounded())
            let Ctt = try await segment.CapacitanceTurnToTurn()
            let gaps = try await phModel.AxialSpacesAboutSegment(segment: segment)

            guard let bs = await segment.basicSections.first else {

                PCH_ErrorAlert(message: "That segment has no basic sections.")
                return
            }

            let Cdd = await Segment.DiscToDiscSeriesCapacitance(belowGap: gaps.below,
                                                                aboveGap: gaps.above,
                                                                basicSection: bs,
                                                                innerRadius: segment.r1,
                                                                outerRadius: segment.r2)

            let nodes = await phModel.AdjacentNodes(to: segment)

            guard let instant = await self.WorstInstant(nodes: nodes) else {

                PCH_ErrorAlert(message: "That segment's nodes are not in the simulation result.")
                return
            }

            let vStart = instant.vBelow
            let vEnd = instant.vAbove

            // A continuous disc winding alternates direction, so a disc at an even axial position winds outward.
            let windsOutward = (await segment.axialPos) % 2 == 0

            let result = try TurnLadderModel.Solve(turnCount: turnCount,
                                                   Ctt: Ctt,
                                                   CddBelow: Cdd.below,
                                                   CddAbove: Cdd.above,
                                                   windsOutward: windsOutward,
                                                   vStart: vStart,
                                                   vEnd: vEnd,
                                                   belowProfile: [],
                                                   aboveProfile: [])

            // Compare against the screening estimate for the same disc. The two are independent routes to the same quantity - the
            // screen interpolates between Stein's two exact limits, this solves the turn network - so agreement is real evidence
            // and a large disagreement is worth understanding before trusting either.
            var screenEstimate = "not available"

            if let Cs = try? await segment.BasicSectionSeriesCapacitance(), Cs > 0.0 {

                let stein = Segment.SteinParameters.For(Cs: Cs, Cdd: Cdd, endDisc: nil, adjStaticRing: nil)
                screenEstimate = String(format: "%.2fx (alpha = %.2f)", stein.gradientEnhancement, stein.alpha)
            }

            let alert = NSAlert()
            alert.messageText = "Turn Ladder: \(turnCount) turns, disc at axial position \(await segment.axialPos)"
            alert.informativeText = """
            Disc voltage at its own worst instant (\(instant.label)): \(String(format: "%.1f kV", abs(vEnd - vStart) / 1000.0)).

            Worst turn-to-turn voltage: \(String(format: "%.1f V", result.worstTurnToTurn)), between the turns at radial positions \(result.worstPosition) and \(result.worstPosition + 1).

            The linear assumption gives \(String(format: "%.1f V", result.linearTurnToTurn)), so the real distribution is \(String(format: "%.2f", result.enhancementOverLinear))x worse.

            The alpha screen's estimate of the same enhancement: \(screenEstimate)
            """
            alert.alertStyle = .informational
            alert.runModal()
        }
        catch {

            PCH_ErrorAlert(message: "The turn ladder could not be solved.", info: error.localizedDescription)
        }
    }

    /// The instant at which one Segment sees its OWN largest terminal-to-terminal voltage, with the whole node vector at that
    /// instant so that anything else in the model can be read at the same moment.
    ///
    /// Two things this fixes, and both of them understated every number the turn ladder produced.
    ///
    /// THE WORST STEP IS THE SEGMENT'S OWN. The code this replaces picked the step with the largest span over ALL the nodes in the
    /// model and then read this segment's two nodes at that instant. That is the moment the winding SET is most stressed, which is
    /// not the moment a given coil is: a low-voltage coil takes its surge by transfer and peaks well after the impulsed winding's
    /// line end does. Reading it at the HV's worst instant can understate it by any factor at all, and a sheet or layer coil - which
    /// is usually the LV - is exactly the case where the two instants are furthest apart.
    ///
    /// t = 0+ IS A CANDIDATE. Turn-to-turn and layer-to-layer gradients peak essentially at t → 0+, and the frequency-domain
    /// solver's uniform grid starts some tens of nanoseconds in, by which time the steepest part has begun to relax. The dielectric
    /// stress screen prepends `FrequencyDomainSolver.CapacitiveDistribution` for precisely this reason - see the header of
    /// `DielectricStress.Scan` - and the turn ladder scanned only the time grid, so it never saw it.
    ///
    /// The whole `volts` vector comes back, not just the two terminals, because the layer solve needs the potential of the
    /// NEIGHBOURING coil at the same instant. Reading that from a different step would be worse than not reading it at all.
    func WorstInstant(nodes:(below:Int, above:Int)) async -> (vBelow:Double, vAbove:Double, label:String, volts:[Double])? {

        guard let simResult = self.latestSimulationResult else {

            return nil
        }

        var alpha:[Double]? = nil

        if let simModel = self.currentSimModel, let snapshot = await simModel.Snapshot() {

            alpha = await FrequencyDomainSolver.CapacitiveDistribution(snapshot: snapshot)
        }

        return AppController.WorstInstant(nodes: nodes,
                                          results: simResult.stepResults,
                                          capacitiveDistribution: alpha,
                                          peakVoltage: simResult.peakVoltage)
    }

    /// The same choice, over candidate vectors that are already in hand. Split out so the scripted self-test can make it without an
    /// AppController's live state - it has the step results and the capacitive distribution already.
    static func WorstInstant(nodes:(below:Int, above:Int), results:[SimulationModel.SimulationStepResult], capacitiveDistribution:[Double]?, peakVoltage:Double) -> (vBelow:Double, vAbove:Double, label:String, volts:[Double])? {

        guard nodes.below >= 0, nodes.above >= 0 else {

            return nil
        }

        var best:(vBelow:Double, vAbove:Double, label:String, volts:[Double])? = nil

        func Consider(_ volts:[Double], _ label:String) {

            guard nodes.below < volts.count, nodes.above < volts.count else {

                return
            }

            let span = abs(volts[nodes.above] - volts[nodes.below])

            if let best, abs(best.vAbove - best.vBelow) >= span {

                return
            }

            best = (vBelow: volts[nodes.below], vAbove: volts[nodes.above], label: label, volts: volts)
        }

        if let alpha = capacitiveDistribution, !alpha.isEmpty, peakVoltage != 0.0 {

            // alpha is per-unit, normalized to a 1 V drive, exactly as DielectricStress.Scan takes it.
            Consider(alpha.map { $0 * peakVoltage }, "t = 0+, initial distribution")
        }

        for step in results {

            Consider(step.volts, String(format: "t = %.3f µs", step.time * 1.0E6))
        }

        return best
    }

    @IBAction func handleShowRadialProfile(_ sender: Any) {

        Task {

            await doShowRadialProfile()
        }
    }

    /// The conductor-to-conductor voltage profile across the radial build of a sheet or layer winding.
    ///
    /// This is the counterpart of the turn ladder for the windings whose turns run OUT rather than around, and it is the only place
    /// in the program where either type is checked at all: `DielectricStress.AppendTurnToTurnSites` takes `.disc` and nothing else,
    /// so before this a sheet or layer winding had no turn-to-turn or layer-to-layer number anywhere in the report.
    ///
    /// The two winding types share a picture and nothing else - see the note above TurnLadderModel.SolveSheet and .SolveLayer for
    /// why one is a closed-form series chain and the other needs a network solve.
    func doShowRadialProfile() async {

        guard let phModel = self.currentModel else {

            PCH_ErrorAlert(message: "There is no model!")
            return
        }

        guard self.latestSimulationResult != nil else {

            PCH_ErrorAlert(message: "You must run the simulation first!", info: "The radial profile needs the coil's terminal voltages, which come from the simulation.")
            return
        }

        guard let segment = self.txfoView.currentSegments.map({ $0.segment }).first else {

            PCH_ErrorAlert(message: "Select a sheet or layer winding first.")
            return
        }

        let wdgType = await segment.wdgType

        guard wdgType == .sheet || wdgType == .layer else {

            PCH_ErrorAlert(message: "The radial voltage profile could not be produced.", info: TurnLadderModel.LadderError.notRadialWinding.localizedDescription)
            return
        }

        let nodes = await phModel.AdjacentNodes(to: segment)

        guard let instant = await self.WorstInstant(nodes: nodes) else {

            PCH_ErrorAlert(message: "That segment's nodes are not in the simulation result.")
            return
        }

        do {

            let contents = try await AppController.BuildRadialProfile(model: phModel, segment: segment, instant: instant)

            let window = RadialProfileWindow(contents: contents, peakTestVoltage: self.latestSimulationResult?.peakVoltage ?? 0.0)

            self.radialProfileWindow = window
            window.showWindow(self)
        }
        catch {

            PCH_ErrorAlert(message: "The radial voltage profile could not be produced.", info: error.localizedDescription)
        }
    }

    /// The solid insulation in a plain gap, for the annotation, and where the figure came from.
    ///
    /// Worth a row of its own because it is the one dimension the whole profile turns on and the only one a reader cannot check
    /// against the picture: every gap voltage is proportional to its reduced thickness, so a wrong τ moves every number here. Both
    /// winding types read `interLayerInsulation` from the design file - a foil turn is a layer - and both fall back to what is left
    /// of the radial build when the file leaves it at zero. The fallback is NOT the same quantity: the build carries a percentage
    /// overbuild allowance and no insulation term, so what is left over is that allowance and not a dimension. The row says which
    /// one is in force rather than leaving a reader to work it out.
    static func GapInsulationNote(gaps:[(radius:Double, capacitance:Double, insulation:Double, duct:Double)], basicSection:BasicSection, between:String) -> String {

        let tau = gaps.first?.insulation ?? 0.0
        let fromDesignFile = basicSection.wdgData.layers.interLayerInsulation > 0.0

        return String(format: "%.3f mm between %@%@", tau * 1000.0, between, fromDesignFile ? "" : ", derived from the radial build — the design file gives none")
    }

    /// Everything the radial profile window draws, assembled from the model.
    ///
    /// This is separate from the command above it so that the scripted self-test can build the same window from the same numbers
    /// without a selection or a menu - which is the only way the DRAWING gets exercised, since nothing about a plot running off its
    /// axis is visible to an assertion. See SelfTest.RenderGraphs.
    static func BuildRadialProfile(model:PhaseModel, segment:Segment, instant:(vBelow:Double, vAbove:Double, label:String, volts:[Double])) async throws -> RadialProfileWindow.Contents {

        let coil = await segment.radialPos
        let wdgType = await segment.wdgType
        let profile:TurnLadderModel.RadialProfile
        let gapColumns:[[DielectricLayer]]
        /// Which gaps hold a cooling duct, gap for gap with the profile. The annotation reports the worst ducted gap and the worst
        /// plain one separately, because a duct takes some fifty times the volts of the paper beside it and is allowed a great deal
        /// more, so the two are not on the same scale and the larger ΔV is not the gap in trouble.
        let gapHasDuct:[Bool]
        let usesCornerModel:Bool
        let cornerRadius:Double?
        var notes:[(label:String, value:String)] = []
        var screenEstimate:Double? = nil
        let ductedGapCount:Int
        var equalSpacing:RadialProfileWindow.EqualSpacingComparison? = nil

        guard let bs = await segment.basicSections.first else {

            throw TurnLadderModel.LadderError.noGaps
        }

        if wdgType == .sheet {

            let gaps = try await segment.SheetGapCapacitances()

            profile = try TurnLadderModel.SolveSheet(gapCapacitances: gaps.map { $0.capacitance },
                                                     gapRadii: gaps.map { $0.radius },
                                                     segmentVoltage: instant.vAbove - instant.vBelow)

            // Two smooth broad faces of foil, so there is NO conductor corner to concentrate the field - the physical difference
            // between this and a disc's turn-to-turn site, where the strand corner is what governs. A foil EDGE is a different site
            // altogether and is not this check. Where a cooling duct sits in the gap, the oil goes into the column behind the paper.
            gapColumns = gaps.map { gap in

                var column = [DielectricLayer.Paper(gap.insulation)]

                if gap.duct > 0.0 {

                    column.append(DielectricLayer.Oil(gap.duct))
                }

                return column
            }

            usesCornerModel = false
            cornerRadius = nil
            gapHasDuct = gaps.map { $0.duct > 0.0 }

            ductedGapCount = gaps.filter { $0.duct > 0.0 }.count

            notes.append((label: "Winding:", value: "sheet, \(Int((await segment.N).rounded())) turns"))
            notes.append((label: "Model:", value: "series chain, each gap at its own radius"))
            notes.append((label: "Insulation:", value: AppController.GapInsulationNote(gaps: gaps, basicSection: bs, between: "turns")))
            notes.append((label: "Ducts:", value: ductedGapCount > 0 ? "\(ductedGapCount), at gaps \(gaps.enumerated().filter { $0.element.duct > 0.0 }.map { String($0.offset + 1) }.joined(separator: ", "))" : "none"))

            // THE EQUAL-SPACING CONVENTION, beside the model rather than instead of it: ID to OD less the copper, divided equally over
            // the gaps, ducts and all - see Segment.SheetGapCapacitancesEqualSpacing. Same coil voltage, same instant, so the two
            // curves differ only in how the ducts are treated. A failure here (a build the copper fills) costs the comparison and
            // nothing else.
            //
            // Its worst ΔV is judged across the insulation REALLY between two turns where there is no duct - the plain gap of the
            // model above - because the spacing it was divided with has oil smeared into it and is no material at all. That is the
            // question the convention is normally asked to answer: is the turn paper good for this voltage.
            if let equalGaps = try? await segment.SheetGapCapacitancesEqualSpacing(), !equalGaps.isEmpty,
               let equalProfile = try? TurnLadderModel.SolveSheet(gapCapacitances: equalGaps.map { $0.capacitance },
                                                                  gapRadii: equalGaps.map { $0.radius },
                                                                  segmentVoltage: instant.vAbove - instant.vBelow),
               let worst = equalProfile.worst {

                var allowable:Double? = nil
                var utilization = 0.0
                var material = "-"

                if let plain = gaps.first(where: { $0.duct == 0.0 }), plain.insulation > 0.0 {

                    let site = DielectricStress.StressSite(kind: .turnToTurn,
                                                           location: "Coil \(coil), gap \(worst.index + 1), equal spacing",
                                                           voltageTerms: [],
                                                           columns: [[DielectricLayer.Paper(plain.insulation)]],
                                                           innerRadius: worst.radius - plain.insulation / 2.0,
                                                           usesCornerModel: false,
                                                           gapLength: plain.insulation)

                    if let check = DielectricStress.Evaluate(site: site, deltaV: worst.deltaV, time: 0.0), check.averageUtilization > 0.0 {

                        allowable = worst.deltaV / check.averageUtilization
                        utilization = check.averageUtilization
                        material = "\(check.material)"
                    }
                }

                equalSpacing = RadialProfileWindow.EqualSpacingComparison(spacing: equalGaps[0].spacing,
                                                                          deltaV: equalProfile.gaps.map { $0.deltaV },
                                                                          worstIndex: worst.index,
                                                                          worstDeltaV: worst.deltaV,
                                                                          allowableDeltaV: allowable,
                                                                          utilization: utilization,
                                                                          material: material)
            }
        }
        else if wdgType == .layer {

            let turnCounts = try await segment.LayerTurnCounts()
            let gaps = try await segment.LayerGapCapacitances()
            let Ctt = try await segment.CapacitanceTurnToTurn()

            // What lies on each side of the coil. The capacitance between two coils is the OUTER one's inner shunt, so the path out
            // of the outside of this coil is the next coil's inner shunt - or, for the outermost coil, the tank and the next phase.
            let coilCount = await model.CoilCount()
            let innerGround = (try? await model.CoilInnerShuntCapacitance(coil: coil)) ?? 0.0
            let outerGround:Double

            if coil + 1 < coilCount {

                outerGround = (try? await model.CoilInnerShuntCapacitance(coil: coil + 1)) ?? 0.0
            }
            else {

                let outer = try? await model.OuterShuntCapacitance()
                outerGround = (outer?.tank ?? 0.0) + (outer?.adjacentPhase ?? 0.0)
            }

            let zBottom = await segment.z1
            let zTop = await segment.z2

            let geometry = TurnLadderModel.LayerGeometry(turnCounts: turnCounts,
                                                         gapCapacitances: gaps.map { $0.capacitance },
                                                         gapRadii: gaps.map { $0.radius },
                                                         Ctt: Ctt,
                                                         innerGroundCapacitance: innerGround,
                                                         outerGroundCapacitance: outerGround,
                                                         zBottom: zBottom,
                                                         zTop: zTop)

            // The neighbours' potentials at THIS instant, sampled at the height of each axial slot. A core or a tank is at ground; a
            // coil is at whatever its own profile says at that height, held at the nearest value past its ends - the same rule the
            // radial stress screen uses for coils of unequal height. The slot grid is the geometry's own, so the sample heights are
            // the ones the solve puts its turns at.
            let innerProfile = coil > 0 ? try? await model.CoilVoltageProfile(coil: coil - 1) : nil
            let outerProfile = coil + 1 < coilCount ? try? await model.CoilVoltageProfile(coil: coil + 1) : nil

            func Sampled(_ points:[PhaseModel.CoilProfilePoint]?) -> [Double] {

                return (0..<geometry.slotCount).map { slot in

                    return AppController.PotentialAt(profile: points, z: geometry.SlotHeight(slot), volts: instant.volts)
                }
            }

            profile = try TurnLadderModel.SolveLayer(geometry: geometry,
                                                     vStart: instant.vBelow,
                                                     vEnd: instant.vAbove,
                                                     innerNeighbourPotential: Sampled(innerProfile),
                                                     outerNeighbourPotential: Sampled(outerProfile))

            // The inter-layer gap is the composite LayerToLayerCapacitance models: solid insulation, plus the duct where there is
            // one. Two conductor turns face each other across it, so the corner model applies exactly as it does to a disc's
            // turn-to-turn site.
            gapColumns = gaps.map { gap in

                var column = [DielectricLayer.Paper(gap.insulation)]

                if gap.duct > 0.0 {

                    column.append(DielectricLayer.Oil(gap.duct))
                }

                return column
            }

            usesCornerModel = true
            cornerRadius = DielectricStress.CornerRadius(thickness: bs.wdgData.turn.strandRadial, width: bs.wdgData.turn.strandAxial)
            gapHasDuct = gaps.map { $0.duct > 0.0 }

            // The classical screen for the same quantity, from the coil's LUMPED capacitances rather than from the turn network:
            // alpha = sqrt(Cg/Cs) and a line-end gradient of alpha/tanh(alpha). This is the layer-winding counterpart of the alpha
            // figure the turn ladder reports beside its own answer, and it is worth having for exactly the same reason - the two
            // are independent routes to one number, so agreement is real evidence and a large disagreement is worth understanding
            // before trusting either. They are not the SAME quantity (this solves for the worst inter-layer gap against twice the
            // volts per layer, while alpha/tanh alpha is the continuum line-end gradient of a uniform winding), so they are not
            // expected to agree exactly - on the SheetAndLayer fixture they come out at 2.46x and 2.71x.
            if let Cs = try? await model.CoilSeriesCapacitance(coil: coil), Cs > 0.0 {

                let alpha = sqrt((innerGround + outerGround) / Cs)
                screenEstimate = alpha > 0.0 ? alpha / tanh(alpha) : nil
            }

            ductedGapCount = gaps.filter { $0.duct > 0.0 }.count

            // The turns per layer is N/L and is generally fractional, so it is shown as the one number every layer holds rather than
            // as a list of whole counts that the winding does not actually have.
            let totalTurns = turnCounts.reduce(0.0, +)

            notes.append((label: "Winding:", value: String(format: "layer, %d layers, %.0f turns, %.4g turns/layer", turnCounts.count, totalTurns, totalTurns / Double(turnCounts.count))))
            notes.append((label: "Sense:", value: "starts at the innermost layer, at the lower node"))
            notes.append((label: "Insulation:", value: AppController.GapInsulationNote(gaps: gaps, basicSection: bs, between: "layers")))
            notes.append((label: "Ducts:", value: ductedGapCount > 0 ? "\(ductedGapCount), at gaps \(gaps.enumerated().filter { $0.element.duct > 0.0 }.map { String($0.offset + 1) }.joined(separator: ", "))" : "none"))
        }
        else {

            throw TurnLadderModel.LadderError.notRadialWinding
        }

        // Each gap through the SAME evaluation the stress report uses, so a number here and a number there cannot disagree about what
        // paper withstands. The allowable ΔV is deltaV/averageUtilization, which is exact because the field is linear in the driving
        // voltage - the trick both stress-profile windows already use.
        var points:[RadialProfileWindow.GapPoint] = []

        for gap in profile.gaps {

            let column = gap.index < gapColumns.count ? gapColumns[gap.index] : []
            let thickness = column.reduce(0.0) { $0 + $1.thickness }

            var site = DielectricStress.StressSite(kind: .turnToTurn,
                                                   location: "Coil \(coil), gap \(gap.index + 1)",
                                                   voltageTerms: [],
                                                   columns: column.isEmpty ? [] : [column],
                                                   innerRadius: gap.radius - thickness / 2.0,
                                                   usesCornerModel: usesCornerModel,
                                                   gapLength: thickness)

            if let cornerRadius {

                site.cornerRadius = cornerRadius
                site.farCornerRadius = cornerRadius
            }

            let check = DielectricStress.Evaluate(site: site, deltaV: gap.deltaV, time: 0.0)

            points.append(RadialProfileWindow.GapPoint(index: gap.index,
                                                       radius: gap.radius,
                                                       deltaV: gap.deltaV,
                                                       allowableDeltaV: check.flatMap { $0.averageUtilization > 0.0 ? gap.deltaV / $0.averageUtilization : nil },
                                                       utilization: check?.averageUtilization ?? 0.0,
                                                       worstHeight: gap.worstHeight,
                                                       material: check.map { "\($0.material)" } ?? "-",
                                                       hasDuct: gap.index < gapHasDuct.count ? gapHasDuct[gap.index] : false))
        }

        // The TURN-TO-TURN site of a layer winding, which the solve found in the same network the gaps came out of. It is not a gap
        // and does not go on the graph: the graph is per gap and this is one number for the coil.
        //
        // The site is two conductors stacked AXIALLY at the same radius, so the field is laminar rather than coaxial - hence no
        // innerRadius, where every gap above has one - and the stack between them is the turns' own paper. τ is the TWO-SIDED turn
        // insulation, which is the whole of what is in the gap because each of the two turns contributes half of it (standing rule 4,
        // and the same τ CapacitanceTurnToTurn builds the Ctt this ΔV was solved through).
        //
        // Built EXACTLY as AppendTurnToTurnSites builds a disc's turn-to-turn site - two half-wraps rather than one span of τ, and
        // the same conductor corner at both ends - so that the two screens cannot disagree about what a turn's paper withstands. The
        // split is not cosmetic: the allowable is evaluated at the GOVERNING LAYER'S own thickness, and thinner paper is allowed a
        // higher field, so one layer of τ and two of τ/2 give different utilizations for the same volts.
        var turnToTurn:RadialProfileWindow.TurnToTurnPoint? = nil

        if let pair = profile.turnToTurn, bs.wdgData.turn.turnInsulation > 0.0 {

            let tau = bs.wdgData.turn.turnInsulation

            var site = DielectricStress.StressSite(kind: .turnToTurn,
                                                   location: "Coil \(coil), layer \(pair.layer + 1), turn to turn",
                                                   voltageTerms: [],
                                                   columns: [[DielectricLayer.Paper(tau / 2.0), DielectricLayer.Paper(tau / 2.0)]],
                                                   innerRadius: nil,
                                                   usesCornerModel: usesCornerModel,
                                                   gapLength: tau)

            if let cornerRadius {

                site.cornerRadius = cornerRadius
                site.farCornerRadius = cornerRadius
            }

            let check = DielectricStress.Evaluate(site: site, deltaV: pair.deltaV, time: 0.0)

            turnToTurn = RadialProfileWindow.TurnToTurnPoint(deltaV: pair.deltaV,
                                                             allowableDeltaV: check.flatMap { $0.averageUtilization > 0.0 ? pair.deltaV / $0.averageUtilization : nil },
                                                             utilization: check?.averageUtilization ?? 0.0,
                                                             layer: pair.layer,
                                                             height: pair.height,
                                                             insulation: tau,
                                                             material: check.map { "\($0.material)" } ?? "-")
        }

        notes.append((label: "Coil voltage:", value: String(format: "%.2f kV", abs(profile.segmentVoltage) / 1000.0)))
        notes.append((label: "At:", value: instant.label))
        notes.append((label: profile.referenceName + ":", value: RadialProfileWindow.Volts(profile.reference)))

        return RadialProfileWindow.Contents(coil: coil,
                                            isSheet: wdgType == .sheet,
                                            points: points,
                                            enhancement: profile.enhancementOverReference,
                                            reference: profile.reference,
                                            ductedGapCount: ductedGapCount,
                                            screenEstimate: screenEstimate,
                                            turnToTurn: turnToTurn,
                                            notes: notes,
                                            equalSpacing: equalSpacing)
    }

    /// A coil's potential at a height, held at the nearest node past either end of it.
    ///
    /// A nil or empty profile is a core or a tank rather than a coil, and those are at ground. Past the end of a shorter coil the
    /// field is genuinely two-dimensional and the nearest potential is the best a one-dimensional model can say - the same rule, and
    /// the same caveat, as `DielectricStress.AppendRadialSites`.
    static func PotentialAt(profile:[PhaseModel.CoilProfilePoint]?, z:Double, volts:[Double]) -> Double {

        guard let profile, !profile.isEmpty else {

            return 0.0
        }

        func Volts(_ point:PhaseModel.CoilProfilePoint) -> Double {

            guard point.nodeIndex >= 0, point.nodeIndex < volts.count else { return 0.0 }
            return volts[point.nodeIndex]
        }

        guard let first = profile.first, let last = profile.last else {

            return 0.0
        }

        if z <= first.z { return Volts(first) }
        if z >= last.z { return Volts(last) }

        for i in 0..<(profile.count - 1) {

            let low = profile[i]
            let high = profile[i + 1]

            if z >= low.z, z <= high.z {

                let span = high.z - low.z

                guard span > 0.0 else { return Volts(low) }

                let fraction = (z - low.z) / span
                return Volts(low) + fraction * (Volts(high) - Volts(low))
            }
        }

        return Volts(last)
    }

    @IBAction func handleShowCoilResults(_ sender: Any) {
        
        guard let phModel = self.currentModel, self.currentSimModel != nil else {
            
            DLog("No simulation model!")
            return
        }
        
        Task {
            
            let coilCount = await phModel.CoilCount()
            guard let showCoilResultsDlog = ShowCoilResultsDialog(numCoils: coilCount) else {
                
                DLog("Couldn't open dialog box!")
                return
            }
            
            if showCoilResultsDlog.runModal() == .OK {
                
                let coilSelected = showCoilResultsDlog.coilPicker.indexOfSelectedItem
                
                var segmentRange:ClosedRange<Int> = 0...0
                
                do {
                    
                    segmentRange = try await phModel.SegmentRange(coil: coilSelected)
                    // let coilBase = coilSelected == 0 ? 0 : try phModel.GetHighestSection(coil: coilSelected - 1) + 1
                    // let coilTop = try phModel.GetHighestSection(coil: coilSelected) + coilBase
                    // segmentRange = coilBase...coilTop
                }
                catch {
                    
                    PCH_ErrorAlert(message: error.localizedDescription)
                    return
                }
                
                await doShowCoilResults(totalAnimationTime: showCoilResultsDlog.animationTimeTextField.doubleValue, segments: segmentRange, showVoltage: showCoilResultsDlog.voltagesCheckBox.state == .on, showCurrent: showCoilResultsDlog.currentsCheckBox.state == .on)
            }
        }
    }
    
    func doShowCoilResults(totalAnimationTime:Double, segments:ClosedRange<Int>, showVoltage:Bool, showCurrent:Bool) async {
        
        guard let phModel = self.currentModel, let simResult = self.latestSimulationResult, !segments.isEmpty else {
            
            DLog("No model or simulation results!")
            return
        }
        
        if showVoltage {
            
            // The node dimensions will look wrong for end discs that do not have static rings (the above/below value returned by AxialSpacesAboutSegment() will be half the distance to the core) so we'll set a maximum for those
            let greatestExtremeDimension = 0.1 * meterPerInch
            // For offload taps (and, eventually, breaks within the coil) set the distance to the "floating" node as 1mm
            let axialBreakDimension = 0.001
            
            do {
                
                let coilSegments = await phModel.CoilSegments()
                let coilIndex = coilSegments[segments.lowerBound].radialPos
                let highestSection = try await phModel.GetHighestSection(coil: coilIndex)
                
                // var runningDim = 0.0 // try phModel.AxialSpacesAboutSegment(segment: coilSegments[segments.lowerBound]).below / 2.0
                /*
                if coilSegments[segments.lowerBound].axialPos == 0 {
                    
                    runningDim = min(greatestExtremeDimension, runningDim)
                } */
                
                var xDims:[Double] = [] // [runningDim * 1000.0]
                
                for segIndex in segments {
                    
                    let theSegment = coilSegments[segIndex]
                    
                    let realAxialSpaces = try await phModel.AxialSpacesAboutSegment(segment: theSegment)
                    var axialSpaceBelow = realAxialSpaces.below / 2.0
                    var axialSpaceAbove = realAxialSpaces.above / 2.0
                    
                    // we'll fix some variables for taking care of coil starts, ends, and tapping breaks
                    if theSegment.axialPos == 0 {
                        
                        xDims = await [(theSegment.z1 - greatestExtremeDimension) * 1000.0]
                        axialSpaceBelow = greatestExtremeDimension
                    }
                    else if segIndex == segments.lowerBound {
                        
                        xDims = await [(theSegment.z1 - axialSpaceBelow) * 1000.0]
                    }
                    else if theSegment.axialPos == highestSection {
                        
                        axialSpaceAbove = greatestExtremeDimension
                    }
                    else {
                        
                        let prevSegment = coilSegments[segIndex - 1]
                        let nextSegment = coilSegments[segIndex + 1]
                        let tappingGapBelow = await phModel.IsTappingGap(segment1: prevSegment, segment2: theSegment)
                        let tappingGapAbove = await phModel.IsTappingGap(segment1: theSegment, segment2: nextSegment)
                        if tappingGapAbove {
                            
                            axialSpaceAbove = axialBreakDimension
                        }
                        else if tappingGapBelow {
                            
                            let startDim = await theSegment.z1 - axialBreakDimension
                            xDims.append(startDim * 1000.0)
                            axialSpaceBelow = axialBreakDimension
                        }
                    }
                    
                    /*
                    let realAxialSpaces = try phModel.AxialSpacesAboutSegment(segment: theSegment)
                    let axialSpaceBelow = theSegment.axialPos == 0 ? min(greatestExtremeDimension, realAxialSpaces.below / 2.0) : realAxialSpaces.below / 2.0
                    let axialSpaceAbove = theSegment.axialPos == highestSection ? min(greatestExtremeDimension, realAxialSpaces.above / 2.0) : realAxialSpaces.above / 2.0
                    */
                    let newDim = await xDims.last! / 1000.0 + axialSpaceBelow + theSegment.rect.height + axialSpaceAbove
                    // segment dimensions are in meters, convert to mm
                    xDims.append(newDim * 1000.0)
                }
                
                let lowNode = await phModel.AdjacentNodes(to: coilSegments[segments.lowerBound]).below
                let hiNode = await phModel.AdjacentNodes(to: coilSegments[segments.upperBound]).above
                
                self.coilResultsWindow = CoilResultsDisplayWindow(windowTitle: "Voltage: Segments [\(segments.lowerBound)-\(segments.upperBound)]", showVoltages: true, xDimensions: xDims, resultData: simResult, indicesToDisplay: ClosedRange(uncheckedBounds: (lowNode, hiNode)), totalAnimationTime: totalAnimationTime)
                
                self.coilResultsWindow!.showWindow(self)
            }
            catch {
                
                PCH_ErrorAlert(message: error.localizedDescription)
                return
            }
        }
    }
    
    // MARK: Matrix display routines
    
    @IBAction func handleShowBaseCmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        Task {
            
            guard let Cmatrix = await model.C else {
                
                return
            }
            
            let capWindow = Cmatrix.GetViewer()
            capWindow.window?.title = "Base (unfixed) Capacitance Matrix"
            capWindow.showWindow(self)
        }
    }
    
    
    @IBAction func handleShowUnfactoredMmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        Task {
            
            guard let Mmatrix = await model.unfactoredM else {
                
                return
            }
            
            let mWindow = Mmatrix.GetViewer()
            mWindow.window?.title = "Unfactored Inductance Matrix"
            mWindow.showWindow(self)
        }
    }
    
    // MARK: File routines
    func doOpen(fileURL:URL) -> Bool {
        
        if !FileManager.default.fileExists(atPath: fileURL.path)
        {
            let alert = NSAlert()
            alert.messageText = "The file does not exist!"
            alert.alertStyle = .critical
            let _ = alert.runModal()
            return false
        }
        
        do {
            
            // create the current Transformer from the Excel design file
            let xlFile = try PCH_ExcelDesignFile(designFile: fileURL)
            
            // if we make it here, we have successfully opened the file, so save it as the "last successfully opened file"
            UserDefaults.standard.set(fileURL, forKey: LAST_OPENED_INPUT_FILE_KEY)
                
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            
            Task {
                await self.updateModel(oldSegments: [], newSegments: [], xlFile: xlFile, reinitialize: true, designFile: fileURL)
            }
            
            self.mainWindow.title = fileURL.lastPathComponent
                        
            return true
        }
        catch
        {
            let alert = NSAlert(error: error)
            let _ = alert.runModal()
            return false
        }
    }
    
    /// Save the unfactored inductance matrix as a CSV file
    @IBAction func handleSaveRawMmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        guard let uttptxtType = UTType(filenameExtension: "txt") else {
            
            DLog("Couldn't create UTType for txt!");
            return;
        }
        
        Task {
            
            guard let Mmatrix = await model.unfactoredM else {
                return
            }
            let csvFileString = await Mmatrix.csv
            
            let savePanel = NSSavePanel()
            savePanel.title = "Inductance Matrix"
            savePanel.message = "Save Unfactored Inductance Matrix as CSV file"
            // savePanel.allowedFileTypes = ["txt"]
            savePanel.allowedContentTypes = [uttptxtType];
            savePanel.allowsOtherFileTypes = false
            
            if savePanel.runModal() == .OK
            {
                if let fileUrl = savePanel.url
                {
                    do {
                        
                        try csvFileString.write(to: fileUrl, atomically: false, encoding: .utf8)
                    }
                    catch {
                        
                        let alert = NSAlert(error: error)
                        let _ = alert.runModal()
                        return
                    }
                }
            }
        }
    }
    
    /// Save the factored inductance 
    @IBAction func handleSaveMmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        guard let uttptxtType = UTType(filenameExtension: "txt") else {
            
            DLog("Couldn't create UTType for txt!");
            return;
        }
        
        Task {
            
            guard let Mmatrix = await model.M else {
                return
            }
            let csvFileString = await Mmatrix.csv
            
            let savePanel = NSSavePanel()
            savePanel.title = "Inductance Matrix"
            savePanel.message = "Save Inductance Matrix as CSV file"
            // savePanel.allowedFileTypes = ["txt"]
            savePanel.allowedContentTypes = [uttptxtType];
            savePanel.allowsOtherFileTypes = false
            
            if savePanel.runModal() == .OK
            {
                if let fileUrl = savePanel.url
                {
                    do {
                        
                        try csvFileString.write(to: fileUrl, atomically: false, encoding: .utf8)
                    }
                    catch {
                        
                        let alert = NSAlert(error: error)
                        let _ = alert.runModal()
                        return
                    }
                }
            }
        }
    }
    
    @IBAction func handleBmatrixSave(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        guard let uttptxtType = UTType(filenameExtension: "txt") else {
            
            DLog("Couldn't create UTType for txt!")
            return
        }
        
        Task {
            
            do {
                
                let Bmatrix = try await model.GetBmatrix()
                
                let csvFileString = await Bmatrix.csv
                
                let savePanel = NSSavePanel()
                savePanel.title = "B Matrix"
                savePanel.message = "Save B Matrix as CSV file"
                // savePanel.allowedFileTypes = ["txt"]
                savePanel.allowedContentTypes = [uttptxtType];
                savePanel.allowsOtherFileTypes = false
                
                if savePanel.runModal() == .OK
                {
                    if let fileUrl = savePanel.url
                    {
                        try csvFileString.write(to: fileUrl, atomically: false, encoding: .utf8)
                    }
                }
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    
    @IBAction func handleSaveBaseCmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        guard let uttptxtType = UTType(filenameExtension: "txt") else {
            
            DLog("Couldn't create UTType for txt!")
            return
        }
        
        Task {
            
            guard let Cmatrix = await model.C  else {
                return
            }
            let csvFileString = await Cmatrix.csv
            
            let savePanel = NSSavePanel()
            savePanel.title = "Base Capacitance Matrix"
            savePanel.message = "Save Capacitance Matrix as CSV file"
            // savePanel.allowedFileTypes = ["txt"]
            savePanel.allowedContentTypes = [uttptxtType]
            savePanel.allowsOtherFileTypes = false
            
            if savePanel.runModal() == .OK
            {
                if let fileUrl = savePanel.url
                {
                    do {
                        
                        try csvFileString.write(to: fileUrl, atomically: false, encoding: .utf8)
                    }
                    catch {
                        
                        let alert = NSAlert(error: error)
                        let _ = alert.runModal()
                        return
                    }
                }
            }
        }
    }
    
    @IBAction func handleSaveFixedCmatrix(_ sender: Any) {
        
        guard let model = self.currentModel else {
            
            return
        }
        
        guard let uttptxtType = UTType(filenameExtension: "txt") else {
            
            DLog("Couldn't create UTType for txt!")
            return
        }
        
        Task {
            
            guard let Cmatrix = await model.fixedC else {
                return
            }
            let csvFileString = await Cmatrix.csv
            
            let savePanel = NSSavePanel()
            savePanel.title = "Fixed Capacitance Matrix"
            savePanel.message = "Save Capacitance Matrix as CSV file"
            savePanel.allowedContentTypes = [uttptxtType]
            savePanel.allowsOtherFileTypes = false
            
            if savePanel.runModal() == .OK
            {
                if let fileUrl = savePanel.url
                {
                    do {
                        
                        try csvFileString.write(to: fileUrl, atomically: false, encoding: .utf8)
                    }
                    catch {
                        
                        let alert = NSAlert(error: error)
                        let _ = alert.runModal()
                        return
                    }
                }
            }
        }
    }
    
    
    // MARK: Zoom functions
    @IBAction func handleZoomIn(_ sender: Any) {
        
        self.txfoView.handleZoomIn()
    }
    
    
    
    
    @IBAction func handleZoomOut(_ sender: Any) {
        
        self.txfoView.handleZoomOut()
    }
    
    
    
    
    @IBAction func handleZoomAll(_ sender: Any) {
        
        guard self.currentModel != nil, /* model.segments.count > 0,*/ let core = self.currentCore else
        {
            return
        }
        
        self.txfoView.handleZoomAll(coreRadius: CGFloat(core.radius), windowHt: CGFloat(core.realWindowHeight), tankWallR: CGFloat(self.tankDepth / 2.0))
    }
    
    
    
    
    @IBAction func handleZoomRect(_ sender: Any) {
        
        guard self.currentModel != nil /*, model.segments.count > 0 */ else
        {
            return
        }
        
        self.txfoView.mode = .zoomRect
    }
    
    // MARK: Coordinate update function
    func updateCoordinates(rValue:Double, zValue:Double) {
        
        self.rLocationTextField.doubleValue = rValue
        self.zLocationTextField.doubleValue = zValue
    }
    
   
    
    // MARK: View functions
    // This function does the following things:
    // 1) Shows the main window (if its hidden)
    // 2) Sets the bounds of the transformer view to the window of the transformer (does a "zoom all" using the current transformer core)
    // 3) Calls updateViews() to draw the coil segments
    func initializeViews()
    {
        self.mainWindow.makeKeyAndOrderFront(self)
        
        self.handleZoomAll(self)
        
        self.updateViews()
    }
    
    func updateViews()
    {
        // self.txfoView.segments = []
        
        Task {
            
            guard let model = self.currentModel else
            {
                return
            }
            
            let segs = await model.segments
            
            guard segs.count > 0 else {
                return
            }
            
            self.txfoView.currentSegments = []
            
            self.txfoView.removeAllToolTips()
            
            // See the comment for the TransformerView property 'segments' to see why I coded this in this way
            var newSegmentPaths:[SegmentPath] = []
            for nextSegment in segs
            {
                let pathColor = AppController.segmentColors[nextSegment.radialPos % AppController.segmentColors.count]
                
                var newSegPath = await SegmentPath(segment: nextSegment, segRect: nextSegment.rect, segIsStaticRing: nextSegment.isStaticRing, segmentColor: pathColor)
                // var newSegPath = SegmentPath(segment: nextSegment, segmentColor: pathColor)
                
                newSegPath.toolTipTag = self.txfoView.addToolTip(newSegPath.GetRect(), owner: self.txfoView as Any, userData: nil)
                
                newSegmentPaths.append(newSegPath)
            }
            
            self.txfoView.segments = newSegmentPaths
            self.txfoView.needsDisplay = true
        }
    }
    
    // MARK: Preferences

    /// Show the preferences dialog (⌘,). The dialog builds itself from `Preference.allCases`, so adding a preference needs no
    /// work here - see the header of Preferences.swift. What DOES belong here is anything that has to be invalidated when a
    /// particular preference moves, which is why the dialog reports which ones the user actually changed.
    @IBAction func handleShowPreferences(_ sender: Any) {

        guard let changed = PreferencesDialog().runModal(), !changed.isEmpty else {

            return
        }

        // Every utilization in the stress report is a fraction of an allowable that carries the design margin, so a report that
        // is already on screen (and the checks cached behind it) became wrong the moment the margin moved. The screen is
        // milliseconds - see doShowStressReport - so re-run it rather than leaving a stale table up or making the user
        // remember to.
        if changed.contains(.dielectricDesignMargin) {

            self.latestStressChecks = []
        }

        // The corner columns are built once, in StressReportWindow's initializer, so an open report cannot pick the preference up
        // where it stands. The findings themselves are untouched by it - nothing is ranked or judged on a corner field - so this
        // one only costs a rebuilt window, not a re-run screen.
        let mustRebuildReport = changed.contains(.dielectricDesignMargin) || changed.contains(.showCornerStresses)

        if mustRebuildReport, let reportWindow = self.stressReportWindow, reportWindow.window?.isVisible ?? false {

            let cachedChecks = self.latestStressChecks

            reportWindow.close()
            self.stressReportWindow = nil

            if cachedChecks.isEmpty {

                // The margin moved, so the checks above were thrown away. Re-run the screen; it is milliseconds - see
                // doShowStressReport.
                Task {

                    await self.doShowStressReport()
                }
            }
            else {

                let rebuilt = StressReportWindow(checks: cachedChecks, title: AppController.stressReportTitle)
                self.stressReportWindow = rebuilt
                rebuilt.showWindow(self)
            }
        }
    }

    // MARK: Menu routines

    @IBAction func handleWdgAsSingleSegment(_ sender: Any) {
        
        self.doWdgAsSingleSegment()
    }
    
    func doWdgAsSingleSegment(segmentPath:SegmentPath? = nil) {
        
        
    }
    
    @IBAction func handleCombineSelectionIntoSingleSegment(_ sender: Any) {
        
        self.doCombineSelectionIntoSingleSegment(segmentPaths: self.txfoView.currentSegments)
    }
    
    func doCombineSelectionIntoSingleSegment(segmentPaths:[SegmentPath]) {
        
        guard let model = self.currentModel, segmentPaths.count > 1 else {
            
            return
        }
        
        var segments:[Segment] = []
        for nextPath in segmentPaths {
            
            segments.append(nextPath.segment)
        }
        
        segments.sort(by: { lhs, rhs in
            
            if lhs.radialPos != rhs.radialPos {
                
                return lhs.radialPos < rhs.radialPos
            }
            
            return lhs.axialPos < rhs.axialPos
        })
        
        Task {

            // Combining rebuilds the Segments from their BasicSections, which would silently throw any shields away
            for nextSegment in segments {

                if await nextSegment.HasWoundInShield() {

                    PCH_ErrorAlert(message: "The selection contains at least one segment with wound-in shields!", info: "Remove the shields first.")
                    return
                }
            }

            if await model.SegmentsAreContiguous(segments: segments) {

                // The combined Segment has two terminals, so every node inside the selection is about to disappear along with
                // anything the user attached to it. See SelectionStrandedConnection.
                if let stranded = await self.SelectionStrandedConnection(model: model, segments: segments) {

                    PCH_ErrorAlert(message: "There is a connection inside the selection!", info: "Combining would destroy the node it is attached to (\(stranded)). Remove the connection first.")
                    return
                }

                var newBasicSectionArray:[BasicSection] = []
                
                
                
                for nextSegment in segments {
                    
                    newBasicSectionArray.append(contentsOf: nextSegment.basicSections)
                }
                
                
                do {

                    let core = await model.core
                    let combinedSegment = try Segment(basicSections: newBasicSectionArray, realWindowHeight: core.realWindowHeight, useWindowHeight: core.adjustedWindHt)

                    // Static rings at the ends of the selection need no attention here any more, and that is the point of the
                    // geometric lookup in PhaseModel.NearestStaticRing: a ring does not name the Segment it sits against, so
                    // rebuilding that Segment cannot orphan it. This used to tear each end ring down and build a replacement
                    // against the combined Segment, which was both unnecessary and lossy - the replacement was created at the
                    // DEFAULT gap and thickness, silently discarding a ring the user had asked for at anything else.
                    await self.updateModel(oldSegments: segments, newSegments: [combinedSegment], xlFile: nil, reinitialize: false)
                }
                catch {
                    
                    let alert = NSAlert(error: error)
                    let _ = alert.runModal()
                    return
                }
                
            }
            else {
                
                PCH_ErrorAlert(message: "Segments must be from the same coil and be contiguous to combine them!", info: nil)
            }
        }
    }

    
    @IBAction func handleInterleaveSelection(_ sender: Any) {
        
        self.doInterleaveSelection(segmentPaths: self.txfoView.currentSegments)
    }
    
    func doInterleaveSelection(segmentPaths:[SegmentPath]) {
        
        guard let model = self.currentModel, segmentPaths.count > 0 else {
            
            return
        }
        
        Task {
            
            /* This is taken care of in the for-loop immediately following...
            guard !segmentPaths.contains(where: { $0.segment.IsInterleaved()}) else {
                
                PCH_ErrorAlert(message: "The selection contains at least one interleaved segment!", info: "Cannot 'double-interleave'")
                return
            } */
            
            var segments:[Segment] = []
            for nextPath in segmentPaths {
                
                if await nextPath.segment.IsInterleaved() {
                    PCH_ErrorAlert(message: "The selection contains at least one interleaved segment!", info: "Cannot 'double-interleave'")
                    return
                }
                // Interleaving rebuilds the Segments, which would silently throw the shields away
                if await nextPath.segment.HasWoundInShield() {
                    PCH_ErrorAlert(message: "The selection contains at least one segment with wound-in shields!", info: "Remove the shields first.")
                    return
                }
                segments.append(nextPath.segment)
            }
            
            segments.sort(by: { lhs, rhs in
                
                if lhs.radialPos != rhs.radialPos {
                    
                    return lhs.radialPos < rhs.radialPos
                }
                
                return lhs.axialPos < rhs.axialPos
            })
            
            
            
            if await model.SegmentsAreContiguous(segments: segments) {

                // See SelectionSpansTappingGap. Interleaving always regroups, so unlike the wound-in-shield path this is
                // unconditional.
                if await self.SelectionSpansTappingGap(model: model, segments: segments) {

                    PCH_ErrorAlert(message: "The selection spans a tapping gap!", info: "Interleaving would regroup the discs across the gap. Select the discs on one side of the gap at a time.")
                    return
                }

                // Interleaving turns each disc pair into one two-terminal Segment, so any connection inside the selection loses the
                // node it was made at. See SelectionStrandedConnection.
                if let stranded = await self.SelectionStrandedConnection(model: model, segments: segments) {

                    PCH_ErrorAlert(message: "There is a connection inside the selection!", info: "Interleaving would destroy the node it is attached to (\(stranded)). Remove the connection first.")
                    return
                }

                var basicSections:[BasicSection] = []
                for nextSegment in segments {

                    basicSections.append(contentsOf: nextSegment.basicSections)
                }

                guard basicSections.count % 2 == 0 else {

                    PCH_ErrorAlert(message: "There must be an even number of total discs to create interleaved segments!", info: nil)
                    return
                }
                
                
                do {
                    
                    var interleavedSegments:[Segment] = []
                    let core = await model.core

                    for i in stride(from: 0, to: basicSections.count, by: 2) {

                        interleavedSegments.append(try Segment(basicSections: [basicSections[i], basicSections[i+1]], interleaved: true, realWindowHeight: core.realWindowHeight, useWindowHeight: core.adjustedWindHt))
                    }
                    
                    await self.updateModel(oldSegments: segments, newSegments: interleavedSegments, xlFile: nil, reinitialize: false)
                }
                catch {
                    
                    let alert = NSAlert(error: error)
                    let _ = alert.runModal()
                    return
                }
            }
            
            else {
                
                PCH_ErrorAlert(message: "Segments must be from the same coil and be contiguous to interleave them!", info: nil)
            }
        }
    }
    
    // MARK: Wound-in shields (DelVecchio ch. 12, section 12.11)

    /// Whether a tapping gap falls between any two axially adjacent Segments of `segments`, which must already be sorted.
    ///
    /// Both of the operations that REGROUP a selection - interleaving and wound-in-shield pairing - flatten it into BasicSections
    /// and rebuild two-disc Segments from the result. A tapping gap inside the selection is a genuine break in the winding, and
    /// regrouping across it would swallow the break into the middle of a Segment: the two floating center leads that mark the gap
    /// would survive on a Segment that is now electrically continuous, and SetNodes would have no way to put a node there. Refusing
    /// is the honest answer - the alternative is a model that looks right and is not.
    ///
    /// The test is deliberately over the WHOLE selection rather than only the boundaries that happen to fall between pairs. A gap
    /// that lands exactly on a pair boundary would in fact regroup safely, but which boundaries those are depends on how the flatten
    /// happens to divide, and a silently-conditional rule is worse than a conservative one for something this easy to work around
    /// (select one side of the gap at a time).
    func SelectionSpansTappingGap(model:PhaseModel, segments:[Segment]) async -> Bool {

        guard segments.count > 1 else {

            return false
        }

        for i in 0..<(segments.count - 1) {

            if await model.IsTappingGap(segment1: segments[i], segment2: segments[i + 1]) {

                return true
            }
        }

        return false
    }

    /// Describe the first connection that would be stranded by folding `segments` (which must already be sorted) into fewer
    /// Segments, or nil if there is none.
    ///
    /// Combining, interleaving and wound-in-shield pairing all replace a run of Segments with fewer, larger ones, and a Segment is
    /// a single series branch with exactly two terminals. Every node INSIDE the run therefore ceases to exist. A series connection
    /// across such a node is exactly what is supposed to disappear; anything else attached there - a jumper to another disc or
    /// another coil, a ground, an impulse - has nowhere to go.
    ///
    /// Letting it through is not a cosmetic problem. A jumper is stored as one connection per Segment that meets the node it was
    /// dropped on, so the two halves of one jumper end up on opposite terminals of the new Segment, and SimulationModel's node
    /// merging then ties those two terminals together - shorting the new Segment out, with no error anywhere. PhaseModel's
    /// UpdateConnectors now discards both halves rather than leave that behind, so the model is safe either way; this guard is
    /// what makes the loss the user's decision instead of a silent one.
    ///
    /// Like SelectionSpansTappingGap, the test is over the WHOLE selection rather than only the boundaries a particular regrouping
    /// would actually swallow. Interleaving pairs the flattened discs 0-1, 2-3, ..., so a jumper on an even boundary would in fact
    /// survive - but which boundaries those are depends on how the flatten happens to divide, and a rule that sometimes lets a
    /// connection through is worse than a conservative one for something with an easy workaround (remove the connection, regroup,
    /// put it back if the node still exists).
    func SelectionStrandedConnection(model:PhaseModel, segments:[Segment]) async -> String? {

        guard segments.count > 1 else {

            return nil
        }

        /// The connections `segment` carries at the node it shares with `neighbour`, other than the series connection itself.
        func StrandedAt(segment:Segment, upperEnd:Bool, neighbour:Segment) async -> String? {

            for nextConnection in await segment.connections {

                let atThisEnd = upperEnd ? nextConnection.connector.fromIsUpper : nextConnection.connector.fromIsLower

                guard atThisEnd, nextConnection.connector.toLocation != .floating else {

                    continue
                }

                if let connectedID = nextConnection.segmentID {

                    // The series connection to the neighbour is the one thing here that is meant to vanish.
                    if connectedID != neighbour.serialNumber {

                        return "segment \(segment.serialNumber) (\(nextConnection.connector.fromLocation)) is connected to segment \(connectedID)"
                    }
                }
                else {

                    return "segment \(segment.serialNumber) (\(nextConnection.connector.fromLocation)) is connected to \(nextConnection.connector.toLocation)"
                }
            }

            return nil
        }

        for i in 0..<(segments.count - 1) {

            let lower = segments[i]
            let upper = segments[i + 1]

            if let stranded = await StrandedAt(segment: lower, upperEnd: true, neighbour: upper) {

                return stranded
            }

            if let stranded = await StrandedAt(segment: upper, upperEnd: false, neighbour: lower) {

                return stranded
            }
        }

        return nil
    }

    @IBAction func handleAddWoundInShields(_ sender: Any) {

        self.doAddWoundInShields(segmentPaths: self.txfoView.currentSegments)
    }

    /// Put wound-in shields into every disc of the selected Segments.
    ///
    /// The shield is an open-circuited conductor - it carries no current in any of DelVecchio's three connections - so it never
    /// becomes a circuit element. Its whole effect is a much larger series capacitance for the disc pair, plus the geometry change
    /// from the radial build it takes up. Both of those are picked up by recalculateModel().
    func doAddWoundInShields(segmentPaths:[SegmentPath]) {

        guard let model = self.currentModel, segmentPaths.count > 0 else {

            return
        }

        var segments:[Segment] = []
        for nextPath in segmentPaths {

            segments.append(nextPath.segment)
        }

        segments.sort(by: { lhs, rhs in

            if lhs.radialPos != rhs.radialPos {

                return lhs.radialPos < rhs.radialPos
            }

            return lhs.axialPos < rhs.axialPos
        })

        // A shield spans a disc PAIR and crosses over at the outermost turn, so the discs have to be grouped two to a Segment
        // before any shield can be set. A Segment that already holds an even number of discs is left exactly as it stands; if any
        // Segment holds an odd number, the whole selection is rebuilt into two-disc Segments below, the same way
        // doInterleaveSelection does it. The load path gives every disc its own Segment, so on a freshly loaded model this is
        // always the rebuild case.
        let needsRebuild = segments.contains(where: { $0.basicSections.count % 2 != 0 })

        let allSections = segments.flatMap({ $0.basicSections })

        guard let discTurns = allSections.map({ $0.N }).min(), let firstSection = allSections.first else {

            return
        }

        guard !needsRebuild || allSections.count % 2 == 0 else {

            PCH_ErrorAlert(message: "A wound-in shield spans two discs, so the selection must hold an even number of discs!", info: "There are \(allSections.count).")
            return
        }

        let turnInsulation = firstSection.wdgData.turn.turnInsulation
        let bareCopperHeight = firstSection.height - turnInsulation

        Task {

            // Pairing discs ACROSS Segment boundaries only means anything if the Segments are neighbours to begin with - otherwise
            // a "pair" could be two discs with a gap between them. Segments that are already even are never re-paired, so this is
            // only asked on the rebuild path.
            if needsRebuild, await !model.SegmentsAreContiguous(segments: segments) {

                PCH_ErrorAlert(message: "Segments must be from the same coil and be contiguous to pair them up for wound-in shields!", info: nil)
                return
            }

            // See SelectionSpansTappingGap. Only the rebuild path regroups the discs, so only it can swallow a gap; a selection
            // whose Segments are already even is left structurally alone and needs no such check.
            if needsRebuild, await self.SelectionSpansTappingGap(model: model, segments: segments) {

                PCH_ErrorAlert(message: "The selection spans a tapping gap!", info: "Pairing the discs for a wound-in shield would regroup them across the gap. Select the discs on one side of the gap at a time.")
                return
            }

            // Same story for a connection at a node the pairing would swallow - and, as above, only the rebuild path can swallow
            // one. See SelectionStrandedConnection.
            if needsRebuild, let stranded = await self.SelectionStrandedConnection(model: model, segments: segments) {

                PCH_ErrorAlert(message: "There is a connection inside the selection!", info: "Pairing the discs for a wound-in shield would destroy the node it is attached to (\(stranded)). Remove the connection first.")
                return
            }

            // These have to be checked here rather than in validateMenuItem, which is synchronous and so cannot reach an actor's
            // mutable state. Same reason doInterleaveSelection tests IsInterleaved() here.
            for nextSegment in segments {

                if await nextSegment.IsInterleaved() {

                    PCH_ErrorAlert(message: "The selection contains at least one interleaved segment!", info: "Interleaving and wound-in shields are two different ways of raising the series capacitance - use one or the other.")
                    return
                }

                if await nextSegment.HasWoundInShield() {

                    PCH_ErrorAlert(message: "The selection already contains wound-in shields!", info: "Remove them first if you want to change the shield count or the connection.")
                    return
                }
            }

            let voltsPerTurn = await model.voltsPerTurn

            guard voltsPerTurn > 0.0 else {

                PCH_ErrorAlert(message: "The model has no volts/turn!", info: "The shield insulation is sized from the working voltage, so a design file has to be loaded first.")
                return
            }

            guard let shieldDlog = GetWoundInShieldDialog(discTurns: discTurns, voltsPerTurn: voltsPerTurn, turnInsulation: turnInsulation, bareCopperHeight: bareCopperHeight, discCount: allSections.count) else {

                PCH_ErrorAlert(message: "This coil cannot carry wound-in shields!", info: "A shield turn goes between two coil turns, so there have to be at least 2 turns per disc.")
                return
            }

            guard let result = shieldDlog.runModal() else {

                return
            }

            // Nothing above this line has touched the model, so a cancelled dialog leaves the segmentation exactly as it was.
            if needsRebuild {

                do {

                    let core = await model.core
                    var pairedSegments:[Segment] = []

                    for i in stride(from: 0, to: allSections.count, by: 2) {

                        let newSegment = try Segment(basicSections: [allSections[i], allSections[i + 1]], realWindowHeight: core.realWindowHeight, useWindowHeight: core.adjustedWindHt)

                        // Two discs to a Segment means exactly one pair per Segment. Set the shield BEFORE the Segment goes into
                        // the model: updateModel ends in recalculateModel, so doing it in this order costs one pass over the
                        // geometry and the matrices rather than two.
                        await newSegment.SetWoundInShield(Segment.WoundInShield(wire: result.wire, turnsPerDisc: result.turnsPerDisc, pairCount: 1))
                        pairedSegments.append(newSegment)
                    }

                    // Also does the connector fixup that swapping Segments needs, and ends in recalculateModel.
                    await self.updateModel(oldSegments: segments, newSegments: pairedSegments, xlFile: nil, reinitialize: false)
                }
                catch {

                    let alert = NSAlert(error: error)
                    let _ = alert.runModal()
                }

                return
            }

            for nextSegment in segments {

                let pairCount = nextSegment.basicSections.count / 2
                await nextSegment.SetWoundInShield(Segment.WoundInShield(wire: result.wire, turnsPerDisc: result.turnsPerDisc, pairCount: pairCount))
            }

            // Rebuilds the radial geometry of the whole model (this coil widens, everything outside it moves out, the tank and leg
            // centers grow), then redoes the inductance and the capacitance.
            await self.recalculateModel(reinitialize: false)
        }
    }

    @IBAction func handleRemoveWoundInShields(_ sender: Any) {

        self.doRemoveWoundInShields(segmentPaths: self.txfoView.currentSegments)
    }

    func doRemoveWoundInShields(segmentPaths:[SegmentPath]) {

        guard self.currentModel != nil, segmentPaths.count > 0 else {

            return
        }

        let segments = segmentPaths.map({ $0.segment })

        Task {

            var removedAny = false

            for nextSegment in segments {

                if await nextSegment.HasWoundInShield() {

                    await nextSegment.SetWoundInShield(nil)
                    removedAny = true
                }
            }

            guard removedAny else {

                PCH_ErrorAlert(message: "The selection has no wound-in shields!", info: nil)
                return
            }

            // ApplyRadialBuildUp recomputes absolute positions from the pristine design-file radii, so this puts the geometry back
            // exactly where it started rather than approximately.
            await self.recalculateModel(reinitialize: false)
        }
    }

    @IBAction func handleSplitSegmentIntoBasicSections(_ sender: Any) {
        
        guard self.currentModel != nil, self.txfoView.currentSegments.count == 1 else {
            
            return
        }
        
        self.doSplitSegmentIntoBasicSections(segmentPath: self.txfoView.currentSegments[0])
    }
    
    func doSplitSegmentIntoBasicSections(segmentPath:SegmentPath) {
        
        guard let model = self.currentModel, segmentPath.segment.basicSections.count > 1 else {
            
            return
        }
        
        let segment = segmentPath.segment
        var newSegments:[Segment] = []
        
        Task {

            // Splitting rebuilds the Segments, which would silently throw any shields away
            if await segment.HasWoundInShield() {

                PCH_ErrorAlert(message: "The segment has wound-in shields!", info: "Remove them first.")
                return
            }

            do {

                let core = await model.core

                for nextBasicSection in segment.basicSections {

                    newSegments.append(try Segment(basicSections: [nextBasicSection], interleaved: false, isStaticRing: false, isRadialShield: false, realWindowHeight: core.realWindowHeight, useWindowHeight: core.adjustedWindHt))
                }
                
                await self.updateModel(oldSegments: [segment], newSegments: newSegments, xlFile: nil, reinitialize: false)
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    @IBAction func handleAddGround(_ sender: Any) {
        
        self.doAddGround()
    }
    
    func doAddGround() {
        
        guard self.currentModel != nil else {
            
            return
        }
        
        self.txfoView.mode = .addGround
    }
    
    @IBAction func handleAddImpulse(_ sender: Any) {
        
        self.doAddImpulse()
    }
    
    func doAddImpulse() {
        
        guard self.currentModel != nil else {
            
            return
        }
        
        self.txfoView.mode = .addImpulse
    }
    
    @IBAction func handleAddConnection(_ sender: Any) {
        
        self.doAddConnection()
    }
    
    func doAddConnection() {
        
        guard self.currentModel != nil else {
            
            return
        }
        
        self.txfoView.mode = .addConnection

        // Esc cancels a half-drawn connection, and keyDown only gets there if the view is the first responder. Clicking in
        // the view makes it one anyway, but the mode can also be entered from the menu without a click having happened yet.
        self.txfoView.window?.makeFirstResponder(self.txfoView)
    }
    
    @IBAction func handleRemoveConnection(_ sender: Any) {
        
        self.doRemoveConnection()
    }
    
    func doRemoveConnection() {
        
        guard self.currentModel != nil else {
            
            return
        }
        
        self.txfoView.mode = .removeConnector
    }

    // MARK: Regulating windings

    @IBAction func handleRegulatingWinding(_ sender: Any) {

        guard let firstSelected = self.txfoView.currentSegments.first else {

            return
        }

        self.doRegulatingWinding(coil: firstSelected.segment.radialPos)
    }

    /// Declare `coil` a regulating winding (or change or withdraw an existing declaration), and put on or take off the connections
    /// that are a permanent part of it. See RegulatingWinding.swift.
    ///
    /// Like a jumper added by hand, this changes the connections and nothing else: no geometry moves, so there is nothing for
    /// recalculateModel to do, and the simulation model is rebuilt from the connections on the next run anyway.
    func doRegulatingWinding(coil:Int) {

        guard let model = self.currentModel else {

            return
        }

        Task {

            guard let arrangement = await self.RegulatingWindingArrangement(coil: coil), let xlFile = self.currentXLfile else {

                self.PCH_ErrorAlert(message: "Coil \(coil) is not in the design file.", info: "How a regulating winding is built - double-stacked, multi-start or a single stack - is read from the design file, so the model has to have been opened from one.")
                return
            }

            let existing = self.regulatingWindings.first(where: { $0.coil == coil })

            // The disc count as the model has it now, which is also the check that the winding can still be connected at all -
            // a double-stacked coil that has been interleaved has no crossovers left to tie together.
            let numDiscs:Int

            do {

                numDiscs = try await RegulatingWinding(coil: coil, numLoops: 1).CheckModel(model, arrangement: arrangement)
            }
            catch {

                self.PCH_ErrorAlert(message: error.localizedDescription, info: (error as? RegulatingWinding.DeclarationError)?.info)
                return
            }

            var initialLoops = existing?.numLoops ?? 1

            if arrangement == .multiStart {

                // Not the user's to choose: a multi-start winding's loops ARE its starts, which are the design file's axial cables
                // per turn, and that same number is what DelVecchio 12.12 computes the winding's capacitance from. So the dialog shows
                // it and does not let it be edited - a declaration that disagreed with the capacitance would be worse than none.
                initialLoops = max(1, await xlFile.windings[coil].turnDefinition.multistartLoops)
            }
            else if existing == nil, arrangement == .doubleStack {

                initialLoops = RegulatingWinding.DefaultLoops(discsPerStack: numDiscs / 2)
            }

            let dialog = RegulatingWindingDialog(coil: coil, arrangement: arrangement, numDiscs: numDiscs, initialLoops: initialLoops, isAlreadyDeclared: existing != nil)

            guard let result = dialog.runModal() else {

                return
            }

            switch result {

            case .remove:

                if let existing {

                    await existing.Remove(from: model, arrangement: arrangement)
                }

                self.regulatingWindings.removeAll(where: { $0.coil == coil })

            case .declare(let numLoops):

                let declared = RegulatingWinding(coil: coil, numLoops: numLoops)

                // A changed loop count moves the tap points, so the old ties have to come off before the new ones go on - otherwise
                // both sets would be on the winding at once, which is a transformer nobody built.
                if let existing, existing != declared {

                    await existing.Remove(from: model, arrangement: arrangement)
                }

                do {

                    let outcome = try await declared.Apply(to: model, arrangement: arrangement)
                    DLog("Regulating winding, coil \(coil): \(outcome.made) jumper(s) made, \(outcome.alreadyThere) already there\n" + outcome.log.joined(separator: "\n"))
                }
                catch {

                    // Put the old declaration's connections back, so that a failed change leaves the winding as it was.
                    if let existing, existing != declared {

                        _ = try? await existing.Apply(to: model, arrangement: arrangement)
                    }

                    self.PCH_ErrorAlert(message: error.localizedDescription, info: (error as? RegulatingWinding.DeclarationError)?.info)
                    self.txfoView.RebuildConnectors()
                    return
                }

                self.regulatingWindings.removeAll(where: { $0.coil == coil })
                self.regulatingWindings.append(declared)
            }

            if let designFile = self.currentDesignFileURL {

                RegulatingWindingStore.shared.save(self.regulatingWindings, for: designFile)
            }

            self.txfoView.RebuildConnectors()
            self.txfoView.needsDisplay = true
        }
    }

    /// How `coil` is built, according to the design file. Nil if there is no design file or no such coil in it.
    func RegulatingWindingArrangement(coil:Int) async -> RegulatingWinding.Arrangement? {

        guard let xlFile = self.currentXLfile else {

            return nil
        }

        // A coil's radial position IS its index in the design file's windings - createBasicSections numbers them that way.
        let windings = await xlFile.windings

        guard coil >= 0, coil < windings.count else {

            return nil
        }

        return RegulatingWinding.Arrangement.Of(windings[coil])
    }

    /// Re-apply the declarations saved with a design to the model just built from it, and put the ones that took into
    /// `regulatingWindings`.
    ///
    /// A declaration that no longer fits the design - its coil is gone, or the stack no longer divides into its loops - is
    /// reported and left out of what is in force. It is NOT deleted from the store here; that happens only if the user then
    /// declares something on this design, which saves what is in force. Opening a design is not an edit.
    func ApplySavedRegulatingWindings(_ saved:[RegulatingWinding], model:PhaseModel) async {

        for nextWinding in saved {

            guard let arrangement = await self.RegulatingWindingArrangement(coil: nextWinding.coil) else {

                self.PCH_ErrorAlert(message: "The regulating winding declared on coil \(nextWinding.coil) was not applied.", info: "The design no longer has a coil \(nextWinding.coil).")
                continue
            }

            do {

                let outcome = try await nextWinding.Apply(to: model, arrangement: arrangement)
                DLog("Regulating winding, coil \(nextWinding.coil): \(outcome.made) jumper(s) made on load")

                self.regulatingWindings.append(nextWinding)
            }
            catch {

                self.PCH_ErrorAlert(message: "The regulating winding declared on coil \(nextWinding.coil) was not applied.", info: "\(error.localizedDescription) \((error as? RegulatingWinding.DeclarationError)?.info ?? "")")
            }
        }
    }

    // next two functions for adding a static ring over the selection
    @IBAction func handleAddStaticRingOver(_ sender: Any) {
        
        self.doAddStaticRingOver()
    }
    
    func doAddStaticRingOver(segmentPath:SegmentPath? = nil) {
        
        guard let model = self.currentModel, self.txfoView.currentSegments.count > 0 else {
            
            return
        }
        
        let currentSegment = segmentPath == nil ? self.txfoView.currentSegments[0] : segmentPath!
        
        Task {
            do {
                
                let newStaticRing = try await model.AddStaticRing(adjacentSegment: currentSegment.segment, above: true)
                
                try await model.InsertSegment(newSegment: newStaticRing)
                
                try await model.CalculateCapacitanceMatrix()
                // print("Coil 1 Cs: \(try model.CoilSeriesCapacitance(coil: currentSegment.segment.radialPos))")
                
                // var newSegPath = await SegmentPath(segment: newStaticRing, segRect: newStaticRing.rect, segIsStaticRing: true, segmentColor: currentSegment.segmentColor)
                await self.txfoView.segments.append(SegmentPath(segment: newStaticRing, segRect: newStaticRing.rect, segIsStaticRing: true, segmentColor: currentSegment.segmentColor))
                self.txfoView.currentSegments = [self.txfoView.segments.last!]
                
                self.txfoView.needsDisplay = true
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    // next two functions for adding a static ring under the selection
    @IBAction func handleAddStaticRingBelow(_ sender: Any) {
        
        self.doAddStaticRingBelow()
    }
    
    func doAddStaticRingBelow(segmentPath:SegmentPath? = nil) {
        
        guard let model = self.currentModel, self.txfoView.currentSegments.count > 0 else {
            
            return
        }
        
        let currentSegment = segmentPath == nil ? self.txfoView.currentSegments[0] : segmentPath!
        
        Task {
            
            do {
                
                let newStaticRing = try await model.AddStaticRing(adjacentSegment: currentSegment.segment, above: false)
                
                try await model.InsertSegment(newSegment: newStaticRing)
                
                try await model.CalculateCapacitanceMatrix()
                print("Coil 1 Cs: \(try await model.CoilSeriesCapacitance(coil: currentSegment.segment.radialPos))")
                
                await self.txfoView.segments.append(SegmentPath(segment: newStaticRing, segRect: newStaticRing.rect, segIsStaticRing: true, segmentColor: currentSegment.segmentColor))
                self.txfoView.currentSegments = [self.txfoView.segments.last!]
                
                self.txfoView.needsDisplay = true
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    // next two functions for removing a static ring
    @IBAction func handleRemoveStaticRing(_ sender: Any) {
        
        self.doRemoveStaticRing()
    }
    
    func doRemoveStaticRing(segmentPath:SegmentPath? = nil) {
        
        guard let model = self.currentModel, self.txfoView.currentSegments.count > 0 else {
            
            return
        }
        
        let currentSegment = segmentPath == nil ? self.txfoView.currentSegments[0] : segmentPath!
        
        Task {
            
            do {
                
                try await model.RemoveStaticRing(staticRing: currentSegment.segment)
                
                self.txfoView.segments.remove(at: self.txfoView.currentSegmentIndices[0])
                
                
                self.txfoView.currentSegments = []
                self.txfoView.needsDisplay = true
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    // next two functions for adding a radial shield
    @IBAction func handleAddRadialShield(_ sender: Any) {
        
        self.doAddRadialShield()
    }
    
    func doAddRadialShield(segmentPath:SegmentPath? = nil) {
        
        guard let model = self.currentModel, self.txfoView.currentSegments.count > 0 else {
            
            return
        }
        
        let currentSegment = segmentPath == nil ? self.txfoView.currentSegments[0] : segmentPath!
        
        let getHiloDlog = GetNumberDialog(descriptiveText: "Gap to shield:", unitsText: "meters", noteText: "Must be less then the hilo under the coil", windowTitle: "Add Radial Shield")
        
        if getHiloDlog.runModal() == .cancel {
            
            return
        }
        
        let hilo = getHiloDlog.numberValue
        
        if hilo <= 0 {
            
            return
        }
        
        Task {
            
            do {
                
                // let hilo = 0.012
                let newRadialShield = try await model.AddRadialShieldInside(coil: currentSegment.segment.location.radial, hiloToShield: hilo)
                
                try await model.InsertSegment(newSegment: newRadialShield)
                await self.txfoView.segments.append(SegmentPath(segment: newRadialShield, segRect: newRadialShield.rect, segIsStaticRing: false, segmentColor: .green))
                // self.txfoView.segments.append(SegmentPath(segment: newRadialShield, segmentColor: .green))
                self.txfoView.currentSegments = [self.txfoView.segments.last!]
                
                self.txfoView.needsDisplay = true
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    // next two functions for removing a radial shield
    @IBAction func handleRemoveRadialShield(_ sender: Any) {
        
        self.doRemoveRadialShield()
    }
    
    func doRemoveRadialShield(segmentPath:SegmentPath? = nil) {
        
        guard let model = self.currentModel, self.txfoView.currentSegments.count > 0 else {
            
            return
        }
        
        let currentSegment = segmentPath == nil ? self.txfoView.currentSegments[0] : segmentPath!
        
        Task {
            
            do {
                
                try await model.RemoveRadialShield(radialShield: currentSegment.segment)
                
                self.txfoView.segments.remove(at: self.txfoView.currentSegmentIndices[0])
                
                self.txfoView.currentSegments = []
                self.txfoView.needsDisplay = true
            }
            catch {
                
                let alert = NSAlert(error: error)
                let _ = alert.runModal()
                return
            }
        }
    }
    
    /*
    @IBAction func handleShowGraph(_ sender: Any) {
        
        DLog("Creating window controller")
        
        self.graphWindowCtrl = PCH_GraphingWindow(graphBounds: NSRect(x: -10.0, y: -10.0, width: 1000.0, height: 400.0))
        
        
    } */
    
    
    @IBAction func handleOpenFile(_ sender: Any) {
        
        let openPanel = NSOpenPanel()
        
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.title = "Design file"
        openPanel.message = "Open a valid Excel-design-sheet-generated file"
        openPanel.allowsMultipleSelection = false
        
        // If there was a previously successfully opened design file, set that file's directory as the default, otherwise go to the user's Documents folder
        if let lastFile = UserDefaults.standard.url(forKey: LAST_OPENED_INPUT_FILE_KEY)
        {
            openPanel.directoryURL = lastFile.deletingLastPathComponent()
        }
        else
        {
            openPanel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        
        if openPanel.runModal() == .OK
        {
            if let fileURL = openPanel.url
            {
                let _ = self.doOpen(fileURL: fileURL)
            }
            else
            {
                DLog("This shouldn't ever happen...")
            }
        }
    }
    
    @IBAction func HandleSaveAsCIRfile(_ sender: Any) {
        
        let saveAsPanel = NSSavePanel()
        saveAsPanel.title = "SPICE File"
        saveAsPanel.message = "Save SPICE (.cir) File"
        
        guard let cirType = UTType(filenameExtension: PCH_CIR_FILETYPE, conformingTo: .utf8PlainText) else {
            
            DLog("Could not create file type!")
            return
        }
        
        saveAsPanel.allowedContentTypes = [cirType]
        saveAsPanel.allowsOtherFileTypes = false
        
        Task {
            
            if saveAsPanel.runModal() == .OK
            {
                if let fileURL = saveAsPanel.url
                {
                    if let fileString = await self.doCreateCirFile(filename: fileURL.path) {
                        
                        do {
                            
                            try fileString.write(to: fileURL, atomically: false, encoding: .utf8)
                        }
                        catch {
                            
                            let alert = NSAlert(error: error)
                            let _ = alert.runModal()
                            return
                        }
                    }
                    else {
                        
                        let alert = NSAlert()
                        alert.messageText = "Could not create CIR file from the current model!"
                        alert.alertStyle = .warning
                        let _ = alert.runModal()
                        return
                    }
                }
                else {
                    
                    let alert = NSAlert()
                    alert.messageText = "Illegal URL when creating CIR file."
                    alert.alertStyle = .warning
                    let _ = alert.runModal()
                    return
                }
            }
        }
        
    }
    
    /// Build a SPICE netlist for the current model.
    ///
    /// # What this is for
    ///
    /// External validation of `FrequencyDomainSolver`. An exact method fails
    /// silently - a wrong system of equations still solves cleanly - so the
    /// only way to be confident the assembled network really is the network
    /// intended is to hand the same circuit to an independent tool.
    ///
    /// Two analyses are emitted, and they check different things:
    ///
    ///   - `.ac` compares like with like. The solver IS a frequency-domain
    ///     solve, so an AC sweep sidesteps every time-stepping difference and
    ///     any mismatch is an assembly error, localised to a frequency. Drive
    ///     the comparison with the transfer function: divide the solver's
    ///     nodal voltage by U(jw) and compare against SPICE's AC result, which
    ///     uses a unit source.
    ///   - `.tran` then checks the inverse transform. With `.ac` already
    ///     matching, any remaining discrepancy is in the NILT stage.
    ///
    /// # Use a SMALL model
    ///
    /// Mutual inductance in SPICE is one `K` card per pair - 190 of them for
    /// 20 segments, but around 20,000 for 200, where it becomes numerically
    /// fragile as k approaches 1. Validate on 10-20 segments. The solver's
    /// code path does not change with size, so correctness there is
    /// correctness everywhere; the large case is what SPICE cannot do, which
    /// is the whole reason this program computes the inductance matrix itself.
    ///
    /// ngspice is recommended over LTspice for the dense coupling.
    ///
    /// # Per-unit
    ///
    /// The source is 1 V peak, so results come out per-unit and can be
    /// compared against the solver at any impulse level.
    func doCreateCirFile(filename:String) async -> String? {

        guard let model = self.currentModel else {

            DLog("No model is currently defined!")
            return nil
        }

        guard let indMatrix = await model.unfactoredM else {

            DLog("The inductance matrix has not been calculated!")
            return nil
        }

        let segments = await model.CoilSegments()
        let nodes = await model.nodes

        guard !segments.isEmpty, !nodes.isEmpty else {

            DLog("The model has no segments or no nodes!")
            return nil
        }

        // The resolved sets, not NodesOfType's direct ones: a node grounded through a jumper is grounded, and writing it as a
        // node of its own instead of collapsing it onto SPICE's node 0 would export a netlist that is not the model.
        guard let connectivity = try? await model.ResolveNodeConnectivity() else {

            DLog("The jumpers in this model do not resolve to nodes - see PhaseModel.VerifyNodeTopology.")
            return nil
        }

        let grounded = connectivity.grounded
        let impulsed = connectivity.impulsed

        guard !grounded.isEmpty, !impulsed.isEmpty else {

            DLog("The model needs at least one grounded and one impulsed node!")
            return nil
        }

        // SPICE node 0 IS ground, so grounded model nodes collapse onto it
        // rather than getting a node of their own. Everything else is offset by
        // one so that model node 0 does not collide with SPICE's ground.
        func nodeName(_ number:Int) -> String {

            return grounded.contains(number) ? "0" : "N\(number)"
        }

        // Which nodes bracket each segment. Same derivation as
        // SimulationModel.init: a node records the segments below and above
        // it, so scanning the nodes inverts that into segment -> nodes.
        var below = [Int](repeating: -1, count: segments.count)
        var above = [Int](repeating: -1, count: segments.count)

        for node in nodes {

            if let belowSegment = node.belowSegment, !belowSegment.isStaticRing, !belowSegment.isRadialShield,
               let index = try? await model.SegmentIndex(segment: belowSegment) {

                above[index] = node.number
            }

            if let aboveSegment = node.aboveSegment, !aboveSegment.isStaticRing, !aboveSegment.isRadialShield,
               let index = try? await model.SegmentIndex(segment: aboveSegment) {

                below[index] = node.number
            }
        }

        let k1 = 14285.0
        let k2 = 3.3333333E6

        var result = "* SPICE netlist generated by ImpulseDistribution\n"
        result += "* " + filename + "\n"
        result += "* \(segments.count) segments, \(nodes.count) nodes\n"
        result += "*\n"
        result += "* Generated to cross-check FrequencyDomainSolver. Run the .ac sweep first:\n"
        result += "* it compares directly against the solver's own per-frequency solution.\n"
        result += "* Divide the solver's nodal voltage by U(jw) to get the transfer function\n"
        result += "* that .ac reports, since the source here is a unit source.\n"
        result += "*\n"
        result += "* Source is 1V peak, so all results are per-unit.\n"
        result += "*\n\n"

        // --- the impulse source ---
        //
        // EXP(V1 V2 TD1 TAU1 TD2 TAU2) with V1=0, TD1=TD2=0 evaluates to
        //     V2 * ( exp(-t/TAU2) - exp(-t/TAU1) )
        // so TAU1 = 1/k2 and TAU2 = 1/k1 reproduce the full wave
        //     v0 * ( exp(-k1*t) - exp(-k2*t) )
        // exactly - the same function as SimulationModel.WaveForm.V(t).
        //
        // The DC/AC prefix makes the same source usable for the .ac sweep,
        // where the transient description is ignored and the unit AC magnitude
        // is used instead.
        result += "* Full wave 1.2 x 50 us, 1V peak (v0 = 1.03 pu, per DelVecchio)\n"

        for node in impulsed.sorted() {

            result += String(format: "VIMP%d %@ 0 DC 0 AC 1 EXP(0 %.6E 0 %.6E 0 %.6E)\n", node, nodeName(node), 1.03, 1.0 / k2, 1.0 / k1)
        }

        // --- series branches: R and L per segment, series capacitance across ---
        result += "\n* Segment branches: L in series with R, series capacitance in parallel\n"

        for (index, segment) in segments.enumerated() {

            guard below[index] >= 0, above[index] >= 0 else {

                DLog("Segment \(index) is missing a node - cannot export")
                return nil
            }

            guard let selfInductance:Double = await indMatrix[index, index], selfInductance > 0 else {

                DLog("Segment \(index) has a non-positive self-inductance")
                return nil
            }

            let lowNode = nodeName(below[index])
            let highNode = nodeName(above[index])
            let midNode = "S\(index)"

            result += String(format: "L%d %@ %@ %.6E\n", index, lowNode, midNode, selfInductance)
            result += await String(format: "R%d %@ %@ %.6E\n", index, midNode, highNode, segment.resistance())

            let seriesCapacitance = await segment.seriesCapacitance

            if seriesCapacitance > 0 {

                result += String(format: "CS%d %@ %@ %.6E\n", index, lowNode, highNode, seriesCapacitance)
            }
        }

        // --- mutual inductance ---
        //
        // k_ij = M_ij / sqrt(L_ii * L_jj). SPICE requires |k| < 1 and the
        // resulting matrix to be positive definite; both are guaranteed here,
        // because the inductance matrix has already been successfully
        // Cholesky-factorized (see AppController's inductance calculation) and
        // that succeeds only for a positive-definite matrix.
        //
        // Adjacent discs give k of 0.99 and above, which is where SPICE
        // implementations start to struggle - hence the small-model advice.
        result += "\n* Mutual inductance: \(segments.count * (segments.count - 1) / 2) coupling coefficients\n"

        var worstCoupling = 0.0

        for i in 0..<segments.count {

            for j in (i + 1)..<segments.count {

                guard let lii:Double = await indMatrix[i, i], let ljj:Double = await indMatrix[j, j], let mij:Double = await indMatrix[i, j] else {

                    continue
                }

                let denominator = (lii * ljj).squareRoot()

                guard denominator > 0 else { continue }

                let k = mij / denominator

                guard abs(k) > 1.0E-9 else { continue }

                worstCoupling = max(worstCoupling, abs(k))

                // Clamp strictly inside unity. A k of exactly 1 is rejected by
                // every SPICE, and rounding in the division can produce one
                // even when the matrix itself is fine.
                let safe = min(max(k, -0.999999), 0.999999)

                result += String(format: "K%d_%d L%d L%d %.9f\n", i, j, i, j, safe)
            }
        }

        result += String(format: "* strongest coupling in this model: %.6f\n", worstCoupling)

        // --- shunt capacitances ---
        result += "\n* Shunt capacitances (toNode -1 means to ground)\n"

        var shuntIndex = 0

        for node in nodes {

            for shunt in node.shuntCapacitances {

                // Each pair is stored on both nodes, so emit only one
                // direction. -1 means ground, which is never a real node
                // number and so always passes this test.
                guard shunt.toNode < 0 || shunt.toNode > node.number else { continue }

                guard shunt.capacitance > 0 else { continue }

                let from = nodeName(node.number)
                let other = shunt.toNode < 0 ? "0" : nodeName(shunt.toNode)

                // A grounded node's shunt capacitance to ground collapses to a
                // component with both terminals on node 0 once grounded nodes
                // are mapped onto SPICE's ground. It carries no current and
                // ngspice rejects it, so drop it.
                guard from != other else { continue }

                result += String(format: "CP%d %@ %@ %.6E\n", shuntIndex, from, other, shunt.capacitance)
                shuntIndex += 1
            }
        }

        // --- analyses ---
        result += "\n* .ac first: it compares directly against the solver's per-frequency result.\n"
        result += "* .tran afterwards checks the inverse transform.\n"
        result += ".ac dec 100 1E3 1E7\n"
        result += ".tran 5E-9 100E-6 0 5E-9\n"
        result += "\n* Adjacent discs couple at k > 0.99, so the default tolerances are too loose.\n"
        result += ".options reltol=1e-6 abstol=1e-12 vntol=1e-9 gmin=1e-15\n"
        result += ".end\n"

        return result
    }

    @IBAction func handleMainWdgInductances(_ sender: Any) {
        
        Task {
            
            let _ = await self.doMainWindingInductances()
        }
        
    }
    
    /// Function to calculate the self-inductance of each main winding (as defined by the XL file) as well as the mutual inductance to every other main winding. It is assumed that all Segments of all Windings are in the circuit. The amp values are those calculated using the highest kVA in the XL file.
    /// - Returns: A matrix where entry i,i is the self-inductance of the winding in the 'i' radial position (0 closest to the core), and entry i,j (and j,i) is the mutual inductance beyween coil i and coil j
    func doMainWindingInductances() async -> PchMatrix? {
        
        guard let model = self.currentModel, currentXLfile != nil, let iMatrix = await model.unfactoredM , let fePhase = self.currentFePhase else {
            
            DLog("A valid model, a valid XL file, and an unfactored inductance matrix must be defined!")
            return nil
        }
        
        let indMatrix = await PchMatrix(srcMatrix: iMatrix)
        
        let segments = await model.CoilSegments()
        let numCoils = segments.last!.radialPos + 1
        
        let coilIndMatrix = PchMatrix(matrixType: .general, numType: .Double, rows: UInt(numCoils), columns: UInt(numCoils))
        
        // NOTE: This all assumes that the index in the 'segments' array matches the index in the 'indMatrix' matrix, which I believe it does
        do {
            for i in 0..<numCoils {
            
                let segRange = try await model.SegmentRange(coil: i)
                
                for nextRow in segRange {
                    
                    for nextCol in segRange {
                        
                        if let nextValue:Double = await indMatrix[nextRow, nextCol], let oldValue:Double = await coilIndMatrix[i, i] {
                            
                            // The mutual inductances should be doubled, but ONLY if we are reading them once. The matrix is symmetrical and we'll just go over every single entry and add it.
                            await coilIndMatrix.SetDoubleValue(value: oldValue + nextValue, row: i, col: i)
                            // coilIndMatrix[i, i] = oldValue + nextValue
                        }
                        else {

                            ALog("Summing coil \(i)'s inductance: could not read the segment matrix at [\(nextRow), \(nextCol)] and/or the coil matrix at [\(i), \(i)]. The segment matrix is \(await indMatrix.rows) x \(await indMatrix.columns) and the coil matrix is \(await coilIndMatrix.rows) x \(await coilIndMatrix.columns), so check that SegmentRange is returning indices that fit.")
                        }
                    }
                }
            }
        }
        catch {
            
            let alert = NSAlert(error: error)
            let _ = alert.runModal()
            return nil
        }
        
        // get the energy from the last FePhase used
        let leakageEnergy = await fePhase.EnergyFromInductance()
        DLog("Energy: \(leakageEnergy)")
        
        // use DelVecchio eq. 4.22 to solve for M12
        // Current calculations are a pain because this routine assumes all turns are in the circuit. For a coil with off-load taps, this is the low-current tap, which is NOT what is saved as the 'seriesRMSCurremt'. That is actually the nominal current.
        // The magnitudes are taken (and coil 1's sign forced) rather than used as stored: the two coils carry their amp-turns in opposite senses, which is what makes the mutual term come out of the energy at all.
        let I0 = await abs(fePhase.SeriesRmsCurrent(section: 0) * sqrt(2))
        guard let section1Index = try? await model.SegmentRange(coil: 1).lowerBound else {
            
            DLog("Bad section index!")
            return nil
        }
        let I1 = await -abs(fePhase.SeriesRmsCurrent(section: section1Index) * sqrt(2))
        var M12 = 2 * leakageEnergy
        M12 -= await coilIndMatrix[0, 0]! * I0 * I0
        await M12 -= coilIndMatrix[1, 1]! * I1 * I1
        M12 /= 2
        M12 /= I0
        M12 /= I1
        await coilIndMatrix.SetDoubleValue(value: M12, row: 0, col: 1)
        await coilIndMatrix.SetDoubleValue(value: M12, row: 1, col: 0)
        // coilIndMatrix[0, 1] = M12
        // coilIndMatrix[1, 0] = M12
        
        print(coilIndMatrix)
        return coilIndMatrix
    }
    
    /*
    @IBAction func handleWdgImpedancePairs(_ sender: Any) {
        
        let kvaImp = doWindingImpedance(coil1: 0, coil2: 1)
        
        if kvaImp.baseVA != 0 && kvaImp.impedancePU != 0 {
            
            print("Impedance: \(kvaImp.impedancePU * 100)% at \(kvaImp.baseVA) kVA")
        }
    } */
    
    /*
    /// Function to get the impedance (in p.u. of the winding with the higher VA) between two coils. If the VA of the two windings is different, the higher of the two is used to do the calculation. Note that if an error occurs (like if coil1 = coil2 or one of the coils does not exist), the tuple (0,0) is returned.
    /// - Parameter coil1: One of the two coils of the calculation, as referred to by its radial position in the phase (0-based)
    /// - Parameter coil2: The other coil in the calculation
    /// - Returns: A tuple where 'baseVA' is the VA upon which the impedance is based; where impedancePU is the impedance in p.u. between the windings at that base
    func doWindingImpedance(coil1:Int, coil2:Int) -> (baseVA:Double, impedancePU:Double) {
        
        guard let model = self.currentModel, let xlFile = currentXLfile else {
            
            DLog("Both a valid model and a valid XL file must be defined!")
            return (0, 0)
        }
        
        guard let energy = try? model.TotalMagneticEnergy(coil1: coil1, coil2: coil2) else {
            
            DLog("Could not calculate energy! (Bad coil designation(s)")
            return (0 , 0)
        }
        
        // if we get here, then coil1 and coil2 are valid and the energy calculation has been successfully done
        let baseVA = 1000.0 / Double(xlFile.numPhases) * (xlFile.windings[coil1].terminal.kVA >= xlFile.windings[coil2].terminal.kVA ? xlFile.windings[coil1].terminal.kVA : xlFile.windings[coil2].terminal.kVA)
        
        // this comes from the Andersen paper for transformer flux calculation using finite elements
        let impedance = (2.0 * π * xlFile.frequency) / baseVA * energy
        
        return (baseVA, impedance)
    } */
    
    // MARK: Menu Validation
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        if menuItem == self.zoomInMenuItem || menuItem == self.zoomOutMenuItem || menuItem == self.zoomRectMenuItem || menuItem == self.zoomRectMenuItem || menuItem == self.addGroundMenuItem || menuItem == self.addImpulseMenuItem || menuItem == self.addConnectionMenuItem || menuItem == self.removeConnectionMenuItem || menuItem == self.saveAsCirFileMenuItem || menuItem == saveBmatrixMenuItem {
            
            return self.currentModel != nil
        }
        
        if menuItem == self.mainWdgInductanceMenuItem || menuItem == self.mainWdgImpedanceMenuItem {
            
            return self.currentModel != nil && self.currentXLfile != nil && inductanceIsValid
        }
        
        // get local copies of variables that we access often
        let currentSegs = self.txfoView.currentSegments
        let currentSegsCount = currentSegs.count
        
        if menuItem == self.staticRingOverMenuItem || menuItem == self.staticRingBelowMenuItem || menuItem == self.radialShieldInsideMenuItem {
            
            return self.currentModel != nil && currentSegsCount == 1 && !currentSegs[0].segment.isStaticRing && !currentSegs[0].segment.isRadialShield
        }
        
        if menuItem == self.removeStaticRingMenuItem {
            
            return self.currentModel != nil && currentSegsCount == 1 && currentSegs[0].segment.isStaticRing
        }
        
        if menuItem == self.removeRadialShieldMenuItem {
            
            return self.currentModel != nil && currentSegsCount == 1 && currentSegs[0].segment.isRadialShield
        }
        
        if menuItem == self.combineSegmentsIntoSingleSegmentMenuItem {
            
            return self.currentModel != nil && currentSegsCount > 1 && !self.txfoView.currentSegmentsContainMoreThanOneWinding && !currentSegs.contains(where: {$0.segment.isStaticRing}) && !currentSegs.contains(where: {$0.segment.isRadialShield})
        }
        
        if menuItem == self.interleaveSelectionMenuItem {
            
            var totalBasicSections = 0
            for nextSegment in currentSegs {
                
                totalBasicSections += nextSegment.segment.basicSections.count
            }
            
            return self.currentModel != nil && totalBasicSections > 1 && totalBasicSections % 2 == 0 && !self.txfoView.currentSegmentsContainMoreThanOneWinding && currentSegs[0].segment.basicSections[0].wdgData.type == .disc && !currentSegs.contains(where: {$0.segment.isStaticRing}) && !currentSegs.contains(where: {$0.segment.isRadialShield})
        }
        
        if menuItem == self.addWoundInShieldsMenuItem || menuItem == self.removeWoundInShieldsMenuItem {

            guard self.currentModel != nil, currentSegsCount > 0, !self.txfoView.currentSegmentsContainMoreThanOneWinding else {

                return false
            }

            guard !currentSegs.contains(where: { $0.segment.isStaticRing || $0.segment.isRadialShield }) else {

                return false
            }

            guard currentSegs[0].segment.basicSections[0].wdgData.type == .disc else {

                return false
            }

            if menuItem == self.removeWoundInShieldsMenuItem {

                // Whether the selection actually HAS shields cannot be tested here - 'woundInShield' is mutable state on an actor
                // and validateMenuItem is synchronous. doRemoveWoundInShields reports it instead, the same way doInterleaveSelection
                // handles the equivalent test for 'interleaved'.
                return true
            }

            // A shield spans a disc PAIR, so the discs have to divide evenly into pairs. There are two ways of getting there and
            // both are accepted, because doAddWoundInShields handles both:
            //
            //   - an even NUMBER OF SEGMENTS, which it pairs up by rebuilding them into two-disc Segments. This is the case that
            //     matters in practice: the load path gives every disc its own Segment (see the Segment(basicSections:
            //     [nextSection]) call there), so a freshly loaded model is always all-odd and testing only the per-Segment disc
            //     count disabled the item permanently;
            //   - or every Segment already holding an even number of discs, which needs no rebuild at all. Testing only the
            //     segment count would in turn have disabled the single already-combined Segment, which works today.
            //
            // Two things this deliberately does NOT test, both because they need state validateMenuItem cannot reach - it is
            // synchronous and cannot await an actor - and both reported by doAddWoundInShields instead: whether the Segments are
            // contiguous (only relevant on the rebuild path, since pairing across a gap would straddle two discs that are not
            // neighbours), and whether a disc has the 2 turns a shield turn needs to sit between.
            return currentSegsCount % 2 == 0 || !currentSegs.contains(where: { $0.segment.basicSections.count % 2 != 0 })
        }

        if menuItem == self.regulatingWindingMenuItem {

            // The arrangement comes from the design file, so there has to be one. Whether the coil is still one disc per Segment
            // is NOT tested here - basicSections is readable, but the answer is only needed for a double-stacked winding, which
            // is a design-file question validateMenuItem cannot await - so doRegulatingWinding reports it instead.
            return self.currentModel != nil && self.currentXLfile != nil && currentSegsCount > 0 && !self.txfoView.currentSegmentsContainMoreThanOneWinding && !currentSegs.contains(where: { $0.segment.isStaticRing || $0.segment.isRadialShield })
        }

        if menuItem == self.showWdgAsSingleSegmentMenuItem {
            
            return self.currentModel != nil && currentSegsCount > 0 && !self.txfoView.currentSegmentsContainMoreThanOneWinding
        }
        
        if menuItem == self.splitSegmentToBasicSectionsMenuItem {
            
            return self.currentModel != nil && currentSegsCount == 1 && currentSegs[0].segment.basicSections.count > 1 && !currentSegs.contains(where: {$0.segment.isStaticRing}) && !currentSegs.contains(where: {$0.segment.isRadialShield})
        }
        
        if menuItem == self.saveMmatrixMenuItem {
            
            return self.currentModel != nil && inductanceIsValid
        }
        
        if menuItem == self.saveUnfactoredMmatrixMenuItem {
            
            return self.currentModel != nil && inductanceIsValid
        }
        
        // Neither of these needs a simulation model to exist: both build one if there isn't one (and "Simulate now" rebuilds it
        // whether there is one or not). What they need is a design complete enough to build one FROM, which is designIsValid.
        if menuItem == self.compareSolversMenuItem {

            return self.currentModel != nil && self.designIsValid && self.runningSimulationTask == nil
        }

        if menuItem == self.simulateMenuItem {

            return self.currentModel != nil && self.designIsValid && self.runningSimulationTask == nil
        }

        if menuItem == self.cancelSimulationMenuItem {

            return self.runningSimulationTask != nil
        }

        if menuItem == self.cancelInductanceMenuItem {

            return self.runningInductanceTask != nil
        }
        
        if menuItem == self.showWaveformsMenuItem || menuItem == self.showCoilResultsMenuItem || menuItem == self.showVoltageDiffsMenuItem {

            return self.currentModel != nil && self.currentSimModel != nil && self.latestSimulationResult != nil
        }

        // The three stress items are matched on their action rather than on an outlet. They need exactly the same state as the three
        // above, and matching the selector saves adding three more @IBOutlets and three more xib connections for no benefit.
        if menuItem.action == #selector(handleShowStressReport(_:)) || menuItem.action == #selector(handleShowRadialStressProfiles(_:)) || menuItem.action == #selector(handleShowAxialStressProfile(_:)) {

            return self.currentModel != nil && self.currentSimModel != nil && self.latestSimulationResult != nil
        }

        // The initial distribution is purely electrostatic - the s -> infinity limit of the sweep's own assembly - so it needs a
        // simulation model but NOT a run, and it builds the model itself if there isn't one. See doShowInitialDistribution.
        if menuItem.action == #selector(handleShowInitialDistribution(_:)) {

            return self.currentModel != nil && self.designIsValid
        }

        // The turn ladder handles plain continuous discs and nothing else, so the menu says so rather than letting the command be
        // chosen and then refused. Interleaved and wound-in-shield Segments are enabled deliberately: those are refused with an
        // explanation of WHY the winding order cannot be guessed, which is worth reading, whereas a sheet or layer winding has
        // somewhere else to go and is simply pointed at it.
        if menuItem.action == #selector(handleShowTurnLadder(_:)) {

            guard self.currentModel != nil, self.latestSimulationResult != nil, currentSegsCount == 1 else {

                return false
            }

            let segment = currentSegs[0].segment

            return !segment.isStaticRing && !segment.isRadialShield && segment.wdgType == .disc
        }

        // Its counterpart for the windings whose turns run out along a radius. Enabled only for those two types - the graph's whole
        // x axis is a count of radial gaps, and a disc winding has one.
        if menuItem.action == #selector(handleShowRadialProfile(_:)) {

            guard self.currentModel != nil, self.latestSimulationResult != nil, currentSegsCount == 1 else {

                return false
            }

            let segment = currentSegs[0].segment

            return !segment.isStaticRing && !segment.isRadialShield && (segment.wdgType == .sheet || segment.wdgType == .layer)
        }
        
        if menuItem == self.saveBaseCmatrixMenuItem {
            
            return self.currentModel != nil && self.capacitanceIsValid
        }
        
        if menuItem == self.saveFixedCmatrixMenuItem {
            
            return self.currentModel != nil && self.capacitanceIsValid
        }
        
        // default to true
        return true
    }
    
    /// Tell the user that something did not work, and why.
    ///
    /// This is the app's only way of reporting a refusal: 52 call sites, most of them a guard that has decided an operation cannot
    /// be done - a selection that spans a tapping gap, a coil that is already interleaved, a model that is not there yet. It used
    /// to come from `PchBasePackage` and put a real alert up; when it was dropped from the package this stub replaced it and only
    /// called `DLog`, which is compiled out entirely in Release. Every one of those refusals therefore became **silent**, and a
    /// menu command that declines to act while saying nothing is indistinguishable from a broken one. That is what "Interleave
    /// Section does nothing on the tap winding" was: the tapping-gap guard firing into a log nobody was reading.
    ///
    /// The log line stays, because it is what a self-test run leaves behind, and it is the only report in a headless run: a modal
    /// alert with nobody at the keyboard hangs the run forever (see `docs/self-test.md`).
    func PCH_ErrorAlert(message: String, info: String? = nil) {

        var dlogMsg = message
        if let info = info {
            dlogMsg += ": \(info)"
        }

        DLog(dlogMsg)

        guard !SelfTest.isRunningHeadless else {

            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let info = info {
            alert.informativeText = info
        }
        alert.addButton(withTitle: "OK")
        let _ = alert.runModal()
    }
    
}
