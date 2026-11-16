//
//  FaceBeautyTests.swift
//  FaceBeautyTests
//

import CoreImage
import Foundation
import Testing
@testable import FaceBeauty

@Suite("Face beauty")
struct FaceBeautyTests {

    private func oneFrame(time: TimeInterval = 0) -> FaceLandmarkFrame {
        FaceLandmarkFrame(
            time: time,
            leftEye: FacePoint(x: 0.40, y: 0.35), rightEye: FacePoint(x: 0.60, y: 0.35), eyeSpan: 0.20,
            mouth: FacePoint(x: 0.50, y: 0.62), mouthWidth: 0.18, mouthHeight: 0.06,
            jawLeft: FacePoint(x: 0.30, y: 0.55), jawRight: FacePoint(x: 0.70, y: 0.55)
        )
    }

    @Test("FaceBeauty round-trips through Codable")
    func roundTrip() throws {
        let beauty = FaceBeauty(eyeEnlarge: 0.5, faceSlim: 0.3, eyeBrighten: 0.2, teethWhiten: 0.6, keyframes: [oneFrame()])
        let back = try JSONDecoder().decode(FaceBeauty.self, from: JSONEncoder().encode(beauty))
        #expect(back == beauty)
        #expect(back.isActive)
    }

    @Test("isActive is false without a track or without any amount")
    func activeGate() {
        #expect(!FaceBeauty(keyframes: []).isActive)
        let allZero = FaceBeauty(eyeEnlarge: 0, faceSlim: 0, noseSlim: 0, eyeBrighten: 0,
                                 underEye: 0, teethWhiten: 0, lipTint: 0, blush: 0, browDefine: 0,
                                 keyframes: [oneFrame()])
        #expect(!allZero.isActive)
        #expect(FaceBeauty(eyeEnlarge: 0.4, keyframes: [oneFrame()]).isActive)
    }

    @Test("Presets set sensible amounts; old JSON tolerates missing keys")
    func presetsAndTolerance() throws {
        #expect(FaceBeauty.amounts(for: .glam).teethWhiten > FaceBeauty.amounts(for: .subtle).teethWhiten)
        #expect(FaceBeauty.amounts(for: .natural).lipTint > 0)
        // A minimal JSON with only a couple keys must decode with defaults.
        let json = "{\"eyeEnlarge\":0.5,\"keyframes\":[]}".data(using: .utf8)!
        let b = try JSONDecoder().decode(FaceBeauty.self, from: json)
        #expect(b.eyeEnlarge == 0.5)
        #expect(b.teethWhiten == 0.35)   // default filled in
        #expect(b.lipColor == .lip)
    }

    @Test("Track interpolates linearly and clamps at the ends")
    func interpolation() {
        let a = oneFrame(time: 0)
        var b = oneFrame(time: 2); b.leftEye = FacePoint(x: 0.50, y: 0.45)
        let frames = [a, b]
        let mid = FaceLandmarkTrack.sample(at: 1, keyframes: frames)!
        #expect(abs(mid.leftEye.x - 0.45) < 1e-6)
        #expect(abs(mid.leftEye.y - 0.40) < 1e-6)
        // Clamp.
        #expect(FaceLandmarkTrack.sample(at: -5, keyframes: frames)!.leftEye.x == a.leftEye.x)
        #expect(FaceLandmarkTrack.sample(at: 99, keyframes: frames)!.leftEye.x == b.leftEye.x)
    }

    @Test("Eye brighten lifts a bright eye highlight, not the surrounding skin")
    func filterLocality() {
        let side = 200
        let ctx = CIContext()
        // Gray "skin" with a bright disk where the left eye is (stand-in sclera).
        let base = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        // Left eye top-left (0.40, 0.35) → CI bottom-left y = 0.65.
        let eyeCI = CGPoint(x: 0.40 * Double(side), y: 0.65 * Double(side))
        let disk = CIImage(color: CIColor(red: 0.75, green: 0.75, blue: 0.75))
            .cropped(to: CGRect(x: eyeCI.x - 12, y: eyeCI.y - 8, width: 24, height: 16))
        let img = disk.composited(over: base)

        let beauty = FaceBeauty(eyeEnlarge: 0, faceSlim: 0, eyeBrighten: 1.0, teethWhiten: 0, keyframes: [oneFrame()])
        let out = FaceBeautyFilter(beauty: beauty)!.apply(img, at: 0, sourceSize: CGSize(width: side, height: side))

        let x = Int(0.40 * Double(side)), y = Int(0.35 * Double(side))
        let eyeBefore = luminance(img, x: x, y: y, side: side, ctx: ctx)
        let eyeAfter = luminance(out, x: x, y: y, side: side, ctx: ctx)
        let corner = luminance(out, x: 6, y: 6, side: side, ctx: ctx)
        #expect(eyeAfter > eyeBefore + 0.02, "the eye highlight should brighten (before=\(eyeBefore) after=\(eyeAfter))")
        #expect(abs(corner - 0.35) < 0.05, "the far corner (skin) should be untouched")
    }

    @Test("Geometry warp renders without crashing")
    func geometryRuns() {
        let side = 200
        let img = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let beauty = FaceBeauty(eyeEnlarge: 1.0, faceSlim: 1.0, eyeBrighten: 0, teethWhiten: 0, keyframes: [oneFrame()])
        let filter = FaceBeautyFilter(beauty: beauty)!
        let out = filter.apply(img, at: 0, sourceSize: CGSize(width: side, height: side))
        #expect(out.extent.width == CGFloat(side) && out.extent.height == CGFloat(side))
    }

    /// Renders one pixel of a CIImage and returns its luminance in `0…1`.
    private func luminance(_ image: CIImage, x: Int, y: Int, side: Int, ctx: CIContext) -> Double {
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        ctx.render(image, toBitmap: &buf, rowBytes: side * 4,
                   bounds: CGRect(x: 0, y: 0, width: side, height: side),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let i = (y * side + x) * 4
        let r = Double(buf[i]) / 255, g = Double(buf[i + 1]) / 255, b = Double(buf[i + 2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
