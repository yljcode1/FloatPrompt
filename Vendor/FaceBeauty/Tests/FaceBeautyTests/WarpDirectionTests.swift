//
//  WarpDirectionTests.swift
//  FaceBeautyTests
//
//  Direction contract for the Metal warp: strength > 0 must MAGNIFY (bump),
//  strength < 0 must PINCH. A previous kernel negated internally on top of the
//  caller's negation, so nose/face slims bulged — this test pins the sign.
//

import CoreImage
import CoreGraphics
import Foundation
import Testing
@testable import FaceBeauty

@Suite("WarpDirection")
struct WarpDirectionTests {

    /// Renders a horizontal black→white ramp warped by one region, and reads
    /// the red channel at (x, y). An inverse warp that samples FARTHER from
    /// the center (pinch) reads a HIGHER ramp value right of center; a bump
    /// samples closer and reads LOWER.
    private func rampValue(strength: Double, probeX: Int, size: Int = 64) -> Int? {
        let g = CIFilter(name: "CILinearGradient")!
        g.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        g.setValue(CIVector(x: CGFloat(size), y: 0), forKey: "inputPoint1")
        g.setValue(CIColor.black, forKey: "inputColor0")
        g.setValue(CIColor.white, forKey: "inputColor1")
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let ramp = g.outputImage!.cropped(to: extent)
        let c = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        guard let warped = FaceBeautyWarp.apply(
            ramp, extent: extent,
            face: .init(center: c, radius: CGFloat(size) / 2 - 2, strength: strength),
            nose: nil, leftEye: nil, rightEye: nil
        ) else { return nil }
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes {
            CIContext().render(warped.cropped(to: extent), toBitmap: $0.baseAddress!, rowBytes: size * 4,
                               bounds: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Int(px[((size / 2) * size + probeX) * 4])
    }

    @Test("Positive strength magnifies, negative pinches")
    func directions() throws {
        guard FaceBeautyWarp.isAvailable else {
            Issue.record("Metal warp kernel failed to load")
            return
        }
        let probeX = 44   // right of the 32px center, inside the region
        let neutral = try #require(rampValue(strength: 0.0001, probeX: probeX))
        let pinched = try #require(rampValue(strength: -0.4, probeX: probeX))
        let bumped = try #require(rampValue(strength: 0.4, probeX: probeX))
        // Pinch (−) samples farther from center → brighter right of center.
        #expect(pinched > neutral + 3, "pinch must pull content inward (sampled \(pinched) vs \(neutral))")
        // Bump (+) samples closer to center → darker right of center.
        #expect(bumped < neutral - 3, "bump must magnify outward (sampled \(bumped) vs \(neutral))")
    }
}
