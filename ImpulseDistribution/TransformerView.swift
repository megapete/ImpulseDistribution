//
//  TransformerView.swift
//  AndersenFE_2020
//
//  Created by Peter Huber on 2020-07-29.
//  Copyright © 2020 Peter Huber. All rights reserved.
//

// The original file for this class comes from AndersenFE_2020. It has been adapted to this program.

import Cocoa
import Carbon.HIToolbox
import PchBasePackage

// Through trial and error, I have discovered that NSView does not like small (<1) dimensions. Since the main units used in transformer design are in meters, I multiply all dimensions that are drawn by 1000 so that the NSView is using numbers that it likes more.
fileprivate let dimensionMultiplier = 1000.0

/// These extensions to NSImage come from the Internet. I only use them for custom cursors and didn't want to bother figuring this stuff out by myself. However, I have commented the code so that I can understand what its doing.
fileprivate extension NSImage {
    
    // PCH: Create a new NSImage by resizing 'self'
    func resized(to newSize: NSSize) -> NSImage? {
        
        // PCH: Create a bitmap image representation. We will draw into this bitmap.
        if let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(newSize.width), pixelsHigh: Int(newSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) {
            bitmapRep.size = newSize
            // PCH: Save the current NSGraphicsContext
            NSGraphicsContext.saveGraphicsState()
            // PCH: Set the current NSGraphicsContexto to our bitmap. Subsequent drawing calls will draw into the bitmap
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
            // PCH: Draw self (an NSImage) into the bitmap. Note that the width and height parameters are the new size - our image will be scaled to fit into those dimensions
            draw(in: NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height), from: .zero, operation: .copy, fraction: 1.0)
            // PCH: Restore the NSGraphicsContext to whatever it was before we did our drawing
            NSGraphicsContext.restoreGraphicsState()
            
            // PCH: At this point, we have a bitmap image with our resized drawing in it, but we need to convert it to an NSimage by using the 'addRepresentation' call.
            let resizedImage = NSImage(size: newSize)
            resizedImage.addRepresentation(bitmapRep)
            return resizedImage
        }
        
        return nil
    }
    
    // PCH: Create a new NSImage by rotating 'self'
    func rotated(by degrees: CGFloat) -> NSImage {
        
        // PCH: Get the sin and cos of the angle (convert to radians first)
        let sinDegrees = abs(sin(degrees * CGFloat.pi / 180.0))
        let cosDegrees = abs(cos(degrees * CGFloat.pi / 180.0))
        
        // PCH: The rectangle that the image will fit into will change based on the rotation angle - calculate the size of the rectangle
        let newSize = CGSize(width: size.height * sinDegrees + size.width * cosDegrees,
                             height: size.width * sinDegrees + size.height * cosDegrees)
        
        // PCH: Create the new rectangle so that it will be centered on the new size
        let imageBounds = NSRect(x: (newSize.width - size.width) / 2,
                                 y: (newSize.height - size.height) / 2,
                                 width: size.width, height: size.height)
        
        // PCH: Create an affine transform (this is an advanced graphics topic). From the Xcode documentatiion: "A transformation specifies how points in one coordinate system are transformed to points in another coordinate system. An affine transformation is a special type of transformation that preserves parallel lines in a path but does not necessarily preserve lengths or angles."
        let otherTransform = NSAffineTransform()
        // PCH: Move to the center of the transform
        otherTransform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        // PCH: Rotate the transform
        otherTransform.rotate(byDegrees: degrees)
        // PCH: Move back to where we started
        otherTransform.translateX(by: -newSize.width / 2, yBy: -newSize.height / 2)
        
        // PCH: Create a new, empty NSImage
        let rotatedImage = NSImage(size: newSize)
        // PCH: Lock the focus of drawing routines to the new NSImage
        rotatedImage.lockFocus()
        // PCH: Multiply the NSImage's transformation matrix by the affine transform's matrix (this is an advanced graphics topic)
        otherTransform.concat()
        // PCH: Draw the new image
        draw(in: imageBounds, from: CGRect.zero, operation: NSCompositingOperation.copy, fraction: 1.0)
        // PCH: Reset the focus
        rotatedImage.unlockFocus()
        
        return rotatedImage
    }
}


/// A struct for representing the segment paths that are displayed by the TransformeView class. Some of this comes from my AndersenFE-2020 program so there are a few things that aren't actually used. Eventually, I will remove unused code.
@MainActor
struct SegmentPath:Equatable, Sendable  {
    
    // This is kind of an ugly way to get "global" access to the TransformerView. Since my program only has one TransformerView available at a time, this works, but it would probably be better to declare it as an instance variable (in case I ever allow more than one TransformerView).
    static var txfoView:TransformerView? = nil
    
    // The Segment that is displayed by this instance
    let segment:Segment
    
    // Local copy of the Segment's rectangle (to avoid 'await' calls when drawing)
    let segRect:NSRect
    // Local copy of the Segment's isStaticRing ivar (to avoid 'await' calls when drawing)
    let segIsStaticRing:Bool
    
    // A holder for future ToolTips for the Segment (not sure what to show yet)
    var toolTipTag:NSView.ToolTipTag = 0
    
    // The actual path that is drawn for the Segment. Note that for a Static Ring, the path is converted from a rectangle to a RoundedRectangle
    func GetPath() -> NSBezierPath {
        
        if segIsStaticRing {
            
            let radius = self.segRect.height / 2.0
            return NSBezierPath(roundedRect: self.GetRect(), xRadius: radius * dimensionMultiplier, yRadius: radius * dimensionMultiplier)
        }
        
        return NSBezierPath(rect: self.GetRect())
    }
    
    // The rectangle that the Segment occupies (multiplied by the dimensionMultiplier global
    func GetRect() -> NSRect {
        
        return self.segRect * dimensionMultiplier
    }
        
    // The color of the Segment
    let segmentColor:NSColor
    
    // The background for the a Segment
    static var bkGroundColor:NSColor = .white
    
    // Unused indicator to show that the Segment is active
    var isActive:Bool {
        get {
            return true
        }
    }
    
    /// Test whether this segment contains 'point'
    func contains(point:NSPoint) -> Bool
    {
        let segPath = self.GetPath()
        
        return segPath.contains(point)
    }
    
    /// constant for showing that a segment is not active (unused)
    let nonActiveAlpha:CGFloat = 0.25
    
    /// Call this function to actually show the Segment. If the Segment is active, then call clear()
    func show() {
        
        if isActive
        {
            self.clear()
        }
        else
        {
            self.fill(alpha: nonActiveAlpha)
        }
    }
    
    /// The stroke() function so that  we can use SegmentPaths in a similar way as NSBezierPaths
    func stroke()
    {
        let path = self.GetPath()
        
        if self.isActive
        {
            self.segmentColor.set()
            path.stroke()
        }
    }
    
    /// The fill() function so that  we can use SegmentPaths in a similar way as NSBezierPaths
    func fill(alpha:CGFloat)
    {
        let path = self.GetPath()
        
        self.segmentColor.withAlphaComponent(alpha).set()
        path.fill()
        self.segmentColor.set()
        path.stroke()
    }
    
    /// fill the path with the background color and stroke the path with the segmentColor
    func clear()
    {
        let path = self.GetPath()
        
        SegmentPath.bkGroundColor.set()
        path.fill()
        self.segmentColor.set()
        path.stroke()
    }
    
    /// Set up the paths for all connectors for this SegmentPath EXCEPT any that end at a Segment in 'maskSegments'. This allows us to avoid redrawing paths. This function is automatically called when the "segments" property of TransformerView is changed. However, it must be called manually when adding (or removing) a connection. The 'viewConnectors' property of the TransformerView is changed by this routine. See the Connector struct and the Segment.Connection struct for more details on how those structures work.
    func SetUpConnectors(allSegments:[Segment], maskSegments:[Int]) async {
                
        let model = SegmentPath.txfoView!.appController!.currentModel!
        let txfoView = SegmentPath.txfoView!

        // The current view scale (as used to size the ground / impulse symbols), so lead stubs stay a consistent size on screen.
        let scaleSize = txfoView.convert(NSSize(width: 1.0, height: 1.0), from: txfoView.scrollView)

        // Geometry-derived routing offsets (Phase 3), so the routing scales with the physical size of the model.
        let stub = txfoView.connectorStubOffset
        let laneGap = txfoView.connectorLaneGap
        let crossMargin = txfoView.connectorCrossoverClearance

        let selfConnections = await self.segment.connections

        // Where a run down a coil flank actually goes. `preferred` is where the routing would put it on its own (the coil
        // edge plus a stub, plus whatever lane it was given); the answer is that, or further out if a radial lead stub
        // crosses the run's axial span - see RadialLeadClearance for why this is a per-run, per-zoom question rather than a
        // constant. `edgeX` is the flank the run measures from, and the result is never pushed more than
        // connectorMaxFlankFraction of the radial gap away from it.
        var leadClearanceCache:[ClearanceKey:Double?] = [:]
        func FlankRunX(preferred:Double, edgeX:Double, coil:Int, span:ClosedRange<Double>, outside:Bool) async -> Double {

            let key = ClearanceKey(coil: coil, outside: outside, spanLow: span.lowerBound, spanHigh: span.upperBound)
            let leadTipX:Double?
            if let cached = leadClearanceCache[key] {

                leadTipX = cached
            }
            else {

                leadTipX = await RadialLeadClearance(coil: coil, span: span, outside: outside, segments: allSegments, scaleSize: scaleSize)
                leadClearanceCache[key] = leadTipX
            }

            guard let leadTipX else {

                return preferred
            }

            let limit = txfoView.connectorRadialUnit * connectorMaxFlankFraction

            if outside {

                return min(max(preferred, leadTipX + laneGap), edgeX + limit)
            }

            return max(min(preferred, leadTipX - laneGap), edgeX - limit)
        }

        for nextConnection in selfConnections {

            if let otherSegmentID = nextConnection.segmentID {

                if maskSegments.contains(otherSegmentID) || otherSegmentID == self.segment.serialNumber {

                    continue
                }
            }

            // One jumper, one line. A connection the user drew is stored once for every Segment that meets each of the two nodes
            // it joins - CompleteAddConnection() adds the whole cross-product of the (Segment, location) pairs at the two ends, and records the
            // result in each copy's equivalentConnections. Two axially adjacent discs meet at the same node, so those copies land
            // a disc gap apart and used to be drawn as two or four lines almost (but not exactly) on top of each other. Drawing
            // only the first member of an equivalence class also keeps the lane assignment honest: the copies have different
            // ViewConnectorIdentities, so assignLane would otherwise spread them into parallel lanes as though they were separate
            // connections. Removing the drawn one still removes the whole class - RemoveConnection() follows the same set.
            if !nextConnection.equivalentConnections.isEmpty, txfoView.viewConnectors.contains(where: { drawnConnector in

                let drawnFrom = drawnConnector.segments.from.serialNumber
                let drawn = Segment.Connection(segmentID: drawnConnector.segments.to?.serialNumber, connector: drawnConnector.connector)

                return nextConnection.equivalentConnections.contains(where: { $0.parent == drawnFrom && $0.connection == drawn })

            }) {

                continue
            }

            let connectorPath = NSBezierPath()
            
            var fromPoint = NSPoint()
            let segRect = await self.segment.rect
            
            switch nextConnection.connector.fromLocation {
            
            case .outside_upper:
                fromPoint = segRect.TopRight()
            
            case .center_upper:
                fromPoint = segRect.TopCenter()
            
            case .inside_upper:
                fromPoint = segRect.TopLeft()
            
            case .outside_center:
                fromPoint = segRect.RightCenter()
            
            case .inside_center:
                fromPoint = segRect.LeftCenter()
            
            case .outside_lower:
                fromPoint = segRect.BottomRight()
            
            case .center_lower:
                fromPoint = segRect.BottomCenter()
            
            case .inside_lower:
                fromPoint = segRect.BottomLeft()
            
            default:
                fromPoint = NSPoint()
            }
            
            // now for the end point of the path
            var toPoint = NSPoint()
            
            if let otherSegID = nextConnection.segmentID, let otherSeg = allSegments.first(where: { $0.serialNumber == otherSegID }) {
                
                let segRect = await otherSeg.rect
                switch nextConnection.connector.toLocation {
                    
                case .outside_upper:
                    toPoint = segRect.TopRight()
                
                case .center_upper:
                    toPoint = segRect.TopCenter()
                
                case .inside_upper:
                    toPoint = segRect.TopLeft()
                
                case .outside_center:
                    toPoint = segRect.RightCenter()
                
                case .inside_center:
                    toPoint = segRect.LeftCenter()
                
                case .outside_lower:
                    toPoint = segRect.BottomRight()
                
                case .center_lower:
                    toPoint = segRect.BottomCenter()
                
                case .inside_lower:
                    toPoint = segRect.BottomLeft()
                
                default:

                    toPoint = NSPoint()
                }

                // Coil ends and tapping gaps carry a floating "lead" stub. If this connection starts and/or ends at
                // such a point, attach it to the tip of the existing lead rather than drawing a new stub beside it.
                if let leadVector = ConnectorLeadVector(for: nextConnection.connector.fromLocation, scaleSize: scaleSize),
                   selfConnections.contains(where: { $0.connector.fromLocation == nextConnection.connector.fromLocation && $0.connector.toLocation == .floating }) {

                    fromPoint = fromPoint + leadVector
                }

                let otherConnections = await otherSeg.connections
                if let leadVector = ConnectorLeadVector(for: nextConnection.connector.toLocation, scaleSize: scaleSize),
                   otherConnections.contains(where: { $0.connector.fromLocation == nextConnection.connector.toLocation && $0.connector.toLocation == .floating }) {

                    toPoint = toPoint + leadVector
                }

                // check if same coil
                if await otherSeg.location.radial == self.segment.location.radial {
                    
                    // check if adjacent section
                    if await model.SegmentsAreAdjacent(segment1: self.segment, segment2: otherSeg) {
                        
                        connectorPath.move(to: fromPoint * dimensionMultiplier)
                        connectorPath.line(to: toPoint * dimensionMultiplier)

                        txfoView.viewConnectors.append(ViewConnector(segments: (self.segment, otherSeg), pathColor: self.segmentColor, connectorType: .adjacent, connectorDirection: .up, connector: nextConnection.connector, path: connectorPath))
                    }
                    else {
                        // non-adjacent section, same coil
                        print("Got a non-adjacent connection from Segment#\(self.segment.serialNumber) to Segment#\(otherSeg.serialNumber)")

                        let currentIdentity = ViewConnectorIdentity(fromSerialNumber: self.segment.serialNumber, toSerialNumber: otherSeg.serialNumber, fromLocation: nextConnection.connector.fromLocation, toLocation: nextConnection.connector.toLocation)
                        var channelUses:[ConnectorChannelUse] = []
                        var lane = 0

                        let fromIsRadialCenter = nextConnection.connector.fromLocation == .center_upper || nextConnection.connector.fromLocation == .center_lower
                        let toIsRadialCenter = nextConnection.connector.toLocation == .center_upper || nextConnection.connector.toLocation == .center_lower

                        if fromIsRadialCenter && toIsRadialCenter {

                            // Both ends are at the radial centre of the coil (typically its top and bottom terminals). A
                            // vertical run alongside would pass through the coil body, so wrap around the outside of the coil.
                            guard let highestSegmentIndex = try? await model.GetHighestSection(coil: self.segment.radialPos) else {

                                return
                            }

                            let highestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: highestSegmentIndex))!
                            let lowestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: 0))!
                            let coilTop = await highestSegment.z2
                            let coilBottom = await lowestSegment.z1

                            // upper terminals exit up over the top, lower terminals exit down under the bottom
                            let fromExitY = nextConnection.connector.fromIsUpper ? coilTop + crossMargin : coilBottom - crossMargin
                            let toExitY = nextConnection.connector.toIsUpper ? coilTop + crossMargin : coilBottom - crossMargin

                            // this one wraps right around the coil, so its span reaches past both ends and it has to clear
                            // every radial lead on the flank
                            let wrapSpan = ConnectorSpan(fromExitY, toExitY)
                            let outsideX = await FlankRunX(preferred: segRect.maxX + stub, edgeX: segRect.maxX, coil: self.segment.radialPos, span: wrapSpan, outside: true)
                            channelUses = [ConnectorChannelUse(channel: .vertical(baseX: outsideX), span: wrapSpan)]
                            lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                            let runX = outsideX + Double(lane) * laneGap

                            connectorPath.move(to: fromPoint * dimensionMultiplier)
                            connectorPath.line(to: NSPoint(x: fromPoint.x, y: fromExitY) * dimensionMultiplier)
                            connectorPath.line(to: NSPoint(x: runX, y: fromExitY) * dimensionMultiplier)
                            connectorPath.line(to: NSPoint(x: runX, y: toExitY) * dimensionMultiplier)
                            connectorPath.line(to: NSPoint(x: toPoint.x, y: toExitY) * dimensionMultiplier)
                            connectorPath.line(to: toPoint * dimensionMultiplier)
                        }
                        else if nextConnection.connector.fromIsOutside {
                            
                            if nextConnection.connector.toIsOutside {

                                let runSpan = ConnectorSpan(fromPoint.y, toPoint.y)
                                let baseX = await FlankRunX(preferred: fromPoint.x + stub, edgeX: fromPoint.x, coil: self.segment.radialPos, span: runSpan, outside: true)
                                channelUses = [ConnectorChannelUse(channel: .vertical(baseX: baseX), span: runSpan)]
                                lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                                let runX = (baseX - fromPoint.x) + Double(lane) * laneGap

                                connectorPath.move(to: fromPoint * dimensionMultiplier)
                                connectorPath.line(to: (fromPoint + NSSize(width: runX, height: 0)) * dimensionMultiplier)
                                connectorPath.line(to: (toPoint + NSSize(width: runX, height: 0)) * dimensionMultiplier)
                                connectorPath.line(to: toPoint * dimensionMultiplier)
                            }
                            else {
                                
                                guard let highestSegmentIndex = try? await model.GetHighestSection(coil: self.segment.radialPos) else {
                                    
                                    return
                                }
                                
                                let highestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: highestSegmentIndex))!
                                let lowestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: 0))!
                                
                                let crossover = ConnectorCrossover(fromZ: fromPoint.y, toZ: toPoint.y, extentBottom: await lowestSegment.z1, extentTop: await highestSegment.z2, margin: crossMargin)
                                let baseChannelY = crossover.baseChannelY
                                let laneSign = crossover.goUp ? 1.0 : -1.0

                                // The two legs run up (or down) the coil's flanks to the cross-over channel, so each has to
                                // clear the radial leads between its own end and the coil extent - not just the ones beside it.
                                let exitX = await FlankRunX(preferred: fromPoint.x + stub, edgeX: fromPoint.x, coil: self.segment.radialPos, span: ConnectorSpan(fromPoint.y, baseChannelY), outside: true)
                                let entryX = await FlankRunX(preferred: toPoint.x - stub, edgeX: toPoint.x, coil: self.segment.radialPos, span: ConnectorSpan(toPoint.y, baseChannelY), outside: false)

                                channelUses = [ConnectorChannelUse(channel: .horizontal(baseY: baseChannelY), span: ConnectorSpan(exitX, entryX))]
                                lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                                let channelY = baseChannelY + laneSign * Double(lane) * laneGap

                                connectorPath.move(to: fromPoint * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: exitX, y: fromPoint.y) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: exitX, y: channelY) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: entryX, y: channelY) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: entryX, y: toPoint.y) * dimensionMultiplier)
                                connectorPath.line(to: toPoint * dimensionMultiplier)
                            }
                        }
                        else { // fromConnector is inside
                            
                            if nextConnection.connector.toIsOutside {
                                
                                guard let highestSegmentIndex = try? await model.GetHighestSection(coil: self.segment.radialPos) else {
                                    
                                    return
                                }
                                
                                let highestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: highestSegmentIndex))!
                                let lowestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: 0))!
                                
                                let crossover = ConnectorCrossover(fromZ: fromPoint.y, toZ: toPoint.y, extentBottom: await lowestSegment.z1, extentTop: await highestSegment.z2, margin: crossMargin)
                                let baseChannelY = crossover.baseChannelY
                                let laneSign = crossover.goUp ? 1.0 : -1.0

                                // mirror of the outside-to-inside case above: this one leaves by the inside flank and arrives
                                // on the outside one
                                let exitX = await FlankRunX(preferred: fromPoint.x - stub, edgeX: fromPoint.x, coil: self.segment.radialPos, span: ConnectorSpan(fromPoint.y, baseChannelY), outside: false)
                                let entryX = await FlankRunX(preferred: toPoint.x + stub, edgeX: toPoint.x, coil: self.segment.radialPos, span: ConnectorSpan(toPoint.y, baseChannelY), outside: true)

                                channelUses = [ConnectorChannelUse(channel: .horizontal(baseY: baseChannelY), span: ConnectorSpan(exitX, entryX))]
                                lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                                let channelY = baseChannelY + laneSign * Double(lane) * laneGap

                                connectorPath.move(to: fromPoint * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: exitX, y: fromPoint.y) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: exitX, y: channelY) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: entryX, y: channelY) * dimensionMultiplier)
                                connectorPath.line(to: NSPoint(x: entryX, y: toPoint.y) * dimensionMultiplier)
                                connectorPath.line(to: toPoint * dimensionMultiplier)
                            }
                            else {

                                let runSpan = ConnectorSpan(fromPoint.y, toPoint.y)
                                let baseX = await FlankRunX(preferred: fromPoint.x - stub, edgeX: fromPoint.x, coil: self.segment.radialPos, span: runSpan, outside: false)
                                channelUses = [ConnectorChannelUse(channel: .vertical(baseX: baseX), span: runSpan)]
                                lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                                let runX = (baseX - fromPoint.x) - Double(lane) * laneGap

                                connectorPath.move(to: fromPoint * dimensionMultiplier)
                                connectorPath.line(to: (fromPoint + NSSize(width: runX, height: 0)) * dimensionMultiplier)
                                connectorPath.line(to: (toPoint + NSSize(width: runX, height: 0)) * dimensionMultiplier)
                                connectorPath.line(to: toPoint * dimensionMultiplier)
                            }
                        }

                        var nonAdjacentConnector = ViewConnector(segments: (self.segment, otherSeg), pathColor: self.segmentColor, connectorType: .adjacent, connectorDirection: .variable, connector: nextConnection.connector, path: connectorPath)
                        nonAdjacentConnector.channelUses = channelUses
                        nonAdjacentConnector.lane = lane
                        txfoView.viewConnectors.append(nonAdjacentConnector)
                    }
                }
                else {
                    
                    // it's to another coil
                    let fromAndToInSameHilo = (otherSeg.radialPos - self.segment.radialPos == 1 && nextConnection.connector.fromIsOutside && !nextConnection.connector.toIsOutside) || (otherSeg.radialPos - self.segment.radialPos == -1 && !nextConnection.connector.fromIsOutside && nextConnection.connector.toIsOutside)
                    
                    guard let highestSegmentIndex = try? await model.GetHighestSection(coil: self.segment.radialPos) else {
                        
                        return
                    }
                    
                    let highestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: highestSegmentIndex))!
                    let lowestSegment = await model.SegmentAt(location: LocStruct(radial: self.segment.radialPos, axial: 0))!

                    // The two flank offsets are settled before anything is drawn, because a leg that runs up to a cross-over
                    // channel may have to be pushed out to clear a radial lead, and that changes where the path starts.
                    let fromIsOutside = nextConnection.connector.fromIsOutside
                    let toIsOutside = nextConnection.connector.toIsOutside
                    var currentX = fromIsOutside ? fromPoint.x + stub : fromPoint.x - stub
                    var currentY = fromPoint.y
                    var channelConnPoint = toIsOutside ? toPoint + NSSize(width: stub, height: 0.0) : toPoint + NSSize(width: -stub, height: 0.0)

                    let currentIdentity = ViewConnectorIdentity(fromSerialNumber: self.segment.serialNumber, toSerialNumber: otherSeg.serialNumber, fromLocation: nextConnection.connector.fromLocation, toLocation: nextConnection.connector.toLocation)
                    var channelUses:[ConnectorChannelUse] = []
                    var lane = 0

                    if !fromAndToInSameHilo {

                        // Find the axial extent spanning every coil between the source and destination so that the
                        // cross-over channel clears them all instead of cutting through an intervening (or taller) coil.
                        let minPos = min(self.segment.radialPos, otherSeg.radialPos)
                        let maxPos = max(self.segment.radialPos, otherSeg.radialPos)
                        var spanTop = await highestSegment.z2
                        var spanBottom = await lowestSegment.z1
                        for coil in minPos...maxPos {

                            guard let hiIdx = try? await model.GetHighestSection(coil: coil),
                                  let hiSeg = await model.SegmentAt(location: LocStruct(radial: coil, axial: hiIdx)),
                                  let loSeg = await model.SegmentAt(location: LocStruct(radial: coil, axial: 0)) else { continue }

                            spanTop = max(spanTop, await hiSeg.z2)
                            spanBottom = min(spanBottom, await loSeg.z1)
                        }

                        let crossover = ConnectorCrossover(fromZ: fromPoint.y, toZ: toPoint.y, extentBottom: spanBottom, extentTop: spanTop, margin: crossMargin)
                        let baseChannelY = crossover.baseChannelY
                        let laneSign = crossover.goUp ? 1.0 : -1.0

                        // Each end climbs its own coil's flank to reach the channel, so each is cleared against that coil's
                        // radial leads - the destination's are a different coil's, which is why the two calls differ in more
                        // than their direction.
                        currentX = await FlankRunX(preferred: currentX, edgeX: fromPoint.x, coil: self.segment.radialPos, span: ConnectorSpan(fromPoint.y, baseChannelY), outside: fromIsOutside)
                        let toFlankX = await FlankRunX(preferred: channelConnPoint.x, edgeX: toPoint.x, coil: otherSeg.radialPos, span: ConnectorSpan(toPoint.y, baseChannelY), outside: toIsOutside)
                        channelConnPoint = NSPoint(x: toFlankX, y: channelConnPoint.y)

                        channelUses = [ConnectorChannelUse(channel: .horizontal(baseY: baseChannelY), span: ConnectorSpan(currentX, channelConnPoint.x))]
                        lane = ViewConnector.assignLane(uses: channelUses, existing: txfoView.viewConnectors, excluding: currentIdentity)
                        currentY = baseChannelY + laneSign * Double(lane) * laneGap
                    }

                    connectorPath.move(to: fromPoint * dimensionMultiplier)
                    connectorPath.line(to: NSPoint(x: currentX, y: fromPoint.y) * dimensionMultiplier)

                    if !fromAndToInSameHilo {

                        connectorPath.line(to: NSPoint(x: currentX, y: currentY) * dimensionMultiplier)
                    }

                    connectorPath.line(to: NSPoint(x: channelConnPoint.x, y: currentY) * dimensionMultiplier)
                    connectorPath.line(to: channelConnPoint * dimensionMultiplier)
                    connectorPath.line(to: toPoint * dimensionMultiplier)

                    var coilToCoilConnector = ViewConnector(segments: (self.segment, otherSeg), pathColor: self.segmentColor, connectorType: .general, connectorDirection: .variable, connector: nextConnection.connector, path: connectorPath)
                    coilToCoilConnector.channelUses = channelUses
                    coilToCoilConnector.lane = lane
                    txfoView.viewConnectors.append(coilToCoilConnector)
                }
            }
            else {
                
                // must be a 'termination' (ground, impulse, or floating). This draws the "lead" stub for a coil end or
                // tapping gap; connectors to this point attach to the tip of this lead (see the routed branches above).
                let fromLoc = nextConnection.connector.fromLocation
                let leadVector = ConnectorLeadVector(for: fromLoc, scaleSize: scaleSize) ?? NSPoint()
                toPoint = fromPoint + NSSize(width: leadVector.x, height: leadVector.y)

                var specialDirection = ViewConnector.direction.down
                if fromLoc == .center_upper || fromLoc == .inside_upper || fromLoc == .outside_upper {

                    specialDirection = .up
                }
                else if fromLoc == .outside_center {

                    specialDirection = .right
                }
                else if fromLoc == .inside_center {

                    specialDirection = .left
                }

                connectorPath.move(to: fromPoint * dimensionMultiplier)
                connectorPath.line(to: toPoint * dimensionMultiplier)

                let toLoc = nextConnection.connector.toLocation
                if toLoc == .ground {

                    let gndConnector = ViewConnector.GroundConnection(connectionPoint: toPoint * dimensionMultiplier, segments: (self.segment, nil), connector: nextConnection.connector, owner: SegmentPath.txfoView!, connectorDirection: specialDirection)
                    txfoView.viewConnectors.append(gndConnector)
                }
                else if toLoc == .impulse {

                    let impConnector = ViewConnector.ImpulseConnection(connectionPoint: toPoint * dimensionMultiplier, segments: (self.segment, nil), connector: nextConnection.connector, owner: SegmentPath.txfoView!, connectorDirection: specialDirection)
                    txfoView.viewConnectors.append(impConnector)
                }

                txfoView.viewConnectors.append(ViewConnector(segments: (self.segment, nil), pathColor: self.segmentColor, connectorType: .general, connectorDirection: specialDirection, connector: nextConnection.connector, path: connectorPath))
            }
        }
    }
}

/// Definition and drawing routines for Ground, Impulse, and connections between non-adjacent coil segments. Note that dimensions passed in to routines in the struct are expected to be in the model's coordiantes (including the 'dimensionMultiplier' global variable). The fancy cursors are also defined here.
// @MainActor
struct ViewConnector : Equatable {
    
    static func == (lhs: ViewConnector, rhs: ViewConnector) -> Bool {
        
        return lhs.segments.from == rhs.segments.from && lhs.segments.to == rhs.segments.to
    }
    
    /// The different types of connectors
    enum type {
        
        case ground
        case impulse
        case general
        case adjacent
    }
    
    /// The direction of the connector (the reasoning for this enum is evolving - it will probably be  changed in some future version of the program)
    enum direction {
        
        case variable
        case up
        case down
        case left
        case right
    }
    
    /// The Segments associated with the connector. There is always a 'from' Segment and there may be a 'to' Segment
    var segments:(from:Segment, to:Segment?)
    
    /// The global Ground cursor and its creation routine
    @MainActor static let GroundCursor:NSCursor = ViewConnector.LoadGroundCursor()
    
    static func LoadGroundCursor() -> NSCursor {
        
        if let groundImage = NSImage(named: "Ground") {
            
            let imageSize = groundImage.size
            print("ground image size: \(imageSize)")
            let groundCursor = NSCursor(image: groundImage, hotSpot: NSPoint(x: 8, y: 1))
            
            return groundCursor
        }
    
        // couldn't load the cursor image, just show the arrow
        return NSCursor.arrow
    }
    
    /// The global Impulse cursor and its creation routine
    @MainActor static let ImpulseCursor:NSCursor = ViewConnector.LoadImpulseCursor()
    
    static let impulseImagePoint = NSPoint(x: 9, y: 22)
   
    static func LoadImpulseCursor() -> NSCursor {
        
        if let impulseImage = NSImage(named: "Impulse") {
            
            let impulseCursor = NSCursor(image: impulseImage, hotSpot: ViewConnector.impulseImagePoint)
            
            return impulseCursor
        }
    
        // couldn't load the cursor image, just show the arrow
        return NSCursor.arrow
    }
    
    /// The global Add Connection cursor and its creation routine
    @MainActor static let AddConnectionCursor:NSCursor = ViewConnector.LoadAddConnectorCursor()
    
    static func LoadAddConnectorCursor() -> NSCursor {
        
        if let addCursor = NSImage(named: "AddConnector") {
            
            let addConnCursor = NSCursor(image: addCursor, hotSpot: NSPoint(x: 7, y: 9))
            
            return addConnCursor
        }
        
        return NSCursor.arrow
    }
    
    /// The global pliers cursor and its creation routine
    @MainActor static let PliersCursor:NSCursor = ViewConnector.LoadPliersCursor()
    
    static func LoadPliersCursor() -> NSCursor {
        
        if let pliersImage = NSImage(named: "Pliers") {
            
            if let scaledPliers = pliersImage.resized(to: NSSize(width: 16, height: 24)) {
            
                // The image of the pliers is pointing straight up, so rotate it 45 degrees so it looks better
                let rotatedPliers = scaledPliers.rotated(by: 45.0)
                let pliersCursor = NSCursor(image: rotatedPliers, hotSpot: NSPoint(x: 6, y: 8))
                
                return pliersCursor
            }
        }
        
        // couldn't load the cursor image, just show the arrow
        return NSCursor.arrow
    }
    
    /// The circle that shows we're "connected"
    static let connectorCircleRadius = 1.5

    /// The color of a ground symbol. This is a *dark* green (6.05:1 against the white background) because a saturated one is
    /// the worst ink there is on white: the green channel carries ~72% of the luminance signal, so the `.green` this replaced
    /// measured **1.37:1** and read as a faint smear. Only the lightness has been moved - the hue is untouched, which is why
    /// it still reads as green. See `AppController.segmentColors` for the same reasoning applied to the coils.
    static let groundColor:NSColor = NSColor(srgbRed: 0.00, green: 0.45, blue: 0.15, alpha: 1.0)

    /// The color of an impulse symbol: a darkened red (5.89:1 against white, where `.red` was 4.00:1). Red and green are
    /// reserved for the two terminations and appear in no coil's palette, so an impulse or a ground is identifiable by colour
    /// alone no matter which coil it lands on.
    static let impulseColor:NSColor = NSColor(srgbRed: 0.80, green: 0.00, blue: 0.00, alpha: 1.0)


    /// The color of the connector (only used if the 'path' property is not nil)
    let pathColor:NSColor
    
    /// The type
    let connectorType:ViewConnector.type
    
    /// The direction
    let connectorDirection:ViewConnector.direction
    
    /// The connector itself
    let connector:Connector
    
    // A ViewConnector can have only a path, or a path and an image
    /// The drawn path
    var path:NSBezierPath
    
    /// Or the image to display
    var image:NSImage? = nil
    
    /// The destination rectangle (in model coordinates) of the image
    var imageRect:NSRect = NSRect()

    // MARK: Phase 1 routing metadata (used to spread overlapping connectors into parallel lanes)

    /// The routing channels this connector occupies, if it is lane-managed (empty ⇒ not lane-managed).
    var channelUses:[ConnectorChannelUse] = []
    /// The parallel-lane index assigned to this connector within its shared channels.
    var lane:Int = 0

    /// The identity of the logical connection this ViewConnector belongs to (duplicates share an identity).
    var identity:ViewConnectorIdentity {

        return ViewConnectorIdentity(fromSerialNumber: segments.from.serialNumber, toSerialNumber: segments.to?.serialNumber, fromLocation: connector.fromLocation, toLocation: connector.toLocation)
    }

    /// Assign the lowest lane index not used by any already-placed connector that shares a channel with an
    /// overlapping span. Connectors that belong to the connection being (re)drawn are excluded, and duplicate
    /// copies of any other connection are counted only once, so the result is stable across redraws.
    static func assignLane(uses:[ConnectorChannelUse], existing:[ViewConnector], excluding identity:ViewConnectorIdentity) -> Int {

        guard !uses.isEmpty else { return 0 }

        var seenIdentities:Set<ViewConnectorIdentity> = []
        var usedLanes:Set<Int> = []

        for existingConnector in existing {

            let existingIdentity = existingConnector.identity
            if existingIdentity == identity { continue }
            if !seenIdentities.insert(existingIdentity).inserted { continue }

            let conflicts = existingConnector.channelUses.contains { existingUse in
                uses.contains { newUse in existingUse.channel == newUse.channel && existingUse.span.overlaps(newUse.span) }
            }

            if conflicts { usedLanes.insert(existingConnector.lane) }
        }

        var lane = 0
        while usedLanes.contains(lane) { lane += 1 }
        return lane
    }

    /// The end points of the path
    var endPoints:(p1:NSPoint, p2:NSPoint) {
        
        var result = (NSPoint(), NSPoint())
        
        let path = self.path
        
        let numElements = path.elementCount
        
        if numElements > 1 {
            
            var pointArray:[NSPoint] = Array(repeating: NSPoint(), count: 3)
            var _ = path.element(at: 0, associatedPoints: &pointArray)
            let point1 = pointArray[0]
            path.element(at: 1, associatedPoints: &pointArray)
            let point2 = pointArray[0]
            
            result = (point1, point2)
        }
        
        return result
    }
    
    /// Return the end point of this SegmentPath that is closest to the given point (in TransformerView dimensions)
    func ClosestEndPoint(toPoint:NSPoint) -> NSPoint {
        
        let points = self.endPoints
        
        if toPoint.Distance(otherPoint: points.p1) <= toPoint.Distance(otherPoint: points.p2) {
            
            return points.p1
        }
        
        return points.p2
    }
    
    /// The "hit zone" for the connector. This can be polled by the NSBezierPath function 'contains' to see if a mouse click in in this hit zone.
    ///
    /// The zone is a fixed size **on screen**, converted out of the scrollView the same way the lead stubs and the ground /
    /// impulse symbols are. It used to be a model dimension (3 mm of winding), which is the wrong frame of reference for a
    /// pointing target: aiming is done in screen space by a hand, so a zone in model space grew when the user zoomed in - when
    /// the lead was already easy to hit - and shrank to nothing when zoomed out, which is exactly when help was wanted.
    @MainActor
    var hitZone:NSBezierPath {
        get {

            let result = NSBezierPath()

            // view units per screen point; the identity fallback only applies before the view has been set up
            let scaleSize = SegmentPath.txfoView.map({ $0.convert(NSSize(width: 1.0, height: 1.0), from: $0.scrollView) }) ?? NSSize(width: 1.0, height: 1.0)
            let insetX = TransformerViewConstants.connectorHitTolerance * scaleSize.width
            let insetY = TransformerViewConstants.connectorHitTolerance * scaleSize.height

            let numElements = path.elementCount
            
            if numElements > 1 {
                
                var pointArray:[NSPoint] = Array(repeating: NSPoint(), count: 3)
                var _ = path.element(at: 0, associatedPoints: &pointArray)
                var point1 = pointArray[0]
                
                for i in 1..<numElements {
            
                    _ = path.element(at: i, associatedPoints: &pointArray)
                    let point2 = pointArray[0]
                    
                    // Convert the line into a rectangle for hit-testing. I came up with this all by myself.
                    let nextZoneRect = NSInsetRect(NormalizeRect(srcRect: NSRect(x: point1.x, y: point1.y, width: point2.x - point1.x, height: point2.y - point1.y)), -insetX, -insetY)
                    
                    result.append(NSBezierPath(rect: nextZoneRect))
                    
                    if (i < numElements - 1) {
                        
                        point1 = point2
                    }
                }
            }
            
            return result
        }
    }
    
    /// Function to draw an Impulse connection image at the given NSPoint and in the given direction.
    /// - Parameter connectionPoint: The point (in TransformerView coordinates) where the connector will be drawn. This should be an EndPoint of a ViewConnector.
    /// - Parameter segments: Needed for the call to ViewConnector(). The 'to' member should always be 'nil'
    /// - Parameter connector: The Connector that this will replace
    /// - Parameter owner: The TransformerView that is to display this connector
    /// - Parameter connectorDirection: The direction that the new connector should point in
    /// - Returns: A ViewConnector
    @MainActor static func ImpulseConnection(connectionPoint:NSPoint, segments:(from:Segment, to:Segment?), connector:Connector, owner:TransformerView, connectorDirection:ViewConnector.direction) -> ViewConnector {
        
        // Get the scale from the scrollView
        let scaleSize = owner.convert(NSSize(width: 1.0, height: 1.0), from: owner.scrollView)

        // set theta from the direction so the lead points into free space (matching GroundConnection)
        var theta = 0.0
        if connectorDirection == .up {
            theta = 0.5 * π
        }
        else if connectorDirection == .left {
            theta = π
        }
        else if connectorDirection == .down {
            theta = 1.5 * π
        }

        // set up the lead (it points to the right at theta = 0) and rotate it to the requested direction
        let leadEndPoint = NSPoint(x: 10.0 * scaleSize.width, y: 0.0).Rotate(theta: theta)

        let circleRadius = ViewConnector.connectorCircleRadius * scaleSize.width
        let circleRectOrigin = connectionPoint + NSSize(width: -circleRadius, height: -circleRadius)
        let circleRect = NSRect(origin: circleRectOrigin, size: NSSize(width: circleRadius * 2, height: circleRadius * 2))
        let path = NSBezierPath(roundedRect: circleRect, xRadius: circleRadius, yRadius: circleRadius)
        
        // print("Connection: \(connectionPoint), leadEnd: \(leadEndPoint), Connection + leadEnd: \(connectionPoint + leadEndPoint)")
        
        path.move(to: connectionPoint)
        path.relativeLine(to: leadEndPoint)
        
        let impulseImage = NSImage(named: "Impulse")
        
        var imageRect = NSRect()
        if let image = impulseImage {
            
            let anchor = NSPoint(x: impulseImagePoint.x, y: image.size.height - impulseImagePoint.y) * scaleSize.width
            imageRect = NSRect(x: (connectionPoint + leadEndPoint).x - anchor.x, y: (connectionPoint + leadEndPoint).y - anchor.y, width: image.size.width * scaleSize.width, height: image.size.height * scaleSize.height)
        }
        
        return ViewConnector(segments:segments, pathColor: ViewConnector.impulseColor, connectorType: .impulse, connectorDirection: connectorDirection, connector: connector, path: path, image: impulseImage, imageRect: imageRect)
    }
    
    /// Function to draw a ground connection image at the given NSPoint and in the given direction.
    /// - Parameter connectionPoint: The point (in TransformerView coordinates) where the connector will be drawn. This should be an EndPoint of a ViewConnector.
    /// - Parameter segments: Needed for the call to ViewConnector(). The 'to' member should always be 'nil'
    /// - Parameter connector: The Connector that this will replace
    /// - Parameter owner: The TransformerView that is to display this connector
    /// - Parameter connectorDirection: The direction that the new connector should point in
    /// - Returns: A ViewConnector
    @MainActor static func GroundConnection(connectionPoint:NSPoint, segments:(from:Segment, to:Segment?), connector:Connector, owner:TransformerView, connectorDirection:ViewConnector.direction) -> ViewConnector {
        
        // set theta according to the direction that was passed into the routine - this value will be used to calculate the rotation matrix
        var theta = 0.0
        if connectorDirection == .up {
            theta = 0.5 * π
        }
        else if connectorDirection == .left {
            theta = π
        }
        else if connectorDirection == .down {
            theta = 1.5 * π
        }
        
        // Get the scale from the scrollView
        let scaleSize = owner.convert(NSSize(width: 1.0, height: 1.0), from: owner.scrollView)
        // set up the grounding arrow as if it is pointing to the right (theta = 0)
        let leadEndPoint = NSPoint(x: 10.0 * scaleSize.width, y: 0.0)
        let toFirstLine = NSPoint(x: 0.0, y: -8.5 * scaleSize.height)
        let toEndFirstLine = NSPoint(x: 0.0, y: 17.0 * scaleSize.height)
        
        let circleRadius = ViewConnector.connectorCircleRadius * scaleSize.width
        let circleRectOrigin = connectionPoint + NSSize(width: -circleRadius, height: -circleRadius)
        let circleRect = NSRect(origin: circleRectOrigin, size: NSSize(width: circleRadius * 2, height: circleRadius * 2))
        let path = NSBezierPath(roundedRect: circleRect, xRadius: circleRadius, yRadius: circleRadius)
        
        //let path = Circle(center: connectionPoint, radius: ViewConnector.connectorCircleRadius * scaleSize.width).path
        path.move(to: connectionPoint)
        
        // apply the rotation matrix to the points on the grounding symbol before adding it to the path
        path.relativeLine(to: leadEndPoint.Rotate(theta: theta))
        path.relativeMove(to: toFirstLine.Rotate(theta: theta))
        path.relativeLine(to: toEndFirstLine.Rotate(theta: theta))
        
        let heightOffset = 2.0 * scaleSize.height
        let widthOffset = 2.0 * scaleSize.width
        var lastHeight = toEndFirstLine.y
        for _ in 0..<3 {
            
            path.relativeMove(to: NSPoint(x: widthOffset, y: -lastHeight + heightOffset).Rotate(theta: theta))
            lastHeight -= 2 * heightOffset
            path.relativeLine(to: NSPoint(x: 0.0, y: lastHeight).Rotate(theta: theta))
            
        }
        
        return ViewConnector(segments:segments, pathColor: ViewConnector.groundColor, connectorType: .ground, connectorDirection: connectorDirection, connector: connector, path: path)
    }
}

/// Constants associated with TransformerView that are placed here to get them out of the MainActor
struct TransformerViewConstants {

    /// How far (in view points at magnification 1, ie: on screen) either side of a connector still counts as a hit. `hitZone`
    /// inflates every leg of the connector's path by this, so it is what decides how close the mouse has to be to pick a lead
    /// up - in add-connection, add-ground, add-impulse and remove-connector modes alike.
    ///
    /// 4 points is deliberately more than the "pixel or two" it looks like it should be. The line itself is 1.5 points wide,
    /// so this makes a corridor about 9.5 points across, and that is roughly where the drawing programs that do this for a
    /// living sit (Illustrator's selection tolerance defaults to 4 px, AutoCAD's pickbox to about 5). The reason is that the
    /// hand is not the limit - stopping is: a pointer being moved has to be *halted* on the target, and the overshoot in that
    /// is a few points however steady the hand. Note the cost of going much further: neighbouring lanes are spaced by a model
    /// dimension, so zoomed out they converge on screen, and a zone wide enough to cover two of them makes the first one in
    /// `viewConnectors` win rather than the nearest.
    static let connectorHitTolerance = 4.0 // view points
}

// MARK: - Connector lane routing (Phase 1: overlap avoidance)

// The routing offsets below are the fallback defaults; TransformerView.UpdateConnectorMetrics() overrides them with
// values derived from the model geometry (Phase 3) so they scale with the physical size of the model.

/// Default spacing (in model meters) between parallel connector lanes that share a routing channel.
let connectorLaneSpacing = 0.004
/// Default radial offset (in model meters) that a connector steps out of a coil into the adjacent gap.
let connectorStubDefault = 0.010
/// Default axial clearance (in model meters) between the winding extent and the horizontal cross-over channel.
let connectorCrossoverMargin = 0.055

// Fractions used to derive the routing offsets from the model geometry (see UpdateConnectorMetrics). Chosen so that a
// typical mid-size winding reproduces roughly the previous fixed offsets.
/// Fraction of the tightest radial gap used for the step-out stub.
let connectorStubGapFraction = 0.33
/// Fraction of the tightest radial gap used for the spacing between parallel lanes.
let connectorLaneGapFraction = 0.15
/// Fraction of the winding height used for the axial cross-over clearance.
let connectorCrossoverHeightFraction = 0.035
/// The on-screen length (in view points at magnification 1) of the lead stub drawn for a coil-end or tapping-gap
/// (floating / ground / impulse) termination. It is scaled by the current view scale so it stays a consistent size on
/// screen (like the ground / impulse symbols). Halved again on 2026-08-12 (it was 12.5, itself half of the original fixed
/// length) because the stubs read as too long. Shortening a lead also makes it *less* likely to reach a routing lane and so
/// to need clearing - see `RadialLeadClearance` - but the two are independent knobs and neither assumes a value of the other.
let connectorLeadScreenLength = 6.25
/// The on-screen distance (view points at magnification 1) a **ground** symbol reaches beyond the tip of the lead it hangs
/// on: `GroundConnection` draws 10 points of arrow lead and then three bars at +2, +4 and +6. Kept beside that routine's
/// numbers - if the symbol is redrawn, this has to follow, or a connector routed to clear it will clip it.
let groundSymbolScreenReach = 16.0
/// The same figure for an **impulse** symbol: `ImpulseConnection` draws 10 points of lead, then hangs the 24-point-wide bolt
/// image from an anchor 9 points in from its left edge, so the image reaches 15 points past the lead end.
let impulseSymbolScreenReach = 25.0
/// The furthest a flank run may be pushed out from a coil edge to clear a lead stub, as a fraction of the radial unit (the
/// tightest hilo gap). A lead - especially a grounded or impulsed one, which carries a symbol on its tip - can be longer
/// than the gap it sits in, and a run pushed out far enough to clear THAT would be drawn through the neighbouring coil.
/// Crossing a lead is untidy; routing through a winding is wrong, so the clearance gives up rather than cross the gap.
let connectorMaxFlankFraction = 0.8
/// Coordinate quantum (in model meters) used to decide whether two connector runs share a channel.
private let connectorChannelQuantum = 0.002

/// Identifies a routing channel (a shared straight run) that connectors can occupy, so that several
/// connectors using the same channel can be spread out into parallel lanes instead of overlapping.
struct ConnectorChannel:Hashable {

    enum Orientation { case vertical, horizontal }

    let orientation:Orientation
    /// The quantized base coordinate of the run (the x-value for a vertical run, the y-value for a horizontal run).
    let coordinateKey:Int

    static func vertical(baseX:Double) -> ConnectorChannel {

        return ConnectorChannel(orientation: .vertical, coordinateKey: Int((baseX / connectorChannelQuantum).rounded()))
    }

    static func horizontal(baseY:Double) -> ConnectorChannel {

        return ConnectorChannel(orientation: .horizontal, coordinateKey: Int((baseY / connectorChannelQuantum).rounded()))
    }
}

/// A connector's occupancy of a channel over a given span (the extent along the run direction), in model meters.
struct ConnectorChannelUse {

    let channel:ConnectorChannel
    let span:ClosedRange<Double>
}

/// Key for `SetUpConnectors`' per-call cache of radial-lead clearances. The scan behind one answer walks every connection of
/// every Segment in a coil, and a Segment carrying several routed connections asks the same question more than once.
struct ClearanceKey:Hashable {

    let coil:Int
    let outside:Bool
    let spanLow:Double
    let spanHigh:Double
}

/// Identifies a logical connection so that duplicate ViewConnectors (e.g. a ground symbol plus its lead, or a
/// connector that is re-drawn on an incremental update) are counted only once during lane assignment.
struct ViewConnectorIdentity:Hashable {

    let fromSerialNumber:Int
    let toSerialNumber:Int?
    let fromLocation:Connector.Location
    let toLocation:Connector.Location
}

/// A closed range built from the two given values in either order.
func ConnectorSpan(_ a:Double, _ b:Double) -> ClosedRange<Double> {

    return Swift.min(a, b)...Swift.max(a, b)
}

/// The lead (stub) vector, in model coordinates, that a floating coil-end / tapping-gap termination draws from its
/// take-off location (matching the geometry drawn in the termination branch of SetUpConnectors). The length is derived
/// from the current view scale (`scaleSize`, as used by the ground / impulse symbols) so the lead is a consistent size
/// on screen, then divided by dimensionMultiplier to bring it back into model coordinates. A connector to a location
/// that has such a lead attaches to the tip (take-off point + this vector) instead of drawing its own stub. Returns nil
/// for locations that do not have a lead.
func ConnectorLeadVector(for location:Connector.Location, scaleSize:NSSize) -> NSPoint? {

    let dx = connectorLeadScreenLength * scaleSize.width / dimensionMultiplier
    let dy = connectorLeadScreenLength * scaleSize.height / dimensionMultiplier

    switch location {

    case .center_lower, .inside_lower, .outside_lower:
        return NSPoint(x: 0.0, y: -dy)

    case .center_upper, .inside_upper, .outside_upper:
        return NSPoint(x: 0.0, y: dy)

    case .outside_center:
        return NSPoint(x: dx, y: 0.0)

    case .inside_center:
        return NSPoint(x: -dx, y: 0.0)

    default:
        return nil
    }
}

/// The outward reach, in model coordinates, of a **radial** lead stub - the kind drawn at `inside_center`/`outside_center`,
/// ie: at a tapping gap or the break in a double-stacked winding - measured from the coil edge it takes off from, and
/// including whatever symbol sits on its tip. A plain floating lead reaches `connectorLeadScreenLength`; a ground or an
/// impulse reaches further, because the symbol is drawn beyond the lead's end (see the two `*SymbolScreenReach` constants).
/// Only the radial locations have any reach worth speaking of: the leads at `*_upper`/`*_lower` run axially, along the coil
/// edge rather than out into the gap the connectors are routed through.
func RadialLeadReach(termination:Connector.Location, scaleSize:NSSize) -> Double {

    var screenLength = connectorLeadScreenLength

    if termination == .ground {

        screenLength += groundSymbolScreenReach
    }
    else if termination == .impulse {

        screenLength += impulseSymbolScreenReach
    }

    return screenLength * scaleSize.width / dimensionMultiplier
}

/// The x-coordinate that a vertical connector run down one flank of `coil` has to get past to miss the radial lead stubs it
/// would otherwise cross, or nil if it crosses none. Only leads whose take-off point lies **within the run's axial span**
/// count: a jumper between two discs above a tapping gap has no reason to be pushed out by the gap's lead, and pushing every
/// run out to clear every lead would waste the radial gap the routing lives in.
///
/// This is deliberately recomputed on each rebuild rather than folded into `connectorStubOffset` once. A lead is drawn at a
/// constant length **on screen** (like the ground and impulse symbols), so how far it reaches in *model* coordinates - which
/// is what the routing is laid out in - depends entirely on the current zoom. At a high magnification a lead is a whisker
/// and nothing has to move; zoomed out it is longer than the stub offset, which is the case the user sees a connector drawn
/// straight through it.
func RadialLeadClearance(coil:Int, span:ClosedRange<Double>, outside:Bool, segments:[Segment], scaleSize:NSSize) async -> Double? {

    let leadLocation:Connector.Location = outside ? .outside_center : .inside_center
    var result:Double? = nil

    for nextSegment in segments where nextSegment.radialPos == coil {

        let connections = await nextSegment.connections

        for nextConnection in connections {

            // a termination (and so a drawn lead) is a connection with no destination Segment
            guard nextConnection.segmentID == nil, nextConnection.connector.fromLocation == leadLocation else {

                continue
            }

            let leadRect = await nextSegment.rect

            guard span.contains(leadRect.midY) else {

                continue
            }

            let reach = RadialLeadReach(termination: nextConnection.connector.toLocation, scaleSize: scaleSize)
            let tipX = outside ? leadRect.maxX + reach : leadRect.minX - reach

            result = result.map({ outside ? max($0, tipX) : min($0, tipX) }) ?? tipX
        }
    }

    return result
}

/// Decide whether a connector should route over the top or under the bottom of the given axial extent, choosing
/// whichever gives the shorter total vertical travel for the two endpoints. Returns the direction and the base
/// cross-over channel Y (the height of the horizontal run, before any lane offset), in model coordinates.
func ConnectorCrossover(fromZ:Double, toZ:Double, extentBottom:Double, extentTop:Double, margin:Double) -> (goUp:Bool, baseChannelY:Double) {

    let costUp = (extentTop - fromZ) + (extentTop - toZ)
    let costDown = (fromZ - extentBottom) + (toZ - extentBottom)
    let goUp = costUp <= costDown

    return (goUp, goUp ? extentTop + margin : extentBottom - margin)
}

/// The class that actually displays all the Segments the current model, along with all Connectors. There are also routines to update the mouse cursor depending on the current mode of the TransformerView, as well as mouseDown routines that do different things depending on the mode. See each function for a biref description of what it does. This class derives from NSView and conforms to the NSViewToolTipOwner and NSMenuItemValidation protocols.
@MainActor
class TransformerView: NSView, NSViewToolTipOwner, NSMenuItemValidation {
    
    /// I suppose that I could get fancy and create a TransformerViewDelegate protocol but since the calls are so specific, I'm unable to justify the extra complexity, so I'll just save a weak reference to the AppController here. The AppController will need to stuff a pointer to itself in here, probably best done in awakeFromNib()
    weak var appController:AppController? = nil
    
    /// The different modes that are available
    enum Mode {
        
        /// Select a segment
        case selectSegment
        /// Use a rectangle to select one or more segments
        case selectRect
        /// Use a rectangle to zoom in on a certain section of the TransformerView
        case zoomRect
        /// Add a ground connector
        case addGround
        /// Add an impulse connector
        case addImpulse
        /// Add a connector between any two existing connectors
        case addConnection
        /// Remove a connector
        case removeConnector
    }
    
    /// The actual storage for the TransformerView's mode
    private var modeStore:Mode = .selectSegment

    /// The cursor that belongs to the current mode.
    ///
    /// AppKit owns the cursor. A bare `NSCursor.set()` is a one-shot that survives only until the next time the window
    /// recalculates its cursor rectangles - which a redraw does - after which the pointer falls back to the arrow. That is why
    /// adding a ground used to put the arrow back the moment the connector was drawn, even though the mode was still
    /// `.addGround`: nothing had changed the mode, only the cursor had been forgotten. Declaring a cursor *rect* instead
    /// (see `resetCursorRects`) makes the mode's cursor the view's steady state, so it stays until the mode itself changes.
    var modeCursor:NSCursor {

        switch self.modeStore {

        case .selectSegment:
            return .arrow

        case .selectRect, .zoomRect:
            return .crosshair

        case .addGround:
            return ViewConnector.GroundCursor

        case .addImpulse:
            return ViewConnector.ImpulseCursor

        case .addConnection:
            return ViewConnector.AddConnectionCursor

        case .removeConnector:
            return ViewConnector.PliersCursor
        }
    }

    // Hand AppKit the cursor for the current mode over the whole view, and let it re-apply it whenever it likes.
    override func resetCursorRects() {

        self.addCursorRect(self.bounds, cursor: self.modeCursor)
    }

    /// A computed property for the mode of the TransformerView. The getter just returns the current mode, but the setter does things like update the mode indicator field at the bottom of the window and change the cursor (if necessary)
    var mode:Mode {
        
        get {
            
            return self.modeStore
        }
        
        set {

            // Leaving addConnection with a half-finished gesture (the Esc key, a right-click, another mode picked from a
            // menu) drops the rubber band and the start connector. Doing it here rather than in each of those places is
            // what makes 'get out of this' a single rule: the gesture only exists while the mode does.
            if self.modeStore == .addConnection && newValue != .addConnection && self.addConnectionStartConnector != nil {

                self.addConnectionStartConnector = nil
                self.addConnectionPath.removeAllPoints()
                self.highlightedConnectorPath = nil
                self.needsDisplay = true
            }

            if newValue == .selectSegment
            {
                if let appCtrl = self.appController {
                    
                    appCtrl.modeIndicatorTextField.stringValue = "Mode: Select"
                }
                
                NSCursor.arrow.set()
            }
            else if newValue == .zoomRect || newValue == .selectRect
            {
                if let appCtrl = self.appController {
                    
                    if newValue == .zoomRect {
                    
                        appCtrl.modeIndicatorTextField.stringValue = "Mode: Zoom Rect"
                    }
                    else {
                        
                        appCtrl.modeIndicatorTextField.stringValue = "Mode: Select Rect"
                    }
                }
                
                NSCursor.crosshair.set()
            }
            else if newValue == .addGround {
                
                if let appCtrl = self.appController {
                    
                    appCtrl.modeIndicatorTextField.stringValue = "Mode: Add Ground"
                }
                
                ViewConnector.GroundCursor.set()
            }
            else if newValue == .addImpulse {
                
                if let appCtrl = self.appController {
                    
                    appCtrl.modeIndicatorTextField.stringValue = "Mode: Add Impulse"
                }
                
                ViewConnector.ImpulseCursor.set()
            }
            else if newValue == .removeConnector {
                
                if let appCtrl = self.appController {
                    
                    appCtrl.modeIndicatorTextField.stringValue = "Mode: Remove Connector"
                }
                
                ViewConnector.PliersCursor.set()
            }
            else if newValue == .addConnection {
                
                if let appCtrl = self.appController {
                    
                    appCtrl.modeIndicatorTextField.stringValue = "Mode: Add Connector"
                }
                
                ViewConnector.AddConnectionCursor.set()
            }

            self.modeStore = newValue

            // The .set() calls above are what makes the change of cursor immediate; this is what makes it stick. Cursor rects
            // are AppKit's own record of what the pointer should be over this view, and resetCursorRects reads modeStore, so
            // the mode has to be stored before the rects are invalidated.
            self.window?.invalidateCursorRects(for: self)
        }
    }
    
    /// An array of all the Segment paths in the model.
    /// - Warning: If it is necessary to add a large number of SegmentPaths (when initializing the model, for example), it is better to create a separate array in the calling routine and append it (or assign it, for initialization) to this property. The reason for this is that any change to the segments array will cause a recalculation of all the ViewConnectors, which tends to slow things down...a lot.
    var segments:[SegmentPath] = [] {

        didSet {

            self.RebuildConnectors()
        }
    }

    /// True while a connector rebuild is in progress, and whether another rebuild was requested while one was running.
    /// These coalesce bursts of rebuild requests (e.g. rapid zooming) into a single serialized re-run.
    private var connectorsRebuildRunning = false
    private var connectorsRebuildPending = false

    // MARK: Connector routing offsets (Phase 3: derived from the model geometry so they scale with model size)

    /// The radial offset a connector steps out of a coil into the adjacent gap.
    var connectorStubOffset = connectorStubDefault
    /// The spacing between parallel connector lanes in a shared channel.
    var connectorLaneGap = connectorLaneSpacing
    /// The axial clearance between the winding extent and a horizontal cross-over channel.
    var connectorCrossoverClearance = connectorCrossoverMargin
    /// The radial distance the routing has to work in (the tightest hilo gap, or the smallest coil build when there is only
    /// one coil) - the raw figure the two offsets above are fractions of. It is kept because a run pushed out to clear a lead
    /// stub has to know how much room there is before it would be drawn through the neighbouring coil (`connectorMaxFlankFraction`).
    var connectorRadialUnit = connectorStubDefault / connectorStubGapFraction

    /// Recompute the connector routing offsets from the model geometry (tightest radial gap and winding height) so that
    /// they scale with the physical size of the model. Falls back to the previous fixed defaults for degenerate geometry.
    func UpdateConnectorMetrics() async {

        let allSegments = segments.map { $0.segment }
        guard !allSegments.isEmpty else { return }

        // Gather each coil's radial extent (inside/outside edge) and the overall axial extent of the winding.
        var coilInside:[Int:Double] = [:]
        var coilOutside:[Int:Double] = [:]
        var windingTop = -Double.greatestFiniteMagnitude
        var windingBottom = Double.greatestFiniteMagnitude

        for segment in allSegments {

            let rect = await segment.rect
            let pos = segment.radialPos
            coilInside[pos] = min(coilInside[pos] ?? Double.greatestFiniteMagnitude, rect.minX)
            coilOutside[pos] = max(coilOutside[pos] ?? -Double.greatestFiniteMagnitude, rect.maxX)
            windingTop = max(windingTop, rect.maxY)
            windingBottom = min(windingBottom, rect.minY)
        }

        // Smallest radial build across the coils (fallback radial unit when there is only one coil).
        var minBuild = Double.greatestFiniteMagnitude
        for pos in coilInside.keys {

            if let inside = coilInside[pos], let outside = coilOutside[pos] {

                minBuild = min(minBuild, outside - inside)
            }
        }

        // Smallest positive hilo gap between radially-adjacent coils (preferred radial unit, since stubs sit in the gap).
        let sortedPositions = coilInside.keys.sorted()
        var minGap = Double.greatestFiniteMagnitude
        if sortedPositions.count > 1 {

            for i in 0 ..< (sortedPositions.count - 1) {

                if let curOutside = coilOutside[sortedPositions[i]], let nextInside = coilInside[sortedPositions[i + 1]] {

                    let gap = nextInside - curOutside
                    if gap > 0 { minGap = min(minGap, gap) }
                }
            }
        }

        let radialUnit = minGap.isFinite ? minGap : (minBuild.isFinite ? minBuild : 0.0)
        let windingHeight = windingTop - windingBottom

        if radialUnit > 0 {

            self.connectorRadialUnit = radialUnit
            self.connectorStubOffset = radialUnit * connectorStubGapFraction
            self.connectorLaneGap = radialUnit * connectorLaneGapFraction
        }

        if windingHeight > 0 {

            self.connectorCrossoverClearance = windingHeight * connectorCrossoverHeightFraction
        }
    }

    /// Rebuild every connector's ViewConnector from scratch. Call this whenever the model changes, or whenever the
    /// view scale changes (so that scale-dependent geometry — the coil-end / gap lead stubs — re-fits to the new zoom).
    func RebuildConnectors() {

        if connectorsRebuildRunning {

            connectorsRebuildPending = true
            return
        }

        connectorsRebuildRunning = true

        Task {

            // Refresh the geometry-derived routing offsets before rebuilding (the model may have changed).
            await self.UpdateConnectorMetrics()

            repeat {

                connectorsRebuildPending = false

                let allSegments = segments.map { $0.segment }
                var maskSegments:[Int] = []
                self.viewConnectors = []
                for nextSegment in segments {

                    await nextSegment.SetUpConnectors(allSegments: allSegments, maskSegments: maskSegments)
                    maskSegments.append(nextSegment.segment.serialNumber)
                }

                self.needsDisplay = true

            } while connectorsRebuildPending

            connectorsRebuildRunning = false
        }
    }
    
    var allSegments:[Segment] {
        
        get {
            
            let result = segments.map({ $0.segment })
            return result
        }
    }
    
    /// An array of the ViewConnectors currently being displayed by the TransformerView
    var viewConnectors:[ViewConnector] = []
    /// The bezier path of the currently-highlighted connector path (if any)
    var highlightedConnectorPath:NSBezierPath? = nil
    /// A constant for the color of the highighted connector path
    let highlightColor:NSColor = .lightGray.withAlphaComponent(0.5)
    
    /// The boundary of the core window
    var boundary:NSRect = NSRect(x: 0, y: 0, width: 0, height: 0)
    /// The color to stroke the edges of the core window
    let boundaryColor:NSColor = .gray
    
    /// In zoom mode, this variable holds the current zoom rectangle
    var zoomRect:NSRect? = nil
    /// A constant for the line dash used when displaying the zoom rectangle
    let zoomRectLineDash = NSSize(width: 15.0, height: 8.0)
    
    /// In selectRect mode, this variable holds the current selection rectangle
    var selectRect:NSRect? = nil
    /// A constant for the line dash used when displaying the selecttion rectangle
    let selectRectLineDash = NSSize(width: 10.0, height: 5.0)
    
    /// In addConnection mode, this holds the ViewConnector where the connection started. It is non-nil for exactly as long as the gesture is live - ie: from the click that picks the first lead until the click that picks the second one (or until the user cancels with Esc), which is what every other part of the add-connection code tests to know whether a connection is being drawn.
    var addConnectionStartConnector:ViewConnector? = nil
    /// In addConnection mode, this holds the NSPoint where the connection started
    var addConnectionStartPoint:NSPoint = NSPoint()
    /// In addConnection mode, this holds the current connection path
    let addConnectionPath = NSBezierPath()
    
    /// The default line width for the TransformerView, in *screen* points - draw() converts it out of the scrollView's
    /// coordinates, so a stroke is this wide at every zoom level rather than growing with the model. It was 1.0, and the
    /// half-point is the third lever on legibility alongside the colours (`AppController.segmentColors`): contrast is a
    /// property of the ink, but how much ink there is decides how much of that contrast the eye actually gets, and a
    /// one-point line is the least of it.
    let defaultLineWidth = 1.5
    
    /// An array of the currently-selected SegmentPaths
    var currentSegments:[SegmentPath] = []
    
    /// An array of Int that holds the indices of the currently-selected SegmentPaths (the indices are into the segments array)
    var currentSegmentIndices:[Int] {
        
        get {
            
            var result:[Int] = []
            
            for i in 0..<self.segments.count {
                
                if self.currentSegments.contains(self.segments[i]) {
                    
                    result.append(i)
                }
            }
            
            return result
        }
    }
    
    /// A Boolean that returns true if the collection of currently-selected SegmentPaths includes Segments from more than one coil (winding).
    var currentSegmentsContainMoreThanOneWinding:Bool {
        
        get {
            
            if self.currentSegments.count > 1 {
                
                let radialPosToCheck = self.currentSegments[0].segment.radialPos
                
                for nextSegment in self.currentSegments {
                    
                    if nextSegment.segment.radialPos != radialPosToCheck {
                        
                        return true
                    }
                }
            }
            
            return false
        }
    }
    
    /// A variable that holds the currently-selected SegmentPath that was actually selected with a right-click
    var rightClickSelection:SegmentPath? = nil
    
    // contextual (right-click) menus
    @IBOutlet weak var contextualMenu:NSMenu!
    @IBOutlet weak var addStaticRingAboveMenuItem:NSMenuItem!
    @IBOutlet weak var addStaticRingBelowMenuItem:NSMenuItem!
    @IBOutlet weak var removeStaticRingMenuItem:NSMenuItem!
    @IBOutlet weak var addRadialShieldMenuItem:NSMenuItem!
    @IBOutlet weak var removeRadialShieldMenuItem:NSMenuItem!
    
    // The scrollview that this view is in
    @IBOutlet weak var scrollView:NSScrollView!
        
    // Override awakeFromNib() to do some initialization. Note that NSObject's awakeFromNib() is
    // 'nonisolated' in the SDK, so this override does not inherit the class's @MainActor - nib
    // loading is always on the main thread, so assume the isolation explicitly.
    override func awakeFromNib() {

        MainActor.assumeIsolated {

            // stuff ourself into the SegmentPath.txfoView global
            SegmentPath.txfoView = self

            // mark our window as 'wanting' mouse-moved events
            self.window!.acceptsMouseMovedEvents = true

            // call our function createTrackingArea() so that we can check if the mouse is in our window for cursor-changing
            self.createTrackingArea()

            // Rebuild the connectors when a trackpad pinch-zoom ends so that the scale-dependent lead stubs re-fit to the new zoom.
            NotificationCenter.default.addObserver(self, selector: #selector(handleLiveMagnifyDidEnd(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: self.scrollView)
        }
    }

    // Called when a trackpad pinch-zoom on the scrollView finishes.
    @objc func handleLiveMagnifyDidEnd(_ notification: Notification) {

        self.RebuildConnectors()
    }
    
    // We want to get first-responder messages, so we need to override the property and return true
    override var acceptsFirstResponder: Bool
    {
        return true
    }
    
    // We need to create a tracking area so that the cursor is updated when it leaves our view (we don't want to have select menus, for instance, using the "ground" cursor).
    func createTrackingArea() {
        
        let newTrackingArea = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        
        self.addTrackingArea(newTrackingArea)
    }
    
    // Override the updateTrackingAreas() function, which is called by the system whenever something about the view changes (scrolling, resizing, etc)
    override func updateTrackingAreas() {
        
        for nextTrackingArea in self.trackingAreas {
        
            self.removeTrackingArea(nextTrackingArea)
        }
        
        self.createTrackingArea()
        
        super.updateTrackingAreas()
    }
    
    // Whenever the user exits the view, we reset the cursor to the arrow
    override func mouseExited(with event: NSEvent) {
        
        NSCursor.arrow.set()
    }
    
    // Whenever we re-enter the view, we set the cursor depending on the mode of the view
    override func mouseEntered(with event: NSEvent) {

        // the cursor rect (resetCursorRects) says the same thing; this just makes it immediate on the way in
        self.modeCursor.set()
    }
    
    
    // MARK: Draw function override
    override func draw(_ dirtyRect: NSRect) {
        
        // save the old line width
        let oldLineWidth = NSBezierPath.defaultLineWidth
        
        // calculate the new line width based on the size of the scrollView. We use the convenient 'convert' function from NSView to do this
        let fixedLineWidthSize = self.convert(NSSize(width: self.defaultLineWidth, height: self.defaultLineWidth), from: self.scrollView)
        NSBezierPath.defaultLineWidth = fixedLineWidthSize.width
        
        // In the interest of speed, we do not simply set "needsDisplay" to true for every single update that is required (that will cause a complete redraw of the entire view rectangle, which takes time). Instead, most of the routines will call setNeedsDisplay(invalidRect:NSRect) with a rectangle (in TransformerView coordinates) that needs to be redrawn. The system collects these rectangles and then passes it through to the draw routine. We could either check ourselves if we need to redraw certain elements, or use the NSView routine "needsToDraw" and only redraw if that routine returns 'true'. This is the kind of advanced programming that is needed if you are drawing a LOT of different elements at a somewhat high speed (for instance, the zoom and select rectangles).
        
        if self.needsToDraw(self.boundary) {
            
            // print("Drawing boundary")
            let boundaryPath = NSBezierPath(rect: boundary)
            self.boundaryColor.set()
            boundaryPath.stroke()
        }
        
        for nextSegment in self.segments
        {
            if self.needsToDraw(nextSegment.GetRect()) {
                
                nextSegment.show()
            }
        }
        
        for nextViewConnector in self.viewConnectors {
            
            if self.needsToDraw(nextViewConnector.hitZone.bounds) {
                
                nextViewConnector.pathColor.set()
                nextViewConnector.path.stroke()
                
            }
            
            if let image = nextViewConnector.image, self.needsToDraw(nextViewConnector.imageRect) {
                
                // draw the image
                image.draw(in: nextViewConnector.imageRect, from: NSRect(origin: NSPoint(), size: image.size), operation: .sourceOver, fraction: 1)
            }
        }
        
        for nextSegment in self.currentSegments
        {
            self.ShowHandles(segment: nextSegment)
        }
        
        if self.mode == .zoomRect
        {
            if let rect = self.zoomRect
            {
                // print(rect)
                NSColor.gray.set()
                let zoomPath = NSBezierPath(rect: rect)
                let lineDashSize = self.convert(self.zoomRectLineDash, from: self.scrollView)
                zoomPath.setLineDash([lineDashSize.width, lineDashSize.height], count: 2, phase: 0.0)
                zoomPath.stroke()
            }
        }
        else if self.mode == .selectRect {
            
            if let rect = self.selectRect {
                
                NSColor.gray.set()
                let selectPath = NSBezierPath(rect: rect)
                let lineDashSize = self.convert(self.selectRectLineDash, from: self.scrollView)
                selectPath.setLineDash([lineDashSize.width, lineDashSize.height], count: 2, phase: 0.0)
                selectPath.stroke()
            }
        }
        else if self.mode == .addConnection {
            
            if let highlightPath = self.highlightedConnectorPath {
                
                self.highlightColor.set()
                highlightPath.stroke()
                highlightPath.fill()
            }
            
            if let startConnector = self.addConnectionStartConnector {
                
                startConnector.pathColor.set()
                self.addConnectionPath.stroke()
            }
        }
        else if self.mode == .addGround || self.mode == .addImpulse || self.mode == .removeConnector {
            
            if let highlightPath = self.highlightedConnectorPath {
                
                self.highlightColor.set()
                highlightPath.stroke()
                highlightPath.fill()
            }
        }
        
        NSBezierPath.defaultLineWidth = oldLineWidth
    }
    
    // MARK: Current segment functions
    
    /// Show the little square 'handles' on the corners of the given SegmentPath
    func ShowHandles(segment:SegmentPath)
    {
        let handleSide = NSBezierPath.defaultLineWidth * 5.0
        let handleBaseRect = NSRect(x: 0.0, y: 0.0, width: handleSide, height: handleSide)
        let handleFillColor = NSColor.white
        let handleStrokeColor = NSColor.darkGray
        
        let segRect = segment.GetRect()
        var corners:[NSPoint] = [segRect.origin]
        corners.append(NSPoint(x: segRect.origin.x + segRect.size.width, y: segRect.origin.y))
        corners.append(NSPoint(x: segRect.origin.x + segRect.size.width, y: segRect.origin.y + segRect.size.height))
        corners.append(NSPoint(x: segRect.origin.x, y: segRect.origin.y + segRect.size.height))
        
        for nextPoint in corners
        {
            let handleRect = NSRect(origin: NSPoint(x: nextPoint.x - handleSide / 2.0, y: nextPoint.y - handleSide / 2.0), size: handleBaseRect.size)
            
            let handlePath = NSBezierPath(rect: handleRect)
            
            handleFillColor.set()
            handlePath.fill()
            handleStrokeColor.setStroke()
            handlePath.stroke()
        }
    }
    
    // MARK: Tooltips to display over segments
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String
    {
        let result = "Tooltip!"
        
        
        
        return result
    }
    
    // MARK: Contextual Menu Handlers

    @IBAction func handleAddRadialShield(_ sender: Any) {
        
        guard let appCtrl = self.appController, let segment = self.rightClickSelection else {
            
            return
        }
        
        appCtrl.doAddRadialShield(segmentPath: segment)
    }
    
    @IBAction func handleRemoveRadialShield(_ sender: Any) {
        
        guard let appCtrl = self.appController, let segment = self.rightClickSelection else {
            
            return
        }
        
        appCtrl.doRemoveRadialShield(segmentPath: segment)
    }
    
    @IBAction func handleAddStaticRingAbove(_ sender: Any) {
        
        guard let appCtrl = self.appController, let segment = self.rightClickSelection else {
            
            return
        }
        
        appCtrl.doAddStaticRingOver(segmentPath: segment)
    }
    
    @IBAction func handleAddStaticRingBelow(_ sender: Any) {
        
        guard let appCtrl = self.appController, let segment = self.rightClickSelection else {
            
            return
        }
        
        appCtrl.doAddStaticRingBelow(segmentPath: segment)
    }
    
    @IBAction func handleRemoveStaticRing(_ sender: Any) {
        
        guard let appCtrl = self.appController, let segment = self.rightClickSelection else {
            
            return
        }
        
        appCtrl.doRemoveStaticRing(segmentPath: segment)
    }
    
    @IBAction func handleMoveWdgRadially(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.handleMoveWindingRadially(self)
    }
    
    @IBAction func handleMoveWdgAxially(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.handleMoveWindingAxially(self)
    }
    
    @IBAction func handleToggleActivation(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.doToggleSegmentActivation(segment: currSeg.segment)
    }
    
    @IBAction func handleActivateAllWindingTurns(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.doSetActivation(winding: currSeg.segment.inLayer!.parentTerminal.winding!, activate: true)
    }
    
    @IBAction func handleDeactivateAllWindingTurns(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.doSetActivation(winding: currSeg.segment.inLayer!.parentTerminal.winding!, activate: false)
    }
    
    
    @IBAction func handleSplitSegment(_ sender: Any) {
        
        guard self.appController != nil else
        {
            return
        }
        
        // appCtrl.handleSplitSegment(self)
    }
    
    // MARK: Menu validation
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        guard let appCtrl = self.appController, appCtrl.currentModel != nil else
        {
            return false
        }
        
        if menuItem == addStaticRingAboveMenuItem || menuItem == addStaticRingBelowMenuItem || menuItem == addRadialShieldMenuItem {
            
            return self.currentSegments.count == 1 && !self.currentSegments[0].segment.isStaticRing && !self.currentSegments[0].segment.isRadialShield
        }
        
        if menuItem == removeStaticRingMenuItem {
            
            return self.currentSegments.count == 1 && self.currentSegments[0].segment.isStaticRing
        }
        
        if menuItem == removeRadialShieldMenuItem {
            
            return self.currentSegments.count == 1 && self.currentSegments[0].segment.isRadialShield
        }
        
        return true
    }

    // MARK: Key Events
    override func keyDown(with event: NSEvent) {

        // Esc gets out of whatever mode we are in. Note that this is also how a half-drawn connection is cancelled: the
        // mode setter throws the pending gesture away on the way out of addConnection.
        if event.keyCode == kVK_Escape {

            self.mode = .selectSegment
            return
        }
        
        super.keyDown(with: event)
    }
    
    // MARK: Mouse Events
    
    // We track mouse-moved events so that we can highlight the connector paths if the mode is one of addConnectio, addImpulse, addground, or removeConnector. We also update the R/Z indicator at the bottom of teh window (but only if the mouse is in the TransformerView).
    override func mouseMoved(with event: NSEvent) {
        
        guard let appCtrl = self.appController, appCtrl.currentModel != nil else {
            
            return
        }
        
        let mouseLoc = self.convert(event.locationInWindow, from: nil)
        
        if !self.isMousePoint(mouseLoc, in: self.bounds) {
            
            return
        }
        
        appCtrl.updateCoordinates(rValue: mouseLoc.x, zValue: mouseLoc.y)
        
        if self.mode == .addConnection || self.mode == .addImpulse || self.mode == .addGround || self.mode == .removeConnector {
            
            if let oldHightlightPath = self.highlightedConnectorPath {
                
                self.highlightedConnectorPath = nil
                self.setNeedsDisplay(oldHightlightPath.bounds)
            }
            
            for nextViewConnector in self.viewConnectors {
                
                let hitZone = nextViewConnector.hitZone
                if hitZone.contains(mouseLoc) {
                
                    self.highlightedConnectorPath = hitZone
                    self.setNeedsDisplay(hitZone.bounds)
                    break
                }
            }

            // Between the two clicks of an add-connection gesture the mouse button is up, so this - and not mouseDragged -
            // is what keeps the line from the first lead tracking the mouse.
            if self.mode == .addConnection {

                self.TrackAddConnection(to: mouseLoc)
            }
        }
    }
    
    // We forward the various mouse-down events based on the current mode
    override func mouseDown(with event: NSEvent) {
        
        if self.mode == .zoomRect
        {
            self.mouseDownWithZoomRect(event: event)
            return
        }
        else if self.mode == .selectSegment
        {
            self.mouseDownWithSelectSegment(event: event)
            return
        }
        else if self.mode == .addGround {
            
            self.mouseDownWithAddGround(event: event)
            return
        }
        else if self.mode == .addImpulse {
            
            self.mouseDownWithAddImpulse(event: event)
            return
        }
        else if self.mode == .addConnection {
            
            self.mouseDownWithAddConnection(event: event)
            return
        }
        else if self.mode == .removeConnector {
            
            self.mouseDownWithRemoveConnector(event: event)
            return
        }
    }
    
    // Depending on the current mode, dragging the mouse means different things. We handle selection-rectangle updating in this routine but transfer to otehr routines for zooming and for adding a connection.
    override func mouseDragged(with event: NSEvent) {
        
        if self.mode == .zoomRect
        {
            self.mouseDraggedWithZoomRect(event: event)
            return
        }
        else if self.mode == .addConnection {

            // Adding a connection is a click-move-click gesture, so the dragging is normally done with the button up (see
            // mouseMoved). We track it here as well only so that a user who does hold the button down still sees the line -
            // the release does nothing, and the second click is what completes the connection either way.
            self.TrackAddConnection(to: self.convert(event.locationInWindow, from: nil))
            return
        }
        
        // testing has revealed that fast clicking can sometimes make the program think there should be a selection rectangle when there actually is not, so we check for it before proceeding
        guard self.selectRect != nil else {
            
            return
        }
        
        // must be dragging with selection rectangle
        let endPoint = self.convert(event.locationInWindow, from: nil)
        let newSize = NSSize(width: endPoint.x - selectRect!.origin.x, height: endPoint.y - selectRect!.origin.y)
        self.selectRect!.size = newSize
        self.needsDisplay = true
    }
    
    // Depending on the mode, we may be interested when the user releases the mouse button.
    override func mouseUp(with event: NSEvent) {
        
        // The user has finished dragging his zoom rectangle, get the end point and do the zoom
        if self.mode == .zoomRect
        {
            let endPoint = self.convert(event.locationInWindow, from: nil)
            let newSize = NSSize(width: endPoint.x - self.zoomRect!.origin.x, height: endPoint.y - self.zoomRect!.origin.y)
            self.zoomRect!.size = newSize
            self.handleZoomRect(zRect: self.zoomRect!)
            self.mode = .selectSegment
            self.needsDisplay = true
        }
        // The user has finished dragging his selection rectangle, so get the end point and add all segments in the rectangle to the currentSegments array
        else if self.mode == .selectRect {
            
            let endPoint = self.convert(event.locationInWindow, from: nil)
            let newSize = NSSize(width: endPoint.x - self.selectRect!.origin.x, height: endPoint.y - self.selectRect!.origin.y)
            self.selectRect!.size = newSize
            
            self.selectRect = NormalizeRect(srcRect: self.selectRect!)
            
            self.currentSegments = []
            
            
            
            for nextSegment in self.segments {
                
                if NSContainsRect(self.selectRect!, nextSegment.GetRect()) {
                    
                    if self.currentSegments.firstIndex(of: nextSegment) == nil {
                        
                        self.currentSegments.append(nextSegment)
                    }
                }
            }
            
            self.mode = .selectSegment
            self.needsDisplay = true
        }
        // Note that addConnection mode is deliberately NOT handled here: it is a click-move-click gesture, so the button
        // comes up immediately after the click that picks the FIRST lead. Completing the connection on that release is
        // what the old drag-based gesture did, and doing it here now would finish every connection before it was aimed.
        // CompleteAddConnection() is called from the second mouseDown instead.
    }

    // The second click of the add-connection gesture. If it landed on a connector other than the one the gesture started
    // on, add the new connector to the model. A click on nothing - or back on the starting lead - leaves the gesture
    // running rather than throwing the start point away, so a mis-click costs nothing; Esc is what cancels.
    func CompleteAddConnection(at endPoint:NSPoint) {

        guard let startConnector = self.addConnectionStartConnector else {

            return
        }

        guard let endConnector = self.viewConnectors.first(where: { $0.hitZone.contains(endPoint) }), endConnector != startConnector else {

            return
        }

        let segmentArray = self.allSegments

        // The gesture is over the instant the second lead is picked, so end it here rather than at the end of the Task
        // below: the model work suspends on the Segment actors, and a click landing in that window would otherwise be read
        // as another second click and add the same jumper twice.
        self.EndAddConnection()

        Task {

            var startConnections = await startConnector.segments.from.ConnectionDestinations(fromLocation: startConnector.connector.fromLocation)
            startConnections.removeAll(where: { $0.segmentID == nil })
            startConnections.insert((startConnector.segments.from.serialNumber, startConnector.connector.fromLocation), at: 0)

            var endConnections = await endConnector.segments.from.ConnectionDestinations(fromLocation: endConnector.connector.fromLocation)
            endConnections.removeAll(where: { $0.segmentID == nil })
            endConnections.insert((endConnector.segments.from.serialNumber, endConnector.connector.fromLocation), at: 0)

            var equivalentConnections:Set<Segment.Connection.EquivalentConnection> = []

            for nextStartConnection in startConnections {

                for nextEndConnection in endConnections {

                    guard let nextStartSegment = segmentArray.first(where: {$0.serialNumber == nextStartConnection.segmentID}) else {

                        ALog("Adding a connector: the start segment \(nextStartConnection.segmentID.map({ String($0) }) ?? "nil") is not in the model. A connection is naming a Segment that no longer exists - see UpdateConnectors' remap.")
                        return
                    }
                    let newConnections = await nextStartSegment.AddConnector(segments: segmentArray, fromLocation: nextStartConnection.location, toLocation: nextEndConnection.location, toSegmentID: nextEndConnection.segmentID)

                    guard let newSrcConnection = newConnections.from, let newDestConnection = newConnections.to else {

                        // AddConnector returns (nil, nil) for exactly one reason: it was asked to connect a Segment to
                        // itself, which it refuses. That means the two ends resolved to the same serial number.
                        ALog("AddConnector returned nothing for \(nextStartConnection.segmentID.map({ String($0) }) ?? "nil") (\(nextStartConnection.location)) -> \(nextEndConnection.segmentID.map({ String($0) }) ?? "nil") (\(nextEndConnection.location)) - the two ends are the same Segment, so no connector was made.")
                        return
                    }

                    equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextStartConnection.segmentID!, connection: newSrcConnection))
                    equivalentConnections.insert(Segment.Connection.EquivalentConnection(parent: nextEndConnection.segmentID!, connection: newDestConnection))
                }
            }

            for nextConnection in equivalentConnections {

                guard let nextConnParent = segmentArray.first(where: {$0.serialNumber == nextConnection.parent}) else {

                    ALog("Registering equivalent connections: parent segment \(nextConnection.parent) is not in the model. An EquivalentConnection is naming a Segment that no longer exists - see UpdateConnectors' remap.")
                    return
                }
                await nextConnParent.AddEquivalentConnections(to: nextConnection.connection, equ: equivalentConnections)
            }

            guard let startSegmentPath = self.segments.first(where: {$0.segment == startConnector.segments.from}) else {

                // this should never happen
                DLog("Problem!")
                return
            }

            // add all the non-touched segments to the maskSegment array so that the SetUpConnectors call goes quickly
            var maskSegments:[Int] = []
            for nextSegmentPath in self.segments {

                if nextSegmentPath.segment != endConnector.segments.from {

                    maskSegments.append(nextSegmentPath.segment.serialNumber)
                }
            }

            await startSegmentPath.SetUpConnectors(allSegments: segmentArray, maskSegments: maskSegments)

            // The redraw EndAddConnection() asked for above happened while this Task was still suspended, ie: before the
            // ViewConnector for the new jumper existed, so it drew the winding exactly as it was. Ask again now that the
            // connector is there, or the new connection stays invisible until some unrelated event dirties the view.
            self.needsDisplay = true
        }
    }

    // Tear down whatever is left of an add-connection gesture, leaving the view ready for the next one. It deliberately does
    // NOT leave addConnection mode: the mode stays armed until the user drops out of it with Esc, the same way add-ground,
    // add-impulse and remove-connector do, so that a run of jumpers does not mean a trip back to the menu between each. That
    // also means the cursor is untouched here - resetCursorRects keeps showing the add-connection cursor because the mode
    // itself has not changed, which is the whole point of it being a cursor rect.
    func EndAddConnection() {

        self.highlightedConnectorPath = nil
        self.addConnectionStartConnector = nil
        self.addConnectionPath.removeAllPoints()

        self.needsDisplay = true
    }

    // Update the rubber-band line (and the target highlight) while an add-connection gesture is waiting for its second
    // click. Does nothing unless a gesture is actually running, so it is safe to call from any mouse-tracking routine.
    func TrackAddConnection(to endPoint:NSPoint) {

        guard self.addConnectionStartConnector != nil else {

            return
        }

        self.addConnectionPath.removeAllPoints()
        self.addConnectionPath.move(to: self.addConnectionStartPoint)
        self.addConnectionPath.line(to: endPoint)

        self.highlightedConnectorPath = nil

        for nextViewConnector in self.viewConnectors {

            let hitZone = nextViewConnector.hitZone
            if hitZone.contains(endPoint) {

                self.highlightedConnectorPath = hitZone
                break
            }
        }

        self.needsDisplay = true
    }
    
    // The mouse is being dragged while in zoomRect mode. Update the zoom rectangle
    func mouseDraggedWithZoomRect(event:NSEvent)
    {
        let endPoint = self.convert(event.locationInWindow, from: nil)
        let newSize = NSSize(width: endPoint.x - self.zoomRect!.origin.x, height: endPoint.y - self.zoomRect!.origin.y)
        self.zoomRect!.size = newSize
        self.needsDisplay = true
    }
    
    // The mouse was clicked while in removeConnector mode. Remove the connection and call SetUpConnectors to update the connectors that are displayed.
    func mouseDownWithRemoveConnector(event:NSEvent) {
        
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        let segmentArray = self.allSegments
                
        Task {
            
            for nextViewConnector in self.viewConnectors {
                
                if nextViewConnector.hitZone.contains(clickPoint) {
                    
                    guard let appCtrl = self.appController, let model = appCtrl.currentModel else {
                        
                        return
                    }
                    
                    // Through the model rather than straight to the Segment: removing the series jumper between two discs cuts the
                    // winding there, and the model puts a lead on each side of the break so that it can be connected to again.
                    let affectedSegments = await model.RemoveConnection(from: nextViewConnector.segments.from, connection: Segment.Connection(segmentID: nextViewConnector.segments.to?.serialNumber, connector: nextViewConnector.connector))

                    // The clicked connector is gone, so its highlight must go with it; left set, it stays on screen as a faint
                    // ghost of the connection until the mouse next moves.
                    self.highlightedConnectorPath = nil
                    
                    // we will be removing ALL the ViewConnectors that are associated with the affected Segments. Since we show the ViewConnectors in a way that keeps "moving forward" (up), we need to also keep the previous segments (as long as they are on the same coil) out of thh maskSegments array
                    var adjacentSegments:[Segment] = []
                    for nextAffectedSegment in affectedSegments {
                        
                        guard let affSegment = segmentArray.first(where: {$0.serialNumber == nextAffectedSegment}) else {

                            ALog("Removing a connector: RemoveConnection reported segment \(nextAffectedSegment) as affected, but it is not in the model. An EquivalentConnection is naming a Segment that no longer exists - see UpdateConnectors' remap.")
                            return
                        }
                        if let adjSegs = try? await model.AxiallyAdjacentSegments(to: affSegment) {
                            
                            if let belowAdj = adjSegs.below {
                                
                                adjacentSegments.append(belowAdj)
                            }
                            
                            if let aboveAdj = adjSegs.above {
                                
                                adjacentSegments.append(aboveAdj)
                            }
                        }
                    }
                    
                    // add all the non-touched segments to the maskSegment array so that the SetUpConnectors call goes quickly
                    var maskSegments:[Int] = []
                    for nextSegmentPath in self.segments {
                        
                        if !affectedSegments.contains(nextSegmentPath.segment.serialNumber) && !adjacentSegments.contains(nextSegmentPath.segment) {
                            
                            maskSegments.append(nextSegmentPath.segment.serialNumber)
                        }
                    }
                    
                    
                    
                    self.viewConnectors.removeAll(where: { affectedSegments.contains($0.segments.from.serialNumber) || ($0.segments.to != nil && affectedSegments.contains($0.segments.to!.serialNumber)) })
                    
                    for nextChangedSegment in affectedSegments {
                        
                        if let changedIndex = self.segments.firstIndex(where: { $0.segment.serialNumber == nextChangedSegment }) {
                            
                            await self.segments[changedIndex].SetUpConnectors(allSegments: segmentArray, maskSegments: maskSegments)
                            // maskSegments.append(nextChangedSegment)
                        }
                    }
                    
                    // segmentPath.SetUpConnectors(maskSegments: maskSegments)
                    
                    self.needsDisplay = true
                    
                    do {
                        
                        let _ = try await model.SetNodes()
                    }
                    catch {
                        
                        let alert = NSAlert(error: error)
                        let _ = alert.runModal()
                        return
                    }
                    
                    break
                }
            }
        }
        
    }
    
    // The mouse was clicked while in addImpulse mode. Check if the clicked point is a valid location and if so, add the impulse connection and show it
    func mouseDownWithAddImpulse(event:NSEvent) {
        
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        
        let segmentArray = self.allSegments
        
        Task {
            
            for nextViewConnector in self.viewConnectors {
                
                if nextViewConnector.hitZone.contains(clickPoint) {
                    
                    // The impulse goes on the lead the user clicked, and ONLY there. Everything jumpered to it is at the same
                    // potential, but that is a fact about the jumpers rather than about those leads, and
                    // PhaseModel.ResolveNodeConnectivity is what says so - see the long note there for what happened when this
                    // routine wrote an impulse onto each of them instead and a later removal of the jumper left it behind.
                    await nextViewConnector.segments.from.AddConnector(segments: segmentArray, fromLocation: nextViewConnector.connector.fromLocation, toLocation: .impulse, toSegmentID: nil)

                    var maskSegments:[Int] = []
                    for nextSegmentPath in self.segments {
                        
                        if nextSegmentPath.segment != nextViewConnector.segments.from {
                            
                            maskSegments.append(nextSegmentPath.segment.serialNumber)
                        }
                    }
                    
                    guard let segmentPath = self.segments.first(where: {$0.segment == nextViewConnector.segments.from}) else {
                        
                        DLog("Problem!")
                        break
                    }
                    
                    await segmentPath.SetUpConnectors(allSegments: segmentArray, maskSegments: maskSegments)
                    
                    break
                }
            }
            
            self.highlightedConnectorPath = nil
            self.needsDisplay = true
        }
    }
    
    // The mouse was clicked while in addGround mode. Check if the clicked point is a valid location and if so, add the ground connection and show it
    func mouseDownWithAddGround(event:NSEvent) {
        
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        
        let segmentArray = self.allSegments
        
        Task {
            
            for nextViewConnector in self.viewConnectors {
                
                if nextViewConnector.hitZone.contains(clickPoint) {
                    
                    if nextViewConnector.hitZone.contains(clickPoint) {
                        
                        // The ground goes on the lead the user clicked, and ONLY there. See mouseDownWithAddImpulse above, and
                        // PhaseModel.ResolveNodeConnectivity for why a ground copied onto every jumpered lead was a cache with no
                        // invalidation: pulling the jumper afterwards left the copies behind, holding leads at zero that the user
                        // had disconnected.
                        await nextViewConnector.segments.from.AddConnector(segments: segmentArray, fromLocation: nextViewConnector.connector.fromLocation, toLocation: .ground, toSegmentID: nil)

                        var maskSegments:[Int] = []
                        for nextSegmentPath in self.segments {
                            
                            if nextSegmentPath.segment != nextViewConnector.segments.from {
                                
                                maskSegments.append(nextSegmentPath.segment.serialNumber)
                            }
                        }
                        
                        guard let segmentPath = self.segments.first(where: {$0.segment == nextViewConnector.segments.from}) else {
                            
                            DLog("Problem!")
                            break
                        }
                        
                        await segmentPath.SetUpConnectors(allSegments: segmentArray, maskSegments: maskSegments)
                        
                        break
                    }
                }
            }
            
            self.highlightedConnectorPath = nil
            self.needsDisplay = true
        }
    }
    
    // The user clicked the mouse while in addConnection mode. Adding a connection takes two clicks: the first picks the lead
    // the connection starts at (and starts the line that follows the mouse from there), the second picks the lead it ends at.
    // Which of the two this is is answered by addConnectionStartConnector - it is non-nil only while a gesture is running.
    func mouseDownWithAddConnection(event:NSEvent) {

        let clickPoint = self.convert(event.locationInWindow, from: nil)

        // second click: finish (or, on a miss, keep waiting - see CompleteAddConnection)
        if self.addConnectionStartConnector != nil {

            self.CompleteAddConnection(at: clickPoint)
            return
        }

        // print("Click location: \(clickPoint)")
        for nextViewConnector in self.viewConnectors {

            if nextViewConnector.hitZone.contains(clickPoint) {

                // print("Got connector")
                self.addConnectionStartConnector = nextViewConnector
                self.addConnectionStartPoint = nextViewConnector.ClosestEndPoint(toPoint: clickPoint)

                // draw the line from the very first event rather than waiting for the mouse to move, so that the click is
                // visibly acknowledged even if the user does not move at all
                self.TrackAddConnection(to: clickPoint)

                return
            }
        }
    }
    
    // The user clicked the mouse while in selectSegment mode. Check if the click was in a segment and if so, highlight it. If the user was holding down the shift key while clicking, add the segment to the set of current segments, otherwise erase the set of current segments and add the new one to it. If the segment is already selected, de-select it (remove it from the set of current segments).
    func mouseDownWithSelectSegment(event:NSEvent)
    {
        let clickPoint = self.convert(event.locationInWindow, from: nil)
        
        if !event.modifierFlags.contains(.shift) {
        
            self.currentSegments = []
        }
        
        for nextSegment in self.segments
        {
            if nextSegment.contains(point: clickPoint)
            {
                if let selectedSegmentIndex = self.currentSegments.firstIndex(of: nextSegment) {
                    
                    self.currentSegments.remove(at: selectedSegmentIndex)
                }
                else {
                    
                    self.currentSegments.append(nextSegment)
                }
                
                break
            }
        }
        
        if self.currentSegments == [] {
            
            let eventLocation = event.locationInWindow
            let localLocation = self.convert(eventLocation, from: nil)
            self.mode = .selectRect
            self.selectRect = NSRect(origin: localLocation, size: NSSize())
            // self.needsDisplay = true
        }
        
        // check if it was actually a double-click
        if event.clickCount == 2
        {
            DLog("Do nothing")
        }
        
        self.needsDisplay = true
    }
    
    // The user clicked the mouse while in zoomRect mode. Start tracking the zoom rectangle
    func mouseDownWithZoomRect(event:NSEvent)
    {
        let eventLocation = event.locationInWindow
        let localLocation = self.convert(eventLocation, from: nil)
        
        self.zoomRect = NSRect(origin: localLocation, size: NSSize())
        self.needsDisplay = true
    }
    
    // MARK: Contextual Menu handling
    
    override func rightMouseDown(with event: NSEvent) {
        
        // reset the mode
        self.mode = .selectSegment
        let eventLocation = event.locationInWindow
        let clickPoint = self.convert(eventLocation, from: nil)
        
        for nextPath in self.segments
        {
            if nextPath.contains(point: clickPoint)
            {
                self.rightClickSelection = nextPath
                if self.currentSegments.firstIndex(of: nextPath) == nil {
                    
                    self.currentSegments = [nextPath]
                }
                self.needsDisplay = true
                NSMenu.popUpContextMenu(self.contextualMenu, with: event, for: self)
                
                break
            }
        }
        
        self.rightClickSelection = nil
    }
    
    // MARK: Zoom Functions

    // Zoom the view so that we see the entire model (ie: zoom to the core window)
    func handleZoomAll(coreRadius:CGFloat, windowHt:CGFloat, tankWallR:CGFloat)
    {
        guard let parentView = self.superview else
        {
            return
        }
        
        // find the center point of the view, then set the magnification of the scrollView to 1, centered on that point
        let contentCenter = NSPoint(x: self.scrollView.contentView.bounds.origin.x + self.scrollView.contentView.bounds.width / 2.0, y: self.scrollView.contentView.bounds.origin.y + self.scrollView.contentView.bounds.height / 2.0)
        self.scrollView.setMagnification(1.0, centeredAt: contentCenter)
        
        // set our frame to the clipView's bounds
        self.frame = parentView.bounds
        
        // aspectRatio is defined as width/height
        // it is assumed that the window height (z) is ALWAYS the dominant dimension compared to the "half tank-width" in the r-direction
        let aspectRatio = parentView.bounds.width / parentView.bounds.height
        let boundsW = windowHt * aspectRatio
        
        // Set the display rectangle to be equal to the core window - don't forget to multiply everything by dimensionMultiplier so that it shows up correctly
        let newRect = NSRect(x: coreRadius, y: 0.0, width: boundsW, height: windowHt) * dimensionMultiplier
        
        // and set the new bounds rectangle
        self.bounds = newRect
        
        self.boundary = self.bounds
        
        self.boundary.size.width = (tankWallR - coreRadius) * dimensionMultiplier

        self.needsDisplay = true

        // re-fit the scale-dependent lead stubs to the new zoom
        self.RebuildConnectors()
    }

    // the zoom in/out ratio (maybe consider making this user-settable)
    var zoomRatio:CGFloat = 0.75

    func handleZoomOut()
    {
        // Define the center of the new view and multiply the current scrollView magnification by the zoomRatio global to get the new view rectangle
        let contentCenter = NSPoint(x: self.scrollView.contentView.bounds.origin.x + self.scrollView.contentView.bounds.width / 2.0, y: self.scrollView.contentView.bounds.origin.y + self.scrollView.contentView.bounds.height / 2.0)
        self.scrollView.setMagnification(scrollView.magnification * zoomRatio, centeredAt: contentCenter)
        self.needsDisplay = true

        // re-fit the scale-dependent lead stubs to the new zoom
        self.RebuildConnectors()
    }

    func handleZoomIn()
    {
        // Define the center of the new view and divide the current scrollView magnification by the zoomRatio global to get the new view rectangle
        let contentCenter = NSPoint(x: self.scrollView.contentView.bounds.origin.x + self.scrollView.contentView.bounds.width / 2.0, y: self.scrollView.contentView.bounds.origin.y + self.scrollView.contentView.bounds.height / 2.0)
        self.scrollView.setMagnification(scrollView.magnification / zoomRatio, centeredAt: contentCenter)
        self.needsDisplay = true

        // re-fit the scale-dependent lead stubs to the new zoom
        self.RebuildConnectors()
    }

    func handleZoomRect(zRect:NSRect)
    {
        // reset the zoomRect
        self.zoomRect = NSRect()
        
        // Get the width/height ratio of self.bounds
        let reqWidthHeightRatio = self.bounds.width / self.bounds.height
        // Fix the zoomRect using my ForceAspectRatioAndNormalize routine (found in GlobalDefs)
        let newBoundsRect = ForceAspectRatioAndNormalize(srcRect: zRect, widthOverHeightRatio: reqWidthHeightRatio)
        // calculate the required zoom factor
        let zoomFactor = newBoundsRect.width / self.bounds.width
        
        // find the new center
        let clipView = self.scrollView.contentView
        let contentCenter = NSPoint(x: newBoundsRect.origin.x + newBoundsRect.width / 2, y: newBoundsRect.origin.y + newBoundsRect.height / 2)
        
        // set the magnification (it is guaranteed to be a "zoom in") and center it at the new center point
        self.scrollView.setMagnification(scrollView.magnification / zoomFactor, centeredAt: clipView.convert(contentCenter, from: self))
        self.needsDisplay = true

        // re-fit the scale-dependent lead stubs to the new zoom
        self.RebuildConnectors()
    }
}
