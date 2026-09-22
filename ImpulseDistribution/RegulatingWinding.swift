//
//  RegulatingWinding.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-09-22.
//
//  Declaring a coil to be a REGULATING (tapping) winding, and putting on the connections that are a permanent part of it.
//
//  WHY. A tapping winding is not wired like a plain one. Some of its connections are made in the factory and never change
//  with the tap position, and until this existed every one of them had to be clicked on by hand - on a double-stacked tap
//  winding that is nine jumpers for eight loops, each between two crossovers that have to be counted out disc by disc, and
//  a miscount is a different transformer that looks exactly the same on screen. The idea is borrowed from PchMagneticFlux's
//  "Set Layer As Regulating Winding" (OnLoadTapChanger / TapDefinitionsStore): the user says what the winding IS, the
//  declaration is remembered with the design file, and the program works out what follows from it.
//
//  WHAT IS DECLARED. Only what the design file cannot say: the number of tapping LOOPS (steps) wound. How the winding is
//  arranged - double-stacked, multi-start or a single stack - is read from the design file every time, so a re-exported
//  design picks up a change of arrangement rather than having a stale one restored. The same discipline as TapDefinitionsStore,
//  which saves the user's position count and never the design's turns.
//
//  WHAT FOLLOWS FROM IT, arrangement by arrangement:
//
//  * DOUBLE-STACKED (disc or helical). The two stacks are wound as mirror images about the centre gap and connected in
//    PARALLEL, so every point of the lower stack is tied to the point of the upper stack the same number of turns from the
//    centre. Concretely, with N discs, N/2 per stack and L loops per stack, d = N/(2L) discs per loop:
//
//        - the two outer ends (below disc 1 and above disc N), tied to each other;
//        - the crossover above disc k·d tied to the crossover above disc N − k·d, for k = 1 … L−1 - the tap points, where
//          one loop ends and the next begins;
//        - the two leads facing each other across the centre gap.
//
//    That is L + 1 jumpers. The designer aims for d = 2 (tap leads always on the same side of the winding); what d actually
//    is follows from the disc count and the loop count, and a stack that does not divide evenly into loops is refused rather
//    than rounded, because a rounded tap point is a tap in the wrong place.
//
//    Pinned against SelfTest's T0223TapParallel, which wired exactly this by hand before the declaration existed: 32 discs,
//    8 loops, discs 2-14 against 30-18. VerifySelf() checks the generator reproduces that list jumper for jumper.
//
//  * MULTI-START. The loops are wound side by side, turn beside turn, each over the whole height of the winding, and the end
//    of each loop is tied to the start of the next. The program models the whole winding as ONE lumped BasicSection, so
//    none of those tie points is a node and there is nothing to connect: the joins are implicit in DelVecchio 12.12's series
//    capacitance, where each turn lies beside a turn one loop-voltage away. The declaration records the loop count for that
//    formula. (12.12 is not implemented yet - TODO.md item 2 - so CapacitanceTurnToTurn still refuses the winding type.)
//
//  * SINGLE STACK. Every tap lead goes out to the tap changer and none is tied to another inside the winding, so there are
//    no permanent connections either. The declaration is still worth having: it is what the tap connection scenarios
//    will be built on.
//
//  THE STANDING RULES THIS HAS TO KEEP (CLAUDE.md). Points on the winding are named as Wiring.LeadPoints and FOUND, never
//  computed from axialPos (rule 1). Only jumpers are written - never a termination, and nothing is copied onto a lead because
//  of what it is jumpered to (rule 6). The centre gap is found by its centre-location connectors, the same predicate
//  IsTappingGap uses (rule 5), and a jumper across it is a jumper between two nodes, not a series connection.
//

import Foundation
import PchBasePackage
import PchExcelDesignFilePackage

/// A coil declared as a regulating winding. See the file header.
struct RegulatingWinding: Codable, Sendable, Equatable {

    /// How the winding is built, which is what decides its permanent connections. Always read from the design file, never stored.
    enum Arrangement: Sendable, Equatable {

        /// Two stacks either side of a centre gap, in parallel.
        case doubleStack
        /// Loops wound side by side over the whole height, modelled as one lumped section.
        case multiStart
        /// One stack, every tap lead brought out.
        case singleStack

        var description:String {

            switch self {

            case .doubleStack:
                return "Double-stacked"

            case .multiStart:
                return "Multi-start"

            case .singleStack:
                return "Single stack"
            }
        }

        /// The arrangement a design-file winding has.
        ///
        /// Multi-start is tested first and by either flag, because the design file carries it twice (the winding type and the
        /// `isMultiStart` flag) and AppController models a winding of either kind as the lumped `.multistart` section. A
        /// double-stacked winding is only treated as one when it is built of discs (or helical turns, which the model treats as
        /// one-turn discs): a double-stacked layer or sheet winding is a single BasicSection with no crossovers to tie together.
        static func Of(_ winding:PCH_ExcelDesignFile.Winding) -> Arrangement {

            if winding.windingType == .multistart || winding.isMultiStart {

                return .multiStart
            }

            if winding.isDoubleStack && (winding.windingType == .disc || winding.windingType == .helix) {

                return .doubleStack
            }

            return .singleStack
        }
    }

    /// Why a declaration could not be turned into connections.
    struct DeclarationError: LocalizedError {

        let message:String
        let info:String

        var errorDescription:String? { message }
        var failureReason:String? { info }
    }

    /// The coil, by radial position (0 is closest to the core) - the design file's `Winding.position` and the model's `radialPos`.
    var coil:Int

    /// The tapping loops (steps) wound on the winding. For a double-stacked winding this is the loops in ONE stack - the two
    /// stacks are in parallel, so each carries every loop.
    var numLoops:Int

    // MARK: The permanent connections

    /// The connections that are a permanent part of the winding, as jumpers between named points. Empty for an arrangement that
    /// has none (see the file header).
    ///
    /// Pure arithmetic on the disc count, so that it can be checked without a model (see `VerifySelf`). Whether the model the
    /// jumpers are applied to actually HAS the points they name is `CheckModel`'s question.
    ///
    /// - Parameter numDiscs: the discs in the whole coil, both stacks.
    func PermanentJumpers(arrangement:Arrangement, numDiscs:Int) throws -> [Wiring.Jumper] {

        guard numLoops >= 1 else {

            throw DeclarationError(message: "A regulating winding needs at least one loop.", info: "\(numLoops) loops were given for coil \(coil).")
        }

        guard arrangement == .doubleStack else {

            return []
        }

        // A double-stacked winding is two mirror-image stacks, so it has as many discs above the centre gap as below it.
        guard numDiscs >= 2, numDiscs % 2 == 0 else {

            throw DeclarationError(message: "Coil \(coil) cannot be double-stacked.", info: "It has \(numDiscs) disc(s), and a double-stacked winding needs the same number in each stack.")
        }

        let discsPerStack = numDiscs / 2

        // The tap points have to fall on crossovers, so every loop must be a whole number of discs. Refused rather than rounded:
        // a rounded tap point is a tap in the wrong place, and the result would look perfectly plausible.
        guard discsPerStack % numLoops == 0 else {

            throw DeclarationError(message: "\(discsPerStack) discs per stack do not divide into \(numLoops) loops.", info: "Each tapping loop has to be a whole number of discs, so that every tap point falls on a crossover. Loop counts that work for coil \(coil): \(Self.WholeDiscLoopCounts(discsPerStack: discsPerStack).map({ String($0) }).joined(separator: ", ")).")
        }

        let discsPerLoop = discsPerStack / numLoops

        // The order is outside-in, and it is the order T0223TapParallel lists them in, so that a model wired by the declaration
        // and one wired by that scenario print the same report line for line.
        //
        // The outermost pair: the lead below disc 1 and the lead above disc N.
        var result = [Wiring.Jumper(from: .coilEnd(coil: coil, end: .top), to: .coilEnd(coil: coil, end: .bottom))]

        // The tap points: the crossover above disc k·d is k loops from the bottom end, and its mirror k loops from the top end is
        // the crossover above disc N − k·d. `discCrossover` names a crossover by the disc BELOW it, counting from 1.
        for k in 1..<numLoops {

            let disc = k * discsPerLoop

            result.append(Wiring.Jumper(from: .discCrossover(coil: coil, disc: disc), to: .discCrossover(coil: coil, disc: numDiscs - disc)))
        }

        // The innermost pair: the two leads facing each other across the centre gap. The gap breaks the node chain even though
        // it is bridged (CLAUDE.md rule 5), so this is a jumper between two nodes and not a series connection.
        result.append(Wiring.Jumper(from: .gapLead(coil: coil, gap: 0, side: .bottom), to: .gapLead(coil: coil, gap: 0, side: .top)))

        return result
    }

    /// The loop counts that divide a stack into whole discs, smallest first - what the dialog offers and what a refusal lists.
    static func WholeDiscLoopCounts(discsPerStack:Int) -> [Int] {

        guard discsPerStack >= 1 else {

            return []
        }

        return (1...discsPerStack).filter({ discsPerStack % $0 == 0 })
    }

    /// The loop count a double-stacked winding's dialog opens on: two discs per loop if the stack allows it, which is what a
    /// designer aims for (every tap lead then comes off the same side of the winding), otherwise one.
    static func DefaultLoops(discsPerStack:Int) -> Int {

        return discsPerStack >= 2 && discsPerStack % 2 == 0 ? discsPerStack / 2 : max(discsPerStack, 1)
    }

    /// Whether the coil in `model` is still the winding the design file describes - one disc per Segment and, for a
    /// double-stacked winding, exactly one internal gap, in the middle. Returns the disc count.
    ///
    /// Both conditions are about the NAMES the jumpers use rather than about the physics. Disc numbering means nothing once a
    /// coil has been combined or interleaved (`Wiring.FindLead` refuses it outright), and a double-stacked winding with embedded
    /// off-load taps is cut at the quarter points instead of the centre (AppController.initializeModel), so it has no centre
    /// gap for the innermost pair to cross.
    func CheckModel(_ model:PhaseModel, arrangement:Arrangement) async throws -> Int {

        let coilSegments = await model.CoilSegments().filter({ $0.radialPos == coil })

        guard !coilSegments.isEmpty else {

            throw DeclarationError(message: "Coil \(coil) is not in the model.", info: "The design may have changed since the declaration was made.")
        }

        guard arrangement == .doubleStack else {

            return coilSegments.count
        }

        if let folded = coilSegments.first(where: { $0.basicSections.count != 1 }) {

            throw DeclarationError(message: "Coil \(coil) has been restructured.", info: "Segment \(folded.serialNumber) holds \(folded.basicSections.count) discs. The permanent connections are made at individual crossovers, so declare the regulating winding before combining or interleaving its discs.")
        }

        let numDiscs = coilSegments.count
        let gaps = await Wiring.InternalGaps(coil: coil, model: model)

        guard gaps.count == 1, numDiscs % 2 == 0, gaps[0].below == coilSegments[numDiscs / 2 - 1] else {

            throw DeclarationError(message: "Coil \(coil) does not have a single centre gap.", info: "A double-stacked regulating winding is built as two stacks either side of a centre gap, but this coil has \(gaps.count) internal gap(s)\(gaps.count == 1 ? " away from the centre" : ""). A double-stacked winding with off-load taps in it is cut at the quarter points instead, and is not a regulating winding.")
        }

        return numDiscs
    }

    // MARK: Putting the connections on and taking them off

    /// What `Apply` did.
    struct Outcome {

        /// The jumpers put on.
        let made:Int
        /// The jumpers that were already there, and were left alone rather than doubled.
        let alreadyThere:Int
        /// One line per jumper, for anyone who wants to see what went where.
        let log:[String]
    }

    /// Put the winding's permanent connections onto `model`.
    ///
    /// Every lead is found before any jumper goes on, so a declaration that cannot be applied leaves the model as it was rather
    /// than half-wired. A jumper that is already there - put on by an earlier application, or by hand - is left alone, so
    /// applying a declaration twice is the same as applying it once.
    ///
    /// Coil-end leads are accepted even when already grounded or impulsed (`acceptTerminated`): the connections are part of the
    /// winding whatever the user has done to its ends, and a jumper appends beside a termination rather than replacing it.
    func Apply(to model:PhaseModel, arrangement:Arrangement) async throws -> Outcome {

        let numDiscs = try await CheckModel(model, arrangement: arrangement)
        let jumpers = try PermanentJumpers(arrangement: arrangement, numDiscs: numDiscs)

        for nextJumper in jumpers {

            for nextPoint in [nextJumper.from, nextJumper.to] {

                if case .failed(let why) = await Wiring.FindLead(nextPoint, model: model, acceptTerminated: true) {

                    throw DeclarationError(message: "Coil \(coil)'s permanent connections could not be made.", info: "\(Wiring.Describe(nextPoint)): \(why). Nothing was connected.")
                }
            }
        }

        var made = 0
        var alreadyThere = 0
        var log:[String] = []

        for nextJumper in jumpers {

            if await Wiring.IsApplied(nextJumper, model: model) {

                alreadyThere += 1
                log.append("\(Wiring.Describe(nextJumper)): already connected")
                continue
            }

            switch await Wiring.ApplyJumper(nextJumper, model: model, acceptTerminated: true) {

            case .made(let count, let fromSegment, let fromLocation, let toSegment, let toLocation):

                made += 1
                log.append("\(Wiring.Describe(nextJumper)): \(count) connector(s) from segment \(fromSegment) (\(fromLocation)) to segment \(toSegment) (\(toLocation))")

            case .failed(let why):

                // Every lead was found above, so this is a failure inside AddConnector itself rather than a bad declaration.
                // The jumpers already made stay: they are correct, and taking them back out would need the same machinery
                // that has just failed.
                throw DeclarationError(message: "Coil \(coil)'s permanent connections were only partly made.", info: "\(Wiring.Describe(nextJumper)): \(why). \(made) of \(jumpers.count) were connected before this one.")
            }
        }

        return Outcome(made: made, alreadyThere: alreadyThere, log: log)
    }

    /// Take the winding's permanent connections back off `model`, the way the user would with *Remove Connection*. Used when a
    /// declaration is changed or withdrawn, so that the old tap points do not stay tied alongside the new ones.
    ///
    /// Best-effort by design: a jumper the user has already removed by hand is simply not there, and a coil that has since been
    /// restructured has no crossovers left to find. Neither is an error. Returns how many were removed.
    @discardableResult
    func Remove(from model:PhaseModel, arrangement:Arrangement) async -> Int {

        guard let numDiscs = try? await CheckModel(model, arrangement: arrangement), let jumpers = try? PermanentJumpers(arrangement: arrangement, numDiscs: numDiscs) else {

            return 0
        }

        var removed = 0

        for nextJumper in jumpers {

            if await Wiring.RemoveJumper(nextJumper, model: model) {

                removed += 1
            }
        }

        return removed
    }

    // MARK: Verification

    /// Pin `PermanentJumpers` to the one double-stacked wiring that was worked out by hand before the declaration existed, and to
    /// its refusals. Writes its report to UserDefaults like the other `VerifySelf`s:
    ///
    ///     open -a ImpulseDistribution --args -PCH_Verify YES
    ///     defaults read com.huberistech.ImpulseDistribution RegulatingWindingVerification
    static func VerifySelf() {

        var report:[String] = []
        var failures = 0

        func check(_ name:String, _ passed:Bool, _ detail:String) {

            if !passed { failures += 1 }
            report.append("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
        }

        // 1. T0223's coil 3: 32 discs, 8 loops per stack, two discs per loop. SelfTest.T0223TapParallel lists these nine by hand.
        var expected = [Wiring.Jumper(from: .coilEnd(coil: 3, end: .top), to: .coilEnd(coil: 3, end: .bottom))]

        for disc in stride(from: 2, through: 14, by: 2) {

            expected.append(Wiring.Jumper(from: .discCrossover(coil: 3, disc: disc), to: .discCrossover(coil: 3, disc: 32 - disc)))
        }

        expected.append(Wiring.Jumper(from: .gapLead(coil: 3, gap: 0, side: .bottom), to: .gapLead(coil: 3, gap: 0, side: .top)))

        let t0223 = try? RegulatingWinding(coil: 3, numLoops: 8).PermanentJumpers(arrangement: .doubleStack, numDiscs: 32)
        check("T0223 32 discs / 8 loops", t0223 == expected, "\(t0223?.count ?? -1) jumpers, expected \(expected.count) matching T0223TapParallel")

        // 2. One disc per loop: every crossover in the lower stack is a tap point. L + 1 jumpers, the last tap at disc 15 / 17.
        if let perDisc = try? RegulatingWinding(coil: 0, numLoops: 16).PermanentJumpers(arrangement: .doubleStack, numDiscs: 32) {

            let lastTap = perDisc[perDisc.count - 2]
            check("32 discs / 16 loops", perDisc.count == 17 && lastTap == Wiring.Jumper(from: .discCrossover(coil: 0, disc: 15), to: .discCrossover(coil: 0, disc: 17)), "\(perDisc.count) jumpers, last tap \(Wiring.Describe(lastTap))")
        }
        else {

            check("32 discs / 16 loops", false, "refused")
        }

        // 3. One loop: just the paralleling of the two stacks, ends and centre.
        let oneLoop = try? RegulatingWinding(coil: 0, numLoops: 1).PermanentJumpers(arrangement: .doubleStack, numDiscs: 32)
        check("32 discs / 1 loop", oneLoop?.count == 2, "\(oneLoop?.count ?? -1) jumpers, expected 2")

        // 4. The refusals. 16 discs per stack do not divide into 5 loops; 33 discs cannot be two equal stacks; no loops at all.
        check("16 per stack / 5 loops refused", (try? RegulatingWinding(coil: 0, numLoops: 5).PermanentJumpers(arrangement: .doubleStack, numDiscs: 32)) == nil, "")
        check("odd disc count refused", (try? RegulatingWinding(coil: 0, numLoops: 1).PermanentJumpers(arrangement: .doubleStack, numDiscs: 33)) == nil, "")
        check("zero loops refused", (try? RegulatingWinding(coil: 0, numLoops: 0).PermanentJumpers(arrangement: .doubleStack, numDiscs: 32)) == nil, "")

        // 5. The arrangements with nothing to connect.
        check("multi-start is lumped", (try? RegulatingWinding(coil: 0, numLoops: 8).PermanentJumpers(arrangement: .multiStart, numDiscs: 1)) == [], "")
        check("single stack has no ties", (try? RegulatingWinding(coil: 0, numLoops: 8).PermanentJumpers(arrangement: .singleStack, numDiscs: 32)) == [], "")

        // 6. The loop counts offered for a 16-disc stack, and the default.
        check("whole-disc loop counts", WholeDiscLoopCounts(discsPerStack: 16) == [1, 2, 4, 8, 16] && DefaultLoops(discsPerStack: 16) == 8 && DefaultLoops(discsPerStack: 7) == 7, "")

        report.insert("RegulatingWinding.VerifySelf: \(failures == 0 ? "all passed" : "\(failures) FAILED")", at: 0)
        UserDefaults.standard.set(report.joined(separator: "\n"), forKey: "RegulatingWindingVerification")
    }
}

/// Reads and writes the regulating-winding declarations of each design file. A port of PchMagneticFlux's `TapDefinitionsStore`.
///
/// The app is sandboxed with `user-selected.read-write`, which grants the design file the user opened and nothing beside it, so
/// this cannot be a sidecar file next to the design. It is one JSON file in the app's own Application Support directory, holding a
/// record per design, keyed by the design file's path.
///
/// Saving is best-effort: nothing here ever stops the app doing what the user asked. A failure is logged and the declarations stay
/// in force for the session.
struct RegulatingWindingStore: Sendable {

    /// One design's record.
    struct Record: Codable, Sendable {

        /// The design file's path when it was last saved
        var path:String
        /// Its file name, which is what finds it again after a design has been moved
        var name:String
        var windings:[RegulatingWinding]
    }

    struct File: Codable, Sendable {

        /// Bumped if the shape of what is stored ever changes
        var version:Int = 1
        var designs:[Record] = []
    }

    let url:URL

    static let shared = RegulatingWindingStore(url: RegulatingWindingStore.defaultURL())

    /// `~/Library/Containers/com.huberistech.ImpulseDistribution/Data/Library/Application Support/ImpulseDistribution/RegulatingWindings.json`
    /// - inside the sandbox container, so it needs no permission of any kind.
    static func defaultURL() -> URL {

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory

        return support.appendingPathComponent("ImpulseDistribution", isDirectory: true).appendingPathComponent("RegulatingWindings.json")
    }

    /// The key a design is filed under.
    static func key(for designFile:URL) -> String {

        return designFile.standardizedFileURL.path
    }

    func read() -> File {

        guard let data = try? Data(contentsOf: url) else { return File() }

        do {

            return try JSONDecoder().decode(File.self, from: data)
        }
        catch {

            DLog("The regulating-winding file could not be read (\(error)); starting a new one")
            return File()
        }
    }

    /// What was declared for a design, if anything.
    ///
    /// A design that is not found by its path is looked for by file name, but only where the saved path no longer exists - that
    /// is a design that has been moved. Where more than one record shares the name, none is used.
    func windings(for designFile:URL) -> [RegulatingWinding] {

        let file = read()
        let wanted = Self.key(for: designFile)

        if let exact = file.designs.first(where: { $0.path == wanted }) {

            return exact.windings
        }

        let byName = file.designs.filter({ $0.name == designFile.lastPathComponent && !FileManager.default.fileExists(atPath: $0.path) })

        return byName.count == 1 ? byName[0].windings : []
    }

    /// Store a design's declarations, replacing whatever was there. An empty list removes the record.
    func save(_ windings:[RegulatingWinding], for designFile:URL) {

        var file = read()
        let wanted = Self.key(for: designFile)

        file.designs.removeAll(where: { $0.path == wanted })

        // A design that has been moved leaves a record under its old path that would otherwise be found again by name.
        file.designs.removeAll(where: { $0.name == designFile.lastPathComponent && !FileManager.default.fileExists(atPath: $0.path) })

        if !windings.isEmpty {

            file.designs.append(Record(path: wanted, name: designFile.lastPathComponent, windings: windings.sorted(by: { $0.coil < $1.coil })))
        }

        write(file)
    }

    private func write(_ file:File) {

        do {

            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            try encoder.encode(file).write(to: url, options: .atomic)
        }
        catch {

            DLog("The regulating-winding declarations could not be saved: \(error)")
        }
    }
}
