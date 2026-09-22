//
//  BasicSection.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2021-10-06.
//

// This file contains the definition for the most basic section that our program recognizes, along with a few support structs that it uses.

import Cocoa
import PchBasePackage

/// A LocStruct holds the physical location of a coil section in the window.
struct LocStruct:Codable, CustomStringConvertible, Comparable, Sendable {
    
    // Required function for Comparable. Note that the '==' operator is automatically created for us since the member properties of the class (radial and axial) are both of type Int, which is also Comparable.
    // Basically, a section that is part of a coil that is closer to the core is "less than" a section that is further away. If the two sections are in the same coil, then the one closer to the bottom yoke is the 'lesser' of the two.
    static func < (lhs: LocStruct, rhs: LocStruct) -> Bool {
        
        if lhs.radial != rhs.radial {
            
            return lhs.radial < rhs.radial
        }
        else {
            
            return lhs.axial < rhs.axial
        }
    }
    
    
    var description: String {
        
        return "(R:\(self.radial), A:\(self.axial))"
    }
    
    /// The radial location, where 0 is closest to the core leg.
    let radial:Int
    /// The axial location, where 0 is closest to the bottom yoke.
    let axial:Int
}

/// A struct that holds data important to calculations like capacitance. I chose to create this structure instead of dragging around stuff form PCH_ExcelDesignFileReader_ (and thus requiring that that class be attched to any program that this class becomes a part of).
struct BasicSectionWindingData:Codable, Sendable {
    
    /// The winding types that we recognize
    enum WdgType:Int, Codable {
        
        case layer
        case disc
        case helical
        case multistart
        case sheet
    }
    
    /// The WdgType of the section
    let type:WdgType
    
    /// Disc data for the section (only really relevant for disc and helical windings)
    struct DiscData:Codable {
        
        let numAxialColumns:Int
        let axialColumnWidth:Double
    }
    
    let discData:DiscData
    
    /// Layer data for the section (only relevent for layer, sheet, and multistart windings)
    struct LayerData:Codable {
        
        let numLayers:Int
        let interLayerInsulation:Double
        
        struct DuctData:Codable {
            
            let numDucts:Int
            let ductDimn:Double
        }
        
        let ducts:DuctData
    }
    
    let layers:LayerData
    
    /// Turn data for the section
    struct TurnData:Codable {
        
        let radialDimn:Double
        let axialDimn:Double
        let turnInsulation:Double
        let resistancePerMeter:Double
        let strandRadial:Double
        let strandAxial:Double
        
        // calculate the area of copper then divide it by pi and get its square root to come up with an "effective radius"
        var effectiveRadius:Double {
            
            let area = radialDimn * axialDimn
            return sqrt(area / π)
        }
    }
    
    let turn:TurnData

    /// What a multi-start winding needs for DelVecchio 12.12 and nothing else does. Nil for every other winding type.
    ///
    /// A multi-start winding is N_s helical windings ("starts") wound together as one helix and connected in series outside it. Each
    /// revolution of the helix is a GROUP of N_s conductors lying axially side by side, one from each start, and the groups are
    /// separated from each other by the helix's key spacers. The two kinds of interface therefore differ: conductors inside a group
    /// touch paper to paper, while one group faces the next across an oil gap. See Segment.MultiStartSeriesCapacitance.
    struct MultiStartData:Codable {

        /// N_s, the number of starts - the design file's axial cables per turn (`TurnDefinition.multistartLoops`)
        let numStarts:Int
        /// Solid insulation between two adjacent conductors of one group, over and above their own paper - the design file's
        /// internal turn insulation between axial cables. TWO-SIDED like every other insulation figure here; 0 if they simply touch.
        let insulationBetweenStarts:Double
        /// The key-spacer (oil) gap between one group and the next, already shrunk the way the disc windings' gaps are. 0 if the
        /// groups are wound touching.
        let gapBetweenGroups:Double
    }

    var multiStart:MultiStartData? = nil
}

/// This struct defines  the most basic definitiion of a coil section. There are no "electrical" functions defined for the struct. It is basically just used to describe the physical and electrical characteristics of a coil section (either a single disc or a single layer). 
struct BasicSection:Codable, Sendable {
    
    /// The location of the section
    let location:LocStruct
    
    /// The number of turns in the section
    let N:Double
    /// The series current through a single turn in the section
    let I:Double
    
    /// Extra winding data that we need for certain calculations
    let wdgData:BasicSectionWindingData
    
    /// The rectangle that holds the section, assuming that the origin is at (x=coreCenter, y=topOfBottomYoke)
    private var rect:NSRect
    
    /// Deisgnated initializer
    /// - Parameter location: A LocStruct that is the location of the BasicSection in the phase
    /// - Parameter N: The number of turns in the section
    /// - Parameter I: The series current in a single turn of the section
    /// - Parameter wdgData: A BasicSectionWindingData struct for the winding to which the new section belongs
    /// - Parameter rect: The rectangle that the section occupies. The origin is at (LegCenter, BottomYoke)
    init(location:LocStruct, N:Double, I:Double, wdgData:BasicSectionWindingData, rect:NSRect)
    {
        self.location = location
        self.N = N
        self.I = I
        self.rect = rect
        self.wdgData = wdgData
    }
    
    /// The area of the section
    var area:Double {
        get {
            return Double(self.rect.width * self.rect.height)
        }
    }
    
    /// The radial dimension from the core leg center to the left-most edge of the section
    var r1:Double {
        get {
            return Double(self.rect.origin.x)
        }
        set {
            self.rect.origin.x = CGFloat(newValue)
        }
    }
    
    /// The radial dimension from the core leg center to the right-most edge of the section
    var r2:Double {
        get {
            return Double(self.rect.origin.x + self.rect.size.width)
        }
        set {
            self.rect.size.width = CGFloat(newValue) - self.rect.origin.x
        }
    }
    
    /// The axial dimension from the core bottom yoke to the bottom-most edge of the section
    var z1:Double {
        get {
            return Double(self.rect.origin.y)
        }
        set {
            self.rect.origin.y = CGFloat(newValue)
        }
    }
    
    /// The axial dimension from the core bottom yoke to the top-most edge of the section
    var z2:Double {
        get {
            return Double(self.rect.origin.y + self.rect.size.height)
        }
        set {
            self.rect.size.height = CGFloat(newValue) - self.rect.origin.y
        }
    }
    
    /// The axial height of the section
    var height:Double {
        get {
            return Double(self.rect.size.height)
        }
    }
    
    /// The radial build (width) of the section
    var width:Double {
        get {
            return Double(self.rect.size.width)
        }
    }
    
    // MARK: Convenience routines for arrays of BasicSections
    
    /// Routine to find the locations of any non-standard axial gaps in a collection of BasicSections. The return value is an array of indices of the section(s) directly BELOW the gap(s)
    static func AxialGapIndices(basicSections:[BasicSection]) -> [Int] {
        
        if basicSections.isEmpty {
            
            return []
        }
        
        let result:[Int] = []

        for _ in 0..<basicSections.count {

        }

        return result
    }
    
    /// Routine to find the number of coils (radial positions) in the given array of BasicSections. It is assumed that the array is in the order of the locations of the BasicSections.
    static func NumberOfCoils(basicSections:[BasicSection]) -> Int {
        
        guard basicSections.count > 0 else {
            
            return 0
        }
        
        let finalSection = basicSections.last!
        
        return finalSection.location.radial + 1
    }
    
    /// Function to return the indices of the first and last BasicSection of a given coil from the given array of BasicSections. It is assumed that the array is in the order of the locations of the BasicSections.
    static func CoilEnds(coil:Int, basicSections:[BasicSection]) -> (first:Int, last:Int) {
        
        guard basicSections.count > 0 else {
            
            return (-1, -1)
        }
        
        let firstBasicSection = basicSections.firstIndex(where: { $0.location.radial == coil })
        let lastBasicSection = basicSections.lastIndex(where: {$0.location.radial == coil})
        
        guard firstBasicSection != nil, lastBasicSection != nil else {
            
            return (-1, -1)
        }
        
        return (firstBasicSection!, lastBasicSection!)
    }
    
    /// Function to return the number of axial sections in the given coil, from the given array of BasicSections. It is assumed that the array is in the order of the locations of the BasicSections.
    static func NumAxialSections(coil:Int, basicSections:[BasicSection]) -> Int {
        
        let coilEnds = BasicSection.CoilEnds(coil: coil, basicSections: basicSections)
        
        guard coilEnds.first >= 0, coilEnds.last >= 0 else {
            
            return 0
        }
        
        return coilEnds.last - coilEnds.first + 1
    }
    
}
