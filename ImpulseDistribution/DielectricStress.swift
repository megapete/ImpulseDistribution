//
//  DielectricStress.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-08-05.
//
//  Electric stress (V/m) screening of an impulse simulation result.
//
//  The point of this file is to find the APPROXIMATE LOCATIONS in a design that need to be redesigned or
//  built with extra care. It is not a substitute for a finite-element study, and it does not try to be:
//  see the accuracy notes on each routine, and the summary in CLAUDE.md.
//
//  Why this does not need FE. Every capacitance routine in Segment.swift is already a series-dielectric
//  reduction, and that reduction IS the field solution. Segment.DiscToDiscSeriesCapacitance forms
//  Σ(ℓ/ε) over the layers in a gap; continuity of the normal component of D then gives the field in each
//  layer directly, with no further approximation:
//
//      D = ε0·V / Σ(ℓⱼ/εⱼ)                     (Gauss, applied across a laminar stack)
//      E_i = D/(ε0·ε_i) = V / (ε_i · Σ(ℓⱼ/εⱼ))
//
//  So the whole screen is a reuse of the geometry the capacitance code already measures, evaluated per
//  gap per time step: of the order of 200 gaps × 2000 steps, i.e. milliseconds. A finite-element solve
//  per time step would be hours.
//
//  THE ALLOWABLES COME FROM DELVECCHIO CHAPTER 13, "Voltage Breakdown Theory and Practice", and they are
//  functions of distance, not constants. See StressAllowable for the equations and their citations. Four
//  distinctions in there must not be collapsed:
//
//      strike (through a gap)      vs   creep (along a surface) - different formulas, different exponents
//      power frequency (rms)       vs   impulse (peak)          - a factor of ~2.8 for oil
//      the design margin           vs   the 50% breakdown level  - the book's data are the latter
//      distance-dependent          vs   a single number          - a factor of two across one coil's gaps
//
//  In particular Segment.woundInShieldMaxWorkingStress (2755 V/mm, 70 V/mil) is a POWER-FREQUENCY working
//  turn-to-turn stress used to size the paper on a wound-in shield. It is not an impulse allowable and is
//  deliberately not used here.
//
//  The average field is the number that carries a margin. The peak (corner) field is reported alongside
//  it as information only: chapter 13's data are uniform-gap measurements compared against AVERAGE fields
//  by the book's own path-subdivision procedure (p.371), so there is no sourced allowable for a corner
//  peak, and inventing one would put a fabricated number beside cited ones.
//
//  WHAT THIS SCREENS, AND WHAT IT DOES NOT. Every check here is a STRIKE check - breakdown through a gap,
//  across a stack of solid and liquid layers whose thicknesses the model knows. There is no CREEP check:
//  creep sites were built until 2026-08-06 and were removed because the model cannot measure a creep path
//  (a hilo barrier's overhang past the coil ends, and the angle rings and caps on it at high voltage, are
//  not in PhaseModel). The chapter 13 creep allowables are still in StressAllowable, unused and still
//  self-tested; the note above StressAllowable.CreepPowerFrequency says what has to exist first. Until
//  then, creep is a gap in the screen's coverage rather than a clean bill of health - and since creep
//  strength falls with distance far faster than strike strength does, it is not a small gap.
//

import Foundation
import PchBasePackage

/// One layer of a series-dielectric stack, in physical order from the reference electrode outwards.
///
/// Thicknesses are in metres and permittivities are relative (the program's oil-filled values live in
/// PchBasePackage: εPaper 3.5, εOil 2.2, εBoard 4.5).
struct DielectricLayer:Sendable, Equatable {

    /// The layer's thickness, in metres.
    let thickness:Double

    /// The layer's relative permittivity.
    let epsilonR:Double

    /// What the layer is made of. This is carried so that a computed field can be judged against the
    /// right allowable - oil and kraft fail at very different stresses - and so the report can name the
    /// material that is actually in trouble rather than just the gap it sits in.
    let material:Material

    enum Material:String, Sendable, CaseIterable {

        case oil = "Oil"
        case paper = "Kraft paper"
        case pressboard = "Pressboard"
    }

    init(thickness:Double, epsilonR:Double, material:Material) {

        self.thickness = thickness
        self.epsilonR = epsilonR
        self.material = material
    }

    /// A paper layer of the given thickness, at the program's oil-soaked kraft permittivity.
    static func Paper(_ thickness:Double) -> DielectricLayer {

        return DielectricLayer(thickness: thickness, epsilonR: εPaper, material: .paper)
    }

    /// An oil layer of the given thickness.
    static func Oil(_ thickness:Double) -> DielectricLayer {

        return DielectricLayer(thickness: thickness, epsilonR: εOil, material: .oil)
    }

    /// A pressboard layer (key spacer, stick, or barrier) of the given thickness.
    static func Pressboard(_ thickness:Double) -> DielectricLayer {

        return DielectricLayer(thickness: thickness, epsilonR: εBoard, material: .pressboard)
    }
}

/// Namespace for the stress calculations. Everything here is a pure function of geometry and voltage;
/// there is no state, in the style of AxisScale.
enum DielectricStress {

    // MARK: Constants

    /// The corner radius used when the strand dimensions are not known, in metres. 0.81 mm is about
    /// 1/32", and it is the Essex/ASTM value for the middle of the range of strand sizes a disc winding
    /// actually uses, so it is the right thing to fall back to.
    ///
    /// It is a fallback and nothing more. `CornerRadius(thickness:width:)` below reads the real figure
    /// off the manufacturer's table from the bare strand's own dimensions; this constant is what a
    /// StressSite gets when those dimensions are zero - a static ring, a radial shield, or a design file
    /// that did not carry a cable definition.
    ///
    /// Sensitivity: the corner enhancement goes roughly as sqrt(gap/r), so a factor-of-2 error in the
    /// radius is about a factor of 1.4 in the peak column.
    static let defaultCornerRadiusOnCopper = 0.81E-3

    // MARK: The manufacturer's corner-radius table

    /// The corner radius of the bare copper of a rectangular conductor, in metres, from the specified
    /// dimensions of the strand.
    ///
    /// SOURCE: Essex *Magnet Wire / Winding Wire Engineering Data*, p. 54, "RECTANGULAR, BARE WIRE -
    /// DIMENSIONAL LIMITS", the table headed "RADII IN INCHES AND MM (In Inches of Corners of Square and
    /// Rectangular Wire)". Essex in turn cites ASTM B 48 (soft rectangular and square bare copper wire),
    /// so these are the industry limits rather than one supplier's practice. The document is
    /// `~/Documents/MyProjects/Claude/EssexCornerRadius.pdf`.
    ///
    /// The table is two-dimensional - the radius depends on BOTH strand dimensions, and strongly. A
    /// 4 x 10 mm strand gets 0.81 mm while a 6 x 10 mm strand gets 1.02 mm and a 12 x 25 mm strand gets
    /// 3.18 mm, which is a factor of four across sizes that all appear in ordinary disc coils. That is
    /// why this cannot be one constant: the peak column moves as 1/sqrt(r).
    ///
    /// THICKNESS IS THE SMALLER DIMENSION. The table's rows are the thickness and its columns the width,
    /// and rectangular wire is specified thickness-by-width, so the two arguments are sorted here rather
    /// than trusting the caller to know which of strandRadial/strandAxial is which.
    ///
    /// Two entries in the table are not radii:
    ///
    ///  - **"Rounded Edge"** - too thin to hold a specified corner, so the edge is a full half-round.
    ///    The page's own note says such an edge has "corner radii that are essentially half the thickness
    ///    of the wire", which is what is returned.
    ///  - **blank** - thickness bands above 0.226 in. have no entry under the narrowest width band,
    ///    because that would be a wire thicker than it is wide. Unreachable once the arguments are
    ///    sorted; treated as a full round if it ever is reached.
    ///
    /// The footnote on the 0.096 in. row is a separate rule for SQUARE wire and is applied first: "Square
    /// wire 0.072 in. (1.83 mm) and under shall have a corner radius of 0.012 in. (.30 mm) +/- 25%."
    ///
    /// INCHES OR MM: the table prints both, and the two disagree slightly in two cells - it gives
    /// 0.039 in. as 1.02 mm (exactly 0.99) and 0.031 in. as 0.81 mm (exactly 0.79). The printed MILLIMETRE
    /// values are used for the radii, since this program is metric throughout and 0.81 mm is the figure
    /// the whole file was built on; the exact inch conversions are used for the band BOUNDARIES, where
    /// the two agree to within 0.005 mm everywhere except the 0.189 in. edge (printed 4.79, exactly 4.80).
    ///
    /// - Parameter thickness: one bare-copper dimension of the strand, in metres.
    /// - Parameter width: the other, in metres. Order does not matter.
    /// - Returns: the corner radius in metres, or `defaultCornerRadiusOnCopper` if either dimension is
    /// missing or nonsensical.
    static func CornerRadius(thickness:Double, width:Double) -> Double {

        guard thickness > 0.0, width > 0.0, thickness.isFinite, width.isFinite else {

            return defaultCornerRadiusOnCopper
        }

        let t = min(thickness, width)
        let w = max(thickness, width)

        // The square-wire footnote, which overrides the table. The tolerance is there because a design
        // file's two dimensions for a square strand are separate numbers and need not be bit-identical;
        // 1% is far tighter than the gap to the next standard size and far looser than float noise.
        if w <= t * 1.01, t <= 0.072 * meterPerInch {

            return 0.30E-3
        }

        for row in cornerRadiusTable where t < row.underThickness {

            switch w >= 0.751 * meterPerInch ? row.wide : (w >= 0.189 * meterPerInch ? row.medium : row.narrow) {

            case .radius(let r): return r
            case .roundedEdge, .notTabulated: return t / 2.0
            }
        }

        // Unreachable: the last row's bound is infinite.
        return defaultCornerRadiusOnCopper
    }

    /// One cell of the corner-radius table.
    private enum CornerRadiusEntry {

        /// A specified radius, in metres.
        case radius(Double)
        /// Too thin for a specified corner - the edge is a full half-round of the thickness.
        case roundedEdge
        /// No entry, because the thickness band exceeds the width band. See CornerRadius.
        case notTabulated
    }

    /// One row of the corner-radius table: a thickness band and its three width columns.
    private struct CornerRadiusRow {

        /// The row applies to thicknesses strictly BELOW this. The table's rows read "Under X to Y Incl.",
        /// so each band is closed at the bottom and open at the top, and the rows are stored in ascending
        /// order so that the first match is the right one.
        let underThickness:Double
        /// Width 0.751 in. (19.08 mm) and over.
        let wide:CornerRadiusEntry
        /// Width 0.189 to 0.750 in. (4.79 to 19.07 mm) incl.
        let medium:CornerRadiusEntry
        /// Width up to 0.188 in. (4.78 mm) incl.
        let narrow:CornerRadiusEntry
    }

    /// The Essex p.54 table verbatim, thinnest row first. See CornerRadius for the source and the reading.
    ///
    ///     thickness (in.)          >= 0.751     0.189-0.750   <= 0.188
    ///     0.689 and over           0.188        0.188         -
    ///     under 0.689 to 0.439     0.125        0.094         -
    ///     under 0.439 to 0.226     0.094        0.039         -
    ///     under 0.226 to 0.166     0.063        0.039         0.039
    ///     under 0.166 to 0.126     0.063        0.031         0.031
    ///     under 0.126 to 0.096     rounded      0.031         0.026
    ///     under 0.096 to 0.061     rounded      0.031         0.020
    ///     under 0.061              rounded      rounded       rounded
    private static let cornerRadiusTable:[CornerRadiusRow] = [

        CornerRadiusRow(underThickness: 0.061 * meterPerInch, wide: .roundedEdge,      medium: .roundedEdge,     narrow: .roundedEdge),
        CornerRadiusRow(underThickness: 0.096 * meterPerInch, wide: .roundedEdge,      medium: .radius(0.81E-3), narrow: .radius(0.51E-3)),
        CornerRadiusRow(underThickness: 0.126 * meterPerInch, wide: .roundedEdge,      medium: .radius(0.81E-3), narrow: .radius(0.66E-3)),
        CornerRadiusRow(underThickness: 0.166 * meterPerInch, wide: .radius(1.60E-3),  medium: .radius(0.81E-3), narrow: .radius(0.81E-3)),
        CornerRadiusRow(underThickness: 0.226 * meterPerInch, wide: .radius(1.60E-3),  medium: .radius(1.02E-3), narrow: .radius(1.02E-3)),
        CornerRadiusRow(underThickness: 0.439 * meterPerInch, wide: .radius(2.39E-3),  medium: .radius(1.02E-3), narrow: .notTabulated),
        CornerRadiusRow(underThickness: 0.689 * meterPerInch, wide: .radius(3.18E-3),  medium: .radius(2.39E-3), narrow: .notTabulated),
        CornerRadiusRow(underThickness: .infinity,            wide: .radius(4.78E-3),  medium: .radius(4.78E-3), narrow: .notTabulated)
    ]

    // MARK: The two field reductions

    /// The "reduced thickness" Σ(ℓⱼ/εⱼ) of a laminar stack, in metres.
    ///
    /// This is the quantity DelVecchio 12.51/12.52 divide by, so it is exactly what
    /// Segment.DiscToDiscSeriesCapacitance needs, and it is the denominator of the laminar field below.
    /// Sharing it is deliberate: the capacitance and the stress must never be able to disagree about
    /// what is in a gap.
    static func ReducedThickness(_ layers:[DielectricLayer]) -> Double {

        return layers.reduce(0.0) { $0 + $1.thickness / $1.epsilonR }
    }

    /// The field in each layer of a laminar (parallel-plate) stack carrying 'volts' across it, in V/m.
    ///
    /// Derivation. The normal component of D is continuous across every interface, so D is the same in
    /// every layer. With D = ε0·ε_i·E_i and V = Σ E_i·ℓ_i:
    ///
    ///     V = Σ (D/(ε0·ε_i))·ℓ_i = (D/ε0)·Σ(ℓ_i/ε_i)   =>   D/ε0 = V / Σ(ℓ_i/ε_i)
    ///     E_i = V / (ε_i · Σ(ℓⱼ/εⱼ))
    ///
    /// This is EXACT for an infinite parallel-plate stack - there is no approximation in it at all. The
    /// error against a finite-element solution of a real disc-to-disc gap is the finite radial width of
    /// the disc, and it is confined to within about one gap width of the disc's edges: 2-5% in the bulk.
    /// What it does NOT capture is the field concentration at a conductor corner; that is what
    /// CornerField below is for.
    ///
    /// The field is uniform within each layer, so the returned value is both the average and the peak
    /// for that layer. Returns an empty array for an empty or degenerate stack.
    static func LaminarField(volts:Double, layers:[DielectricLayer]) -> [Double] {

        let reduced = ReducedThickness(layers)

        guard reduced > 0.0, volts.isFinite else {

            return []
        }

        return layers.map { abs(volts) / ($0.epsilonR * reduced) }
    }

    /// The field at the INNER surface of each layer of a coaxial stack carrying 'volts' across it, in V/m.
    ///
    /// Derivation. For a cylindrical geometry with line charge λ, Gauss gives D(r) = λ/(2πr), so
    /// E_i(r) = λ/(2π·ε0·ε_i·r) and
    ///
    ///     V = Σ ∫ E_i dr = (λ/(2π·ε0))·Σ (1/ε_j)·ln(r_j/r_{j−1})
    ///     E_i(r) = V / (ε_i · r · Σ_j (1/ε_j)·ln(r_j/r_{j−1}))
    ///
    /// The field falls as 1/r within a layer, so its maximum is at the layer's INNER radius, which is
    /// what is returned.
    ///
    /// This one routine does double duty, and the two uses are four orders of magnitude apart in radius:
    ///
    ///  - At hilo dimensions (r ≈ 0.3 m, gap ≈ 0.02 m) it is the coil-to-coil field. It differs from the
    ///    laminar result by only about 3% there, but it costs nothing to do properly.
    ///  - At r ≈ 0.8 mm it IS the conductor-corner model (see CornerField). The enhancement over the
    ///    laminar value emerges from the geometry rather than being a tabulated multiplier.
    ///
    /// Sanity check, and the reason the laminar limit is worth stating: as r → ∞ at fixed thicknesses,
    /// ln(r_j/r_{j−1}) → ℓ_j/r, so the sum → (1/r)·Σ(ℓ_j/ε_j) and E_i → V/(ε_i·Σ(ℓ/ε)), which is exactly
    /// LaminarField. VerifySelf() checks this numerically at r/d = 100.
    ///
    /// - Parameter innerRadius: the radius of the reference electrode, in metres - the surface the first
    /// layer sits on.
    static func CoaxialField(volts:Double, layers:[DielectricLayer], innerRadius:Double) -> [Double] {

        guard innerRadius > 0.0, volts.isFinite, !layers.isEmpty else {

            return []
        }

        // Accumulate the radii of every interface, then the weighted log sum.
        var radii:[Double] = [innerRadius]
        for layer in layers {

            radii.append(radii.last! + layer.thickness)
        }

        var logSum = 0.0
        for (i, layer) in layers.enumerated() {

            logSum += log(radii[i + 1] / radii[i]) / layer.epsilonR
        }

        guard logSum > 0.0 else {

            return []
        }

        return layers.enumerated().map { (i, layer) in

            abs(volts) / (layer.epsilonR * radii[i] * logSum)
        }
    }

    /// The peak field in each layer at a conductor CORNER, in V/m.
    ///
    /// The corner is treated locally as a cylinder of radius 'cornerRadius' carrying the same concentric
    /// dielectric layers that the flat part of the gap carries - which is precisely the geometry
    /// CoaxialField already solves, so there is no separate model and no tabulated enhancement factor
    /// here. The RADIUS is tabulated, by the wire manufacturer; see CornerRadius(thickness:width:).
    ///
    /// Note what the caller must get right: the paper FOLLOWS the corner, so the copper corner radius is
    /// where the paper's field is read and the paper's outer radius is where the oil's field is read.
    /// Both fall out of passing the stack in physical order starting at the copper.
    ///
    /// Worked example, kept here as a regression anchor. A 4 mm oil duct between two discs each wrapped
    /// with 0.4 mm of paper per face (that is, a two-sided turnInsulation of 0.8 mm), εPaper 3.5,
    /// εOil 2.2, so the stack is paper 0.4 / oil 4.0 / paper 0.4, at the 0.81 mm default radius:
    ///
    ///     laminar:  Σ(ℓ/ε) = 0.4/3.5 + 4.0/2.2 + 0.4/3.5 = 2.0468 mm,  E_oil = V/4.5029 per mm
    ///     corner:   radii 0.81 -> 1.21 -> 5.21 -> 5.61 mm,  Σ(1/ε)ln(r/r) = 0.79942
    ///               E_oil at r = 1.21 mm = V/2.1281 per mm
    ///     enhancement = 4.5029/2.1281 = 2.12x
    ///
    /// A drift in that 2.12 means the two-sided/per-side halving of the turn insulation has been changed,
    /// or the outer radius no longer includes the facing disc's paper. VerifySelf() asserts it.
    ///
    /// ACCURACY, honestly: this is biased HIGH, by roughly 20-30% against a finite-element solution of
    /// the same corner. A real corner is a three-dimensional quarter-toroid rather than an infinite
    /// cylinder, and the facing electrode is a flat disc face rather than a concentric cylinder; both
    /// make the true field lower than this model says. Over-predicting is the right direction for a
    /// screen, so do NOT "correct" the conservatism - the number is used to decide where to look, and
    /// the cost of a false alarm is one FE run while the cost of a miss is a failed coil.
    ///
    /// - Parameter cornerRadius: the strand's corner radius in metres, normally from
    /// CornerRadius(thickness:width:). Defaults to the fallback constant so that the doc comment's
    /// worked example above, and VerifySelf's anchor on it, keep meaning what they say.
    static func CornerField(volts:Double, layers:[DielectricLayer], cornerRadius:Double = defaultCornerRadiusOnCopper) -> [Double] {

        return CoaxialField(volts: volts, layers: layers, innerRadius: cornerRadius)
    }

    // MARK: Allowables

    /// Breakdown strengths from DelVecchio, *Transformer Design Principles*, **chapter 13** ("Voltage Breakdown Theory and
    /// Practice"). Everything here returns V/m and takes metres, converting to the book's kV/mm and mm internally.
    ///
    /// FOUR THINGS THESE ARE NOT INTERCHANGEABLE ACROSS, and conflating any of them gives a wrong answer:
    ///
    ///  1. **Strike versus creep.** Strike is breakdown THROUGH a gap; creep is tracking ALONG a solid surface in oil. DelVecchio
    ///     §13.2.3 (p.372): "Since breakdown along such surfaces generally occurs at a lower stress than breakdown in the oil or air
    ///     through the gap itself, surface breakdown is often design limiting." They have separate formulas and separate exponents.
    ///  2. **Power frequency versus impulse.** The impulse ratio is about 2.8 for oil (13.30), ~2.7 for paper, ~3.0 for pressboard.
    ///     A 60 Hz working stress is NOT an impulse allowable. In particular Segment.woundInShieldMaxWorkingStress (2755 V/mm,
    ///     70 V/mil) is a POWER-FREQUENCY working turn-to-turn figure used to size shield paper, and must never be used here.
    ///  3. **rms versus peak.** The a.c. formulas are rms, the impulse formulas are peak. The simulation produces instantaneous
    ///     volts, so the impulse (peak) forms are the ones that compare like with like.
    ///  4. **Distance dependence.** These are NOT constants. Every one falls with the distance it acts over, which is why they are
    ///     functions. Using a single number for an oil duct would be wrong by a factor of two across the range of gaps in one coil.
    ///
    /// The distance dependence is also what makes this screen match the book's own recommended procedure for non-uniform fields
    /// (p.371): "subdivide a possible breakdown path into equal-length subdivisions and calculate the average electric field over
    /// each subdivision. The maximum of these average fields is then compared with the breakdown value corresponding to a gap length
    /// equal to the subdivision length." Each dielectric layer is one such subdivision, and it is compared against the value for its
    /// own thickness.
    ///
    /// These are 50%-probability BREAKDOWN levels, not design levels - p.368: "some margin below these levels would be needed in
    /// actual design". See `designMargin`.
    enum StressAllowable {

        /// The fraction of the 50%-breakdown level that is treated as allowable. **This is a user preference**
        /// (`Preference.dielectricDesignMargin`, factory default 0.65) rather than a constant, because it is the one number here
        /// that is a house rule and not a citation.
        ///
        /// WHAT THE BOOK ACTUALLY SAYS, since this used to claim more than it should. Chapter 13 states clearly that a margin is
        /// needed and never says how big it should be - p.368: "Generally, the breakdown voltages are those for which the
        /// probability of breakdown is 50%. Thus, some margin below these levels would be needed in actual design." The only
        /// number in the chapter is in one worked example, the cylinder-to-ground-plane calculation on p.382, whose Figure 13.5
        /// is captioned "Breakdown kV with a 20% margin" - and the disk-disk examples on the very next page quote their results
        /// (30.0, 34.0, 40.0 kV/mm impulse) with no margin at all. So 0.80 was one figure's choice in a different geometry, not
        /// a recommendation.
        ///
        /// It is worth knowing what the setting does and does not affect. Every allowable is multiplied by it, so every
        /// utilization in the report scales as 1/margin: it moves the PASS/FAIL LINE and cannot change the worst-first ranking,
        /// which is what the screen is actually for. Set it to 1.0 and the report reads as a straight percentage of the book's
        /// 50%-breakdown level.
        static var designMargin:Double {

            return Preferences.dielectricDesignMargin
        }

        /// The impulse ratio applied to a power-frequency CREEP figure to get an impulse one.
        ///
        /// The book gives creep breakdown only at power frequency (13.15, 13.16); it gives impulse ratios for oil (~2.8, used to
        /// derive 13.30 from 13.27), paper (~2.7) and pressboard (~3.0), but none specifically for creep. Creep along a pressboard
        /// surface in oil is an oil-adjacent process, so the oil ratio is used. **This extrapolation is not in the book** - it is
        /// the one number here that is an assumption rather than a citation, and it is isolated as a constant for that reason.
        static let creepImpulseRatio = 2.8

        // MARK: Strike - breakdown through a gap

        /// Planar oil gap under IMPULSE, V/m peak. DelVecchio 13.30: E = 50·d^(−0.36) kV/mm with d in mm.
        ///
        /// This is 13.27's a.c. figure (17.8·d^(−0.36) rms, from Moser's degassed-oil, non-insulated-electrode data) scaled by the
        /// 2.8 impulse ratio, exactly as the book derives it.
        static func OilImpulse(gap:Double) -> Double {

            return PowerLaw(coefficient: 50.0, exponent: 0.36, distance: gap)
        }

        /// Planar oil gap at power frequency, V/m rms. DelVecchio 13.27: E = 17.8·d^(−0.36) kV/mm.
        static func OilPowerFrequency(gap:Double) -> Double {

            return PowerLaw(coefficient: 17.8, exponent: 0.36, distance: gap)
        }

        /// Oil-impregnated kraft paper under IMPULSE, V/m peak. DelVecchio 13.4 (Palmer and Sharpley, at 90 °C):
        /// E = 79.43·d^(−0.275) kV/mm. The book notes the level rises about 10% going from 90 °C to 20 °C; that bonus is NOT taken
        /// here, since a transformer under test is warm and the hot figure is the conservative one.
        static func PaperImpulse(thickness:Double) -> Double {

            return PowerLaw(coefficient: 79.43, exponent: 0.275, distance: thickness)
        }

        /// Kraft paper at power frequency, V/m rms. DelVecchio 13.5 (Clark, room temperature): E = 32.8·d^(−0.33) kV/mm.
        static func PaperPowerFrequency(thickness:Double) -> Double {

            return PowerLaw(coefficient: 32.8, exponent: 0.33, distance: thickness)
        }

        /// Pressboard under IMPULSE, V/m peak. DelVecchio 13.8 (Palmer and Sharpley, pressboard in oil at 90 °C):
        /// E = 91.2·d^(−0.26) kV/mm.
        ///
        /// The book gives two pressboard pairs and this is the HOTTER of them. 13.7 (Moser, room temperature) is the alternative,
        /// available below. 13.8 is used here for two reasons: it is the more conservative of the two at every thickness in the
        /// range this program sees, and it keeps the temperature assumption consistent with the paper figures, where 13.4 is also a
        /// 90 °C measurement and its 10% room-temperature bonus is deliberately declined. The book notes the difference is real and
        /// in the expected direction, since "pressboard breakdown strength decreases with increasing temperature".
        ///
        /// Switch the dispatch in `Strike(for:thickness:)` to the room-temperature pair if that better matches your test condition.
        static func PressboardImpulse(thickness:Double) -> Double {

            return PowerLaw(coefficient: 91.2, exponent: 0.26, distance: thickness)
        }

        /// Pressboard at power frequency, V/m rms. DelVecchio 13.8, at 90 °C: E = 27.5·d^(−0.26) kV/mm.
        static func PressboardPowerFrequency(thickness:Double) -> Double {

            return PowerLaw(coefficient: 27.5, exponent: 0.26, distance: thickness)
        }

        /// Pressboard under IMPULSE at ROOM temperature, V/m peak. DelVecchio 13.7 (Moser, 25 mm sphere electrodes):
        /// E = 94.6·d^(−0.22) kV/mm. Not used by default - see PressboardImpulse.
        static func PressboardImpulseRoomTemperature(thickness:Double) -> Double {

            return PowerLaw(coefficient: 94.6, exponent: 0.22, distance: thickness)
        }

        /// Pressboard at power frequency, ROOM temperature, V/m rms. DelVecchio 13.7: E = 33.1·d^(−0.32) kV/mm.
        static func PressboardPowerFrequencyRoomTemperature(thickness:Double) -> Double {

            return PowerLaw(coefficient: 33.1, exponent: 0.32, distance: thickness)
        }

        // MARK: Creep - tracking along a surface
        //
        // NOTHING IN THE SCREEN CALLS THESE AT PRESENT. The creep sites were removed on 2026-08-06 because the screen had no way to
        // measure a creep path, not because these allowables are wrong - they are cited, and VerifySelf still pins all three.
        //
        // What was wrong was the geometry. A creep path was taken to be the straight axial run between the two electrodes: the gap
        // itself for a key spacer, and for a hilo barrier the difference in height between the two coils' ends. Both are far shorter
        // than the real surface path, and the hilo one is nearly meaningless - two coils whose ends are a millimetre apart got a
        // 1 mm path carrying the full end-to-end voltage, which 13.16 then judged at the strength of a 1 mm path. A model artifact,
        // reported worst-first at the top of the table.
        //
        // Before this comes back, a creep site has to be able to measure the ACTUAL path, which means the model has to carry the
        // insulation structure that the path runs over:
        //
        //   - a hilo barrier extends some distance BEYOND the coil ends, so the path is up one face of the barrier, around its
        //     end and back down the other - not the gap between the coil ends;
        //   - at high voltage that end is further built up with angle rings and caps, which lengthen it again;
        //   - a key spacer's path is around the spacer, and it is bounded by the disc faces it is clamped between.
        //
        // None of that is in PhaseModel today: the barrier overhang, the angles and the rings are not modelled. Adding a creep
        // check therefore starts with the geometry, not with this file.

        /// Creep along a pressboard surface in oil at power frequency, V/m rms, as a function of the creep DISTANCE.
        /// DelVecchio 13.16 (Moser): E = 16.6·d_c^(−0.46) kV/mm with d_c in mm.
        ///
        /// Note how much steeper the exponent is than any of the strike figures: creep strength falls away with path length far
        /// faster than gap strength falls with gap. That is why a short creep path carrying a large voltage - a bridged tapping gap,
        /// or the end of a short coil against a taller one - is so often the thing that governs a design.
        static func CreepPowerFrequency(path:Double) -> Double {

            return PowerLaw(coefficient: 16.6, exponent: 0.46, distance: path)
        }

        /// Creep along a pressboard surface in oil under IMPULSE, V/m peak. 13.16 scaled by `creepImpulseRatio` - see that constant
        /// for why this one is an extrapolation and the others are not.
        static func CreepImpulse(path:Double) -> Double {

            return CreepPowerFrequency(path: path) * creepImpulseRatio
        }

        /// Creep at power frequency as a function of the creep AREA rather than the distance, V/m rms. DelVecchio 13.15 (Palmer and
        /// Sharpley): E = 16.0 − 1.09·ln(A_c) kV/mm with A_c in mm².
        ///
        /// Note the form: this is LOGARITHMIC IN AREA, not a power law like every other formula here. 13.9 (oil by volume) has the
        /// same shape. Getting this wrong is easy - it was, once, in this file - so the shape is worth restating: the coefficients
        /// are 16.0 and 1.09 in a subtraction, NOT 16.0 and 0.09 in an exponent.
        ///
        /// A logarithm falling without bound eventually goes negative, at A_c = e^(16.0/1.09) ≈ 2.4e6 mm², i.e. about 2.4 m². The
        /// book flags exactly this for its companion formula 13.9 (p.370): "the logarithmic dependence on volume ... cannot be valid
        /// for very large volumes since the breakdown stress would eventually become negative." The result is clamped at zero here
        /// rather than pretending the formula still holds.
        ///
        /// Provided for completeness; the screen uses the distance form, since a path length is what it measures.
        static func CreepPowerFrequencyByArea(area:Double) -> Double {

            let areaInSquareMillimetres = area * 1.0E6

            guard areaInSquareMillimetres > 0.0 else {

                return .greatestFiniteMagnitude
            }

            return max(0.0, 16.0 - 1.09 * log(areaInSquareMillimetres)) * 1.0E6
        }

        // MARK: Dispatch

        /// The impulse strike allowable for a material over a given thickness, with the design margin applied.
        static func Strike(for material:DielectricLayer.Material, thickness:Double) -> Double {

            let breakdown:Double

            switch material {

            case .oil: breakdown = OilImpulse(gap: thickness)
            case .paper: breakdown = PaperImpulse(thickness: thickness)
            case .pressboard: breakdown = PressboardImpulse(thickness: thickness)
            }

            return breakdown * designMargin
        }

        /// The impulse creep allowable over a given path, with the design margin applied.
        static func Creep(path:Double) -> Double {

            return CreepImpulse(path: path) * designMargin
        }

        /// E = coefficient · d^(−exponent), with the book's kV/mm and mm converted to this program's V/m and m.
        private static func PowerLaw(coefficient:Double, exponent:Double, distance:Double) -> Double {

            let distanceInMillimetres = distance * 1000.0

            guard distanceInMillimetres > 0.0 else {

                // A zero-thickness layer carries no voltage, so nothing can fail in it. Returning an infinite strength keeps it out
                // of the ranking rather than dividing by zero.
                return .greatestFiniteMagnitude
            }

            return coefficient * pow(distanceInMillimetres, -exponent) * 1.0E6
        }
    }

    // MARK: What gets checked

    /// The kinds of check this file makes. The report groups and filters on these.
    enum StressCheckKind:String, Sendable, CaseIterable {

        case discToDisc = "Disc to disc"
        case turnToTurn = "Turn to turn"
        case radialCoilToCoil = "Coil to coil (radial)"
        case coilToCore = "Coil to core"
        case coilToTank = "Coil to tank"

        /// Whether the gap this checks is a RADIAL one. Both profile graphs plot against height, and both assemble themselves from
        /// `profileName`/`profileHeight`, so this is what keeps the radial graph from picking up the axial profiles and vice versa.
        var isRadial:Bool {

            switch self {

            case .radialCoilToCoil, .coilToCore, .coilToTank: return true
            case .discToDisc, .turnToTurn: return false
            }
        }
    }

    /// The name of the disc-to-disc-versus-height profile for one coil. In one place because the sites are tagged with it in
    /// `AppendAxialSites` and `AxialStressProfileWindow` groups on it.
    static func AxialProfileName(coil:Int) -> String {

        return "Coil \(coil) — disc to disc"
    }

    /// One term of the linear combination of node potentials that drives a site.
    struct VoltageTerm:Sendable {

        let nodeIndex:Int
        let weight:Double
    }

    // CREEP SITES ARE NOT BUILT (removed 2026-08-06). The allowables in StressAllowable are kept and still self-tested; what was
    // wrong was the GEOMETRY the screen fed them. See the note above StressAllowable.CreepPowerFrequency for what a creep site has
    // to know before this comes back.

    /// A place in the winding where a voltage difference appears across a known dielectric stack.
    ///
    /// A site holds only GEOMETRY and a recipe for extracting its driving voltage from a step's `volts` vector. It carries no
    /// voltage of its own, because the geometry does not change over the run while the voltage does - so the sites are built once
    /// and the time scan then only has to evaluate the linear combination below.
    ///
    /// That the field is LINEAR in the driving voltage is what makes the whole scan cheap: the worst field over the run is the field
    /// of the worst voltage over the run, so the dielectric reduction is done once per site rather than once per site per time step.
    /// This is exact, not an approximation - but it does depend on the geometry being time-invariant, so if a site is ever added
    /// whose stack depends on the instantaneous voltage, it must not use this path.
    struct StressSite:Sendable {

        let kind:StressCheckKind
        /// A human-readable description of where this is, for the report.
        let location:String
        /// The driving voltage is Σ weight·V[nodeIndex] over these terms.
        let voltageTerms:[VoltageTerm]
        /// The dielectric columns spanning the gap, each in physical order outwards from the reference electrode. A disc-to-disc gap
        /// has two - the key-spacer column and the oil column - because the two see the same volts across different stacks and
        /// either may govern.
        let columns:[[DielectricLayer]]
        /// Non-nil for a site whose average field is coaxial rather than laminar: the radius the stack starts at.
        let innerRadius:Double?
        /// Whether the conductor-corner model is meaningful here. False where there is no conductor corner facing the gap - for
        /// instance a gap bounded by the smooth wrapped surface of a static ring.
        let usesCornerModel:Bool
        /// The total gap thickness, for the report. Metres.
        let gapLength:Double
        /// The corner radius of the electrode this stack STARTS at, in metres - the surface CornerField reads the first layer's
        /// field at. From DielectricStress.CornerRadius(thickness:width:) wherever the design file gives strand dimensions; the
        /// fallback constant otherwise. Ignored when usesCornerModel is false.
        var cornerRadius:Double = defaultCornerRadiusOnCopper
        /// The corner radius of the electrode at the FAR end of the stack, in metres, or nil where the far side has no corner worth
        /// modelling. A gap has two electrodes and either may be the sharper one - see Evaluate, which reads the stack from both
        /// ends and keeps the worse. Nil is not the same as "smooth": it means the far electrode is not represented at all, which is
        /// the honest answer for a core or a tank wall whose surface this model does not know.
        var farCornerRadius:Double? = nil

        /// For a site that belongs to a voltage-versus-height profile, the name of the profile it belongs to (which coil against
        /// which) and its height. Nil for sites that are not part of a profile.
        ///
        /// These exist so that the radial profile graphs can be assembled from the SAME scan that produced the table, rather than
        /// from a second pass with its own interpolation. A graph that disagreed with the table it sits beside would be worse than
        /// no graph at all.
        var profileName:String? = nil
        var profileHeight:Double? = nil

        /// The driving voltage for this site at one instant.
        func DrivingVoltage(volts:[Double]) -> Double {

            var result = 0.0

            for term in voltageTerms {

                guard term.nodeIndex >= 0, term.nodeIndex < volts.count else {

                    continue
                }

                result += term.weight * volts[term.nodeIndex]
            }

            return result
        }
    }

    /// One finding: a site, the worst voltage it saw, and what that means in V/m.
    struct StressCheck:Sendable {

        let kind:StressCheckKind
        let location:String
        /// The driving voltage difference at the worst instant, in volts.
        let deltaV:Double
        /// The time at which it occurred, in seconds. Negative marks the t = 0+ capacitive distribution, which is not on the
        /// simulation's time grid but is where the steepest turn-to-turn gradients actually live.
        let time:Double
        /// The thickness of the governing layer, in metres. This is the distance the allowable was evaluated at, which is why it is
        /// the layer's own thickness and not the whole gap.
        let pathLength:Double
        /// The material carrying the governing field.
        let material:DielectricLayer.Material
        /// The average field in the governing layer, V/m. This is the number that is judged.
        let averageField:Double
        /// The peak (conductor-corner) field, V/m. Informational - see Evaluate. Nil where the corner model does not apply.
        let peakField:Double?
        /// averageField divided by the chapter 13 impulse allowable for its material AT ITS OWN THICKNESS, with the design margin
        /// applied. 1.0 means the design margin is exactly used up.
        let averageUtilization:Double
        /// Always nil at present: there is no sourced allowable for a corner peak. Kept so that the report can carry one if a
        /// defensible peak criterion is ever adopted.
        let peakUtilization:Double?
        /// The strand corner radius the peak field was computed at, in metres. Carried so the report can say which one it used -
        /// it is the dominant assumption behind the corner columns, and it now varies from coil to coil.
        var cornerRadius:Double = defaultCornerRadiusOnCopper

        /// How much the conductor corner concentrates the field over the average, or nil where the corner model does not apply.
        var cornerEnhancement:Double? {

            guard let peak = peakField, averageField > 0.0 else { return nil }
            return peak / averageField
        }

        /// Carried through from the site: which voltage-versus-height profile this belongs to, and at what height. See StressSite.
        var profileName:String? = nil
        var profileHeight:Double? = nil

        /// The number the report ranks on. Ranking on utilization rather than on raw V/m is what lets an oil duct and a paper gap be
        /// compared on one scale - they fail at very different stresses, and at different rates with distance.
        var worstUtilization:Double {

            return max(averageUtilization, peakUtilization ?? 0.0)
        }

        /// True if the t = 0+ capacitive distribution, rather than a point on the time grid, produced the worst case.
        var isAtCapacitiveDistribution:Bool {

            return time < 0.0
        }
    }

    // MARK: Turning a site and a voltage into a finding

    /// Evaluate one site at its worst driving voltage.
    ///
    /// The governing layer is chosen by UTILIZATION, not by raw field. Paper carries a lower field than the oil beside it - the
    /// ratio across an interface is ε_oil/ε_paper, so the OIL carries more, which is why DelVecchio says (p.371) "breakdown
    /// generally occurs in the oil gaps first" - but paper also withstands roughly twice as much, so picking the largest V/m would
    /// report the wrong material about as often as not.
    ///
    /// Each layer is judged against the allowable FOR ITS OWN THICKNESS, which is the book's path-subdivision procedure (p.371)
    /// applied to a stack whose subdivisions are the physical layers.
    static func Evaluate(site:StressSite, deltaV:Double, time:Double) -> StressCheck? {

        let volts = abs(deltaV)

        guard volts > 0.0, volts.isFinite else {

            return nil
        }

        guard !site.columns.isEmpty else {

            return nil
        }

        var bestUtilization = -1.0
        var bestField = 0.0
        var bestMaterial = DielectricLayer.Material.oil
        var bestThickness = site.gapLength
        var bestPeak:Double? = nil
        var bestPeakRadius:Double? = nil

        for column in site.columns {

            // The average field: coaxial where the site says so (a hilo, where the stack wraps a real cylinder), laminar otherwise.
            let averageFields = site.innerRadius != nil
                ? CoaxialField(volts: volts, layers: column, innerRadius: site.innerRadius!)
                : LaminarField(volts: volts, layers: column)

            // The peak field at a conductor corner, from the same stack and at the electrode's own tabulated corner radius - see
            // CornerField and CornerRadius.
            //
            // A GAP HAS TWO ELECTRODES, and the corner model is read from whichever one is being stood on: the field falls as 1/r
            // away from it, so the layer against it sees the concentration and the layer at the far end does not. Reading the
            // REVERSED stack at the far electrode's radius is the same calculation seen from the other side, and mapping it back
            // gives a second field per layer; the worse of the two is the peak that layer actually sees.
            //
            // For an ordinary disc-to-disc gap the stack is symmetric and the two views agree exactly, so this changes nothing.
            // It earns its keep where the gap is NOT symmetric - a disc facing a static ring, where 0.4 mm of turn paper on a
            // 0.8 mm strand corner faces 3.18 mm of Kraft on a 1.6 mm foil corner, and the ring's own covering is the layer at
            // risk. Nothing in the one-sided model could see that: it read the ring's Kraft at the far end of the gap, which is
            // where its field is lowest.
            let peakFields = site.usesCornerModel ? CornerField(volts: volts, layers: column, cornerRadius: site.cornerRadius) : []
            let farPeakFields:[Double] = site.usesCornerModel ? (site.farCornerRadius.map { Array(CornerField(volts: volts, layers: column.reversed(), cornerRadius: $0).reversed()) } ?? []) : []

            for (i, layer) in column.enumerated() {

                guard i < averageFields.count, layer.thickness > 0.0 else {

                    continue
                }

                let average = averageFields[i]
                let utilization = average / StressAllowable.Strike(for: layer.material, thickness: layer.thickness)

                if utilization > bestUtilization {

                    bestUtilization = utilization
                    bestField = average
                    bestMaterial = layer.material
                    bestThickness = layer.thickness

                    let near = i < peakFields.count ? peakFields[i] : nil
                    let far = i < farPeakFields.count ? farPeakFields[i] : nil

                    // Keep the worse of the two views, and the radius that produced it, so the report can say which electrode the
                    // number belongs to.
                    if let near = near, let far = far {

                        bestPeak = max(near, far)
                        bestPeakRadius = far > near ? site.farCornerRadius : site.cornerRadius
                    }
                    else {

                        bestPeak = near ?? far
                        bestPeakRadius = near != nil ? site.cornerRadius : site.farCornerRadius
                    }
                }
            }
        }

        guard bestUtilization >= 0.0 else {

            return nil
        }

        // The peak field is reported but NOT given a margin of its own.
        //
        // Chapter 13's data are all uniform-gap measurements, and the book's procedure for a non-uniform field is to compare
        // AVERAGE fields over subdivisions against them (p.371) - so there is no sourced allowable to judge a corner peak against,
        // and inventing one would put a fabricated number beside cited ones. The peak column's job is to show WHERE the geometry
        // concentrates the field; DelVecchio himself says of that situation (p.16) that "there is usually some judgment involved in
        // deciding what level of electrical stress is acceptable", and that is exactly the point at which an FE run earns its keep.
        return StressCheck(kind: site.kind,
                           location: site.location,
                           deltaV: deltaV,
                           time: time,
                           pathLength: bestThickness,
                           material: bestMaterial,
                           averageField: bestField,
                           peakField: bestPeak,
                           averageUtilization: bestUtilization,
                           peakUtilization: nil,
                           cornerRadius: bestPeakRadius ?? site.cornerRadius,
                           profileName: site.profileName,
                           profileHeight: site.profileHeight)
    }

    /// Scan a whole simulation result and return one finding per site, worst-first.
    ///
    /// Two things about the scan are worth knowing.
    ///
    /// First, MAX STRESS IS NOT AT MAX VOLTAGE. The turn-to-turn gradients peak essentially at t = 0+, while the coil-to-ground
    /// stresses peak late, on the tail. So every step is visited and each site keeps its own worst instant - a single "worst step"
    /// for the whole model would be wrong for most of the sites in it.
    ///
    /// Second, the t = 0+ capacitive distribution is prepended as an extra sample when the caller supplies it. The frequency-domain
    /// solver returns results on a uniform grid whose first sample is already some tens of nanoseconds in, by which time the
    /// steepest part of the initial distribution has begun to relax. Since that distribution is precisely the classical initial
    /// distribution of impulse theory - and FrequencyDomainSolver.CapacitiveDistribution already computes it, through the same
    /// assembly as every other frequency - leaving it out would miss the very case the turn-to-turn check exists for.
    ///
    /// - Parameter capacitiveDistribution: alpha from FrequencyDomainSolver.CapacitiveDistribution, per-unit. It is scaled by
    /// 'peakVoltage' to put it in volts, since alpha is normalized to a 1 V drive.
    static func Scan(sites:[StressSite], results:[SimulationModel.SimulationStepResult], capacitiveDistribution:[Double]?, peakVoltage:Double) -> [StressCheck] {

        guard !sites.isEmpty else {

            return []
        }

        var worstVolts = [Double](repeating: 0.0, count: sites.count)
        var worstTime = [Double](repeating: 0.0, count: sites.count)
        var sawAny = false

        // The t = 0+ sample, flagged with a negative time so the report can name it rather than printing a fictitious instant.
        if let alpha = capacitiveDistribution, !alpha.isEmpty, peakVoltage != 0.0 {

            let volts = alpha.map { $0 * peakVoltage }

            for (i, site) in sites.enumerated() {

                let driving = site.DrivingVoltage(volts: volts)

                if abs(driving) > abs(worstVolts[i]) {

                    worstVolts[i] = driving
                    worstTime[i] = -1.0
                }
            }

            sawAny = true
        }

        for step in results {

            guard !step.volts.isEmpty else {

                continue
            }

            for (i, site) in sites.enumerated() {

                let driving = site.DrivingVoltage(volts: step.volts)

                if abs(driving) > abs(worstVolts[i]) {

                    worstVolts[i] = driving
                    worstTime[i] = step.time
                }
            }

            sawAny = true
        }

        guard sawAny else {

            return []
        }

        var result:[StressCheck] = []

        for (i, site) in sites.enumerated() {

            if let check = Evaluate(site: site, deltaV: worstVolts[i], time: worstTime[i]) {

                result.append(check)
            }
        }

        result.sort { $0.worstUtilization > $1.worstUtilization }

        return result
    }

    // MARK: Building the sites from a model

    /// Build every site the screen knows how to check, from the model's geometry and node topology.
    ///
    /// This is where the physics of each check lives. It runs once per report, not per time step.
    static func BuildSites(model:PhaseModel) async -> [StressSite] {

        var result:[StressSite] = []

        let coilSegments = await model.CoilSegments()

        guard !coilSegments.isEmpty else {

            return []
        }

        let coilCount = await model.CoilCount()

        for coil in 0..<coilCount {

            let segments = coilSegments.filter { $0.radialPos == coil }

            guard !segments.isEmpty else {

                continue
            }

            await AppendAxialSites(model: model, coil: coil, segments: segments, into: &result)
            await AppendTurnToTurnSites(model: model, segments: segments, into: &result)
        }

        await AppendRadialSites(model: model, coilCount: coilCount, into: &result)

        return result
    }

    /// Disc-to-disc gaps - everything that lives in an axial gap.
    private static func AppendAxialSites(model:PhaseModel, coil:Int, segments:[Segment], into result:inout [StressSite]) async {

        for (i, segment) in segments.enumerated() {

            // Bound separately: '||' takes an autoclosure, so the right-hand side would escape the await and trip actor isolation.
            let wdgType = segment.wdgType

            guard wdgType == .disc || wdgType == .helical else {

                continue
            }

            let nodes = await model.AdjacentNodes(to: segment)

            guard nodes.below >= 0, nodes.above >= 0 else {

                continue
            }

            let basicSections = segment.basicSections

            guard let bs = basicSections.first else {

                continue
            }

            // The corner facing an axial gap is the corner of one elementary STRAND, not of the whole turn or cable: a CTC or a
            // multi-strand cable presents each strand's own corner to the gap, and it is the smallest radius that governs.
            let cornerRadius = CornerRadius(thickness: bs.wdgData.turn.strandRadial, width: bs.wdgData.turn.strandAxial)

            // ---- the gaps INSIDE this Segment, between the discs it holds ----
            //
            // A multi-disc Segment (a combine, or an interleaved pair) has no node between its discs, so the voltage there is not
            // resolved by the network. The internal gap is driven by the same crossover argument as the external one below - the
            // far end of the gap sees twice the per-disc voltage - applied to this Segment's own span divided among its discs.
            if basicSections.count > 1 {

                let perDisc = 2.0 / Double(basicSections.count)

                for gapIndex in 0..<(basicSections.count - 1) {

                    let gap = basicSections[gapIndex + 1].z1 - basicSections[gapIndex].z2

                    guard gap > 0.0 else {

                        continue
                    }

                    let stacks = Segment.DiscToDiscLayerStack(basicSection: bs, gap: gap, facesStaticRing: false)
                    let location = "Coil \(coil), segment \(segment.axialPos), internal gap \(gapIndex + 1)"

                    result.append(StressSite(kind: .discToDisc,
                                             location: location,
                                             voltageTerms: [VoltageTerm(nodeIndex: nodes.above, weight: perDisc), VoltageTerm(nodeIndex: nodes.below, weight: -perDisc)],
                                             columns: [stacks.keySpacer, stacks.oil],
                                             innerRadius: nil,
                                             usesCornerModel: true,
                                             gapLength: gap,
                                             cornerRadius: cornerRadius,
                                             // The same disc on both sides, so the two views of the stack agree.
                                             farCornerRadius: cornerRadius,
                                             profileName: AxialProfileName(coil: coil),
                                             // The MIDDLE of the gap, which is where the stress being reported actually is. The
                                             // profile is a value per gap, not per disc, so a gap's own centre is the only height
                                             // that does not silently shift the curve half a gap up or down the coil.
                                             profileHeight: (basicSections[gapIndex].z2 + basicSections[gapIndex + 1].z1) / 2.0))
                }
            }

            // ---- the gaps to an adjacent STATIC RING ----
            //
            // These used to produce nothing at all, which left the end of a coil - the very place a ring is fitted - unchecked. A
            // ring above the topmost disc has no coil Segment beyond it, so the "gap above" loop below simply ran off the end; a
            // ring BETWEEN two discs was worse, because that loop measured the gap from disc to disc straight THROUGH the ring and
            // handed the whole span to DiscToDiscLayerStack as though it were oil.
            //
            // The ring is bonded by its lead to the OUTERMOST TURN of the disc it is fitted against (see the static ring constants
            // in Segment.swift), so it sits at that turn's potential: the difference across the gap is zero at the OD and the
            // disc's whole span at the ID, and the worst case is one node step. The far electrode is the ring's foil, at R1 = R2.
            for ringIsAbove in [true, false] {

                guard let ring = (try? await (ringIsAbove ? model.StaticRingAbove(segment: segment) : model.StaticRingBelow(segment: segment))).flatMap({ $0 }) else {

                    continue
                }

                let ringGapBottom = ringIsAbove ? await segment.z2 : await ring.z2
                let ringGapTop = ringIsAbove ? await ring.z1 : await segment.z1
                let ringGap = ringGapTop - ringGapBottom

                guard ringGap > 0.0 else {

                    continue
                }

                let stacks = Segment.DiscToDiscLayerStack(basicSection: bs, gap: ringGap, facesStaticRing: true)

                result.append(StressSite(kind: .discToDisc,
                                         location: "Coil \(coil), segment \(segment.axialPos) to static ring \(ringIsAbove ? "above" : "below"), worst at ID",
                                         voltageTerms: [VoltageTerm(nodeIndex: nodes.above, weight: 1.0), VoltageTerm(nodeIndex: nodes.below, weight: -1.0)],
                                         columns: [stacks.keySpacer, stacks.oil],
                                         innerRadius: nil,
                                         usesCornerModel: true,
                                         gapLength: ringGap,
                                         cornerRadius: cornerRadius,
                                         farCornerRadius: Segment.staticRingCornerRadius,
                                         profileName: AxialProfileName(coil: coil),
                                         profileHeight: (ringGapBottom + ringGapTop) / 2.0))
            }

            // ---- the gap ABOVE this Segment ----

            guard i + 1 < segments.count else {

                continue
            }

            let above = segments[i + 1]
            let gapBottom = await segment.z2
            let gapTop = await above.z1
            let gap = gapTop - gapBottom

            guard gap > 0.0 else {

                continue
            }

            let aboveNodes = await model.AdjacentNodes(to: above)

            guard aboveNodes.above >= 0 else {

                continue
            }

            // A static ring standing in this gap means the gap is not disc-to-disc at all: it is disc-to-ring plus ring-to-disc, and
            // the two sites above have already covered both, at their real spacings and against the ring's own covering. Measuring
            // straight through the ring would double count them and would hand DiscToDiscLayerStack a span that is mostly ring.
            guard ((try? await model.StaticRingAbove(segment: segment)).flatMap { $0 }) == nil else {

                continue
            }

            let isTappingGap = await model.IsTappingGap(segment1: segment, segment2: above)
            let stacks = Segment.DiscToDiscLayerStack(basicSection: bs, gap: gap, facesStaticRing: false)

            // THE TWO-NODE SPAN. In a continuous disc winding the two discs facing each other across a gap are joined at one end -
            // the crossover - and the potential difference across the gap rises linearly from zero there to TWICE the per-disc
            // voltage at the far end. Taking disc A wound ID->OD from 0 to V and disc B wound OD->ID from V to 2V, B's potential at
            // radial position x is (2−x)V while A's is xV, so the difference is 2V(1−x): zero at the OD crossover, 2V at the ID.
            // The far-end value therefore spans TWO node steps, not one, and the worst point alternates ID/OD gap by gap.
            //
            // Reading the adjacent diagonal of MaximumInternodalVoltages instead would understate this by a factor of two.
            //
            // The rule holds for the plain continuous-disc case. Where either Segment holds more than one disc, or is interleaved,
            // the winding order across the gap is different and the crossover argument does not apply unchanged, so the direct node
            // difference is used and the location says so.
            let aboveSectionCount = above.basicSections.count
            let thisInterleaved = await segment.interleaved
            let aboveInterleaved = await above.interleaved
            let plainContinuous = basicSections.count == 1 && aboveSectionCount == 1 && !thisInterleaved && !aboveInterleaved

            let terms:[VoltageTerm]
            let spanNote:String

            if plainContinuous && !isTappingGap {

                terms = [VoltageTerm(nodeIndex: aboveNodes.above, weight: 1.0), VoltageTerm(nodeIndex: nodes.below, weight: -1.0)]
                // The crossover alternates from gap to gap, so the far end alternates with it.
                spanNote = (segment.axialPos) % 2 == 0 ? ", worst at ID" : ", worst at OD"
            }
            else {

                terms = [VoltageTerm(nodeIndex: aboveNodes.below, weight: 1.0), VoltageTerm(nodeIndex: nodes.above, weight: -1.0)]
                spanNote = isTappingGap ? ", across tapping gap" : ", single node step"
            }

            let location = "Coil \(coil), gap above segment \(segment.axialPos)\(spanNote)"

            result.append(StressSite(kind: .discToDisc,
                                     location: location,
                                     voltageTerms: terms,
                                     columns: [stacks.keySpacer, stacks.oil],
                                     innerRadius: nil,
                                     usesCornerModel: true,
                                     gapLength: gap,
                                     cornerRadius: cornerRadius,
                                     // Two discs of the same winding, so the far corner is the same strand's.
                                     farCornerRadius: cornerRadius,
                                     profileName: AxialProfileName(coil: coil),
                                     profileHeight: (gapBottom + gapTop) / 2.0))
        }
    }

    /// Turn-to-turn sites: one per Segment, using the same Stein alpha that its series capacitance is built on.
    private static func AppendTurnToTurnSites(model:PhaseModel, segments:[Segment], into result:inout [StressSite]) async {

        for segment in segments {

            guard segment.wdgType == .disc else {

                continue
            }

            let N = await segment.N

            guard N > 1 else {

                continue
            }

            let nodes = await model.AdjacentNodes(to: segment)

            guard nodes.below >= 0, nodes.above >= 0 else {

                continue
            }

            guard let bs = segment.basicSections.first else {

                continue
            }

            let tp = bs.wdgData.turn.turnInsulation

            guard tp > 0.0 else {

                continue
            }

            // The gradient enhancement over the linear assumption, from the disc's own Stein parameters - the very same alpha that
            // SeriesCapacitance uses. See Segment.SteinParameters.gradientEnhancement for the derivation and for why an interior
            // disc with equal gaps comes out at 1 (its neighbours ramp in step with it) while an end disc goes to alpha/tanh alpha.
            var enhancement = 1.0

            if let gaps = try? await model.AxialSpacesAboutSegment(segment: segment),
               let Cs = try? await segment.BasicSectionSeriesCapacitance(), Cs > 0.0 {

                let staticRing = (above: ((try? await model.StaticRingAbove(segment: segment)).flatMap { $0 }) != nil,
                                  below: ((try? await model.StaticRingBelow(segment: segment)).flatMap { $0 }) != nil)

                let Cdd = Segment.DiscToDiscSeriesCapacitance(belowGap: gaps.below,
                                                              aboveGap: gaps.above,
                                                              basicSection: bs,
                                                              innerRadius: await segment.r1,
                                                              outerRadius: await segment.r2,
                                                              staticRing: staticRing)

                let highest = (try? await model.GetHighestSection(coil: segment.radialPos)) ?? -1
                let endDisc = (lowest: segment.axialPos == 0, highest: segment.axialPos == highest)

                enhancement = Segment.SteinParameters.For(Cs: Cs, Cdd: Cdd, endDisc: endDisc, adjStaticRing: staticRing).gradientEnhancement
            }

            // How much of the Segment's voltage appears between two RADIALLY ADJACENT turns.
            //
            // In a continuous disc the turns are wound in order from one face to the other, so radially adjacent turns are
            // electrically adjacent and the share is 1/N. Interleaving deliberately breaks that: the winding order is
            // 1, N/2+1, 2, N/2+2, ..., so the turn beside any given one is about N/2 turns away and carries roughly HALF the pair
            // voltage. That is exactly the trade interleaving makes - a large series capacitance bought with a large turn-to-turn
            // stress - and it is why an interleaved coil has to be checked here rather than assumed safe.
            let interleaved = await segment.interleaved
            let share = interleaved ? 0.5 : 1.0 / N

            let weight = share * enhancement

            // Two radially adjacent turns are separated by their two half-wraps.
            let column = [DielectricLayer.Paper(tp / 2.0), DielectricLayer.Paper(tp / 2.0)]

            let note = interleaved ? " (interleaved)" : ""
            let location = "Coil \(segment.radialPos), segment \(segment.axialPos), turn to turn\(note), enh \(String(format: "%.2f", enhancement))x"

            result.append(StressSite(kind: .turnToTurn,
                                     location: location,
                                     voltageTerms: [VoltageTerm(nodeIndex: nodes.above, weight: weight), VoltageTerm(nodeIndex: nodes.below, weight: -weight)],
                                     columns: [column],
                                     innerRadius: nil,
                                     usesCornerModel: true,
                                     gapLength: tp,
                                     // Radially adjacent turns face each other corner to corner, and it is the same strand on both
                                     // sides of the paper, so one radius describes both ends of the site.
                                     cornerRadius: CornerRadius(thickness: bs.wdgData.turn.strandRadial, width: bs.wdgData.turn.strandAxial),
                                     farCornerRadius: CornerRadius(thickness: bs.wdgData.turn.strandRadial, width: bs.wdgData.turn.strandAxial)))
        }
    }

    /// Radial sites: coil to coil across each hilo, coil to core, and coil to tank.
    private static func AppendRadialSites(model:PhaseModel, coilCount:Int, into result:inout [StressSite]) async {

        for coil in 0..<coilCount {

            guard let stack = try? await model.HiloLayerStack(coil: coil) else {

                continue
            }

            guard let profile = try? await model.CoilVoltageProfile(coil: coil), !profile.isEmpty else {

                continue
            }

            // What lies inside this coil: the core for coil 0, otherwise the next coil in.
            let innerProfile:[PhaseModel.CoilProfilePoint]?
            let kind:StressCheckKind
            let innerName:String

            if coil == 0 {

                innerProfile = nil
                kind = .coilToCore
                innerName = "core"
            }
            else {

                innerProfile = try? await model.CoilVoltageProfile(coil: coil - 1)
                kind = .radialCoilToCoil
                innerName = "coil \(coil - 1)"
            }

            // HiloLayerStack puts this coil's own half-wrap on the outside of the gap and leaves the inner one to us, because what
            // is inside may be a core, a tank or a shield, none of which carries turn paper. Here it is a coil, so its half-wrap
            // goes on - and the stack then starts half a wrap further in, at the inner coil's copper rather than at its insulated
            // surface, since r2 is over-paper exactly as this coil's r1 is.
            var stickColumn = stack.stick
            var oilColumn = stack.oil
            var stackInnerRadius = stack.innerRadius

            // The corner the hilo model reads is the one on the REFERENCE electrode, since CornerField evaluates the stack from its
            // innermost surface outwards. Where that surface is the inner coil's copper it is that coil's strand; where it is a core,
            // a tank or a radial shield there is no conductor corner at all, and this coil's own strand is the nearest thing to a
            // meaningful figure. (Whether the corner model belongs on those sites is a separate question - see usesCornerModel.)
            var cornerRadius = defaultCornerRadiusOnCopper

            // The OUTER electrode of a hilo is always this coil's own copper, whatever is on the inside of the gap, so the far view
            // is unambiguous here in a way the near one is not.
            var farCornerRadius:Double? = nil

            if let ownSeg = await model.SegmentAt(location: LocStruct(radial: coil, axial: 0)),
               let ownBS = ownSeg.basicSections.first {

                cornerRadius = CornerRadius(thickness: ownBS.wdgData.turn.strandRadial, width: ownBS.wdgData.turn.strandAxial)
                farCornerRadius = cornerRadius
            }

            if kind == .radialCoilToCoil,
               (try? await model.RadialShieldInside(coil: coil)) ?? nil == nil,
               let innerSeg = await model.SegmentAt(location: LocStruct(radial: coil - 1, axial: 0)),
               let innerBS = innerSeg.basicSections.first {

                let innerPaper = DielectricLayer.Paper(innerBS.wdgData.turn.turnInsulation / 2.0)

                if innerPaper.thickness > 0.0 {

                    stickColumn.insert(innerPaper, at: 0)
                    oilColumn.insert(innerPaper, at: 0)
                    stackInnerRadius -= innerPaper.thickness

                    cornerRadius = CornerRadius(thickness: innerBS.wdgData.turn.strandRadial, width: innerBS.wdgData.turn.strandAxial)
                }
            }

            let innerExtent:(low:Double, high:Double)? = innerProfile.flatMap { points in

                guard let lo = points.first?.z, let hi = points.last?.z else { return nil }
                return (lo, hi)
            }

            // Sample at THIS coil's nodes and interpolate the inner coil there. Sampling on one coil's nodes and interpolating the
            // other is what makes unequal heights work at all: the two coils share no node numbering and their discs need not line
            // up, so a common height is the only thing they can be compared at.
            for point in profile {

                var terms = [VoltageTerm(nodeIndex: point.nodeIndex, weight: 1.0)]
                var endNote = ""

                if let inner = innerProfile {

                    // Past the end of the inner coil there is nothing at that height to difference against, and the field there is
                    // genuinely two-dimensional. Flag it rather than pretending to a number: this IS the unequal-height failure
                    // mode, and the honest output is "the short coil ends here, look at it".
                    if let extent = innerExtent, point.z < extent.low || point.z > extent.high {

                        endNote = " [beyond end of \(innerName) - 2-D field, value indicative only]"

                        // Hold the nearest inner potential, which is the best a one-dimensional model can say.
                        if let nearest = point.z < extent.low ? inner.first : inner.last {

                            terms.append(VoltageTerm(nodeIndex: nearest.nodeIndex, weight: -1.0))
                        }
                    }
                    else {

                        for term in InterpolationTerms(profile: inner, z: point.z, sign: -1.0) {

                            terms.append(term)
                        }
                    }
                }

                let location = "Coil \(coil) to \(innerName) at z = \(String(format: "%.1f", point.z * 1000.0)) mm\(endNote)"

                result.append(StressSite(kind: kind,
                                         location: location,
                                         voltageTerms: terms,
                                         columns: [stickColumn, oilColumn],
                                         innerRadius: stackInnerRadius,
                                         usesCornerModel: true,
                                         gapLength: stickColumn.reduce(0.0) { $0 + $1.thickness },
                                         cornerRadius: cornerRadius,
                                         farCornerRadius: farCornerRadius,
                                         profileName: "Coil \(coil) to \(innerName)",
                                         profileHeight: point.z))
            }
        }

        // The outermost coil against the tank. Kulkarni's geometry, as OuterShuntCapacitance uses it: the tank wall sits at half the
        // tank depth from the leg centre, with a solid barrier on it and oil the rest of the way.
        let coilSegments = await model.CoilSegments()

        if let outermost = coilSegments.last, let profile = try? await model.CoilVoltageProfile(coil: outermost.radialPos) {

            let r2 = await outermost.r2
            let tankHalfDepth = await model.tankDepth / 2.0
            let tSolid = 0.25 * meterPerInch
            let tOil = tankHalfDepth - r2 - tSolid

            if tOil > 0.0 {

                guard let bs = outermost.basicSections.first else {

                    return
                }

                let column = [DielectricLayer.Paper(bs.wdgData.turn.turnInsulation / 2.0),
                              DielectricLayer.Oil(tOil),
                              DielectricLayer.Pressboard(tSolid)]

                for point in profile {

                    result.append(StressSite(kind: .coilToTank,
                                             location: "Coil \(outermost.radialPos) to tank at z = \(String(format: "%.1f", point.z * 1000.0)) mm",
                                             voltageTerms: [VoltageTerm(nodeIndex: point.nodeIndex, weight: 1.0)],
                                             columns: [column],
                                             innerRadius: r2,
                                             usesCornerModel: true,
                                             gapLength: tOil + tSolid,
                                             // Here the reference electrode IS this coil - the stack starts with its own half-wrap.
                                             // The far electrode is the tank wall, whose surface this model does not know, so there
                                             // is no far view: nil rather than a guessed radius.
                                             cornerRadius: CornerRadius(thickness: bs.wdgData.turn.strandRadial, width: bs.wdgData.turn.strandAxial),
                                             farCornerRadius: nil,
                                             profileName: "Coil \(outermost.radialPos) to tank",
                                             profileHeight: point.z))
                }
            }
        }
    }

    /// The linear-interpolation terms that give a coil's potential at height z, as a weighted pair of its node potentials.
    ///
    /// Piecewise linear is not a modelling choice so much as an admission: the network does not resolve the voltage inside a
    /// Segment, so between two nodes there is no more information to be had.
    private static func InterpolationTerms(profile:[PhaseModel.CoilProfilePoint], z:Double, sign:Double) -> [VoltageTerm] {

        guard let first = profile.first, let last = profile.last else {

            return []
        }

        if z <= first.z {

            return [VoltageTerm(nodeIndex: first.nodeIndex, weight: sign)]
        }

        if z >= last.z {

            return [VoltageTerm(nodeIndex: last.nodeIndex, weight: sign)]
        }

        for i in 0..<(profile.count - 1) {

            let lower = profile[i]
            let upper = profile[i + 1]

            guard z >= lower.z, z <= upper.z else {

                continue
            }

            let span = upper.z - lower.z

            guard span > 0.0 else {

                return [VoltageTerm(nodeIndex: lower.nodeIndex, weight: sign)]
            }

            let t = (z - lower.z) / span

            return [VoltageTerm(nodeIndex: lower.nodeIndex, weight: sign * (1.0 - t)),
                    VoltageTerm(nodeIndex: upper.nodeIndex, weight: sign * t)]
        }

        return [VoltageTerm(nodeIndex: last.nodeIndex, weight: sign)]
    }

    // MARK: The entry point

    /// Build the sites for a model and scan a simulation result against them, worst-first.
    ///
    /// - Parameter capacitiveDistribution: alpha from FrequencyDomainSolver.CapacitiveDistribution, or nil. Supplying it is what
    /// lets the turn-to-turn checks see the t = 0+ wavefront, which the uniform time grid's first sample has already partly missed.
    /// - Parameter peakVoltage: the crest of the impulse, used to put the per-unit alpha into volts.
    static func Report(model:PhaseModel, results:[SimulationModel.SimulationStepResult], capacitiveDistribution:[Double]?, peakVoltage:Double) async -> [StressCheck] {

        let sites = await BuildSites(model: model)

        return Scan(sites: sites, results: results, capacitiveDistribution: capacitiveDistribution, peakVoltage: peakVoltage)
    }

    // MARK: Self-check

    /// A runnable self-check for the field reductions, run by hand because this program has no test target.
    ///
    /// The app is sandboxed, so `print` and `/tmp` are both dead ends: the report goes into UserDefaults. Call it once from
    /// AppDelegate.applicationDidFinishLaunching:
    ///
    ///     DielectricStress.VerifySelf()
    ///
    /// then read it back from a terminal with:
    ///
    ///     defaults read com.huberistech.ImpulseDistribution DielectricStressVerification
    ///
    /// It asserts the things a transcription error would break:
    ///
    ///  1. A single uniform dielectric gives E = V/d exactly.
    ///  2. Two equal layers at eps 1 and 4 divide the field 4:1, and the fields integrate back to V.
    ///  3. The coaxial form collapses onto the laminar one as the curvature vanishes (r/d = 100, within 1%). This is the check that
    ///     covers the corner model too, since CornerField IS CoaxialField at a small radius - if it holds at both extremes of r/d
    ///     the corner result is the geometry talking and not an arithmetic slip.
    ///  4. The corner enhancement reproduces the worked example in CornerField's comment: 2.12x for a 4 mm duct with 0.4 mm of paper
    ///     per face. A drift here means the two-sided/per-side halving of the turn insulation has been changed, or the outer radius
    ///     no longer includes the facing disc's paper.
    static func VerifySelf() {

        var report:[String] = []
        var failures = 0

        func check(_ name:String, _ value:Double, _ expected:Double, tolerance:Double) {

            let error = expected == 0.0 ? abs(value) : abs(value - expected) / abs(expected)
            let passed = error <= tolerance

            if !passed {

                failures += 1
            }

            report.append(String(format: "%@ %@: got %.9e, expected %.9e, rel err %.3e (tol %.1e)", passed ? "PASS" : "FAIL", name, value, expected, error, tolerance))
        }

        // 1. Uniform single dielectric: E = V/d, independent of epsilon.
        let uniform = LaminarField(volts: 1000.0, layers: [DielectricLayer(thickness: 0.005, epsilonR: 2.2, material: .oil)])
        check("uniform single layer", uniform.first ?? 0.0, 1000.0 / 0.005, tolerance: 1.0E-14)

        // 2. Two equal layers, eps 1 and 4: fields divide 4:1 and integrate back to V.
        let split = LaminarField(volts: 1000.0, layers: [DielectricLayer(thickness: 0.002, epsilonR: 1.0, material: .oil),
                                                         DielectricLayer(thickness: 0.002, epsilonR: 4.0, material: .paper)])

        if split.count == 2 {

            check("field ratio at eps 1:4", split[0] / split[1], 4.0, tolerance: 1.0E-14)
            check("fields integrate to V", split[0] * 0.002 + split[1] * 0.002, 1000.0, tolerance: 1.0E-14)
        }
        else {

            failures += 1
            report.append("FAIL two-layer stack returned \(split.count) fields")
        }

        // 3. Coaxial -> laminar as the curvature vanishes.
        let flatStack = [DielectricLayer.Paper(0.0004), DielectricLayer.Oil(0.004), DielectricLayer.Paper(0.0004)]
        let laminar = LaminarField(volts: 1000.0, layers: flatStack)
        let farCoaxial = CoaxialField(volts: 1000.0, layers: flatStack, innerRadius: 0.004 * 100.0)

        if laminar.count == 3, farCoaxial.count == 3 {

            check("coaxial -> laminar at r/d = 100", farCoaxial[1], laminar[1], tolerance: 0.01)
        }
        else {

            failures += 1
            report.append("FAIL coaxial/laminar stacks returned \(farCoaxial.count)/\(laminar.count) fields")
        }

        // 4. The corner enhancement anchor from CornerField's doc comment.
        let corner = CornerField(volts: 1000.0, layers: flatStack)

        if corner.count == 3, laminar.count == 3, laminar[1] > 0.0 {

            check("corner enhancement (4 mm duct, 0.4 mm paper/face)", corner[1] / laminar[1], 2.1159, tolerance: 1.0E-3)
        }
        else {

            failures += 1
            report.append("FAIL corner stack returned \(corner.count) fields")
        }

        // The corner model must never come out BELOW the laminar one - that would mean the radii were assembled backwards.
        if corner.count == 3, laminar.count == 3 {

            let monotone = corner[1] >= laminar[1]
            if !monotone { failures += 1 }
            report.append("\(monotone ? "PASS" : "FAIL") corner field is not below laminar field")
        }

        // 4b. The Essex p.54 corner-radius table. One cell per row of it, plus the rules around its edges: a mistyped bound shows up
        //     as a neighbouring cell's value, which is exactly what these pin. Dimensions are given in inches and converted here so
        //     that they can be read straight off the printed page.
        func inches(_ x:Double) -> Double { return x * meterPerInch }

        check("table 0.750 x 1.000 in.", CornerRadius(thickness: inches(0.750), width: inches(1.000)), 4.78E-3, tolerance: 1.0E-12)
        check("table 0.500 x 1.000 in.", CornerRadius(thickness: inches(0.500), width: inches(1.000)), 3.18E-3, tolerance: 1.0E-12)
        check("table 0.300 x 1.000 in.", CornerRadius(thickness: inches(0.300), width: inches(1.000)), 2.39E-3, tolerance: 1.0E-12)
        check("table 0.200 x 1.000 in.", CornerRadius(thickness: inches(0.200), width: inches(1.000)), 1.60E-3, tolerance: 1.0E-12)
        check("table 0.300 x 0.500 in.", CornerRadius(thickness: inches(0.300), width: inches(0.500)), 1.02E-3, tolerance: 1.0E-12)
        check("table 0.140 x 0.500 in.", CornerRadius(thickness: inches(0.140), width: inches(0.500)), 0.81E-3, tolerance: 1.0E-12)
        check("table 0.110 x 0.150 in.", CornerRadius(thickness: inches(0.110), width: inches(0.150)), 0.66E-3, tolerance: 1.0E-12)
        check("table 0.080 x 0.150 in.", CornerRadius(thickness: inches(0.080), width: inches(0.150)), 0.51E-3, tolerance: 1.0E-12)

        // The band boundaries are closed at the bottom and open at the top ("Under 0.226 to 0.166 Incl."), so 0.166 belongs to the
        // 0.166-0.226 row and anything below it to the next one down.
        check("table boundary 0.166 in. (inclusive low end)", CornerRadius(thickness: inches(0.166), width: inches(0.500)), 1.02E-3, tolerance: 1.0E-12)
        check("table boundary just under 0.166 in.", CornerRadius(thickness: inches(0.1659), width: inches(0.500)), 0.81E-3, tolerance: 1.0E-12)

        // A wide-but-thin strand gets a full rounded edge: half the thickness, not a tabulated radius.
        check("rounded edge, 0.090 x 1.000 in.", CornerRadius(thickness: inches(0.090), width: inches(1.000)), inches(0.090) / 2.0, tolerance: 1.0E-12)
        check("rounded edge, 0.050 x 0.500 in.", CornerRadius(thickness: inches(0.050), width: inches(0.500)), inches(0.050) / 2.0, tolerance: 1.0E-12)

        // The square-wire footnote overrides the table below 0.072 in., and does NOT apply above it.
        check("square wire 0.060 in. footnote", CornerRadius(thickness: inches(0.060), width: inches(0.060)), 0.30E-3, tolerance: 1.0E-12)
        check("square wire 0.080 in. is table, not footnote", CornerRadius(thickness: inches(0.080), width: inches(0.080)), 0.51E-3, tolerance: 1.0E-12)

        // Order must not matter, and a missing dimension must fall back rather than return zero.
        check("table is symmetric in its arguments", CornerRadius(thickness: inches(0.500), width: inches(0.140)), CornerRadius(thickness: inches(0.140), width: inches(0.500)), tolerance: 1.0E-12)
        check("no strand data falls back", CornerRadius(thickness: 0.0, width: 0.010), defaultCornerRadiusOnCopper, tolerance: 1.0E-12)

        // 4c. The two-sided corner model. A gap is read from BOTH electrodes and the worse view kept - see Evaluate.
        //
        //     Symmetric gap: the far view is the near view mirrored, so it must add nothing at all. This is the check that says the
        //     reversal and the index mapping are right, because any slip shows up as a changed answer on a case whose answer is known.
        let nearView = CornerField(volts: 1000.0, layers: flatStack, cornerRadius: 0.81E-3)
        let farView = Array(CornerField(volts: 1000.0, layers: flatStack.reversed(), cornerRadius: 0.81E-3).reversed())

        if nearView.count == 3, farView.count == 3 {

            check("symmetric gap: far view equals near view, oil", farView[1], nearView[1], tolerance: 1.0E-12)
            check("symmetric gap: far view equals near view, near paper", farView[0], nearView[2], tolerance: 1.0E-12)
        }
        else {

            failures += 1
            report.append("FAIL two-sided views returned \(nearView.count)/\(farView.count) fields")
        }

        //     Static ring gap: 0.4 mm of turn paper on a strand corner, a 4 mm duct, then the ring's 3.18 mm of Kraft on its
        //     1.6 mm foil corner. The ring's covering is read at the FAR end by the near view - where its field is lowest - and at
        //     its own corner by the far view. The far view must be the larger, or the model would still be blind to the ring's
        //     own paper, which is the whole reason for reading both ends.
        let ringStack = [DielectricLayer.Paper(0.0004), DielectricLayer.Oil(0.004), DielectricLayer.Paper(Segment.staticRingInsulationPerSide)]
        let ringNear = CornerField(volts: 1000.0, layers: ringStack, cornerRadius: 0.81E-3)
        let ringFar = Array(CornerField(volts: 1000.0, layers: ringStack.reversed(), cornerRadius: Segment.staticRingCornerRadius).reversed())

        if ringNear.count == 3, ringFar.count == 3 {

            let governed = ringFar[2] > ringNear[2]
            if !governed { failures += 1 }
            report.append(String(format: "%@ static ring Kraft is governed by the ring's own corner (%.3f vs %.3f kV/mm)", governed ? "PASS" : "FAIL", ringFar[2] / 1.0E6, ringNear[2] / 1.0E6))
        }
        else {

            failures += 1
            report.append("FAIL static ring stack returned \(ringNear.count)/\(ringFar.count) fields")
        }

        // 4d. The static ring geometry itself, from Weidmann EHV00112-2: T + 2·T1 is the 5/8" finished thickness the program has
        //     always used, to within the drawing's own rounding. A change to any of the three that breaks that sum means one of
        //     them was read wrong.
        check("static ring T + 2*T1 is the 5/8 in. finished thickness", Segment.stdStaticRingThickness, 0.625 * meterPerInch, tolerance: 1.0E-3)
        check("static ring core thickness T", Segment.staticRingCoreThickness, 9.51E-3, tolerance: 1.0E-12)
        check("static ring covering T1 per side", Segment.staticRingInsulationPerSide, 3.18E-3, tolerance: 1.0E-12)
        check("static ring corner radius R1 = R2", Segment.staticRingCornerRadius, 1.6E-3, tolerance: 1.0E-12)

        // 5. The chapter 13 allowables, spot-checked at 1 mm where every power law reduces to its coefficient. This guards the
        //    transcription of the equations themselves - a mistyped coefficient or a sign error on an exponent shows up here.
        let mm = 0.001

        check("13.30 oil impulse at 1 mm", StressAllowable.OilImpulse(gap: mm), 50.0E6, tolerance: 1.0E-12)
        check("13.27 oil power frequency at 1 mm", StressAllowable.OilPowerFrequency(gap: mm), 17.8E6, tolerance: 1.0E-12)
        check("13.4 paper impulse at 1 mm", StressAllowable.PaperImpulse(thickness: mm), 79.43E6, tolerance: 1.0E-12)
        check("13.5 paper power frequency at 1 mm", StressAllowable.PaperPowerFrequency(thickness: mm), 32.8E6, tolerance: 1.0E-12)
        check("13.8 pressboard impulse at 1 mm", StressAllowable.PressboardImpulse(thickness: mm), 91.2E6, tolerance: 1.0E-12)
        check("13.8 pressboard power frequency at 1 mm", StressAllowable.PressboardPowerFrequency(thickness: mm), 27.5E6, tolerance: 1.0E-12)
        check("13.7 pressboard impulse (room temp) at 1 mm", StressAllowable.PressboardImpulseRoomTemperature(thickness: mm), 94.6E6, tolerance: 1.0E-12)
        check("13.16 creep power frequency at 1 mm", StressAllowable.CreepPowerFrequency(path: mm), 16.6E6, tolerance: 1.0E-12)

        // 13.15 is LOGARITHMIC in area, not a power law - at 1 mm² the log vanishes and the value is the bare 16.0 coefficient.
        // A second point pins the 1.09 slope, which is what distinguishes the correct form from the power law it was once mistaken
        // for: at A = e mm², E = 16.0 − 1.09 = 14.91 kV/mm.
        check("13.15 creep by area at 1 mm²", StressAllowable.CreepPowerFrequencyByArea(area: 1.0E-6), 16.0E6, tolerance: 1.0E-12)
        check("13.15 creep by area at e mm² (pins the log slope)", StressAllowable.CreepPowerFrequencyByArea(area: M_E * 1.0E-6), (16.0 - 1.09) * 1.0E6, tolerance: 1.0E-12)

        // ... and it must clamp rather than go negative at very large areas, the caveat the book itself raises for 13.9.
        let hugeArea = StressAllowable.CreepPowerFrequencyByArea(area: 100.0)
        let clamped = hugeArea >= 0.0
        if !clamped { failures += 1 }
        report.append(String(format: "%@ 13.15 clamps at large area (got %.3e V/m)", clamped ? "PASS" : "FAIL", hugeArea))

        // The impulse ratio the book itself uses to get 13.30 from 13.27.
        check("oil impulse ratio", StressAllowable.OilImpulse(gap: mm) / StressAllowable.OilPowerFrequency(gap: mm), 2.8, tolerance: 0.01)

        // The falling distance dependence is the whole reason these are functions: a 4 mm duct must be materially weaker than a
        // 1 mm one. 13.30 at 4 mm is 50·4^(−0.36) = 29.2 kV/mm.
        check("13.30 oil impulse at 4 mm", StressAllowable.OilImpulse(gap: 0.004), 50.0E6 * pow(4.0, -0.36), tolerance: 1.0E-12)

        // Creep must be far weaker than strike over the same distance, which is why it so often governs. At 4 mm: creep
        // 16.6·2.8·4^(−0.46) = 24.4 kV/mm against oil strike 29.2 kV/mm, before the margin.
        let creepAt4mm = StressAllowable.CreepImpulse(path: 0.004)
        let strikeAt4mm = StressAllowable.OilImpulse(gap: 0.004)
        let creepIsWeaker = creepAt4mm < strikeAt4mm
        if !creepIsWeaker { failures += 1 }
        report.append(String(format: "%@ creep is weaker than strike at 4 mm (%.1f vs %.1f kV/mm)", creepIsWeaker ? "PASS" : "FAIL", creepAt4mm / 1.0E6, strikeAt4mm / 1.0E6))

        // The design margin is a user preference now, so what has to hold is not a particular number but the LINK: whatever the
        // user has set is what the allowable the screen judges against actually carries. Preferences.VerifySelf() covers the
        // store itself.
        check("Strike carries the design margin preference", StressAllowable.Strike(for: .oil, thickness: 0.004), StressAllowable.OilImpulse(gap: 0.004) * Preferences.dielectricDesignMargin, tolerance: 1.0E-12)

        report.insert(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED", at: 0)
        report.append("design margin in force: \(DielectricStress.StressAllowable.designMargin)")

        UserDefaults.standard.set(report, forKey: "DielectricStressVerification")
    }
}
