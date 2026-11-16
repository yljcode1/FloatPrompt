//
//  RenderProofTests.swift
//  FaceBeautyTests
//
//  Visual diagnostics on a real clip — writes PNGs to ~/Downloads. Opt-in
//  (needs FACE_BEAUTY_RENDER set + the video present) so it never runs in the
//  normal suite.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import FaceBeauty

@Suite("Render proof")
struct RenderProofTests {

    private var video: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/talking-head.mov") }
    private var enabled: Bool { ProcessInfo.processInfo.environment["FACE_BEAUTY_RENDER"] != nil }

    private func frame(at t: Double) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
    }

    @Test("Write before/after PNGs", .enabled(if: ProcessInfo.processInfo.environment["FACE_BEAUTY_RENDER"] != nil))
    func beforeAfter() async throws {
        guard FileManager.default.fileExists(atPath: video.path) else { print("[skip]"); return }
        let keyframes = try await FaceLandmarkTracker.track(videoURL: video)
        guard !keyframes.isEmpty else { print("[skip] no face"); return }
        let t = 2.0
        let before = CIImage(cgImage: try frame(at: t))
        let beauty = FaceBeauty(eyeEnlarge: 0.4, faceSlim: 0.4, noseSlim: 0.3, eyeBrighten: 0.4,
                                underEye: 0.5, teethWhiten: 0.6, lipTint: 0.7, blush: 0.6,
                                browDefine: 0.6, glassesMode: true, keyframes: keyframes)
        let after = FaceBeautyFilter(beauty: beauty)!.apply(before, at: t, sourceSize: before.extent.size)
        let ctx = CIContext(), cs = CGColorSpaceCreateDeviceRGB()
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        try ctx.writePNGRepresentation(of: before, to: dir.appendingPathComponent("face_beauty_before.png"), format: .RGBA8, colorSpace: cs)
        try ctx.writePNGRepresentation(of: after, to: dir.appendingPathComponent("face_beauty_after.png"), format: .RGBA8, colorSpace: cs)
        print("WROTE before/after (\(keyframes.count) frames)")
    }

    @Test("Write a landmark-grid debug PNG", .enabled(if: ProcessInfo.processInfo.environment["FACE_BEAUTY_RENDER"] != nil))
    func landmarkGrid() async throws {
        guard FileManager.default.fileExists(atPath: video.path) else { print("[skip]"); return }
        let keyframes = try await FaceLandmarkTracker.track(videoURL: video)
        let t = 2.0
        guard let k = FaceLandmarkTrack.sample(at: t, keyframes: keyframes) else { print("[skip] no frame"); return }
        let cg = try frame(at: t)
        let W = cg.width, H = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Normalized top-left → CGContext bottom-left pixel.
        func pt(_ p: FacePoint) -> CGPoint { CGPoint(x: Double(p.x) * Double(W), y: (1 - Double(p.y)) * Double(H)) }
        func dot(_ p: CGPoint, _ c: CGColor, _ r: CGFloat = 8) {
            ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        func ring(_ p: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ c: CGColor) {
            ctx.setStrokeColor(c); ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: p.x - rx, y: p.y - ry, width: 2 * rx, height: 2 * ry))
        }
        let green = CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
        let blue = CGColor(red: 0.3, green: 0.7, blue: 1, alpha: 1)
        let red = CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)

        let eyeR = CGFloat(k.eyeSpan) * CGFloat(W) * 0.42
        dot(pt(k.leftEye), green); dot(pt(k.rightEye), green)
        ring(pt(k.leftEye), eyeR, eyeR, green); ring(pt(k.rightEye), eyeR, eyeR, green)

        let mw = CGFloat(k.mouthWidth) * CGFloat(W) * 0.42, mh = CGFloat(k.mouthHeight) * CGFloat(H) * 0.42
        dot(pt(k.mouth), blue); ring(pt(k.mouth), mw, mh, blue)

        dot(pt(k.jawLeft), red); dot(pt(k.jawRight), red)   // raw jaw-contour sides
        let mp = pt(k.mouth), emY = (pt(k.leftEye).y + pt(k.rightEye).y) / 2
        let slimC = CGPoint(x: mp.x, y: mp.y - abs(mp.y - emY) * 0.35)
        let slimR = max(40, CGFloat(k.eyeSpan) * CGFloat(W) * 1.4)
        dot(slimC, red, 6); ring(slimC, slimR, slimR, red)   // actual slim pinch region

        guard let out = ctx.makeImage() else { return }
        try CIContext().writePNGRepresentation(
            of: CIImage(cgImage: out),
            to: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/face_beauty_landmarks.png"),
            format: .RGBA8, colorSpace: cs)
        print("WROTE landmarks (green=eyes+radius, blue=mouth/teeth, red=jaw+slim)")
    }
}
