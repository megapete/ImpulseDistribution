//
//  SelfTest.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-08-06.
//
//  A scripted, non-interactive run of a KNOWN design, so that the program can be exercised end to end without anybody
//  sitting at the keyboard: load a design file, apply a fixed set of terminations, build the simulation model, solve
//  the initial distribution, and write a report.
//
//  WHY THIS EXISTS. There is no test target (see CLAUDE.md), and every route to a model otherwise starts at an
//  NSOpenPanel in AppController.handleOpenFile. That makes every check in this program a hand check, which is fine for
//  a one-off verification - DielectricStress.VerifySelf() and TurnLadderModel.VerifySelf() are exactly that - but no
//  use at all as a regression net, because nobody re-runs a hand check after an unrelated edit. This runs the whole
//  pipeline from a launch argument and leaves a text report behind.
//
//  HOW TO RUN IT. The app is launched with the scenario name as a launch argument. NSUserDefaults parses "-key value"
//  launch arguments into the defaults domain automatically, so there is no argument parsing here and no risk of the
//  test path being reachable from a normal launch:
//
//      /path/to/ImpulseDistribution.app/Contents/MacOS/ImpulseDistribution -PCH_SelfTest STME0999
//
//  Add "-PCH_SelfTestTransient YES" to also run the frequency-domain sweep. That is off by default because the sweep
//  is minutes of work and most edits that could break something break it in the assembly or the capacitance, both of
//  which the initial distribution already sees.
//
//  WHERE THE FIXTURE LIVES. The app is sandboxed with only 'user-selected.read-write', so a design file anywhere else
//  on the disk is unreadable without the open panel that granted access to it. The app's OWN container is always
//  readable, so the fixture is looked for in the container's Documents folder:
//
//      ~/Library/Containers/com.huberistech.ImpulseDistribution/Data/Documents/
//
//  Copy the design file there before running. This is deliberately not solved with a temporary-exception entitlement:
//  that would change what the shipped app is allowed to read in order to run a test.
//
//  WHERE THE RESULTS GO. The full report is written to a text file beside the fixture in that same Documents folder,
//  and a one-line summary plus the last stage reached go into UserDefaults:
//
//      defaults read com.huberistech.ImpulseDistribution PCH_SelfTestSummary
//      defaults read com.huberistech.ImpulseDistribution PCH_SelfTestStage
//      cat ~/Library/Containers/com.huberistech.ImpulseDistribution/Data/Documents/SelfTestReport-STME0999.txt
//
//  The stage breadcrumb is written and flushed before each step. If the run hangs - and it can, because the pipeline
//  raises NSAlerts on failure and a modal alert will sit there forever with nobody to dismiss it - that key says which
//  step it hung in.
//
//  WHAT IT CHECKS. Two different things, and it is worth keeping them apart:
//
//  1. A REGRESSION BASELINE. Parsed geometry, per-coil series and ground capacitance, and the computed initial
//     distribution, all printed to enough digits to diff. This does not know what the right answer is; it tells you
//     that today's answer is or is not yesterday's.
//
//  2. A COMPARISON AGAINST DELVECCHIO SECTION 13.5.1, "Uniform Capacitance Model". The continuum model replaces the
//     winding by a uniform ladder of series capacitance and capacitance to ground, and gives the initial distribution
//     in closed form as
//
//         V(x)/V = sinh(alpha*x) / sinh(alpha),     alpha = sqrt(Cg / Cs)
//
//     with x measured from the GROUNDED end (x = 0) to the line end (x = 1), Cg the winding's total capacitance to
//     ground and Cs the winding's total series capacitance (the series combination of the per-disc values, which is
//     what PhaseModel.CoilSeriesCapacitance returns).
//
//     This is an approximation and its disagreements are as informative as its agreements. It assumes Cg and Cs are
//     UNIFORM along the winding, which the real model's are not - the end discs get Stein/end-disc treatment and the
//     ground capacitance is not uniform at the ends either. It has no inductance at all, which is why only the t = 0+
//     distribution is compared and not the transient. And it has no second coil, which is the reason alpha is
//     reported twice, bracketed (see the note on ContinuumComparison).
//

import Cocoa
import PchBasePackage
import PchExcelDesignFilePackage

@MainActor
enum SelfTest {

    // MARK: Keys

    /// The launch argument that names the scenario to run. Absent on a normal launch, which is what keeps this code
    /// unreachable in ordinary use.
    static let scenarioKey = "PCH_SelfTest"
    /// Set this to run the frequency-domain sweep as well as the initial distribution.
    static let transientKey = "PCH_SelfTestTransient"
    /// Set this to render the result graphs to PNGs beside the report, so that a drawing change can be LOOKED at without a
    /// keyboard. Needs the transient, since the graphs are of its findings.
    static let graphsKey = "PCH_SelfTestGraphs"
    /// A one-line summary of the run, in UserDefaults.
    static let summaryKey = "PCH_SelfTestSummary"
    /// The last stage the run reached, flushed before each step so that a hang can be located.
    static let stageKey = "PCH_SelfTestStage"

    /// True when the app was launched to run a scenario, ie: when there is nobody at the keyboard.
    ///
    /// `AppController.PCH_ErrorAlert` asks this before it puts a modal alert up: a run with nobody watching cannot dismiss one and
    /// would hang forever (the whole reason `stageKey` exists). It is written the same way `RunIfRequested` reads the argument -
    /// `NSUserDefaults` parses `-PCH_SelfTest <name>` itself - so a normal launch answers false with no plumbing anywhere.
    static var isRunningHeadless:Bool {

        guard let scenarioName = UserDefaults.standard.string(forKey: scenarioKey) else {

            return false
        }

        return !scenarioName.isEmpty
    }

    // MARK: Scenario description

    /// Which end of a coil a lead comes off. Lives in `Wiring` now, which the regulating-winding path shares.
    typealias CoilEnd = Wiring.CoilEnd

    /// A point on the winding that a lead comes off. A scenario names its connections this way rather than by
    /// (Segment, Connector.Location), for the reasons given on `Wiring.LeadPoint`: the lead is always *found* and never computed,
    /// because a guessed one produces a connector `NodeAt` cannot resolve, which is exactly the failure this file exists to catch.
    typealias LeadPoint = Wiring.LeadPoint

    /// One terminal of the test connection: a lead, and what it is tied to.
    struct Termination {

        let point:LeadPoint
        /// Either `.ground` or `.impulse`. Nothing else is a termination.
        let type:Connector.Location
    }

    /// A jumper between two leads - what the user makes by clicking one connector and then another.
    ///
    /// Applied AFTER the restructure and BEFORE the terminations, in the order the scenario lists them, because both of those
    /// orderings are load-bearing. A restructure swaps Segments and sends `UpdateConnectors` through the connectors, which a
    /// jumper made first would not survive; and `AddConnector` REPLACES a floating lead with a ground or an impulse while it
    /// APPENDS a jumper, so a lead that has already been terminated is no longer there to jumper from.
    typealias Jumper = Wiring.Jumper

    /// One edit made to an already-wired model, applied in order after the scenario's own jumpers and terminations.
    ///
    /// This exists because a model is not always built in one pass. A designer changes a connection scheme by editing the one
    /// that is already there - removing a jumper, grounding what it used to feed - and the interesting failures live in exactly
    /// that sequence rather than in any single operation. A scenario that can only describe a finished wiring cannot reach them.
    enum Edit {

        /// Drag a new jumper between two leads, as `Jumper` does.
        case jumper(Jumper)
        /// Click an existing jumper in *Remove Connector* mode. Named by the two leads it runs between.
        case remove(Jumper)
        /// Click a lead in *Add Ground* / *Add Impulse* mode.
        case terminate(Termination)
    }

    /// Where a paralleled tap winding is tied to the HV neutral.
    ///
    /// The winding is the same either way and so is the paralleling; only the point that is held at earth moves, and with it
    /// which part of the tap winding screens the HV and which part is free to ride up with it.
    enum TapNeutralTie {

        /// The two outer ends, at the top and bottom of the tap winding. Its centre is then the free end.
        case outerEnds
        /// The two leads facing each other across the centre gap. The outer ends are then the free end.
        case centre
    }

    /// A static ring fitted to one end of a coil, AFTER the restructure.
    ///
    /// The order is the point of it. A ring is a Segment like any other, so it has to go on after the interleaving or shielding
    /// that rebuilds the coil's Segments, exactly as the user would fit one (`AppController.doAddStaticRingOver` is enabled on a
    /// selection of one Segment, whatever that Segment turned out to be). The scenario names an END of a coil rather than a
    /// Segment for the same reason `LeadPoint` does: which Segment is at the top of a restructured coil is not knowable from the
    /// design file.
    struct StaticRing {

        let coil:Int
        let end:CoilEnd
    }

    /// A structural change made to the model after it is loaded and before the terminations go on.
    ///
    /// These are the two things a designer does when the initial distribution is too steep, and the whole reason for
    /// wanting more than one scenario: the fixture's line-end gradient can be measured with neither, with interleaving
    /// and with an intershield, on identical geometry.
    ///
    /// Both rebuild the coil into TWO-DISC Segments, which is what makes them comparable to each other and what makes
    /// the per-section numbers in the transient report mean something different from the plain case - see
    /// TransientReport. Terminations are applied afterwards for the same reason `doInterleaveSelection` leaves them to
    /// the user: `UpdateConnectors` rebuilds the connectors when Segments are swapped, and a ground applied first would
    /// not survive it.
    enum Restructure {

        /// Leave the winding as the design file describes it.
        case none
        /// Interleave the whole coil: every two adjacent discs become one interleaved Segment.
        case interleave(coil:Int)
        /// Put a wound-in shield of `turnsPerDisc` turns into every disc pair of the coil (DelVecchio 12.11).
        case woundInShield(coil:Int, turnsPerDisc:Int, connection:Segment.WoundInShieldWire.Connection)

        var isInterleave:Bool {

            if case .interleave = self {

                return true
            }

            return false
        }
    }

    /// Hold a coil at the radial build a wound-in shield would need, without fitting the shield.
    ///
    /// A shield does two things at once - it adds shield turns AND it widens the disc, which raises C_dd on its own because the
    /// disc has more face area. Measuring a shielded coil against an unshielded one of the original width credits the shield with
    /// both. Setting this on the plain and interleaved scenarios to the same turn count the shielded scenario uses puts all three
    /// at one geometry, so the only difference left is the electrical treatment. See `PhaseModel.radialBuildUpFloor`.
    struct MatchedBuild {

        let coil:Int
        /// The shield turn count whose radial build is to be matched - the same number the shielded scenario fits.
        let turnsPerDisc:Int
        let connection:Segment.WoundInShieldWire.Connection
    }

    /// A complete scripted run.
    struct Scenario {

        let name:String
        /// What to do to the winding before terminating it.
        let restructure:Restructure
        /// Widen a coil to a shield's build without fitting the shield. Nil leaves the geometry as the design file has it.
        let matchedBuild:MatchedBuild?
        /// Static rings to fit after the restructure. Empty for a scenario that is about something else.
        var staticRings:[StaticRing] = []
        /// The design file's name in the container's Documents folder.
        let fixtureName:String
        /// A sentence about the design, echoed into the report so that a stale report identifies itself.
        let notes:String
        /// Segment-to-segment jumpers, applied in order, after the restructure and before the terminations.
        let jumpers:[Jumper]
        /// Coils declared as regulating windings, whose permanent connections go on through `RegulatingWinding.Apply` - the path
        /// the menu command and the design-file load take - BEFORE `jumpers`, since a jumper that ties the winding to anything
        /// else is made to a winding that is already connected up. Empty for a scenario that wires everything by hand.
        var regulatingWindings:[RegulatingWinding] = []
        let terminations:[Termination]
        /// Further edits, in order, made to the model once the jumpers and terminations above are all on. Empty for a scenario
        /// that describes a wiring built in one pass.
        var edits:[Edit] = []
        let waveFormType:SimulationModel.WaveForm.Types
        /// Impulse crest, in volts.
        let peakVoltage:Double
        /// How much of the transient to record, in seconds.
        let displaySpan:Double
        /// The sweep's upper frequency, in Hz. This is the solver's only accuracy control.
        let bandwidth:Double
        /// The coil whose initial distribution is compared against the continuum model - the impulsed one.
        let continuumCoil:Int
        /// Print every node of every coil with how the simulation model classified it and what the initial distribution put
        /// there. Off by default because it is a page per hundred nodes; on for any scenario that is about the CONNECTIONS,
        /// where "which nodes did the model decide are grounded" is the whole question.
        var reportNodes:Bool = false
    }

    /// The STME-0999 fixture: a real two-winding core-form design, 4160Y/2400 V LV and 69 kV delta HV, 350 kV BIL on
    /// the HV. Both LV leads and the HV neutral are grounded and the HV line end is impulsed - the standard impulse
    /// test connection, and the reason the LV appears in the model at all (a winding shorted to ground is not a
    /// winding that can be left out of the capacitance picture).
    ///
    /// It was the first fixture because its geometry is uniform: no taps, no axial gaps, a plain 70-disc continuous
    /// HV and a plain 48-turn helical LV. That is precisely the case DelVecchio 13.5.1 is written for, so a
    /// disagreement is much more likely to be this program's than the continuum model's.
    ///
    /// The three variants differ ONLY in `restructure`, which is the point: same core, same conductor, same gaps, same
    /// impulse, so the line-end gradient can be read off three times and compared without anything else having moved.
    private static func STME0999(name:String, notes:String, restructure:Restructure, staticRings:[StaticRing] = []) -> Scenario {

        return Scenario(name: name,
                        restructure: restructure,
                        matchedBuild: nil,
                        staticRings: staticRings,
                        fixtureName: "STME-0999_AndIn.txt",
                        notes: "4160Y/2400 V LV (48-turn helical), 69 kV delta HV (70-disc continuous), 350 kV full wave on the HV line end. " + notes,
                        jumpers: [],
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: 350.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 1)
    }

    /// The scenarios this build knows about, keyed by the string passed to -PCH_SelfTest.
    static let scenarios:[String:Scenario] = [

        "STME0999" : STME0999(name: "STME0999",
                              notes: "HV as designed - plain continuous discs, no interleaving and no shields.",
                              restructure: .none),

        // Interleaving is the big hammer: it raises the series capacitance of a disc pair by an order of magnitude, so
        // alpha falls and the initial distribution flattens. The 70 discs become 35 interleaved Segments.
        "STME0999-interleaved" : STME0999(name: "STME0999-interleaved",
                                          notes: "The whole HV winding interleaved.",
                                          restructure: .interleave(coil: 1)),

        // A wound-in shield is the adjustable version of the same idea (DelVecchio 12.11): it raises the pair's series
        // capacitance by an amount that goes with the shield turn count, so it lands between the two extremes and can
        // be graded. Six turns against 19.7 turns per disc. Floating is the dialog's own default connection.
        "STME0999-shield6" : STME0999(name: "STME0999-shield6",
                                      notes: "A 6-turn wound-in shield in every disc pair of the HV.",
                                      restructure: .woundInShield(coil: 1, turnsPerDisc: 6, connection: .floating)),

        // The second fixture, and the one intershielding is actually FOR. STME-0999 is a small unit with 19.7 turns per HV disc,
        // where interleaving is a perfectly practical option and a 6-turn shield is 30% of the turns; this is a 25 MVA
        // 120 kV(Y)/26.4 kV(D) unit wound in CTC on BOTH coils, where interleaving is essentially impossible and the HV carries
        // only 10.75 turns per disc, so a 5-turn shield is about half of them.
        //
        // All three variants hold the HV at the SAME radial build - the one the 5-turn shield needs - so that the shielded case is
        // not quietly credited for the extra disc face area its own wire bought it. See MatchedBuild.
        "STME0999_2" : STME0999_2(name: "STME0999_2",
                                  notes: "HV as designed - plain continuous discs, at the 5-turn shield's radial build.",
                                  restructure: .none,
                                  matchedBuild: MatchedBuild(coil: 1, turnsPerDisc: 5, connection: .floating)),

        "STME0999_2-interleaved" : STME0999_2(name: "STME0999_2-interleaved",
                                              notes: "The whole HV winding interleaved, at the 5-turn shield's radial build.",
                                              restructure: .interleave(coil: 1),
                                              matchedBuild: MatchedBuild(coil: 1, turnsPerDisc: 5, connection: .floating)),

        "STME0999_2-shield5" : STME0999_2(name: "STME0999_2-shield5",
                                          notes: "A 5-turn wound-in shield in every disc pair of the HV - about half its turns.",
                                          restructure: .woundInShield(coil: 1, turnsPerDisc: 5, connection: .floating),
                                          matchedBuild: nil),

        // A STATIC RING AT EACH END OF THE HV, on top of each of the first two variants.
        //
        // These exist because a static ring is the one thing in the model that is a Segment but is NOT a circuit element, and
        // every array whose length is "the number of Segments" therefore has two possible meanings the moment one is fitted.
        // `CoilSegments()` filters shielding elements out and `PhaseModel.segments` does not, and mixing the two is what made
        // `recalculateModel` walk off the end of the finite-element model's section array - "Index out of range", raised from the
        // eddy-loss transfer immediately before the inductance calculation. The interleaved variant is the case that was
        // reported: a restructure makes the two arrays differ in length twice over, once for the pairing and once for the ring.
        //
        // They are also the only scenarios that fit a ring to a coil whose Segments were REBUILT after it was loaded, which is
        // the other half of the redesign - a ring is located by its geometry, so interleaving cannot renumber it into an orphan.
        "STME0999-rings" : STME0999(name: "STME0999-rings",
                                    notes: "HV as designed, with a static ring at each end of it.",
                                    restructure: .none,
                                    staticRings: [StaticRing(coil: 1, end: .bottom), StaticRing(coil: 1, end: .top)]),

        "STME0999-interleaved-rings" : STME0999(name: "STME0999-interleaved-rings",
                                                notes: "The whole HV winding interleaved, with a static ring at each end of it.",
                                                restructure: .interleave(coil: 1),
                                                staticRings: [StaticRing(coil: 1, end: .bottom), StaticRing(coil: 1, end: .top)]),

        "S0738" : S0738(name: "S0738", restructure: .interleave(coil: 2)),

        // The same connection with the HV left alone, so that a failure can be pinned on the restructure or acquitted of it.
        "S0738-plain" : S0738(name: "S0738-plain", restructure: .none),

        // The two-winding fixture that exists for the radial voltage profile: a sheet coil and a layer coil and nothing else. Each
        // variant impulses ONE of them and shorts the other out, so the profile under test is driven by the impulse directly
        // rather than by transfer, and the coil beside it is at a fixed potential.
        "SHEETLAYER-sheet" : SheetAndLayer(name: "SHEETLAYER-sheet", impulsedCoil: 0, peakVoltage: 45.0e3),
        "SHEETLAYER-layer" : SheetAndLayer(name: "SHEETLAYER-layer", impulsedCoil: 1, peakVoltage: 125.0e3),

        // The same design with coil 0's top lead left floating, so the SHEET winding takes a transferred voltage instead of being
        // shorted end to end. This is the scenario that exercises the radial voltage profile: grounded at both ends coil 0 has no
        // volts across it at any instant, and the graph is a correct but uninformative flat zero.
        "S0738-sheet-floating" : S0738(name: "S0738-sheet-floating", restructure: .none, groundSheetTop: false),

        // The SAME fixture wired the way a double-stacked tap winding is wired when there are no taps in circuit: the two halves
        // PARALLELED rather than put in series with the HV. See S0738Parallel.
        "S0738-parallel" : S0738Parallel(name: "S0738-parallel", restructure: .none),

        "S0738-parallel-interleaved" : S0738Parallel(name: "S0738-parallel-interleaved", restructure: .interleave(coil: 2)),

        // The SAME finished wiring as S0738-parallel, arrived at by EDITING the S0738 wiring rather than by building it in one
        // pass - which is how a designer actually gets there, and which is the case that fails. See S0738ParallelEdited.
        "S0738-parallel-edited" : S0738ParallelEdited(name: "S0738-parallel-edited", groundBeforeRemoving: false),

        // The same three edits with the first two swapped: ground the bottom of coil 2 while the old jumper is still on it, THEN
        // pull the jumper. Reading the connection scheme off the screen afterwards gives the same answer as the other two runs.
        "S0738-parallel-edited-2" : S0738ParallelEdited(name: "S0738-parallel-edited-2", groundBeforeRemoving: true),

        // The T0223 fixture, wired to drive its SHEET winding directly: every lead in the model grounded except coil 1's
        // outermost, which takes 45 kV. See T0223Sheet.
        "T0223-sheet" : T0223Sheet(name: "T0223-sheet"),

        // The same fixture wired as the impulse test of its HV instead: 125 kV on coil 2's line end, its neutral grounded and
        // carrying the tap winding's outer ends, and coil 3's two halves paralleled. See T0223TapParallel.
        "T0223-tap-parallel" : T0223TapParallel(name: "T0223-tap-parallel", neutralTie: .outerEnds),

        // The same again with the tie to the HV neutral moved from the tap winding's outer ends to its CENTRE. Same winding, same
        // paralleling, same impulse - the only difference is which part of coil 3 is held at earth and which part is free.
        "T0223-tap-parallel-centre" : T0223TapParallel(name: "T0223-tap-parallel-centre", neutralTie: .centre),

        // T0223-tap-parallel again, with coil 3's nine paralleling jumpers made by DECLARING it a regulating winding rather than
        // by listing them. Must print the same Connectivity line as T0223-tap-parallel. See RegulatingWinding.swift.
        "T0223-tap-declared" : T0223TapParallel(name: "T0223-tap-declared", neutralTie: .outerEnds, declared: true)
    ]

    /// The T0223 fixture: four coils, of which coil 1 is a 17-turn SHEET winding with two 0.25" cooling ducts in it and 0.010"
    /// of insulation in every gap.
    ///
    /// It is here to read the radial voltage profile of a REAL ducted sheet winding rather than the SheetAndLayer fixture's
    /// synthetic one: two ducts over sixteen gaps, a duct 25 times the geometric thickness of the paper beside it, and the
    /// whole thing driven directly so that the profile is not a transferred shadow of the HV's.
    ///
    /// EVERY OTHER LEAD IN THE MODEL IS GROUNDED, which includes coil 3's two centre leads - it is double-stacked with no
    /// embedded taps, so `AppController`'s segment-building loop cuts a centre gap into it and gives each side its own
    /// floating centre lead. Grounding both is what "ground all the leads" means on this design; each is terminated in its
    /// own right rather than being carried there by a jumper, because there is no jumper.
    private static func T0223Sheet(name:String) -> Scenario {

        return Scenario(name: name,
                        restructure: .none,
                        matchedBuild: nil,
                        fixtureName: "T0223_AndIn.txt",
                        notes: "Four coils: coil 0 (147 turns, 44 discs), coil 1 a 17-turn SHEET winding with 2 x 0.25\" ducts and 0.010\" between turns, coil 2 (336 turns, 44 discs), coil 3 a double-stacked 71-turn winding (32 discs). Every lead grounded except coil 1's outermost, which carries 45 kV full wave.",
                        jumpers: [],
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 3, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 3, end: .top), type: .ground),
                                       Termination(point: .gapLead(coil: 3, gap: 0, side: .bottom), type: .ground),
                                       Termination(point: .gapLead(coil: 3, gap: 0, side: .top), type: .ground),
                                       // The sheet winding last: its innermost lead to ground, its outermost to the impulse.
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: 45.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 1,
                        reportNodes: true)
    }

    /// The T0223 fixture wired as a full-wave impulse test of its HV, with the tap winding's two halves PARALLELED and its
    /// outer ends carried to the HV neutral.
    ///
    /// This is the connection `T0223-sheet` is not. There the sheet winding was driven directly, so that its own radial profile
    /// could be read rather than a transferred shadow of the HV's, and every other lead in the model went straight to ground.
    /// Here the model is wired the way the unit is actually tested, so the number that comes out is the HV's disc-to-disc stress
    /// at the line end - which is the one quantity DelVecchio 13.5.1 gives in closed form (13.65).
    ///
    /// COIL 3 IS A TAP WINDING WITH ITS HALVES IN PARALLEL. It is double-stacked with no embedded taps, so `AppController`'s
    /// segment-building loop cuts a centre gap between discs 16 and 17 and gives each side its own floating centre lead. The
    /// paralleling ties each point of the lower half to its mirror image in the upper half - the same number of turns from the
    /// centre - in 2-disc steps, NINE connections from the outside in:
    ///
    ///   * the two outer ends (the lead below disc 1 and the lead above disc 32), tied to each other;
    ///   * the crossovers above the even discs 2, 4, 6, 8, 10, 12 and 14, each tied to its mirror above disc 32-d;
    ///   * the two leads facing each other across the centre gap, which is the innermost pair.
    ///
    /// ONE POINT OF THE PARALLELED WINDING THEN GOES TO COIL 2'S NEUTRAL, and the ground goes on the NEUTRAL. Coil 3 reaches
    /// earth through a jumper rather than through a termination of its own, which is exactly the case the standing rule about
    /// terminations is written for: nothing writes a `.ground` onto coil 3's leads, and `PhaseModel.ResolveNodeConnectivity` is
    /// what decides they are at earth. The TERMINATIONS and NODE TOPOLOGY sections of the report are where that has to show up -
    /// coil 3's tied leads must come back GROUND without a termination of their own ever having been applied to them.
    ///
    /// `neutralTie` says WHICH point that is, and it is the only difference between the two scenarios built from this function.
    /// The nine connections have already made the two halves one winding, so either the outer ends or the centre will serve as the
    /// earthed terminal; what changes is which part of coil 3 is pinned at earth, screening coil 2, and which part is free to ride
    /// up with it. See TapNeutralTie.
    ///
    /// Coil 2's far end IS directly at earth, and that is what makes this scenario comparable to 13.5.1 at all. The continuum
    /// model solves a boundary-value problem whose far boundary is V = 0; `ContinuumComparison` declines the comparison out loud
    /// when that boundary is not there, as it is not on S0738, where the HV's return runs through both halves of the tap winding
    /// to a centre ground and the far end floats at 0.65 p.u. instead.
    ///
    /// `declared` wires the same thing a second way: coil 3 is DECLARED a double-stacked regulating winding of 8 loops and the nine
    /// connections come from `RegulatingWinding.Apply`, leaving only the tie to the HV neutral as a hand jumper. The declaration was
    /// written to produce exactly the wiring this scenario spells out, so the two runs must print an identical `Connectivity:` line.
    private static func T0223TapParallel(name:String, neutralTie:TapNeutralTie, declared:Bool = false) -> Scenario {

        // Coil 3 is 32 discs with its tapping gap between discs 16 and 17. Disc d pairs with disc 32-d, its mirror image about
        // the gap; `discCrossover` names a crossover by the disc BELOW it, counting from 1 at the bottom of the coil, so the
        // crossover above disc 2 pairs with the one above disc 30.
        //
        // 1 of 9: the outermost pair.
        var jumpers:[Jumper] = [Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 3, end: .bottom))]

        // 2 through 8 of 9: every second crossover, mirrored about the gap.
        for disc in stride(from: 2, through: 14, by: 2) {

            jumpers.append(Jumper(from: .discCrossover(coil: 3, disc: disc), to: .discCrossover(coil: 3, disc: 32 - disc)))
        }

        // 9 of 9: the innermost pair - the two centre-most discs, tied across the tapping gap. The gap breaks the node chain
        // even though it is bridged, so this is a jumper between two nodes and not a series connection.
        jumpers.append(Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .gapLead(coil: 3, gap: 0, side: .top)))

        // The tie to the HV neutral, last, so that it goes onto a coil 3 that is already paralleled. Either end of the paralleled
        // winding will do as the earthed one - the nine connections have already made the two halves one winding - so this is the
        // one line that separates the two scenarios.
        //
        // Tying at the CENTRE means the two leads facing across the tapping gap are tied to each other AND carried to earth, which
        // leaves neither of them floating. That is the case that used to erase the only evidence the gap was there: `IsTappingGap`
        // recognises a gap by the LOCATION of its connectors and never by what they are terminated to, precisely so that this
        // wiring still reads as a gap. The NODE TOPOLOGY line is the check - 126 nodes, not 125.
        switch neutralTie {

        case .outerEnds:
            jumpers.append(Jumper(from: .coilEnd(coil: 3, end: .bottom), to: .coilEnd(coil: 2, end: .bottom)))

        case .centre:
            jumpers.append(Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .coilEnd(coil: 2, end: .bottom)))
        }

        // The declared variant keeps only the last jumper - the neutral tie - and lets the declaration make the other nine.
        let regulatingWindings = declared ? [RegulatingWinding(coil: 3, numLoops: 8)] : []

        if declared {

            jumpers = [jumpers.last!]
        }

        return Scenario(name: name,
                        restructure: .none,
                        matchedBuild: nil,
                        fixtureName: "T0223_AndIn.txt",
                        notes: "Four coils: coil 0 (147 turns, 44 discs), coil 1 a 17-turn sheet winding, coil 2 the impulsed HV (336 turns, 44 discs), coil 3 a double-stacked 71-turn tap winding (32 discs) with its two halves paralleled in 2-disc steps and its \(neutralTie == .outerEnds ? "outer ends" : "centre") tied to the HV neutral. Coils 0 and 1 grounded at both ends; 125 kV full wave on coil 2's top, coil 2's bottom grounded.",
                        jumpers: jumpers,
                        regulatingWindings: regulatingWindings,
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .ground),
                                       // The HV neutral, which carries coil 3's outer ends to earth with it.
                                       Termination(point: .coilEnd(coil: 2, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: 125.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 2,
                        reportNodes: true)
    }


    /// The S0738 tap winding re-wired from series to parallel by EDITING the model, the way it is done at the keyboard.
    ///
    /// The finished connection scheme is identical to `S0738Parallel`'s, node for node. The difference is entirely in how it is
    /// reached: the model starts as `S0738` - coil 3's two ends tied to each other and to the bottom of coil 2, coil 3's centre
    /// grounded, no ground of coil 2's own - and is then edited into the parallel scheme, which is three operations:
    ///
    ///   1. remove the jumper from coil 3's ends to the bottom of coil 2;
    ///   2. ground the bottom of coil 2, which now has nowhere else to go;
    ///   3. add the crossover jumpers that put the two halves of coil 3 in parallel.
    ///
    /// Comparing the two runs isolates the editing history from the wiring: any difference between them is a connection the model
    /// is carrying that no longer corresponds to anything the user can see.
    /// - parameter groundBeforeRemoving: Do step 2 before step 1 - ground the bottom of coil 2 while coil 3 is still hanging off
    ///   it, then pull the jumper. Both orders leave the same picture on the screen, so both have to leave the same model.
    private static func S0738ParallelEdited(name:String, groundBeforeRemoving:Bool) -> Scenario {

        let pullTheJumper = Edit.remove(Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 2, end: .bottom)))
        let groundTheNeutral = Edit.terminate(Termination(point: .coilEnd(coil: 2, end: .bottom), type: .ground))

        var edits:[Edit] = groundBeforeRemoving ? [groundTheNeutral, pullTheJumper] : [pullTheJumper, groundTheNeutral]

        for disc in stride(from: 2, through: 14, by: 2) {

            edits.append(.jumper(Jumper(from: .discCrossover(coil: 3, disc: disc), to: .discCrossover(coil: 3, disc: 32 - disc))))
        }

        return Scenario(name: name,
                        restructure: .none,
                        matchedBuild: nil,
                        fixtureName: "S0738_AndIn.txt",
                        notes: "The S0738 wiring EDITED into the parallel tap connection: the jumper from coil 3's ends to the bottom of coil 2 removed, the bottom of coil 2 grounded in its own right, and the crossovers of every second disc of coil 3 tied across the gap in mirror pairs. The finished scheme is identical to S0738-parallel's; only the route to it differs.",
                        jumpers: [Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 3, end: .bottom)),
                                  Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 2, end: .bottom)),
                                  Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .gapLead(coil: 3, gap: 0, side: .top))],
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .ground),
                                       Termination(point: .gapLead(coil: 3, gap: 0, side: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .top), type: .impulse)],
                        edits: edits,
                        waveFormType: .FullWave,
                        peakVoltage: 1050.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 2,
                        reportNodes: true)
    }

    /// The S0738 fixture wired with its tap winding's two halves PARALLELED - the usual connection when no taps are in circuit.
    ///
    /// The difference from `S0738` is entirely in coil 3, and it is the difference between a winding that carries the HV's return
    /// current and one that does not:
    ///
    ///   * the HV's own neutral (coil 2, bottom) goes straight to ground, so coil 2 has a grounded end of its own;
    ///   * coil 3's two centre leads are still tied together and grounded, but its two OUTER ends are tied only to each other -
    ///     they are not tied to anything that is at a fixed potential;
    ///   * the crossovers of every second disc are tied across the middle of the coil in pairs (2-3 to 30-31, 4-5 to 28-29, and
    ///     so on down to 14-15 to 18-19), which is what puts the two halves in parallel turn for turn.
    ///
    /// That last group is the thing no other scenario here has: a jumper at an INTERIOR node of a winding, rather than at a lead.
    /// The pairing is symmetric about the centre gap - disc d pairs with disc 32-d - so every pair joins two points that are the
    /// same number of turns from the grounded centre.
    ///
    /// The outer ends are then a genuinely floating pair: nothing ties them to ground, to the impulse or to another coil, and
    /// their potential is whatever the winding and the capacitive coupling to coil 2 put there. That is the case this scenario
    /// exists to pin down.
    private static func S0738Parallel(name:String, restructure:Restructure) -> Scenario {

        // Coil 3 is 32 discs with its tapping gap between discs 16 and 17. Pair the crossover above disc d with the crossover
        // above disc 32-d, which is its mirror image about the gap, for the even d from 2 up to 14.
        var jumpers:[Jumper] = [// The tap winding's two outer ends, tied to each other and to nothing else.
                                Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 3, end: .bottom)),
                                // The two leads facing each other across coil 3's centre gap.
                                Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .gapLead(coil: 3, gap: 0, side: .top))]

        for disc in stride(from: 2, through: 14, by: 2) {

            jumpers.append(Jumper(from: .discCrossover(coil: 3, disc: disc), to: .discCrossover(coil: 3, disc: 32 - disc)))
        }

        return Scenario(name: name,
                        restructure: restructure,
                        matchedBuild: nil,
                        fixtureName: "S0738_AndIn.txt",
                        notes: "Four coils. Coils 0 and 1 grounded at both ends; coil 2 is the impulsed HV (1050 kV full wave on its top, neutral grounded); coil 3 is a double-stacked tap winding wired with its two halves in PARALLEL - centre leads tied together and grounded, outer ends tied to each other and to nothing else, and the crossovers of every second disc tied across the gap in mirror pairs. "
                             + (restructure.isInterleave ? "Coil 2 interleaved in its entirety." : "Coil 2 as designed."),
                        jumpers: jumpers,
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .ground),
                                       Termination(point: .gapLead(coil: 3, gap: 0, side: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 2, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: 1050.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 2,
                        reportNodes: true)
    }

    /// The S0738 fixture: a four-coil design whose HV is fed through a centre-grounded tap winding.
    ///
    /// This is the first fixture here that is about the CONNECTIONS rather than about the winding, and it is the first with more
    /// than two coils. Three things in it are not exercised by either STME-0999 fixture, and all three are places where the node
    /// topology has to be got right rather than merely computed:
    ///
    ///   1. A COIL WITH AN INTERNAL TAPPING GAP. Coil 3 is double-stacked, so AppController's segment-building loop cuts a centre
    ///      gap into it and gives each side of the gap its own `outside_center`/`inside_center` floating lead. A gap is a break in
    ///      the node chain even when it is bridged - see the long note in `PhaseModel.SetNodes`.
    ///   2. BOTH CENTRE LEADS TIED TOGETHER AND GROUNDED. That is a jumper across the gap AND a termination on it, which is the
    ///      combination that removes every trace of the gap from the connections: `AddConnector` replaces a floating lead with a
    ///      ground, so after this neither side of the gap still carries a floating centre lead.
    ///   3. A COIL FED FROM ANOTHER COIL. Coil 3's two ends are tied to each other and then to the bottom of coil 2, so the HV's
    ///      return path runs out of coil 2, through both halves of coil 3 in parallel, and to ground at coil 3's centre. Nothing
    ///      in the two-coil fixtures makes a coil end anything other than a ground, an impulse or a floating lead.
    ///
    /// The HV is then interleaved in its entirety, which is what the plain variant exists to isolate.
    /// - Parameter groundSheetTop: false leaves coil 0's TOP lead floating, so the sheet winding takes its voltage by transfer
    /// instead of being shorted end to end. Grounded at both ends - the ordinary connection, and what every other variant uses -
    /// coil 0 has identically zero volts across it at every instant, which is correct but makes the radial voltage profile a flat
    /// line at zero and tests nothing about it. See the S0738-sheet-floating scenario.
    private static func S0738(name:String, restructure:Restructure, groundSheetTop:Bool = true) -> Scenario {

        var terminations = [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                            Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                            Termination(point: .coilEnd(coil: 1, end: .top), type: .ground),
                            // Only ONE of the two jumpered centre leads is grounded, because that is all the user does. The other
                            // is at ground potential through the jumper, which PhaseModel.ResolveNodeConnectivity works out; the
                            // ground is not copied onto it.
                            Termination(point: .gapLead(coil: 3, gap: 0, side: .bottom), type: .ground),
                            Termination(point: .coilEnd(coil: 2, end: .top), type: .impulse)]

        if groundSheetTop {

            terminations.insert(Termination(point: .coilEnd(coil: 0, end: .top), type: .ground), at: 1)
        }

        return Scenario(name: name,
                        restructure: restructure,
                        matchedBuild: nil,
                        fixtureName: "S0738_AndIn.txt",
                        notes: "Four coils. Coil 0 (a SHEET winding) grounded at " + (groundSheetTop ? "both ends" : "the bottom only, its top left floating") + " and coil 1 grounded at both ends; coil 2 is the impulsed HV (1050 kV full wave on its top); coil 3 is a double-stacked tap winding whose two ends are tied together and to the bottom of coil 2, and whose two centre leads are tied together and grounded. "
                             + (restructure.isInterleave ? "Coil 2 interleaved in its entirety." : "Coil 2 as designed."),
                        jumpers: [// The tap winding's two ends, tied to each other and then to the bottom of the HV. The second
                                  // jumper names coil 3's TOP again on purpose: the UI's cross-product (TransformerView.CompleteAddConnection)
                                  // then carries coil 3's bottom along with it, exactly as dragging from an already-jumpered lead
                                  // does, and this routine has to behave the same way or the test is not testing the UI's model.
                                  Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 3, end: .bottom)),
                                  Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 2, end: .bottom)),
                                  // The two leads facing each other across coil 3's centre gap.
                                  Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .gapLead(coil: 3, gap: 0, side: .top))],
                        terminations: terminations,
                        waveFormType: .FullWave,
                        peakVoltage: 1050.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 2)
    }

    /// The SheetAndLayer fixture: one SHEET coil inside one LAYER coil, and nothing else.
    ///
    /// This is the fixture the radial voltage profile needed. Every other design here is disc-wound apart from S0738's coil 0, and
    /// that one is grounded at both ends in every variant - correct, but it leaves the coil with no volts across it, so the profile
    /// is a flat line at zero. Nothing exercised the LAYER path on a real design at all; see TODO.md §8a.
    ///
    /// WHICH LEAD IS WHICH. A sheet or layer coil is one BasicSection, so it is one Segment, and `AppController`'s
    /// segment-building loop gives it exactly two floating leads: `.inside_lower` on the way in and - through
    /// `Connector.AlternatingLocation` - `.outside_upper` on the way out. So on these two coils `.coilEnd(end: .bottom)` IS the
    /// innermost lead and `.coilEnd(end: .top)` IS the outermost one, which is what makes the connection below expressible. The
    /// TERMINATIONS section of the report prints the location each one landed on, so if that ever stops being true the run says so
    /// rather than silently testing the winding backwards.
    ///
    /// Each variant impulses one coil and grounds both leads of the other, which is what makes the profile under test worth
    /// reading: the impulsed coil is driven directly rather than by transfer, and the coil beside it is held at a known potential -
    /// so the layer solve's Cin/Cout terms have something definite on the other end of them.
    ///
    /// - Parameter impulsedCoil: 0 for the sheet, 1 for the layer. The other coil is grounded at both ends.
    private static func SheetAndLayer(name:String, impulsedCoil:Int, peakVoltage:Double) -> Scenario {

        let quietCoil = impulsedCoil == 0 ? 1 : 0

        return Scenario(name: name,
                        restructure: .none,
                        matchedBuild: nil,
                        fixtureName: "SheetAndLayer.txt",
                        notes: "Two coils: coil 0 is a SHEET winding, coil 1 is a LAYER winding. Coil \(impulsedCoil) is impulsed - its innermost lead grounded and \(String(format: "%.0f", peakVoltage / 1000.0)) kV full wave on its outermost - and both leads of coil \(quietCoil) are grounded.",
                        jumpers: [],
                        terminations: [Termination(point: .coilEnd(coil: quietCoil, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: quietCoil, end: .top), type: .ground),
                                       // The innermost lead of the impulsed coil, then the outermost. Order matters only in that
                                       // AddConnector REPLACES a floating lead, so each has to still be floating when it is used.
                                       Termination(point: .coilEnd(coil: impulsedCoil, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: impulsedCoil, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: peakVoltage,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: impulsedCoil,
                        reportNodes: true)
    }

    /// The STME-0999_2 fixture: 25 MVA, 120 kV wye to 26.4 kV delta, both coils disc-wound in CTC. 550 kV BIL on the HV.
    ///
    /// This is the regime wound-in shields exist for. CTC is a large stranded conductor, so a disc holds few turns - 688 turns
    /// over 64 discs, 10.75 each - and interleaving a CTC winding is essentially impossible to manufacture. The interleaved
    /// scenario is therefore a REFERENCE rather than a proposal: it says what the shield is being measured against.
    private static func STME0999_2(name:String, notes:String, restructure:Restructure, matchedBuild:MatchedBuild?) -> Scenario {

        return Scenario(name: name,
                        restructure: restructure,
                        matchedBuild: matchedBuild,
                        fixtureName: "STME-0999_2_AndIn.txt",
                        notes: "25 MVA. Coil 0 = 26.4 kV delta LV (262 turns, 90 discs), coil 1 = 120 kV wye HV (688 turns, 64 discs). Both coils CTC disc windings. 550 kV full wave on the HV line end. " + notes,
                        jumpers: [],
                        terminations: [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                       Termination(point: .coilEnd(coil: 1, end: .top), type: .impulse)],
                        waveFormType: .FullWave,
                        peakVoltage: 550.0e3,
                        displaySpan: 100.0e-6,
                        bandwidth: 10.0e6,
                        continuumCoil: 1)
    }

    // MARK: Entry point

    /// Run a scenario if one was named on the command line.
    ///
    /// Called from AppDelegate.applicationDidFinishLaunching. Returns true if a self test was started, in which case
    /// the app will terminate itself when the run finishes - the caller should not do anything else.
    @discardableResult
    static func RunIfRequested(controller:AppController) -> Bool {

        guard let scenarioName = UserDefaults.standard.string(forKey: scenarioKey), !scenarioName.isEmpty else {

            return false
        }

        if scenarioName == strandedConnectionName {

            Task {

                let report = await CheckStrandedConnection(controller: controller)
                Record(report: report.text, summary: report.summary, fileName: "SelfTestReport-\(strandedConnectionName).txt")
                Stage("finished")
                NSApp.terminate(nil)
            }

            return true
        }

        guard let scenario = scenarios[scenarioName] else {

            Record(report: "No scenario named '\(scenarioName)'. Known scenarios: \((scenarios.keys + [strandedConnectionName]).sorted().joined(separator: ", "))",
                   summary: "FAILED - unknown scenario '\(scenarioName)'",
                   fileName: "SelfTestReport-\(scenarioName).txt")
            NSApp.terminate(nil)
            return true
        }

        Task {

            let report = await Run(scenario: scenario, controller: controller)

            Record(report: report.text,
                   summary: report.summary,
                   fileName: "SelfTestReport-\(scenario.name).txt")

            Stage("finished")
            NSApp.terminate(nil)
        }

        return true
    }

    // MARK: The run

    private struct Report {

        var text:String
        var summary:String
    }

    private static func Run(scenario:Scenario, controller:AppController) async -> Report {

        var text = "ImpulseDistribution self test\n"
        text += "Scenario:  \(scenario.name)\n"
        text += "Run at:    \(Date())\n"
        text += "Design:    \(scenario.notes)\n"
        text += String(repeating: "=", count: 110) + "\n\n"

        Stage("locating the fixture")

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {

            return Report(text: text + "FAILED: the container has no Documents folder.\n", summary: "FAILED - no Documents folder")
        }

        let fixture = documents.appendingPathComponent(scenario.fixtureName)

        guard FileManager.default.fileExists(atPath: fixture.path) else {

            text += "FAILED: the design file was not found.\n"
            text += "Expected it at: \(fixture.path)\n"
            text += "Copy the design file there - the sandbox makes anywhere else unreadable without the open panel.\n"
            return Report(text: text, summary: "FAILED - fixture not found")
        }

        Stage("reading the design file")

        let xlFile:PCH_ExcelDesignFile

        do {

            xlFile = try PCH_ExcelDesignFile(designFile: fixture)
        }
        catch {

            return Report(text: text + "FAILED reading the design file: \(error)\n", summary: "FAILED - could not read the design file")
        }

        // Everything from here is the same path the UI takes, in the same order: build the model (which computes the
        // radial build-up, the FE phase, the eddy losses, the inductance matrix and the capacitance matrix), then add
        // the terminations, then create the simulation model.
        Stage("building the model (inductance + capacitance - this is the slow part)")

        await controller.updateModel(oldSegments: [], newSegments: [], xlFile: xlFile, reinitialize: true)

        guard let model = controller.currentModel else {

            return Report(text: text + "FAILED: no model was built.\n", summary: "FAILED - no model")
        }

        // The structural change goes in BEFORE the geometry is reported and before the terminations, because it swaps
        // Segments and so rebuilds both the connectors and every matrix in the model.
        Stage("restructuring the winding")

        text += "RESTRUCTURE\n"
        text += String(repeating: "-", count: 110) + "\n"

        // The build floor has to be in place before anything recomputes the geometry, so it goes on first. It only
        // reaches the model when something calls ApplyRadialBuildUp, which every path below ends in.
        var matchedOutcome:String? = nil

        if let matched = scenario.matchedBuild {

            matchedOutcome = await ApplyMatchedBuild(matched, model: model)
            text += "  \(matchedOutcome!)\n"

            guard !matchedOutcome!.hasPrefix("FAILED") else {

                return Report(text: text, summary: "FAILED - " + matchedOutcome!)
            }
        }

        let restructureOutcome = await ApplyRestructure(scenario.restructure, model: model, controller: controller)

        text += "  \(restructureOutcome)\n"

        guard !restructureOutcome.hasPrefix("FAILED") else {

            return Report(text: text, summary: "FAILED - " + restructureOutcome)
        }

        // Interleaving and shielding swap Segments, and updateModel ends in recalculateModel, so the floor has already
        // reached the geometry by now. A scenario that only sets a floor has changed nothing the model has noticed yet,
        // so it needs the recalculation asked for explicitly - the same reason recalculateModel exists separately from
        // updateModel, which cannot be called with empty Segment arrays.
        if matchedOutcome != nil, case .none = scenario.restructure {

            Stage("recomputing the geometry for the matched build")
            await controller.recalculateModel(reinitialize: false)
            text += "  (recalculated: nothing was restructured, so the build floor needed its own pass)\n"
        }

        text += "\n"

        // The static rings go on after the restructure, the way the user fits them, and then the whole recalculation is asked for
        // again. That second pass is the thing being tested: it is where CreateFePhase's section array (one entry per
        // CoilSegments() entry) meets code that used to size itself from PhaseModel.segments (the full store, rings included).
        if !scenario.staticRings.isEmpty {

            Stage("fitting the static rings")

            text += "STATIC RINGS\n"
            text += String(repeating: "-", count: 110) + "\n"

            for nextRing in scenario.staticRings {

                let outcome = await ApplyStaticRing(nextRing, model: model)
                text += "  \(outcome)\n"

                guard !outcome.hasPrefix("FAILED") else {

                    return Report(text: text, summary: "FAILED - " + outcome)
                }
            }

            // Ask for the capacitance here, in a do/catch of our own, BEFORE handing the model to recalculateModel. That routine
            // puts an NSAlert up when this throws - .OnlyOneStaticRingAllowed is the reachable one - and a modal alert with nobody
            // at the keyboard hangs the run forever. Same reasoning as the node-topology rebuild further down.
            do {

                try await model.CalculateCapacitanceMatrix()
            }
            catch {

                text += "  FAILED recomputing the capacitance with the rings on: \(error)\n"
                return Report(text: text, summary: "FAILED - capacitance with static rings: \(error)")
            }

            Stage("recalculating with the static rings in place (inductance + capacitance)")

            await controller.recalculateModel(reinitialize: false)

            guard controller.inductanceIsValid, controller.capacitanceIsValid else {

                text += "  FAILED: the recalculation did not complete (inductance valid: \(controller.inductanceIsValid), capacitance valid: \(controller.capacitanceIsValid))\n"
                return Report(text: text, summary: "FAILED - recalculation with static rings did not complete")
            }

            text += "  recalculated: inductance and capacitance both valid with the rings in the model\n"

            let ringCheck = await StaticRingCheck(model: model)
            text += ringCheck.text

            guard ringCheck.ok else {

                return Report(text: text, summary: "FAILED - " + ringCheck.summary)
            }

            text += "\n"
        }

        Stage("reporting the geometry")

        text += await GeometryReport(model: model)
        text += await CapacitanceBreakdown(model: model, coil: scenario.continuumCoil)

        // The jumpers go on after the restructure (which would sweep them away with UpdateConnectors) and before the
        // terminations (which replace the floating lead a jumper needs in order to find its end). See `Jumper`.
        if !scenario.regulatingWindings.isEmpty {

            Stage("applying the regulating-winding declarations")

            text += "REGULATING WINDINGS\n"
            text += String(repeating: "-", count: 110) + "\n"

            for nextWinding in scenario.regulatingWindings {

                guard let arrangement = await controller.RegulatingWindingArrangement(coil: nextWinding.coil) else {

                    return Report(text: text + "FAILED: coil \(nextWinding.coil) is not in the design file\n", summary: "FAILED - regulating winding on a coil the design does not have")
                }

                do {

                    let outcome = try await nextWinding.Apply(to: model, arrangement: arrangement)

                    text += "  Coil \(nextWinding.coil): \(arrangement.description), \(nextWinding.numLoops) loop(s) - \(outcome.made) jumper(s) made\n"
                    text += outcome.log.map({ "    \($0)\n" }).joined()

                    // Applying a declaration a second time must change nothing: every jumper is already there.
                    let again = try await nextWinding.Apply(to: model, arrangement: arrangement)

                    guard again.made == 0, again.alreadyThere == outcome.made + outcome.alreadyThere else {

                        return Report(text: text + "FAILED: applying coil \(nextWinding.coil)'s declaration again made \(again.made) more jumper(s)\n", summary: "FAILED - regulating winding applied twice is not idempotent")
                    }

                    text += "  Applied again: \(again.alreadyThere) already connected, none made - idempotent\n"

                    // What the menu does when the loop count is changed: take the old ties off, put the new ones on. Round-trip
                    // through a different count and back, so the scenario ends on the declared wiring - and since that has to
                    // print the same Connectivity line as the hand-wired scenario, anything a removal left behind shows up there.
                    let total = outcome.made + outcome.alreadyThere
                    let other = RegulatingWinding(coil: nextWinding.coil, numLoops: nextWinding.numLoops == 1 ? 2 : 1)

                    let removed = await nextWinding.Remove(from: model, arrangement: arrangement)
                    let otherOutcome = try await other.Apply(to: model, arrangement: arrangement)
                    let otherRemoved = await other.Remove(from: model, arrangement: arrangement)
                    let restored = try await nextWinding.Apply(to: model, arrangement: arrangement)

                    guard removed == total, otherRemoved == otherOutcome.made, restored.made == total else {

                        return Report(text: text + "FAILED: changing coil \(nextWinding.coil)'s loop count: removed \(removed) of \(total), made \(otherOutcome.made) and removed \(otherRemoved) for \(other.numLoops) loop(s), restored \(restored.made) of \(total)\n", summary: "FAILED - changing a regulating winding's loop count")
                    }

                    text += "  Changed to \(other.numLoops) loop(s) and back: \(removed) removed, \(otherOutcome.made) made and removed, \(restored.made) restored\n"
                }
                catch {

                    let info = (error as? RegulatingWinding.DeclarationError)?.info ?? ""
                    return Report(text: text + "FAILED: coil \(nextWinding.coil): \(error.localizedDescription) \(info)\n", summary: "FAILED - " + error.localizedDescription)
                }
            }

            text += "\n"
        }

        if !scenario.jumpers.isEmpty {

            Stage("applying the jumpers")

            text += "JUMPERS\n"
            text += String(repeating: "-", count: 110) + "\n"

            for nextJumper in scenario.jumpers {

                let outcome = await ApplyJumper(nextJumper, model: model)
                text += "  \(outcome)\n"

                guard !outcome.hasPrefix("FAILED") else {

                    return Report(text: text, summary: "FAILED - " + outcome)
                }
            }

            text += "\n"
        }

        Stage("applying the terminations")

        text += "TERMINATIONS\n"
        text += String(repeating: "-", count: 110) + "\n"

        var terminationsOK = true

        for nextTermination in scenario.terminations {

            let outcome = await ApplyTermination(nextTermination, model: model)
            text += "  \(outcome)\n"

            if outcome.hasPrefix("FAILED") {

                terminationsOK = false
            }
        }

        text += "\n"

        guard terminationsOK else {

            return Report(text: text + "FAILED: a termination could not be applied - see above.\n", summary: "FAILED - could not apply the terminations")
        }

        // The post-wiring edits, in the order the scenario lists them. See `Edit`: this is where a scenario stops describing a
        // finished connection scheme and starts describing a session at the keyboard.
        if !scenario.edits.isEmpty {

            Stage("applying the post-wiring edits")

            text += "EDITS TO THE WIRING\n"
            text += String(repeating: "-", count: 110) + "\n"

            for nextEdit in scenario.edits {

                let outcome = await ApplyEdit(nextEdit, model: model)
                text += "  \(outcome)\n"

                guard !outcome.hasPrefix("FAILED") else {

                    return Report(text: text, summary: "FAILED - " + outcome)
                }
            }

            text += "\n"
        }

        // REBUILD THE NODES WITH THE CONNECTIONS IN PLACE.
        //
        // Nothing above this line has re-run SetNodes since the terminations went on: the node topology the model is carrying was
        // built during the restructure's recalculation, when the coil ends were still floating. That is fine for a scenario whose
        // connections are all coil ends - the nodes do not depend on what a coil end is tied to - but it is NOT fine in general,
        // because a jumper across a tapping gap and a ground on a centre lead both change what SetNodes decides. In the app the
        // same rebuild is provoked by the next edit that touches the model at all.
        //
        // This calls CalculateCapacitanceMatrix rather than AppController.recalculateModel deliberately: recalculateModel puts an
        // NSAlert up when this throws, and a modal alert with nobody at the keyboard hangs the run forever. Here the throw is the
        // result, and PhaseModelError.UnresolvableConnector - the guard at the end of SetNodes - is precisely the failure this
        // scenario is built to provoke, so it has to arrive as text in a report and not as a dialog nobody will see.
        Stage("rebuilding the node topology with the connections in place")

        text += "NODE TOPOLOGY\n"
        text += String(repeating: "-", count: 110) + "\n"

        do {

            try await model.CalculateCapacitanceMatrix()
            text += "  \(await model.nodes.count) nodes; every connector in the model resolves to one (PhaseModel.VerifyNodeTopology).\n\n"
        }
        catch {

            text += "  FAILED: \(error)\n\n"
            return Report(text: text, summary: "FAILED - the node topology does not match the connectors: \(error)")
        }

        Stage("creating the simulation model")

        // Through the controller rather than SimulationModel(model:) directly: this is the same call "Simulate now" makes, so the
        // run exercises the real install path (undo slot, result invalidation) and the controller ends up holding the model that
        // everything downstream of here reads back out of it.
        guard let simModel = await controller.doCreateSimulationModel() else {

            return Report(text: text + "FAILED: the simulation model could not be created.\n", summary: "FAILED - no simulation model")
        }

        Stage("solving the initial distribution")

        guard let snapshot = await simModel.Snapshot() else {

            return Report(text: text + "FAILED: the network snapshot could not be taken.\n", summary: "FAILED - no snapshot")
        }

        guard let alpha = await FrequencyDomainSolver.CapacitiveDistribution(snapshot: snapshot) else {

            return Report(text: text + "FAILED: the capacitive distribution could not be solved.\n", summary: "FAILED - no initial distribution")
        }

        if scenario.reportNodes {

            Stage("reporting the node classification")

            text += await NodeReport(model: model, simModel: simModel, alpha: alpha)
        }

        Stage("comparing against the continuum model")

        let comparison = await ContinuumComparison(model: model, alpha: alpha, coil: scenario.continuumCoil)
        text += comparison.text

        var summary = comparison.summary

        // The transient is opt-in: it is minutes of work, and an edit that breaks the assembly or the capacitance has
        // already shown up in the initial distribution above.
        if UserDefaults.standard.bool(forKey: transientKey) {

            Stage("running the frequency-domain sweep")

            let waveForm = SimulationModel.WaveForm(type: scenario.waveFormType, pkVoltage: scenario.peakVoltage)

            let results = await simModel.SolveFrequencyDomain(waveForm: waveForm,
                                                             displaySpan: scenario.displaySpan,
                                                             maximumFrequency: scenario.bandwidth)

            let transient = await TransientReport(model: model, results: results, scenario: scenario)
            text += transient.text

            summary += "; " + transient.summary

            text += await AxialProfileReport(model: model, results: results, alpha: alpha, scenario: scenario)

            if UserDefaults.standard.bool(forKey: graphsKey) {

                Stage("rendering the graphs")

                text += await RenderGraphs(model: model, results: results, alpha: alpha, scenario: scenario)
            }

            if scenario.reportNodes {

                text += await NodeTransientReport(model: model, results: results)
            }
        }
        else {

            text += "TRANSIENT\n"
            text += String(repeating: "-", count: 110) + "\n"
            text += "  Not run. Add -PCH_SelfTestTransient YES to include the frequency-domain sweep.\n\n"
        }

        return Report(text: text, summary: summary)
    }

    // MARK: A jumper at a node that a fold destroys

    /// The name that runs `CheckStrandedConnection` instead of a design scenario.
    static let strandedConnectionName = "STRANDED"

    private static func DescribeConnections(_ segments:[Segment]) async -> String {

        var text = ""

        for nextSegment in segments {

            text += "  Segment \(nextSegment.serialNumber) (radial \(nextSegment.radialPos), axial \(nextSegment.axialPos), \(nextSegment.basicSections.count) disc(s)):\n"

            for nextConnection in await nextSegment.connections {

                text += "      \(nextConnection.connector.fromLocation) -> \(nextConnection.connector.toLocation)   target: \(nextConnection.segmentID.map({ String($0) }) ?? "-")   equivalents: \(nextConnection.equivalentConnections.count)\n"
            }
        }

        return text
    }

    /// Put a jumper on a node that interleaving is about to swallow, interleave anyway, and check that nothing is left behind.
    ///
    /// This is the only check here that is about the CONNECTIONS rather than about a design, and it exists because the failure it
    /// covers is invisible in every other one: a jumper is stored as one connection per Segment that meets each of the two nodes it
    /// joins (TransformerView.CompleteAddConnection adds the whole cross-product of the (Segment, location) pairs at the two ends), so a jumper
    /// dropped on the node between two discs lives on BOTH of them. Fold those two discs into one Segment and the two halves land
    /// on opposite terminals of it - which drew the user two connector lines where they had made one, and, far worse, made
    /// SimulationModel's node merging tie the new Segment's two terminals together. A shorted-out disc pair changes the answer and
    /// reports nothing.
    ///
    /// Three things are asserted, and all three have to hold together:
    ///
    ///   1. AppController.SelectionStrandedConnection sees the jumper BEFORE the fold - that is the guard the UI puts up;
    ///   2. after the fold, neither the merged Segment nor the far coil still names the other - PhaseModel.UpdateConnectors has to
    ///      drop BOTH halves, since either one alone leaves the far end pointing at a terminal it was never attached to;
    ///   3. no node group ties the merged Segment's two nodes together - the short itself, tested where it would actually appear.
    ///
    /// Run it exactly like a scenario: `-PCH_SelfTest STRANDED`.
    private static func CheckStrandedConnection(controller:AppController) async -> Report {

        var text = "Stranded-connection check: a jumper on a node that interleaving destroys\n"
        text += "Run at: \(Date())\n"
        text += String(repeating: "=", count: 110) + "\n\n"

        Stage("locating the fixture")

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {

            return Report(text: text + "FAILED: no Documents folder.\n", summary: "FAILED - no Documents folder")
        }

        let fixture = documents.appendingPathComponent("STME-0999_AndIn.txt")

        guard let xlFile = try? PCH_ExcelDesignFile(designFile: fixture) else {

            return Report(text: text + "FAILED: could not read \(fixture.path)\n", summary: "FAILED - no fixture")
        }

        Stage("building the model")

        await controller.updateModel(oldSegments: [], newSegments: [], xlFile: xlFile, reinitialize: true)

        guard let model = controller.currentModel else {

            return Report(text: text + "FAILED: no model.\n", summary: "FAILED - no model")
        }

        let hv = await model.CoilSegments().filter({ $0.radialPos == 1 })
        let lv = await model.CoilSegments().filter({ $0.radialPos == 0 })

        guard hv.count > 12, lv.count > 7 else {

            return Report(text: text + "FAILED: not enough segments (hv \(hv.count), lv \(lv.count)).\n", summary: "FAILED - model too small")
        }

        // The interior node between HV discs 10 and 11 - which interleaving, pairing (0,1),(2,3)..., will swallow into
        // the middle of a Segment - jumpered to the interior node between LV segments 5 and 6.
        let hvA = hv[10], hvB = hv[11]
        let lvA = lv[5], lvB = lv[6]

        guard let hvSeries = await hvA.connections.first(where: { $0.segmentID == hvB.serialNumber }),
              let lvSeries = await lvA.connections.first(where: { $0.segmentID == lvB.serialNumber }) else {

            return Report(text: text + "FAILED: could not find the series connections.\n", summary: "FAILED - no series connection")
        }

        let hvLoc = hvSeries.connector.fromLocation
        let lvLoc = lvSeries.connector.fromLocation

        Stage("adding the interconnection")

        // Exactly what TransformerView.CompleteAddConnection does when the user clicks one lead and then another.
        let allSegments = await model.segments

        var startConnections = await hvA.ConnectionDestinations(fromLocation: hvLoc)
        startConnections.removeAll(where: { $0.segmentID == nil })
        startConnections.insert((hvA.serialNumber, hvLoc), at: 0)

        var endConnections = await lvA.ConnectionDestinations(fromLocation: lvLoc)
        endConnections.removeAll(where: { $0.segmentID == nil })
        endConnections.insert((lvA.serialNumber, lvLoc), at: 0)

        text += "The user's single jumper: HV \(hvA.serialNumber)/\(hvLoc) <-> LV \(lvA.serialNumber)/\(lvLoc)\n"
        text += "  start ends at that node: \(startConnections.map({ "\($0.segmentID ?? -1)/\($0.location)" }).joined(separator: ", "))\n"
        text += "  end ends at that node:   \(endConnections.map({ "\($0.segmentID ?? -1)/\($0.location)" }).joined(separator: ", "))\n\n"

        var equivalentConnections:Set<Segment.Connection.EquivalentConnection> = []

        for nextStartConnection in startConnections {

            for nextEndConnection in endConnections {

                guard let nextStartSegment = allSegments.first(where: { $0.serialNumber == nextStartConnection.segmentID }) else { continue }

                let newConnections = await nextStartSegment.AddConnector(segments: allSegments, fromLocation: nextStartConnection.location, toLocation: nextEndConnection.location, toSegmentID: nextEndConnection.segmentID)

                guard let newSrcConnection = newConnections.from, let newDestConnection = newConnections.to else { continue }

                equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextStartConnection.segmentID!, connection: newSrcConnection))
                equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextEndConnection.segmentID!, connection: newDestConnection))
            }
        }

        for nextConnection in equivalentConnections {

            guard let nextConnParent = allSegments.first(where: { $0.serialNumber == nextConnection.parent }) else { continue }

            await nextConnParent.AddEquivalentConnections(to: nextConnection.connection, equ: equivalentConnections)
        }

        text += "BEFORE INTERLEAVING\n" + String(repeating: "-", count: 110) + "\n"
        text += await DescribeConnections([hvA, hvB, lvA, lvB])
        text += "\n"

        Stage("interleaving")

        // 1. The guard the UI puts up. ApplyRestructure deliberately does not call it (see its note), so the fold below happens
        //    whatever this says - which is the point: the model has to be safe even when nothing stopped the operation.
        let guardSays = await controller.SelectionStrandedConnection(model: model, segments: hv)
        let guardSawIt = guardSays != nil

        text += "The UI guard on this selection says: \(guardSays ?? "nothing in the way")\n\n"

        let restructure = await ApplyRestructure(.interleave(coil: 1), model: model, controller: controller)
        text += "AFTER INTERLEAVING (\(restructure))\n" + String(repeating: "-", count: 110) + "\n"

        let newHV = await model.CoilSegments().filter({ $0.radialPos == 1 })

        guard let merged = newHV.first(where: { $0.basicSections.contains(where: { $0.location.axial == hvA.axialPos }) }) else {

            return Report(text: text + "FAILED: could not find the merged Segment.\n", summary: "FAILED - no merged segment")
        }

        text += await DescribeConnections([merged, lvA, lvB])
        text += "\n"

        // 2. Both halves of the jumper have to be gone. Either one left behind re-attaches it to a terminal it was never on.
        let mergedStillNames = await merged.connections.contains(where: { $0.segmentID == lvA.serialNumber || $0.segmentID == lvB.serialNumber })
        let lvAStillNames = await lvA.connections.contains(where: { $0.segmentID == merged.serialNumber })
        let lvBStillNames = await lvB.connections.contains(where: { $0.segmentID == merged.serialNumber })
        let lvStillNames = lvAStillNames || lvBStillNames

        Stage("applying the terminations")

        for nextTermination in [Termination(point: .coilEnd(coil: 0, end: .bottom), type: .ground),
                                Termination(point: .coilEnd(coil: 0, end: .top), type: .ground),
                                Termination(point: .coilEnd(coil: 1, end: .bottom), type: .ground),
                                Termination(point: .coilEnd(coil: 1, end: .top), type: .impulse)] {

            text += "  " + (await ApplyTermination(nextTermination, model: model)) + "\n"
        }

        text += "\n"

        Stage("building the simulation model")

        guard let simModel = await SimulationModel(model: model) else {

            return Report(text: text + "FAILED: no simulation model.\n", summary: "FAILED - no simulation model")
        }

        let upperNode = await model.NodeAt(segment: merged, useFrom: true, connector: Connector(fromLocation: .outside_upper, toLocation: .floating))
        let lowerNode = await model.NodeAt(segment: merged, useFrom: true, connector: Connector(fromLocation: .outside_lower, toLocation: .floating))

        text += "Merged segment \(merged.serialNumber): upper node \(upperNode.map({ String($0.number) }) ?? "-"), lower node \(lowerNode.map({ String($0.number) }) ?? "-")\n\n"

        let groups = await simModel.finalConnectedNodes

        text += "MERGED NODE GROUPS\n" + String(repeating: "-", count: 110) + "\n"

        // 3. The short itself, tested where it would actually show up.
        var shorted = false

        if groups.isEmpty {

            text += "  (none - nothing in this model ties two nodes together)\n"
        }

        for (nextKey, nextSet) in groups {

            let all = [nextKey] + Array(nextSet)
            text += "  \(all.map({ String($0.number) }).sorted().joined(separator: " = "))\n"

            if let upper = upperNode, let lower = lowerNode, all.contains(upper), all.contains(lower) {

                shorted = true
            }
        }

        var failures:[String] = []

        if !guardSawIt {

            failures.append("the UI guard did not see the jumper")
        }

        if mergedStillNames {

            failures.append("the merged Segment still names the far coil")
        }

        if lvStillNames {

            failures.append("the far coil still names the merged Segment")
        }

        if shorted {

            failures.append("the merged Segment's two nodes were tied together")
        }

        let summary = failures.isEmpty ? "PASSED - the jumper was refused by the guard and left nothing behind when folded anyway"
                                       : "FAILED - " + failures.joined(separator: "; ")

        text += "\nVERDICT\n" + String(repeating: "-", count: 110) + "\n  \(summary)\n"

        return Report(text: text, summary: summary)
    }

    // MARK: Restructuring

    /// The result of sizing a wound-in shield for a coil.
    private enum ShieldSizing {

        case ok(wire:Segment.WoundInShieldWire, discTurns:Double, sections:[BasicSection], segments:[Segment])
        case failed(String)
    }

    /// Size the shield wire for `turnsPerDisc` turns in every disc of a coil, and gather what fitting it would need.
    ///
    /// Both the scenario that actually FITS the shield and the one that merely matches its radial build come through here, for
    /// the same reason `DielectricStress` and `SeriesCapacitance` share `DiscToDiscLayerStack`: if the two sized the wire
    /// separately they could disagree about how wide it is, and a "matched" geometry that is not actually matched would silently
    /// invalidate the comparison it exists to make.
    private static func SizeShield(coil:Int, turnsPerDisc:Int, connection:Segment.WoundInShieldWire.Connection, model:PhaseModel) async -> ShieldSizing {

        let segments = await model.CoilSegments().filter({ $0.radialPos == coil })
        let sections = segments.flatMap({ $0.basicSections })

        guard !sections.isEmpty else {

            return .failed("coil \(coil) has no sections")
        }

        // A shield crosses over at the outermost turn of a PAIR, so the pair is the unit.
        guard sections.count % 2 == 0 else {

            return .failed("coil \(coil) has \(sections.count) discs - a wound-in shield needs an even number")
        }

        guard let discTurns = sections.map({ $0.N }).min(), discTurns > 1.0 else {

            return .failed("coil \(coil) has too few turns per disc to carry a shield")
        }

        // There are only N − 1 spaces between the turns of a disc, which is the ceiling GetWoundInShieldDialog enforces on the
        // same figure.
        let maximumTurns = Int(discTurns.rounded(.down)) - 1

        guard turnsPerDisc >= 1, turnsPerDisc <= maximumTurns else {

            return .failed("\(turnsPerDisc) shield turns per disc, but coil \(coil) allows 1 to \(maximumTurns) (N = \(String(format: "%.2f", discTurns)))")
        }

        // The paper on the shield wire is sized from the working turn-to-shield voltage, so the model has to know its volts per
        // turn - which recalculateModel has already set from the design file.
        let voltsPerTurn = await model.voltsPerTurn

        guard voltsPerTurn > 0.0 else {

            return .failed("the model has no volts/turn, so the shield paper cannot be sized")
        }

        let wire = Segment.WoundInShieldWire.Standard(connection: connection,
                                                      maxTurnsPerDisc: turnsPerDisc,
                                                      discTurns: discTurns,
                                                      voltsPerTurn: voltsPerTurn,
                                                      turnInsulation: sections[0].wdgData.turn.turnInsulation)

        return .ok(wire: wire, discTurns: discTurns, sections: sections, segments: segments)
    }

    /// Hold a coil at the radial build a wound-in shield would need, without fitting the shield. See `MatchedBuild`.
    private static func ApplyMatchedBuild(_ matched:MatchedBuild, model:PhaseModel) async -> String {

        switch await SizeShield(coil: matched.coil, turnsPerDisc: matched.turnsPerDisc, connection: matched.connection, model: model) {

        case .failed(let why):

            return "FAILED: matched build: \(why)"

        case .ok(let wire, _, _, _):

            // The same figure RadialBuildUpByCoil would read off a fitted shield: turns per disc times the over-paper radial
            // dimension of one shield turn.
            let adder = Segment.WoundInShield(wire: wire, turnsPerDisc: matched.turnsPerDisc, pairCount: 1).radialBuildAdder

            await model.SetRadialBuildUpFloor([matched.coil : adder])

            return String(format: "coil %d held at the radial build of a %d-turn shield: +%.3f mm (%d turns x %.3f mm over paper)",
                          matched.coil, matched.turnsPerDisc, adder * 1000.0, matched.turnsPerDisc, wire.overPaperRadial * 1000.0)
        }
    }

    /// Interleave a coil, or put a wound-in shield into every one of its disc pairs.
    ///
    /// This is the model-level half of `AppController.doInterleaveSelection` and `doAddWoundInShields`, without the
    /// `SegmentPath` selection or the dialogs. It deliberately does NOT re-implement the guards those two carry -
    /// already-interleaved, already-shielded, non-contiguous, spans a tapping gap - because it always operates on a
    /// whole coil of a freshly loaded model, where every one of them is answered by construction. If a scenario ever
    /// restructures twice or works on part of a coil, route it through the AppController versions instead.
    ///
    /// Both paths end in `updateModel(oldSegments:newSegments:xlFile:nil, reinitialize:false)`, which does the
    /// connector fixup and then the whole recalculation - radial build-up, FE phase, eddy losses, inductance,
    /// capacitance. That is why a shield is set on each new Segment BEFORE it is handed over: it costs one pass over
    /// the geometry and the matrices rather than two.
    private static func ApplyRestructure(_ restructure:Restructure, model:PhaseModel, controller:AppController) async -> String {

        switch restructure {

        case .none:

            return "none - the winding is as the design file describes it"

        case .interleave(let coil):

            let segments = await model.CoilSegments().filter({ $0.radialPos == coil })
            let sections = segments.flatMap({ $0.basicSections })

            guard !sections.isEmpty else {

                return "FAILED: coil \(coil) has no sections to interleave"
            }

            // A pair is the unit, so an odd disc count has nowhere to put the last one.
            guard sections.count % 2 == 0 else {

                return "FAILED: coil \(coil) has \(sections.count) discs - interleaving needs an even number"
            }

            let core = await model.core
            var interleaved:[Segment] = []

            do {

                for i in stride(from: 0, to: sections.count, by: 2) {

                    interleaved.append(try Segment(basicSections: [sections[i], sections[i + 1]],
                                                   interleaved: true,
                                                   realWindowHeight: core.realWindowHeight,
                                                   useWindowHeight: core.adjustedWindHt))
                }
            }
            catch {

                return "FAILED: could not build the interleaved segments: \(error)"
            }

            await controller.updateModel(oldSegments: segments, newSegments: interleaved, xlFile: nil, reinitialize: false)

            return "interleaved coil \(coil): \(sections.count) discs -> \(interleaved.count) interleaved Segments"

        case .woundInShield(let coil, let turnsPerDisc, let connection):

            let sizing = await SizeShield(coil: coil, turnsPerDisc: turnsPerDisc, connection: connection, model: model)

            guard case .ok(let wire, _, let sections, let segments) = sizing else {

                if case .failed(let why) = sizing {

                    return "FAILED: \(why)"
                }

                return "FAILED: the shield could not be sized"
            }

            let core = await model.core
            var paired:[Segment] = []

            do {

                for i in stride(from: 0, to: sections.count, by: 2) {

                    let newSegment = try Segment(basicSections: [sections[i], sections[i + 1]],
                                                 realWindowHeight: core.realWindowHeight,
                                                 useWindowHeight: core.adjustedWindHt)

                    // Two discs to a Segment is exactly one pair per Segment.
                    await newSegment.SetWoundInShield(Segment.WoundInShield(wire: wire, turnsPerDisc: turnsPerDisc, pairCount: 1))
                    paired.append(newSegment)
                }
            }
            catch {

                return "FAILED: could not build the shielded segments: \(error)"
            }

            await controller.updateModel(oldSegments: segments, newSegments: paired, xlFile: nil, reinitialize: false)

            var outcome = "coil \(coil): \(turnsPerDisc)-turn wound-in shield (\(connection.description)) in each of \(paired.count) disc pairs"
            outcome += String(format: ", wire %.3f mm bare radial + %.3f mm insulation (two-sided)", wire.bareRadial * 1000.0, wire.insulation * 1000.0)

            return outcome
        }
    }

    /// Fit one static ring to one end of a coil, the way `AppController.doAddStaticRingOver`/`doAddStaticRingBelow` do: find the
    /// Segment, ask the model for the ring, insert it.
    ///
    /// The Segment is *found* rather than computed, for the reason `LeadPoint` gives - after a restructure the top of a coil is
    /// not at the axial coordinate the design file would suggest.
    private static func ApplyStaticRing(_ ring:StaticRing, model:PhaseModel) async -> String {

        let coilSegments = await model.CoilSegments().filter({ $0.radialPos == ring.coil })
        let isAbove = ring.end == .top

        guard let adjacent = isAbove ? coilSegments.last : coilSegments.first else {

            return "FAILED: coil \(ring.coil) has no Segments to fit a static ring to"
        }

        do {

            let newRing = try await model.AddStaticRing(adjacentSegment: adjacent, above: isAbove)
            try await model.InsertSegment(newSegment: newRing)

            let z1 = await newRing.z1
            let thickness = await newRing.z2 - z1
            let gap = isAbove ? await z1 - adjacent.z2 : await adjacent.z1 - newRing.z2

            return String(format: "coil %d %@: ring at axial %d, %.3f mm thick, z1 = %.1f mm, %.3f mm gap to Segment %d (axial %d, %d disc(s))",
                          ring.coil, isAbove ? "top" : "bottom", newRing.axialPos, thickness * 1000.0, z1 * 1000.0, gap * 1000.0,
                          adjacent.serialNumber, adjacent.axialPos, adjacent.basicSections.count)
        }
        catch {

            return "FAILED adding the static ring to coil \(ring.coil): \(error)"
        }
    }

    /// What has to be true of a model that carries static rings, checked after the recalculation that used to crash.
    ///
    /// Three things, and they are three because the failure they come from had three separable parts:
    ///
    ///   1. **The inductance matrix is sized by `CoilSegments()`, not by the store.** A static ring is not a circuit element and
    ///      gets no row. This is the invariant the eddy-loss transfer in `recalculateModel` broke by walking `segments` while
    ///      indexing the finite-element sections, and it is the one that turns into "Index out of range".
    ///   2. **Every ring is still found from the winding.** A ring is located by geometry now (`PhaseModel.NearestStaticRing`),
    ///      so a restructure cannot leave one in the model that no Segment can see. Under the old axial-coordinate scheme,
    ///      interleaving a coil orphaned every ring already fitted to it, silently: the ring kept its space and kept being drawn
    ///      while the discs either side of it measured their gaps straight through it.
    ///   3. **Both sides of a ring agree about it.** A ring above Segment k IS the ring below Segment k+1. The two used to be
    ///      recovered by different routes, so an interior ring was visible from one side only.
    private static func StaticRingCheck(model:PhaseModel) async -> (ok:Bool, text:String, summary:String) {

        var text = ""
        var failures:[String] = []

        let allSegments = await model.segments
        let coilSegments = await model.CoilSegments()
        let rings = allSegments.filter({ $0.isStaticRing })

        text += "  Store: \(allSegments.count) Segments, of which \(coilSegments.count) are circuit elements and \(rings.count) are static rings\n"

        if let indMatrix = await model.unfactoredM {

            let rows = await indMatrix.rows
            text += "  Inductance matrix: \(rows) x \(await indMatrix.columns)\n"

            if Int(rows) != coilSegments.count {

                failures.append("the inductance matrix is \(rows) rows against \(coilSegments.count) coil Segments")
            }
        }
        else {

            failures.append("there is no inductance matrix")
        }

        // Uniqueness of the rings' axial coordinates. InsertSegment enforces it, so a duplicate here would mean a ring never made
        // it into the store at all.
        let ringLocations = await Locations(rings)
        if Set(ringLocations.map({ "\($0.radial),\($0.axial)" })).count != rings.count {

            failures.append("two static rings share a location")
        }

        for nextRing in rings {

            var seenFromBelow:Segment? = nil
            var seenFromAbove:Segment? = nil

            for nextSegment in coilSegments where nextSegment.radialPos == nextRing.radialPos {

                if let found = try? await model.StaticRingAbove(segment: nextSegment), found === nextRing {

                    seenFromBelow = nextSegment
                }

                if let found = try? await model.StaticRingBelow(segment: nextSegment), found === nextRing {

                    seenFromAbove = nextSegment
                }
            }

            let below = seenFromBelow.map({ "Segment \($0.serialNumber) (axial \($0.axialPos))" }) ?? "-"
            let above = seenFromAbove.map({ "Segment \($0.serialNumber) (axial \($0.axialPos))" }) ?? "-"

            text += "  Ring at axial \(nextRing.axialPos) of coil \(nextRing.radialPos): reported above \(below), below \(above)\n"

            if seenFromBelow == nil && seenFromAbove == nil {

                failures.append("the static ring at axial \(nextRing.axialPos) of coil \(nextRing.radialPos) is orphaned - no Segment can see it")
            }
        }

        for nextFailure in failures {

            text += "  FAILED: \(nextFailure)\n"
        }

        if failures.isEmpty {

            text += "  OK: the rings are all reachable from the winding and the matrices are sized by the circuit elements alone\n"
        }

        return (failures.isEmpty, text, failures.first ?? "")
    }

    /// The locations of a set of Segments. Only here because `Segment.location` is actor-isolated and the caller wants them all.
    private static func Locations(_ segments:[Segment]) async -> [LocStruct] {

        var result:[LocStruct] = []

        for nextSegment in segments {

            result.append(await nextSegment.location)
        }

        return result
    }

    // MARK: Finding a lead

    private static func Describe(_ point:LeadPoint) -> String {

        return Wiring.Describe(point)
    }

    /// Find the (Segment, location) a `LeadPoint` names. See `Wiring.FindLead`; the harness always wants a coil-end lead to be
    /// still floating, which is what the default gives.
    private static func FindLead(_ point:LeadPoint, model:PhaseModel) async -> Wiring.LeadLookup {

        return await Wiring.FindLead(point, model: model)
    }

    // MARK: Jumpers

    /// Put a jumper between two leads, the way `TransformerView.CompleteAddConnection` does - see `Wiring.ApplyJumper`, which is
    /// where the port of that routine now lives - and describe what happened in the report's words.
    private static func ApplyJumper(_ jumper:Jumper, model:PhaseModel) async -> String {

        let label = "\(Describe(jumper.from)) <-> \(Describe(jumper.to))"

        switch await Wiring.ApplyJumper(jumper, model: model) {

        case .made(let count, let fromSegment, let fromLocation, let toSegment, let toLocation):

            return "\(label): \(count) connector(s) from segment \(fromSegment) (\(fromLocation)) to segment \(toSegment) (\(toLocation))"

        case .failed(let why):

            return "FAILED: \(label): \(why)"
        }
    }

    /// The outcome of looking for the Segment a `LeadPoint` sits on, without asking what is on the lead.
    private enum SegmentLookup {

        case ok(Segment)
        case failed(String)
    }

    /// The Segment a `LeadPoint` names, found the same way `FindLead` finds it but without the requirement that the lead still be
    /// floating. Used by the removal path, which needs the Segment only.
    private static func FindSegment(_ point:LeadPoint, model:PhaseModel) async -> SegmentLookup {

        if case .ok(let segment, _) = await FindLead(point, model: model) {

            return .ok(segment)
        }

        // FindLead refused, which for a coil end means the lead is no longer floating. The Segment is still knowable - it is the
        // outermost one of the coil - so fall back to that. The other two cases are located by the connections they carry rather
        // than by a termination, so FindLead's refusal there is real and is passed through.
        guard case .coilEnd(let coil, let end) = point else {

            if case .failed(let why) = await FindLead(point, model: model) {

                return .failed(why)
            }

            return .failed("could not find \(Describe(point))")
        }

        let coilSegments = await model.CoilSegments().filter({ $0.radialPos == coil })

        guard let segment = end == .bottom ? coilSegments.first : coilSegments.last else {

            return .failed("coil \(coil) has no segments")
        }

        return .ok(segment)
    }

    /// Take a jumper back out, the way `TransformerView.mouseDownWithRemoveConnector` does.
    ///
    /// The UI hands `Segment.RemoveConnection` one of the connections the drawn line stands for, and that routine sweeps the whole
    /// equivalence class - which is what makes clicking any one copy of a cross-product jumper take all of them. Here the copy is
    /// found rather than clicked: whichever connection on the `from` lead's Segment names the `to` lead's Segment.
    private static func ApplyRemoval(_ jumper:Jumper, model:PhaseModel) async -> String {

        let label = "remove \(Describe(jumper.from)) <-> \(Describe(jumper.to))"

        // Both ends are resolved to SEGMENTS only, not to (Segment, location) pairs. Clicking a drawn jumper does not care what
        // else is on either lead, and in particular does not require the lead to still be floating - which `FindLead` does,
        // because for its own purposes a coil-end lead IS the floating termination. A jumper is perfectly removable from a lead
        // that has since been grounded, and that is the case worth being able to describe.
        let fromSegmentLookup = await FindSegment(jumper.from, model: model)
        let toSegmentLookup = await FindSegment(jumper.to, model: model)

        guard case .ok(let fromSegment) = fromSegmentLookup, case .ok(let toSegment) = toSegmentLookup else {

            let why = [fromSegmentLookup, toSegmentLookup].compactMap({ if case .failed(let reason) = $0 { return reason } else { return nil } }).joined(separator: "; ")
            return "FAILED: \(label): \(why)"
        }

        guard let victim = await fromSegment.connections.first(where: { $0.segmentID == toSegment.serialNumber }) else {

            return "FAILED: \(label): segment \(fromSegment.serialNumber) has no connection to segment \(toSegment.serialNumber)"
        }

        let affected = await fromSegment.RemoveConnection(segments: model.segments, connection: victim)

        return "\(label): \(affected.count) segment(s) affected \(affected.sorted())"
    }

    /// Apply one post-wiring edit and describe what it did.
    private static func ApplyEdit(_ edit:Edit, model:PhaseModel) async -> String {

        switch edit {

        case .jumper(let jumper):

            return await ApplyJumper(jumper, model: model)

        case .remove(let jumper):

            return await ApplyRemoval(jumper, model: model)

        case .terminate(let termination):

            return await ApplyTermination(termination, model: model)
        }
    }

    // MARK: Terminations

    /// Tie one lead to ground or to the impulse generator.
    ///
    /// This does what TransformerView.mouseDownWithAddGround / .mouseDownWithAddImpulse do when the user clicks a
    /// lead, minus the hit testing: find the lead and hand its location to AddConnector, which REPLACES a floating
    /// lead rather than appending to it. Taking the location from the lead that is already there is the whole point -
    /// see `LeadPoint`.
    ///
    /// It terminates the named lead and nothing else. What is at the same potential through a jumper is
    /// `PhaseModel.ResolveNodeConnectivity`'s answer, not something recorded in the connector store.
    private static func ApplyTermination(_ termination:Termination, model:PhaseModel) async -> String {

        let label = "\(Describe(termination.point)) -> \(termination.type)"

        let lookup = await FindLead(termination.point, model: model)

        guard case .ok(let segment, let fromLocation) = lookup else {

            if case .failed(let why) = lookup {

                return "FAILED: \(label): \(why)"
            }

            return "FAILED: \(label): the lead could not be found"
        }

        let allSegments = await model.segments

        // ONE lead, the one named - which is what the UI now does too. Everything jumpered to it is at the same potential, but
        // that is a property of the jumpers and is resolved by `PhaseModel.ResolveNodeConnectivity` when the answer is wanted.
        // This routine used to copy the termination onto every jumpered lead as well, mirroring what
        // `TransformerView.mouseDownWithAddGround` did at the time; both copies then outlived any removal of the jumper that
        // justified them, which is the failure `S0738-parallel-edited-2` exists to hold down.
        await segment.AddConnector(segments: allSegments, fromLocation: fromLocation, toLocation: termination.type, toSegmentID: nil)

        return "\(label): applied at \(fromLocation) of segment \(segment.serialNumber)"
    }

    // MARK: Geometry

    /// What the design file actually parsed into.
    ///
    /// This is the check on PchExcelDesignFilePackage and on the model-building path, and it is the one part of the
    /// report a human can verify against the design directly: disc counts, turn counts, radii and the axial gaps
    /// between sections are all things the designer knows independently.
    private static func GeometryReport(model:PhaseModel) async -> String {

        var text = "GEOMETRY AS PARSED\n"
        text += String(repeating: "-", count: 110) + "\n"

        let coilCount = await model.CoilCount()
        let allCoilSegments = await model.CoilSegments()

        text += "  Coils: \(coilCount)   Segments: \(allCoilSegments.count)   Nodes: \(await model.nodes.count)\n"
        let core = await model.core

        text += "  Core: leg radius \(Millimetres(core.radius)), window height \(Millimetres(core.realWindowHeight)), leg centres \(Millimetres(core.legCenters))\n"
        text += "  Tank depth: \(Millimetres(await model.tankDepth))\n\n"

        for coil in 0..<coilCount {

            let segments = allCoilSegments.filter({ $0.radialPos == coil })

            guard let first = segments.first, let last = segments.last else {

                continue
            }

            var turns = 0.0
            var discCount = 0

            for nextSegment in segments {

                turns += await nextSegment.N
                discCount += nextSegment.basicSections.count
            }

            let windingType = first.basicSections[0].wdgData.type

            text += "  Coil \(coil): \(WindingTypeName(windingType))\n"
            text += "    Segments:        \(segments.count)  (\(discCount) BasicSections)\n"
            text += "    Turns:           \(String(format: "%.1f", turns))"
            text += discCount > 0 ? "  (\(String(format: "%.3f", turns / Double(discCount))) per section)\n" : "\n"
            text += "    Inside radius:   \(Millimetres(await first.r1))\n"
            text += "    Outside radius:  \(Millimetres(await first.r2))\n"
            text += "    Radial build:    \(Millimetres(await first.r2 - first.r1))\n"
            text += "    Axial extent:    \(Millimetres(await first.z1)) to \(Millimetres(await last.z2))  (height \(Millimetres(await last.z2 - first.z1)))\n"

            // The axial gaps between consecutive sections - the key spacers on a disc coil, the inter-turn gaps on a
            // helical one. Reported as a range because a uniform coil should show one number and a coil with an axial
            // gap in it should show two, and which of those you have is exactly what you want to know.
            var gaps:[Double] = []

            for i in 1..<max(segments.count, 1) {

                gaps.append(await segments[i].z1 - segments[i - 1].z2)
            }

            if let smallest = gaps.min(), let largest = gaps.max() {

                let mean = gaps.reduce(0.0, +) / Double(gaps.count)

                if largest - smallest < 1.0e-6 {

                    text += "    Axial gaps:      \(Millimetres(mean))  (uniform, \(gaps.count) of them)\n"
                }
                else {

                    text += "    Axial gaps:      \(Millimetres(smallest)) to \(Millimetres(largest)), mean \(Millimetres(mean))  (\(gaps.count) of them)\n"
                }
            }

            // The hilo under this coil: the radial gap to whatever is inside it (the core for coil 0).
            if let hilo = try? await model.HiloUnder(coil: coil) {

                text += "    Hilo under:      \(Millimetres(hilo))\n"
            }

            text += "    Series C (coil): \(Farads(try? await model.CoilSeriesCapacitance(coil: coil)))\n"

            // The per-section series capacitances, which is where a coil stops being uniform. A continuous disc coil's
            // END discs are treated differently (DelVecchio 12.63-64: an end disc has a neighbour on one side only),
            // and that shows up here as two outliers. It matters because the continuum model of 13.5.1 assumes a
            // UNIFORM Cs, so any spread in this line is a spread the comparison below cannot represent.
            var sectionCs:[Double] = []

            for nextSegment in segments {

                sectionCs.append(await nextSegment.seriesCapacitance)
            }

            if let smallestCs = sectionCs.min(), let largestCs = sectionCs.max(), let bottomCs = sectionCs.first, let topCs = sectionCs.last {

                let meanCs = sectionCs.reduce(0.0, +) / Double(sectionCs.count)
                text += "    Section Cs:      min \(Farads(smallestCs)), max \(Farads(largestCs)), mean \(Farads(meanCs))\n"
                text += "                     bottom section \(Farads(bottomCs)), top section \(Farads(topCs))"
                text += String(format: "  (%.3f and %.3f of the mean)\n", bottomCs / meanCs, topCs / meanCs)
            }

            let ground = await GroundCapacitance(model: model, coil: coil)

            text += "    Ground C direct: \(Farads(ground.direct))   to other coils: \(Farads(ground.toOtherCoils))\n"

            // The outermost coil's direct-to-ground figure is two very different things added together, and the split
            // is worth printing because it is routinely surprising - see OuterShuntCapacitance. Without it, a hand
            // calculation of "coil to tank" checked against this line looks wrong when nothing is.
            if coil == coilCount - 1, let outer = try? await model.OuterShuntCapacitance() {

                let total = outer.tank + outer.adjacentPhase
                text += "      of which:      to tank \(Farads(outer.tank)), to the adjacent phase \(Farads(outer.adjacentPhase))"
                text += total > 0.0 ? String(format: "  (%.0f%% phase-to-phase)\n", 100.0 * outer.adjacentPhase / total) : "\n"
                let neighbours = await model.adjacentPhaseCount
                let legDescription = neighbours == 0 ? "single phase - no neighbour" : (neighbours == 2 ? "a CENTRE leg" : "\(neighbours) neighbour(s)")
                text += "                     phase-to-phase gap: \(Millimetres(core.legCenters - 2.0 * (await first.r2)))  (\(neighbours) neighbouring phase(s) - \(legDescription))\n"
            }

            text += "\n"
        }

        return text
    }

    private static func WindingTypeName(_ type:BasicSectionWindingData.WdgType) -> String {

        switch type {

        case .layer:      return "layer"
        case .disc:       return "disc"
        case .helical:    return "helical"
        case .multistart: return "multistart"
        case .sheet:      return "sheet"
        }
    }

    // MARK: Series-capacitance breakdown

    /// Take one interior unit of a coil apart into the quantities its series capacitance is built from.
    ///
    /// This exists because the three treatments - plain disc, interleaved pair, shielded pair - reach their answer by three
    /// different routes, and comparing only the totals cannot say which route is responsible for a difference. All three reduce
    /// to a turn-to-turn capacitance times a function of the turn count, plus some fraction of the disc-to-disc capacitance, so
    /// printing those pieces lets the arithmetic be checked by hand:
    ///
    ///     plain disc     Cs_turn = c_t·(N−1)/N²                      then Stein: Cs·α/tanh α
    ///     interleaved    Cs_turn = c_t·(N−1)/2   per PAIR             then Stein, on the pair
    ///     shielded pair  Cs_turn = n·c_w·[4β²+1−1/N+1/2N²] + c_t·(N−n−1)/2N²    then Cdd/3 + (Cdd_ext)/6
    ///
    /// An interior unit is chosen deliberately: the two end units of a coil get the end-disc treatment (DV 12.63-64) and are
    /// several times smaller, so they say nothing about the bulk of the winding.
    private static func CapacitanceBreakdown(model:PhaseModel, coil:Int) async -> String {

        var text = "SERIES CAPACITANCE OF ONE INTERIOR UNIT, coil \(coil)\n"
        text += String(repeating: "-", count: 110) + "\n"

        let segments = await model.CoilSegments().filter({ $0.radialPos == coil })

        guard segments.count > 2 else {

            return text + "  (too few segments to pick an interior one)\n\n"
        }

        let segment = segments[segments.count / 2]
        let sections = segment.basicSections

        guard let bs = sections.first else {

            return text + "  (the segment has no BasicSections)\n\n"
        }

        let N = bs.N
        let tp = bs.wdgData.turn.turnInsulation
        let interleaved = await segment.IsInterleaved()
        let shield = await segment.woundInShield

        guard let ct = try? await segment.CapacitanceTurnToTurn() else {

            return text + "  (the turn-to-turn capacitance could not be computed)\n\n"
        }

        text += "  Segment:              \(sections.count) disc(s), \(String(format: "%.3f", N)) turns each"
        text += interleaved ? ", INTERLEAVED\n" : (shield != nil ? ", SHIELDED\n" : ", plain\n")
        text += "  Turn insulation tp:   \(Millimetres(tp))  (two-sided)\n"
        text += "  c_t (turn to turn):   \(Farads(ct))\n"

        // The disc-to-disc capacitances this unit sees. The internal one only exists for a two-disc unit, and whether it is
        // counted at all is precisely where the interleaved and shielded paths differ.
        let gapAbove = 0.004
        let externals = Segment.DiscToDiscSeriesCapacitance(belowGap: gapAbove, aboveGap: gapAbove, basicSection: bs, innerRadius: await segment.r1, outerRadius: await segment.r2)

        text += "  C_dd (per 4 mm gap):  \(Farads(externals.above))   [reference value at a nominal 4 mm gap]\n"

        if sections.count == 2 {

            let internalGap = sections[1].z1 - sections[0].z2
            let internal2 = Segment.DiscToDiscSeriesCapacitance(belowGap: internalGap, aboveGap: 0.0, basicSection: bs, innerRadius: await segment.r1, outerRadius: await segment.r2).below
            text += "  C_dd inside the pair: \(Farads(internal2))  across \(Millimetres(internalGap))\n"
        }

        if let shield {

            let n = Double(shield.turnsPerDisc.first ?? 0)
            let tw = shield.wire.insulation

            guard let cw = try? await segment.CapacitanceTurnToTurn(effectiveInsulation: 0.5 * (tp + tw)) else {

                return text + "  (the shield-to-turn capacitance could not be computed)\n\n"
            }

            let beta = shield.wire.connection.beta(turnsPerDisc: Int(n), discTurns: N)
            let bracket = 4.0 * beta * beta + 1.0 - 1.0 / N + 1.0 / (2.0 * N * N)

            text += "  Shield insulation tw: \(Millimetres(tw))  (two-sided)\n"
            text += "  tau_avg = (tp+tw)/2:  \(Millimetres(0.5 * (tp + tw)))\n"
            text += "  c_w (shield to turn): \(Farads(cw))"
            text += String(format: "   c_w/c_t = %.4f\n", cw / ct)
            text += "  Shield turns n:       \(String(format: "%.0f", n))   beta = \(String(format: "%.4f", beta))   bracket = \(String(format: "%.4f", bracket))\n"
            text += "  Shield term:          \(Farads(n * cw * bracket))\n"
            text += "  Plain turn term:      \(Farads(ct * (N - n - 1.0) / (2.0 * N * N)))\n"
        }
        else if interleaved {

            text += "  Cs_turn of the pair:  \(Farads(ct * (N - 1.0) / 2.0))   = c_t(N-1)/2, Veverka 6.4\n"
        }
        else {

            text += "  Cs_turn of the disc:  \(Farads(ct * (N - 1.0) / (N * N)))   = c_t(N-1)/N^2, DelVecchio 12.49\n"
        }

        // The number the rest of the report uses, so that the pieces above can be checked against it.
        text += "  Unit Cs as modelled:  \(Farads(await segment.seriesCapacitance))\n\n"

        return text
    }

    // MARK: Capacitance to ground

    /// A coil's total capacitance to ground, split by where it goes.
    ///
    /// - direct: the shunt capacitances the model books straight to ground (toNode == -1) - the tank, the core, and
    ///   the yokes.
    /// - toOtherCoils: the shunt capacitances to nodes belonging to a DIFFERENT coil. Whether these belong in Cg is a
    ///   judgment, which is why they are counted separately rather than folded in; see ContinuumComparison.
    ///
    /// Shunt capacitances between two nodes of the SAME coil (layer-to-layer, on a layer winding) are neither - they
    /// are internal to the winding and the continuum model has no place for them. They are reported as a remainder so
    /// that their existence is never silent.
    private static func GroundCapacitance(model:PhaseModel, coil:Int) async -> (direct:Double, toOtherCoils:Double, withinCoil:Double) {

        let nodes = await model.nodes

        // node number -> the coil it belongs to. A node is bounded by at most one Segment on each side and both are in
        // the same coil, so either one answers.
        var coilOfNode:[Int:Int] = [:]

        for nextNode in nodes {

            if let radial = nextNode.aboveSegment?.radialPos ?? nextNode.belowSegment?.radialPos {

                coilOfNode[nextNode.number] = radial
            }
        }

        var direct = 0.0
        var toOtherCoils = 0.0
        var withinCoil = 0.0

        for nextNode in nodes {

            guard coilOfNode[nextNode.number] == coil else {

                continue
            }

            for nextCap in nextNode.shuntCapacitances {

                if nextCap.toNode < 0 {

                    direct += nextCap.capacitance
                }
                else if coilOfNode[nextCap.toNode] == coil {

                    withinCoil += nextCap.capacitance
                }
                else {

                    toOtherCoils += nextCap.capacitance
                }
            }
        }

        return (direct: direct, toOtherCoils: toOtherCoils, withinCoil: withinCoil)
    }

    // MARK: Node classification

    /// Every node of every coil, with how `SimulationModel` classified it and what the initial distribution put there.
    ///
    /// This is the diagnostic for a scenario that is about the CONNECTIONS. The two things that can go wrong in wiring a model up
    /// are invisible in any aggregate number: a node the model decided is grounded when the user did not ground it, and a set of
    /// nodes the model shorted together that the user did not tie. Both show up here immediately - the first as a `GROUND` in the
    /// class column against a lead the scenario never terminated, the second in the merge column - and both otherwise arrive as a
    /// plausible distribution with a flat zero somewhere in it.
    private static func NodeReport(model:PhaseModel, simModel:SimulationModel, alpha:[Double]) async -> String {

        var text = "NODE CLASSIFICATION AND INITIAL DISTRIBUTION\n"
        text += String(repeating: "-", count: 110) + "\n"

        let grounded = Set(await simModel.groundedNodes.map({ $0.number }))
        let impulsed = Set(await simModel.impulsedNodes.map({ $0.number }))
        let floating = Set(await simModel.floatingNodes.map({ $0.number }))

        // finalConnectedNodes maps a KEPT node to the set shorted to it. Invert it so a node can be looked up by number, and keep
        // the kept node's own number so the report can say which way round the row surgery went.
        var mergeGroup:[Int:Int] = [:]

        for (kept, group) in await simModel.finalConnectedNodes {

            mergeGroup[kept.number] = kept.number

            for eliminated in group {

                mergeGroup[eliminated.number] = kept.number
            }
        }

        text += "  Grounded nodes: \(grounded.count)   impulsed: \(impulsed.count)   floating: \(floating.count)   merged into a group: \(mergeGroup.count)\n"

        // A CANONICAL FORM OF THE WHOLE CLASSIFICATION, ON ONE LINE.
        //
        // The finished connection scheme is what a model IS; the sequence of clicks that produced it is not supposed to survive
        // anywhere. Two scenarios that describe the same wiring by different routes - `S0738-parallel` built in one pass against
        // `S0738-parallel-edited` and `-edited-2` built by editing the series connection into it, in either order - must therefore
        // print this line identically, and the only way they could not is derived state outliving its source. That is exactly the
        // failure these three scenarios exist for, so the check is one `grep Connectivity:` across the three reports.
        //
        // Sorted throughout, because a Set's iteration order is not stable between runs and a fingerprint that changes on its own
        // is not a fingerprint.
        let groups = await simModel.finalConnectedNodes.map({ (kept, group) in "\(kept.number)<-\(group.map({ $0.number }).sorted().map({ String($0) }).joined(separator: ","))" }).sorted()

        text += "  Connectivity: ground[\(grounded.sorted().map({ String($0) }).joined(separator: ","))]"
        text += " impulse[\(impulsed.sorted().map({ String($0) }).joined(separator: ","))]"
        text += " float[\(floating.sorted().map({ String($0) }).joined(separator: ","))]"
        text += " merge[\(groups.joined(separator: " "))]\n\n"

        let coilCount = await model.CoilSegments().reduce(0, { max($0, $1.radialPos + 1) })

        for coil in 0..<coilCount {

            guard let profile = try? await model.CoilVoltageProfile(coil: coil) else {

                text += "  Coil \(coil): no voltage profile\n\n"
                continue
            }

            text += "  Coil \(coil)\n"
            text += "    node        z (mm)   class      merged with   V/Vcrest (t = 0+)\n"

            for nextPoint in profile {

                let number = nextPoint.nodeIndex

                let nodeClass = impulsed.contains(number) ? "IMPULSE" : (grounded.contains(number) ? "GROUND " : (floating.contains(number) ? "float  " : "-      "))
                let merge = mergeGroup[number].map({ $0 == number ? "kept (\(number))" : "-> \($0)" }) ?? "-"
                let value = number >= 0 && number < alpha.count ? String(format: "%18.6f", alpha[number]) : "                 ?"

                text += String(format: "    %4d   %11.3f   %@   %-11@%@\n", number, nextPoint.z * 1000.0, nodeClass, merge as NSString, value)
            }

            text += "\n"
        }

        return text
    }

    /// Every node of every coil again, this time with what the whole transient did there.
    ///
    /// The companion to `NodeReport`: that one says what the model decided and where t = 0+ put each node, this one says whether
    /// anything ever moved. A node the assembly has wrongly pinned reads an exact zero in both columns for the whole run, which
    /// is not something a real node does - even a node with no series path to the source is driven capacitively.
    private static func NodeTransientReport(model:PhaseModel, results:[SimulationModel.SimulationStepResult]) async -> String {

        var text = "NODE EXTREMES OVER THE TRANSIENT\n"
        text += String(repeating: "-", count: 110) + "\n"

        guard !results.isEmpty else {

            text += "  The solver returned no results.\n\n"
            return text
        }

        let coilCount = await model.CoilSegments().reduce(0, { max($0, $1.radialPos + 1) })

        for coil in 0..<coilCount {

            guard let profile = try? await model.CoilVoltageProfile(coil: coil) else {

                continue
            }

            text += "  Coil \(coil)\n"
            text += "    node        z (mm)      min (kV)      max (kV)\n"

            for nextPoint in profile {

                let number = nextPoint.nodeIndex

                var lowest = 0.0
                var highest = 0.0

                for nextStep in results {

                    guard number >= 0, number < nextStep.volts.count else {

                        continue
                    }

                    lowest = min(lowest, nextStep.volts[number])
                    highest = max(highest, nextStep.volts[number])
                }

                text += String(format: "    %4d   %11.3f   %11.3f   %11.3f\n", number, nextPoint.z * 1000.0, lowest / 1000.0, highest / 1000.0)
            }

            text += "\n"
        }

        return text
    }

    // MARK: The continuum comparison (DelVecchio 13.5.1)

    /// Compare the computed initial distribution against DelVecchio's uniform-capacitance continuum model.
    ///
    /// THE TWO ALPHAS. DelVecchio's Cg is "the capacitance to ground of the winding", written for a single winding
    /// against a grounded surround. A real two-winding phase has an inner coil in the way, and here that coil is
    /// grounded at BOTH ends - the standard impulse test connection - so it sits very close to ground potential and
    /// its capacitance from the HV behaves almost like capacitance to ground. Almost, not exactly: it is a winding
    /// with its own series capacitance, not an equipotential surface. Rather than pick one, both are reported:
    ///
    ///     alphaDirect = sqrt(Cg_direct / Cs)                    - lower bound, tank and adjacent phase only
    ///     alphaTotal  = sqrt((Cg_direct + Cg_toOtherCoils) / Cs) - upper bound, the LV counted as ground
    ///
    /// The computed distribution should land BETWEEN the two curves, nearer the alphaTotal one. If it lands outside
    /// them, something is wrong that the continuum model's approximations do not explain.
    ///
    /// A third alpha is fitted to the computed distribution, by least squares on ln(V) - see FitAlpha for why the
    /// logarithm is load-bearing. That one is not a check on anything by itself; it is the shape question. If the
    /// computed distribution is a sinh at all the fit is tight, and a fitted alpha far outside the bracket then says
    /// the capacitances are wrong rather than the shape.
    ///
    /// The table at the end carries a LOCAL alpha per node, which is the same question asked without any fitting: it
    /// is d(ln V)/dx between neighbouring nodes, and it equals alpha wherever 13.5.1 holds. Read that column before
    /// reading any of the three fitted numbers - a coil whose local alpha drifts is a coil the continuum model cannot
    /// describe with one alpha, and no choice of estimator will change that.
    ///
    /// THE LINE-END GRADIENT is reported alongside, because it is the number a designer actually acts on. In the
    /// continuum model dV/dx at the line end is alpha/tanh(alpha) times the average gradient, and the model's own
    /// equivalent is the voltage across the end disc divided by the average voltage per disc.
    private static func ContinuumComparison(model:PhaseModel, alpha:[Double], coil:Int) async -> (text:String, summary:String) {

        var text = "INITIAL DISTRIBUTION vs. DELVECCHIO 13.5.1 (continuum model), coil \(coil)\n"
        text += String(repeating: "-", count: 110) + "\n"

        guard let profile = try? await model.CoilVoltageProfile(coil: coil), profile.count > 1 else {

            return (text + "  FAILED: coil \(coil) has no usable voltage profile.\n\n", "FAILED - no voltage profile")
        }

        guard let seriesCapacitance = try? await model.CoilSeriesCapacitance(coil: coil), seriesCapacitance > 0.0 else {

            return (text + "  FAILED: coil \(coil) has no series capacitance.\n\n", "FAILED - no series capacitance")
        }

        let ground = await GroundCapacitance(model: model, coil: coil)

        // The computed distribution, as (x, V) with x running from the grounded end to the line end. CoilVoltageProfile
        // is sorted by ascending height; which end is driven is settled by looking at where the impulse actually is,
        // not by assuming the top, because a coil can be driven from either end.
        let impulsedNodes = (try? await model.ResolveNodeConnectivity())?.impulsed ?? []
        let drivenAtTop = impulsedNodes.contains(profile.last?.nodeIndex ?? -1)

        guard let lowZ = profile.first?.z, let highZ = profile.last?.z, highZ > lowZ else {

            return (text + "  FAILED: the coil has no axial extent.\n\n", "FAILED - no axial extent")
        }

        var points:[(x:Double, v:Double)] = []

        for nextPoint in profile {

            guard nextPoint.nodeIndex >= 0, nextPoint.nodeIndex < alpha.count else {

                continue
            }

            // x = 0 at the grounded end, 1 at the line end.
            let heightFraction = (nextPoint.z - lowZ) / (highZ - lowZ)
            points.append((x: drivenAtTop ? heightFraction : 1.0 - heightFraction, v: alpha[nextPoint.nodeIndex]))
        }

        points.sort { $0.x < $1.x }

        guard points.count > 2 else {

            return (text + "  FAILED: too few nodes to compare.\n\n", "FAILED - too few nodes")
        }

        // 13.5.1 SOLVES A BOUNDARY-VALUE PROBLEM, AND ONE OF THE TWO BOUNDARIES MAY NOT BE THERE.
        //
        // sinh(alpha*x)/sinh(alpha) is the solution of V'' = alpha^2 V under V(0) = 0 and V(1) = 1. The second boundary is the
        // impulse and is always satisfied; the first says the far end of the winding is AT GROUND, and that is a property of the
        // connection, not of the winding. On S0738 it is false: coil 2's far end returns through both halves of coil 3 to a
        // centre ground, so it floats at 0.65 p.u. at t = 0+ and the whole coil sits on that pedestal.
        //
        // Fitting anyway produces numbers - it produced a fitted alpha of 0.010 "inside the bracket" on a winding whose local
        // alpha is 0.2 and rising - and every one of them is an artefact of forcing a curve through the wrong boundary. That is
        // the same failure as the linear-vs-logarithmic fit recorded in CLAUDE.md, and the same rule applies: a diagnostic that
        // reports a comfortable number on a case it cannot describe is worse than no diagnostic. So the applicability is measured
        // rather than assumed - from the computed distribution's own value at x = 0 - and the comparison is declined out loud.
        //
        // What survives is what does not depend on the continuum model at all: the distribution itself, which is the regression
        // baseline, and the line-end gradient, which is the number the designer acts on.
        let groundedEndVoltage = points[0].v

        guard abs(groundedEndVoltage) < groundedEndTolerance else {

            text += "  Driven end:            \(drivenAtTop ? "top" : "bottom")\n"
            text += "  Nodes compared:        \(points.count)\n"
            text += "  Cs (whole winding):    \(Farads(seriesCapacitance))\n"
            text += "  Cg booked to ground:   \(Farads(ground.direct))   (tank + adjacent phase - see the split above)\n"
            text += "  Cg to other coils:     \(Farads(ground.toOtherCoils))\n\n"

            text += String(format: "  NOT COMPARED against 13.5.1: the far end of coil %d is at %.4f p.u., not at ground.\n", coil, groundedEndVoltage)
            text += "  The continuum model assumes V(0) = 0, so no alpha fitted to this distribution would mean anything. This\n"
            text += "  coil's return path runs through another winding rather than straight to ground - see the jumpers above.\n\n"

            let gradient = LineEndGradient(points: points)
            text += String(format: "  Line-end gradient over the end section: %.4f x the average gradient\n\n", gradient)

            text += "  x (0 = far end)   V/Vcrest (model)   local alpha\n"

            for (i, nextPoint) in points.enumerated() {

                text += String(format: "  %13.6f   %16.6f", nextPoint.x, nextPoint.v)

                if i > 0, points[i - 1].v >= fittingFloor, nextPoint.v > 0.0, nextPoint.x > points[i - 1].x {

                    text += String(format: "   %11.3f", log(nextPoint.v / points[i - 1].v) / (nextPoint.x - points[i - 1].x))
                }

                text += "\n"
            }

            text += "\n"

            let summary = String(format: "13.5.1 not applicable (far end at %.4f p.u., not grounded); line-end gradient %.3f x average, far end %.4f p.u.",
                                 groundedEndVoltage, gradient, groundedEndVoltage)

            return (text, summary)
        }

        let alphaDirect = sqrt(ground.direct / seriesCapacitance)
        let alphaTotal = sqrt((ground.direct + ground.toOtherCoils) / seriesCapacitance)
        let alphaFitted = FitAlpha(points: points)

        text += "  Driven end:            \(drivenAtTop ? "top" : "bottom")\n"
        text += "  Nodes compared:        \(points.count)\n"
        text += "  Cs (whole winding):    \(Farads(seriesCapacitance))\n"

        // NOT "to the tank". For the outermost coil this is the tank AND the adjacent phase, and on a design with tight
        // leg centres the second is the larger of the two - see OuterShuntCapacitance and the split printed in the
        // geometry section above. Labelling it "tank" here once cost an afternoon.
        text += "  Cg booked to ground:   \(Farads(ground.direct))   (tank + adjacent phase - see the split above)\n"
        text += "  Cg to other coils:     \(Farads(ground.toOtherCoils))\n"

        if ground.withinCoil > 0.0 {

            text += "  Cg within the coil:    \(Farads(ground.withinCoil))  (not part of either alpha - see GroundCapacitance)\n"
        }

        text += "\n"
        text += "  alpha (Cg to ground only): \(String(format: "%8.4f", alphaDirect))\n"
        text += "  alpha (Cg incl. LV):       \(String(format: "%8.4f", alphaTotal))\n"
        text += "  alpha (fitted to model):   \(String(format: "%8.4f", alphaFitted))\n"

        let bracketed = alphaFitted >= min(alphaDirect, alphaTotal) && alphaFitted <= max(alphaDirect, alphaTotal)
        text += "  fitted alpha is \(bracketed ? "INSIDE" : "OUTSIDE") the bracket\n\n"

        // How far the computed distribution is from each continuum curve. Both errors are absolute in per-unit of the
        // applied crest, which is the natural unit here: a 0.01 departure means one per cent of the crest, wherever on
        // the winding it happens.
        for (name, value) in [("Cg to ground", alphaDirect), ("Cg incl. LV", alphaTotal), ("fitted", alphaFitted)] {

            let deviation = Deviation(points: points, alpha: value)
            text += "  vs. alpha = \(String(format: "%7.4f", value)) (\(name)):  max \(String(format: "%.5f", deviation.max)) p.u. at x = \(String(format: "%.3f", deviation.atX)),  rms \(String(format: "%.5f", deviation.rms)) p.u.\n"
        }

        text += "\n"

        // The line-end gradient, in multiples of the average gradient.
        //
        // The divisor is the end section's own span in x, NOT 1/N. The end nodes of a coil sit at the outer face of
        // the end disc while the interior ones sit at the gap midpoints, so the end sections are about 12% shorter in
        // x than the interior ones; dividing by 1/N charges the end section for length it does not have. The continuum
        // model's equivalent is its own average slope over that same interval rather than its endpoint derivative
        // alpha/tanh(alpha), so that the two are measured over the same piece of winding.
        let lastSpan = points[points.count - 1].x - points[points.count - 2].x
        let modelEnhancement = LineEndGradient(points: points)

        text += "  Line-end gradient over the end section, as a multiple of the average gradient:\n"
        text += "    model:                        \(String(format: "%8.4f", modelEnhancement))\n"

        for (name, value) in [("Cg to ground", alphaDirect), ("Cg incl. LV", alphaTotal), ("fitted", alphaFitted)] {

            let continuumDrop = 1.0 - ContinuumShape(alpha: value, x: points[points.count - 2].x)
            text += "    continuum, \(name):\(String(repeating: " ", count: max(1, 18 - name.count)))\(String(format: "%8.4f", lastSpan > 0.0 ? continuumDrop / lastSpan : 0.0))"
            text += String(format: "   (alpha/tanh(alpha) = %.4f)\n", value / tanh(value))
        }

        text += "\n"

        // The distribution itself, so that the report can be diffed against a later run, plus the LOCAL alpha between
        // each pair of nodes. The local alpha is the honest way to look at this: it is d(ln V)/dx, which is exactly
        // alpha wherever the distribution is the exponential that 13.5.1 predicts, and it needs no fitting at all. A
        // winding that really is a uniform ladder shows one number down the column. Where it drifts, the ladder is not
        // uniform, and the column says where and by how much - which a single fitted alpha cannot.
        //
        // It is meaningless near the grounded end (sinh is linear there, not exponential, and the model's values are
        // five decades down and set by coupling to the other coil rather than by alpha), so it is only printed above
        // the fitting floor.
        text += "  x (0 = grounded end)   V/Vcrest (model)   sinh fit (fitted alpha)   difference   local alpha\n"

        for (i, nextPoint) in points.enumerated() {

            let fitted = ContinuumShape(alpha: alphaFitted, x: nextPoint.x)
            text += String(format: "  %14.6f   %16.6f   %23.6f   %10.6f", nextPoint.x, nextPoint.v, fitted, nextPoint.v - fitted)

            if i > 0, points[i - 1].v >= fittingFloor, nextPoint.v > 0.0, nextPoint.x > points[i - 1].x {

                let localAlpha = log(nextPoint.v / points[i - 1].v) / (nextPoint.x - points[i - 1].x)
                text += String(format: "   %11.3f", localAlpha)
            }

            text += "\n"
        }

        text += "\n"

        let summary = String(format: "alpha: direct %.3f, incl. LV %.3f, fitted %.3f (%@ bracket); line-end gradient %.3f x average",
                             alphaDirect, alphaTotal, alphaFitted, bracketed ? "inside" : "OUTSIDE", modelEnhancement)

        return (text, summary)
    }

    /// How far from zero the far end of a coil may sit and still be called grounded, in per unit of the crest.
    ///
    /// A node tied to ground comes back from the solver as an exact zero (the row surgery puts it there), so anything this side
    /// of the number is numerical noise and anything the far side is a real potential. It is not a tuned threshold and there is
    /// nothing between 1e-6 and 0.65 to tune it against.
    private static let groundedEndTolerance = 1.0e-6

    /// The voltage gradient over the coil's end section, as a multiple of the average gradient down the whole coil.
    ///
    /// The divisor is the end section's OWN span in x, not 1/N. The end nodes of a coil sit at the outer face of the end disc
    /// while the interior ones sit at the gap midpoints, so the end sections are about 12% shorter in x than the interior ones;
    /// dividing by 1/N charges the end section for length it does not have.
    ///
    /// This is the one number in the comparison that survives the continuum model not applying, which is why it is a function
    /// rather than three lines inside one: it asks only what the model computed, over what length.
    private static func LineEndGradient(points:[(x:Double, v:Double)]) -> Double {

        guard points.count > 1 else {

            return 0.0
        }

        let lastSpan = points[points.count - 1].x - points[points.count - 2].x
        let endSectionDrop = abs(points[points.count - 1].v - points[points.count - 2].v)

        return lastSpan > 0.0 ? endSectionDrop / lastSpan : 0.0
    }

    /// DelVecchio 13.5.1: V(x)/V = sinh(alpha*x) / sinh(alpha), with x = 0 at the grounded end.
    ///
    /// Written in the exponential form that comes from multiplying numerator and denominator by e^-alpha:
    ///
    ///     sinh(ax)/sinh(a) = (e^(a(x-1)) - e^(-a(x+1))) / (1 - e^(-2a))
    ///
    /// which is algebraically identical but cannot overflow - every exponent is <= 0 for x in [0, 1] and a > 0. The
    /// direct form overflows at alpha ~ 710, and although no winding is anywhere near that, a fit that wanders while
    /// searching should not be able to produce an inf.
    private static func ContinuumShape(alpha:Double, x:Double) -> Double {

        // The alpha -> 0 limit is the uniform (purely inductive) distribution. Taking it explicitly avoids 0/0.
        guard alpha > 1.0e-9 else {

            return x
        }

        return (exp(alpha * (x - 1.0)) - exp(-alpha * (x + 1.0))) / (1.0 - exp(-2.0 * alpha))
    }

    /// The largest and rms departure of the computed distribution from a continuum curve of the given alpha.
    private static func Deviation(points:[(x:Double, v:Double)], alpha:Double) -> (max:Double, atX:Double, rms:Double) {

        var largest = 0.0
        var largestX = 0.0
        var sumSquares = 0.0

        for nextPoint in points {

            let error = nextPoint.v - ContinuumShape(alpha: alpha, x: nextPoint.x)

            if abs(error) > largest {

                largest = abs(error)
                largestX = nextPoint.x
            }

            sumSquares += error * error
        }

        return (max: largest, atX: largestX, rms: sqrt(sumSquares / Double(points.count)))
    }

    /// Nodes whose voltage is below this fraction of the crest take no part in the fit, and get no local alpha.
    ///
    /// Two reasons, and they are the same reason twice. ln(V) runs to minus infinity at the grounded end, so a
    /// logarithmic fit needs *some* floor. And the bottom of a real winding is not a sinh at all: down there the
    /// initial distribution is a residual set by capacitance to the other coil, four or five decades below the crest,
    /// carrying no information about alpha and a great deal of information about the LV. 0.1% of crest is well below
    /// anything a designer would look at and well above that residual.
    private static let fittingFloor = 1.0e-3

    /// The alpha whose continuum curve best fits the computed distribution, by least squares ON THE LOGARITHM.
    ///
    /// THE LOGARITHM IS NOT A DETAIL. Over most of a winding the initial distribution is an exponential - within
    /// e^(-2a), sinh(ax)/sinh(a) IS e^(a(x-1)) - so it spans four or five decades from the grounded end to the line
    /// end. A least-squares fit in V therefore sees only the top few per cent of the coil: every residual below about
    /// x = 0.9 is smaller than the rounding on the ones above it, and the fit reduces to "match the last two discs".
    /// That is exactly the region where a real winding departs from 13.5.1 the most, because the end disc has a
    /// neighbour on one side only and gets its own series capacitance (DelVecchio 12.63-64) - so the linear fit
    /// weights the least representative discs the most heavily.
    ///
    /// It is not a small effect. On the STME-0999 fixture the linear fit returned alpha = 14.75 against a winding
    /// whose local d(ln V)/dx sits at 9.3 through the middle and 10.8 near the top; the logarithmic fit returns a
    /// number in that range. The linear fit also put the answer outside the Cg bracket and so reported a disagreement
    /// with DelVecchio that was entirely an artefact of the estimator.
    ///
    /// Golden-section search rather than anything cleverer: the objective is smooth and unimodal in alpha over any
    /// range a winding can occupy (the curve family is monotone in alpha at every interior x), there is exactly one
    /// parameter, and a few hundred evaluations of a closed-form expression costs nothing. The bracket is deliberately
    /// wide - a fitted alpha that runs to either limit is itself the finding.
    private static func FitAlpha(points:[(x:Double, v:Double)]) -> Double {

        // Only the part of the winding where the distribution carries alpha - see fittingFloor.
        let fitted = points.filter({ $0.v >= fittingFloor })

        guard fitted.count >= 3 else {

            return 0.0
        }

        var low = 0.01
        var high = 60.0

        // 1/phi, the golden-section ratio.
        let ratio = 0.6180339887498949

        func SumOfSquares(_ alpha:Double) -> Double {

            var total = 0.0

            for nextPoint in fitted {

                let shape = ContinuumShape(alpha: alpha, x: nextPoint.x)

                // The shape cannot be zero for x > 0 and alpha > 0, but it can underflow at very large alpha, which
                // the search is free to try. Charge a large residual rather than taking log(0).
                guard shape > 0.0 else {

                    total += 100.0
                    continue
                }

                let error = log(nextPoint.v) - log(shape)
                total += error * error
            }

            return total
        }

        var c = high - ratio * (high - low)
        var d = low + ratio * (high - low)
        var fc = SumOfSquares(c)
        var fd = SumOfSquares(d)

        // 100 iterations shrinks the bracket by 0.618^100, which is far below any tolerance that matters; the loop is
        // bounded rather than convergence-tested so that it cannot spin on a pathological objective.
        for _ in 0..<100 {

            if fc < fd {

                high = d
                d = c
                fd = fc
                c = high - ratio * (high - low)
                fc = SumOfSquares(c)
            }
            else {

                low = c
                c = d
                fc = fd
                d = low + ratio * (high - low)
                fd = SumOfSquares(d)
            }
        }

        return (low + high) / 2.0
    }

    // MARK: The axial stress profile

    /// The disc-to-disc stress profile of the continuum coil - the data behind `AxialStressProfileWindow`, in numbers.
    ///
    /// This exists because that window is the one place the screen's output is read as a SHAPE rather than as a ranked list, and a
    /// shape hides the things that go wrong with it: a gap tagged at the wrong height puts a point in the wrong place on a curve
    /// that still looks plausible, and a missing tag drops a gap out of the picture silently. So the profile is printed here with
    /// the checks it came from — the count against the number of gaps in the coil, the heights in order, and the worst gap with
    /// exactly the four numbers the graph's annotation shows.
    ///
    /// It also pins the two derived quantities, which are recovered from the check rather than recomputed: the allowable field is
    /// averageField / averageUtilization and the allowable ΔV is deltaV / averageUtilization, both exact because the field is
    /// linear in the driving voltage.
    private static func AxialProfileReport(model:PhaseModel, results:[SimulationModel.SimulationStepResult], alpha:[Double], scenario:Scenario) async -> String {

        var text = "AXIAL STRESS PROFILE (coil \(scenario.continuumCoil), disc to disc)\n"
        text += String(repeating: "-", count: 110) + "\n"

        let checks = await DielectricStress.Report(model: model,
                                                   results: results,
                                                   capacitiveDistribution: alpha,
                                                   peakVoltage: scenario.peakVoltage)

        let name = DielectricStress.AxialProfileName(coil: scenario.continuumCoil)

        let profile = checks.filter { $0.kind == .discToDisc && $0.profileName == name && $0.profileHeight != nil }
            .sorted { ($0.profileHeight ?? 0.0) < ($1.profileHeight ?? 0.0) }

        guard !profile.isEmpty else {

            text += "  No disc-to-disc gaps are tagged for this coil. If the coil is a disc winding, the profile graph is empty and\n"
            text += "  something has stopped AppendAxialSites tagging its sites.\n\n"
            return text
        }

        // Every disc-to-disc check of this coil should be in the profile: the tag is not optional, and one without a height is a
        // gap the graph cannot draw.
        let untagged = checks.filter { $0.kind == .discToDisc && $0.location.hasPrefix("Coil \(scenario.continuumCoil),") && $0.profileHeight == nil }.count

        text += "  \(profile.count) gaps tagged\(untagged == 0 ? "" : " - FAILED: \(untagged) disc-to-disc check(s) of this coil carry no height")\n"

        let heights = profile.compactMap { $0.profileHeight }
        text += String(format: "  Heights:    %.1f mm to %.1f mm\n", (heights.first ?? 0.0) * 1000.0, (heights.last ?? 0.0) * 1000.0)

        let allowables = profile.map { $0.averageField / $0.averageUtilization }
        let lowestAllowable = allowables.min() ?? 0.0
        let highestAllowable = allowables.max() ?? 0.0
        let constant = highestAllowable - lowestAllowable <= 1.0E-9 * max(1.0, highestAllowable)

        text += String(format: "  Allowable:  %.2f kV/mm%@\n", highestAllowable / 1.0E6,
                       constant ? " (the same in every gap, so the graph's allowable is one horizontal line)"
                                : String(format: " at most, %.2f kV/mm at least - the graph draws it as a curve", lowestAllowable / 1.0E6))

        // The worst gap is picked by utilization, exactly as the window's annotation picks it.
        if let worst = profile.max(by: { $0.averageUtilization < $1.averageUtilization }) {

            let allowableField = worst.averageField / worst.averageUtilization
            let allowableDeltaV = abs(worst.deltaV) / worst.averageUtilization

            text += String(format: "  Worst gap:  %.2f kV/mm at z = %.1f mm, %.0f%% of allowable\n",
                           worst.averageField / 1.0E6, (worst.profileHeight ?? 0.0) * 1000.0, worst.averageUtilization * 100.0)
            text += String(format: "              dV = %.2f kV, allowable dV = %.2f kV at %.2f kV/mm\n",
                           abs(worst.deltaV) / 1000.0, allowableDeltaV / 1000.0, allowableField / 1.0E6)
            text += "              \(worst.location)\n"
        }

        text += "\n  Gap-by-gap (height mm, stress kV/mm, allowable kV/mm, dV kV, allowable dV kV):\n"

        for check in profile {

            let allowableField = check.averageField / check.averageUtilization

            text += String(format: "    %8.1f  %7.3f  %7.3f  %8.2f  %8.2f\n",
                           (check.profileHeight ?? 0.0) * 1000.0,
                           check.averageField / 1.0E6,
                           allowableField / 1.0E6,
                           abs(check.deltaV) / 1000.0,
                           allowableDeltaV(check) / 1000.0)
        }

        return text + "\n"
    }

    /// The driving voltage that would put a check's governing layer exactly at its allowable.
    private static func allowableDeltaV(_ check:DielectricStress.StressCheck) -> Double {

        return abs(check.deltaV) / check.averageUtilization
    }

    /// Draw the result graphs into PNG files beside the report (`-PCH_SelfTestGraphs YES`).
    ///
    /// The numbers behind a graph can be checked by printing them, and `AxialProfileReport` does. The DRAWING cannot: a curve
    /// plotted off the end of its axis, an annotation box sitting on top of the line it describes, or a tick label overwriting its
    /// neighbour are all invisible to any assertion worth writing, and all three are what actually goes wrong when a plot is
    /// edited. So the window is built exactly as the menu item builds it, given a frame, and asked to draw itself into a bitmap.
    ///
    /// The window is never ordered front - `cacheDisplay(in:to:)` renders an unmapped view - so this stays headless.
    private static func RenderGraphs(model:PhaseModel, results:[SimulationModel.SimulationStepResult], alpha:[Double], scenario:Scenario) async -> String {

        var text = "GRAPHS\n"
        text += String(repeating: "-", count: 110) + "\n"

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {

            return text + "  FAILED: the container has no Documents folder.\n\n"
        }

        let checks = await DielectricStress.Report(model: model,
                                                   results: results,
                                                   capacitiveDistribution: alpha,
                                                   peakVoltage: scenario.peakVoltage)

        // Both profile graphs, because they share a view (StressProfileView) and so break together.
        var windows:[(what:String, controller:NSWindowController?)] = []

        windows.append(("axialStress", AxialStressProfileWindow(checks: checks, title: "Disc-to-Disc Stress vs. Height")))
        windows.append(("radialStress", StressProfileWindow(checks: checks, peakTestVoltage: scenario.peakVoltage, title: "Radial Voltage Difference vs. Height")))

        // The radial voltage profile of every sheet or layer winding in the model, if there is one. It shares StressProfileView with
        // the two above, so it breaks with them; and it is the one graph whose x axis is NOT a height, which is exactly the thing a
        // shared view is most likely to get wrong. The S0738 fixture's coil 0 is a sheet winding, so that scenario covers it.
        for segment in await model.CoilSegments() {

            let wdgType = await segment.wdgType

            guard wdgType == .sheet || wdgType == .layer else {

                continue
            }

            let nodes = await model.AdjacentNodes(to: segment)

            guard let instant = AppController.WorstInstant(nodes: nodes, results: results, capacitiveDistribution: alpha, peakVoltage: scenario.peakVoltage) else {

                text += "  SKIPPED the radial profile of coil \(await segment.radialPos): its nodes are not in the result.\n"
                continue
            }

            do {

                let contents = try await AppController.BuildRadialProfile(model: model, segment: segment, instant: instant)

                // TWO WORSTS, printed separately and never merged into one. The gap carrying the most volts is a ducted gap wherever
                // the coil has one, and the gap nearest its allowable is usually a plain one, because the duct is allowed most of
                // what it takes. Printing the larger voltage under the governing gap's index - which this line used to do - reads as
                // one gap with two numbers on it.
                //
                // %g, not %.1f, on the voltages. A coil grounded at both ends comes out at a few nanovolts rather than at exactly
                // zero, and %.1f prints that as "0.0 V" beside a perfectly real enhancement ratio - the shape is scale-invariant and
                // survives however small the driving voltage gets. Printing "1.04x the reference of 0.0 V" reads as a bug in the
                // ratio when it is only a bug in the format.
                let peakGap = contents.points.max { $0.deltaV < $1.deltaV }
                let governingGap = contents.points.max { $0.utilization < $1.utilization }

                func Kind(_ gap:RadialProfileWindow.GapPoint?) -> String {

                    return gap.map { $0.hasDuct ? " (with duct)" : " (no duct)" } ?? ""
                }

                text += String(format: "  coil %d (%@): %d gaps, peak ΔV %g V at gap %d%@, worst utilization %.1f%% at gap %d%@, %@ the reference of %g V, at %@\n",
                               contents.coil,
                               wdgType == .sheet ? "sheet" : "layer",
                               contents.points.count,
                               peakGap?.deltaV ?? 0.0,
                               (peakGap?.index ?? -1) + 1,
                               Kind(peakGap),
                               (governingGap?.utilization ?? 0.0) * 100.0,
                               (governingGap?.index ?? -1) + 1,
                               Kind(governingGap),
                               contents.enhancement.map { String(format: "%.2fx", $0) } ?? "n/a against",
                               contents.reference,
                               instant.label)

                // The other site in a layer winding, and the only place in the program it is reported: two axially adjacent turns
                // across one turn's paper, out of the same network solve as the gaps.
                if let turnToTurn = contents.turnToTurn {

                    text += String(format: "    turn-to-turn on the same coil: %g V in layer %d at height %.0f mm, %.1f%% of allowable across %.2f mm of paper\n",
                                   turnToTurn.deltaV,
                                   turnToTurn.layer + 1,
                                   turnToTurn.height * 1000.0,
                                   turnToTurn.utilization * 100.0,
                                   turnToTurn.insulation * 1000.0)
                }

                // A sheet winding's equal-spacing convention, beside the placed-duct answer. Printed, never asserted: it is a client's
                // convention and not a claim about the physics.
                if let equal = contents.equalSpacing {

                    text += String(format: "    equal spacing on the same coil: %.3f mm per gap, worst ΔV %g V at gap %d, %.1f%% of allowable across the plain-gap paper\n",
                                   equal.spacing * 1000.0,
                                   equal.worstDeltaV,
                                   equal.worstIndex + 1,
                                   equal.utilization * 100.0)
                }

                // The independent check on a layer solve, and the reason it is printed rather than asserted: alpha/tanh(alpha) comes
                // from the coil's LUMPED Cs and Cg while the profile comes from a turn-level network, so agreement is real evidence
                // that the network is assembled right. They are not the same quantity - see the note in BuildRadialProfile - so a
                // tolerance here would be fitted to one design rather than tested against it. Standing rule 8.
                if let screen = contents.screenEstimate {

                    text += String(format: "    alpha screen on the same coil: %.2fx (alpha/tanh alpha from lumped Cs and Cg, which still SPREADS the ducts)\n", screen)
                }

                windows.append(("radialProfile-coil\(contents.coil)", RadialProfileWindow(contents: contents, peakTestVoltage: scenario.peakVoltage)))
            }
            catch {

                text += "  FAILED the radial profile of coil \(await segment.radialPos): \(error.localizedDescription)\n"
            }
        }

        for (what, controller) in windows {

            guard let controller else {

                // Both stress-profile windows are failable initialisers that return nil when the findings hold nothing they can
                // draw, and that is not always a failure: a model with no DISC winding in it has no disc-to-disc gap, so the axial
                // profile has nothing to say and correctly declines to open. The SheetAndLayer fixture is exactly that model.
                let hasDiscGaps = checks.contains { $0.kind == .discToDisc }
                let expected = what == "axialStress" && !hasDiscGaps

                text += expected ? "  \(what): nothing to draw - this model has no disc-to-disc gaps.\n"
                                 : "  FAILED: the \(what) window could not be built from \(checks.count) findings.\n"
                continue
            }

            guard let window = controller.window, let contentView = window.contentView else {

                text += "  FAILED: the \(what) window has no content view.\n"
                continue
            }

            window.setContentSize(NSSize(width: 1000.0, height: 620.0))
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()

            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {

                text += "  FAILED: no bitmap could be made for the \(what) graph.\n"
                continue
            }

            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)

            guard let png = bitmap.representation(using: .png, properties: [:]) else {

                text += "  FAILED: the \(what) bitmap could not be encoded.\n"
                continue
            }

            let url = documents.appendingPathComponent("SelfTestGraph-\(scenario.name)-\(what).png")

            do {

                try png.write(to: url)
                text += "  \(url.lastPathComponent) (\(Int(contentView.bounds.width)) x \(Int(contentView.bounds.height)))\n"
            }
            catch {

                text += "  FAILED writing the \(what) graph: \(error)\n"
            }
        }

        return text + "\n"
    }

    // MARK: The transient

    /// The peak envelope of the impulsed coil, which is what the continuum model's travelling-wave section (13.5.2)
    /// speaks to - but only qualitatively, since that section is a lossless uniform line with no second winding and no
    /// mutual inductance. This is reported as a regression baseline, not compared against a formula.
    private static func TransientReport(model:PhaseModel, results:[SimulationModel.SimulationStepResult], scenario:Scenario) async -> (text:String, summary:String) {

        var text = "TRANSIENT (frequency-domain solve)\n"
        text += String(repeating: "-", count: 110) + "\n"

        guard !results.isEmpty else {

            text += "  FAILED: the solver returned no results.\n\n"
            return (text, "transient FAILED")
        }

        text += "  Waveform:   \(scenario.waveFormType.rawValue) at \(String(format: "%.1f", scenario.peakVoltage / 1000.0)) kV crest\n"
        text += "  Span:       \(String(format: "%.1f", scenario.displaySpan * 1.0e6)) us in \(results.count) steps\n"
        text += "  Bandwidth:  \(String(format: "%.1f", scenario.bandwidth / 1.0e6)) MHz\n\n"

        guard let profile = try? await model.CoilVoltageProfile(coil: scenario.continuumCoil), !profile.isEmpty else {

            text += "  FAILED: no voltage profile for coil \(scenario.continuumCoil).\n\n"
            return (text, "transient FAILED - no voltage profile")
        }

        // HOW MUCH WINDING A "SECTION" IS. This is the thing that makes the three STME-0999 scenarios comparable or
        // not. A section is one Segment, and interleaving or shielding rebuilds the coil into TWO-disc Segments - so
        // the plain scenario's worst section voltage is across one disc while the other two are across two. Comparing
        // them directly still answers the designer's question (what does the end unit of the winding actually hold?)
        // but it is not the same amount of winding, and the report has to say so rather than leave it to be inferred
        // from a segment count in another section.
        //
        // The line-end gradient in the initial-distribution section above is the metric that IS directly comparable -
        // it is a voltage per unit of winding height, so it does not care how the coil is divided up.
        let coilSegments = await model.CoilSegments().filter({ $0.radialPos == scenario.continuumCoil })
        let discCount = coilSegments.reduce(0, { $0 + $1.basicSections.count })
        let discsPerSection = coilSegments.isEmpty ? 1 : Double(discCount) / Double(coilSegments.count)

        text += "  Sections:   \(coilSegments.count) Segments over \(discCount) discs (\(String(format: "%.2f", discsPerSection)) discs per section)\n\n"

        // Each node's worst excursion, and when it happened. The peak is tracked by absolute value but reported
        // signed, because the sign says whether a node has swung past the driven polarity - which is the interesting
        // case and the one an envelope of magnitudes hides.
        var peakVolts = [Double](repeating: 0.0, count: profile.count)
        var peakTimes = [Double](repeating: 0.0, count: profile.count)

        // The largest voltage across any single section, over the whole run. This is the turn-insulation number.
        var worstSectionDrop = 0.0
        var worstSectionIndex = 0
        var worstSectionTime = 0.0

        for nextStep in results {

            for (i, nextPoint) in profile.enumerated() {

                guard nextPoint.nodeIndex >= 0, nextPoint.nodeIndex < nextStep.volts.count else {

                    continue
                }

                let volts = nextStep.volts[nextPoint.nodeIndex]

                if abs(volts) > abs(peakVolts[i]) {

                    peakVolts[i] = volts
                    peakTimes[i] = nextStep.time
                }

                guard i > 0, profile[i - 1].nodeIndex >= 0, profile[i - 1].nodeIndex < nextStep.volts.count else {

                    continue
                }

                let drop = abs(volts - nextStep.volts[profile[i - 1].nodeIndex])

                if drop > worstSectionDrop {

                    worstSectionDrop = drop
                    worstSectionIndex = i
                    worstSectionTime = nextStep.time
                }
            }
        }

        let highest = peakVolts.enumerated().max(by: { abs($0.element) < abs($1.element) })

        if let highest {

            text += "  Highest node voltage:    \(String(format: "%.1f", highest.element / 1000.0)) kV at section \(highest.offset), t = \(String(format: "%.3f", peakTimes[highest.offset] * 1.0e6)) us"
            text += "  (\(String(format: "%.3f", highest.element / scenario.peakVoltage)) p.u.)\n"
        }

        text += "  Worst section voltage:   \(String(format: "%.1f", worstSectionDrop / 1000.0)) kV across section \(worstSectionIndex), t = \(String(format: "%.3f", worstSectionTime * 1.0e6)) us\n"
        text += "                           = \(String(format: "%.1f", worstSectionDrop / 1000.0 / discsPerSection)) kV per disc averaged over the section's \(String(format: "%.2f", discsPerSection)) discs\n"
        text += "                             (the average is NOT the internal distribution - an interleaved or shielded\n"
        text += "                              pair does not divide its voltage equally between its two discs)\n"

        // The caveat that stops this table being read as a clean bill of health on an interleaved winding. A low
        // section-to-section voltage is exactly what interleaving buys, and it is a real gain against the DISC-TO-DISC
        // stress - but it is bought by winding turns that are far apart electrically next to each other, so the
        // TURN-TO-TURN voltage inside the disc goes UP, which is why interleaved windings need heavier turn paper.
        // Nothing in this report measures that: TurnLadderModel refuses interleaved windings on purpose, because the
        // position-to-turn map is scheme-dependent and guessing it would give a confidently wrong answer.
        if let firstSegment = coilSegments.first, await firstSegment.IsInterleaved() {

            text += "\n  NOTE: this coil is interleaved, so the section voltage above is the DISC-TO-DISC stress only.\n"
            text += "        Interleaving lowers it by putting electrically distant turns side by side, which RAISES the\n"
            text += "        turn-to-turn voltage inside each disc - the reason an interleaved winding needs heavier turn\n"
            text += "        insulation. Nothing here measures that; TurnLadderModel handles continuous discs only.\n"
        }

        text += "\n"

        text += "  section   peak kV    p.u.    at t (us)\n"

        for (i, nextPeak) in peakVolts.enumerated() {

            text += String(format: "  %7d   %7.2f   %6.3f   %10.3f\n", i, nextPeak / 1000.0, nextPeak / scenario.peakVoltage, peakTimes[i] * 1.0e6)
        }

        text += "\n"

        let summary = String(format: "worst section %.1f kV over %.2f discs, peak %.3f p.u.",
                             worstSectionDrop / 1000.0, discsPerSection, (highest?.element ?? 0.0) / scenario.peakVoltage)

        return (text, summary)
    }

    // MARK: Reporting

    /// Note the step about to be attempted, and flush it.
    ///
    /// The flush is the point. The pipeline this drives raises NSAlerts on failure, and a modal alert in an app nobody
    /// is watching will sit there until the process is killed - so the last thing that reached the defaults database
    /// is the only evidence of where a hung run stopped.
    private static func Stage(_ what:String) {

        UserDefaults.standard.set(what, forKey: stageKey)
        UserDefaults.standard.synchronize()
    }

    private static func Record(report:String, summary:String, fileName:String) {

        UserDefaults.standard.set(summary, forKey: summaryKey)
        UserDefaults.standard.synchronize()

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {

            return
        }

        // The full report goes to a file rather than to UserDefaults: it is a page or more, which `defaults read`
        // renders as one enormous escaped line. The container's Documents folder is writable without any entitlement
        // beyond the sandbox's own, which is the same reason the fixture is read from there.
        try? report.write(to: documents.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    // MARK: Formatting

    /// Metres in, millimetres out, to three decimals. Every length in the model is in metres; every length a
    /// transformer designer reads is in millimetres.
    private static func Millimetres(_ metres:Double) -> String {

        return String(format: "%.3f mm", metres * 1000.0)
    }

    private static func Farads(_ farads:Double?) -> String {

        guard let farads else {

            return "n/a"
        }

        return String(format: "%.6e F", farads)
    }
}
