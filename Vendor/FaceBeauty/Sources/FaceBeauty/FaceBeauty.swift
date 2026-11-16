//
//  FaceBeauty.swift
//  FaceBeauty
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// A simple RGB colour (`0…1`) for the tint effects. Package-owned so the
/// library stays a self-contained leaf.
public struct FaceColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    /// A natural warm lip red.
    public static let lip = FaceColor(red: 0.78, green: 0.30, blue: 0.34)
    /// A soft blush pink.
    public static let blush = FaceColor(red: 0.93, green: 0.52, blue: 0.53)
}

/// One sampled set of face landmarks on the source timeline (normalized,
/// top-left origin). Newer points (brows, nose) are Optional so a track saved
/// by an earlier version still decodes — the effects that need them just skip
/// until the sticker is re-tracked.
public struct FaceLandmarkFrame: Codable, Equatable, Sendable {

    public var time: TimeInterval
    public var leftEye: FacePoint
    public var rightEye: FacePoint
    public var eyeSpan: Double
    public var mouth: FacePoint
    public var mouthWidth: Double
    public var mouthHeight: Double
    public var jawLeft: FacePoint
    public var jawRight: FacePoint
    /// Eyebrow centers (brow define). Optional — added after the first release.
    public var leftBrow: FacePoint?
    public var rightBrow: FacePoint?
    /// Nose tip/center (nose slim). Optional.
    public var nose: FacePoint?

    public init(
        time: TimeInterval,
        leftEye: FacePoint, rightEye: FacePoint, eyeSpan: Double,
        mouth: FacePoint, mouthWidth: Double, mouthHeight: Double,
        jawLeft: FacePoint, jawRight: FacePoint,
        leftBrow: FacePoint? = nil, rightBrow: FacePoint? = nil, nose: FacePoint? = nil
    ) {
        self.time = time
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.eyeSpan = eyeSpan
        self.mouth = mouth
        self.mouthWidth = mouthWidth
        self.mouthHeight = mouthHeight
        self.jawLeft = jawLeft
        self.jawRight = jawRight
        self.leftBrow = leftBrow
        self.rightBrow = rightBrow
        self.nose = nose
    }
}

/// A landmark-driven beauty pass: reshape (enlarge eyes, slim face, slim nose),
/// masked colour (brighten eyes, whiten teeth, brighten under-eyes, tint lips,
/// add blush, define brows) — all geometric warps and localized colour tweaks
/// (no generative model, on-device, license clean). Amounts are `0…1`.
public struct FaceBeauty: Codable, Equatable, Sendable {

    // Reshape
    public var eyeEnlarge: Double
    public var faceSlim: Double
    public var noseSlim: Double
    // Colour / tone
    public var eyeBrighten: Double
    public var underEye: Double
    public var teethWhiten: Double
    public var lipTint: Double
    public var lipColor: FaceColor
    public var blush: Double
    public var blushColor: FaceColor
    public var browDefine: Double
    /// When on, the eye-warp/brighten are softened — a glasses lens distorts
    /// badly under the eye bump, so this keeps them subtle for glasses wearers.
    public var glassesMode: Bool
    /// The tracked face landmarks over time.
    public var keyframes: [FaceLandmarkFrame]

    public init(
        eyeEnlarge: Double = 0.3,
        faceSlim: Double = 0,
        noseSlim: Double = 0,
        eyeBrighten: Double = 0.25,
        underEye: Double = 0.25,
        teethWhiten: Double = 0.35,
        lipTint: Double = 0,
        lipColor: FaceColor = .lip,
        blush: Double = 0,
        blushColor: FaceColor = .blush,
        browDefine: Double = 0,
        glassesMode: Bool = false,
        keyframes: [FaceLandmarkFrame] = []
    ) {
        self.eyeEnlarge = eyeEnlarge
        self.faceSlim = faceSlim
        self.noseSlim = noseSlim
        self.eyeBrighten = eyeBrighten
        self.underEye = underEye
        self.teethWhiten = teethWhiten
        self.lipTint = lipTint
        self.lipColor = lipColor
        self.blush = blush
        self.blushColor = blushColor
        self.browDefine = browDefine
        self.glassesMode = glassesMode
        self.keyframes = keyframes
    }

    // Tolerant decode — the model grows over time; missing keys take the
    // default so an older saved project keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ fallback: Double) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? fallback }
        eyeEnlarge = try d(.eyeEnlarge, 0.3)
        faceSlim = try d(.faceSlim, 0)
        noseSlim = try d(.noseSlim, 0)
        eyeBrighten = try d(.eyeBrighten, 0.25)
        underEye = try d(.underEye, 0.25)
        teethWhiten = try d(.teethWhiten, 0.35)
        lipTint = try d(.lipTint, 0)
        lipColor = try c.decodeIfPresent(FaceColor.self, forKey: .lipColor) ?? .lip
        blush = try d(.blush, 0)
        blushColor = try c.decodeIfPresent(FaceColor.self, forKey: .blushColor) ?? .blush
        browDefine = try d(.browDefine, 0)
        glassesMode = try c.decodeIfPresent(Bool.self, forKey: .glassesMode) ?? false
        keyframes = try c.decodeIfPresent([FaceLandmarkFrame].self, forKey: .keyframes) ?? []
    }

    /// Whether the pass does anything (has a track and a non-zero amount).
    public var isActive: Bool {
        guard !keyframes.isEmpty else { return false }
        return [eyeEnlarge, faceSlim, noseSlim, eyeBrighten, underEye,
                teethWhiten, lipTint, blush, browDefine].contains { $0 > 0 }
    }
}

public extension FaceBeauty {

    /// One-tap looks. The host applies the amounts and keeps its own tracked
    /// ``keyframes`` (and `glassesMode`).
    enum Preset: String, CaseIterable, Sendable { case subtle, natural, glam }

    /// The amount set for a preset (keyframes stay empty — the host merges them).
    static func amounts(for preset: Preset) -> FaceBeauty {
        switch preset {
        case .subtle:
            return FaceBeauty(eyeEnlarge: 0.15, faceSlim: 0.1, noseSlim: 0.05,
                              eyeBrighten: 0.2, underEye: 0.2, teethWhiten: 0.25,
                              lipTint: 0.1, blush: 0.1, browDefine: 0.15)
        case .natural:
            return FaceBeauty(eyeEnlarge: 0.3, faceSlim: 0.2, noseSlim: 0.1,
                              eyeBrighten: 0.3, underEye: 0.3, teethWhiten: 0.4,
                              lipTint: 0.2, blush: 0.2, browDefine: 0.25)
        case .glam:
            return FaceBeauty(eyeEnlarge: 0.5, faceSlim: 0.35, noseSlim: 0.2,
                              eyeBrighten: 0.45, underEye: 0.4, teethWhiten: 0.6,
                              lipTint: 0.45, blush: 0.35, browDefine: 0.4)
        }
    }
}

/// Linear interpolation over the landmark track — clamped at both ends.
public enum FaceLandmarkTrack {

    public static func sample(at time: TimeInterval, keyframes: [FaceLandmarkFrame]) -> FaceLandmarkFrame? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        for (from, to) in zip(keyframes, keyframes.dropFirst()) where time < to.time {
            let span = max(0.0001, to.time - from.time)
            let t = (time - from.time) / span
            func lerp(_ a: FacePoint, _ b: FacePoint) -> FacePoint {
                FacePoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t))
            }
            func lerpO(_ a: FacePoint?, _ b: FacePoint?) -> FacePoint? {
                guard let a, let b else { return a ?? b }
                return lerp(a, b)
            }
            func lerpD(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            return FaceLandmarkFrame(
                time: time,
                leftEye: lerp(from.leftEye, to.leftEye),
                rightEye: lerp(from.rightEye, to.rightEye),
                eyeSpan: lerpD(from.eyeSpan, to.eyeSpan),
                mouth: lerp(from.mouth, to.mouth),
                mouthWidth: lerpD(from.mouthWidth, to.mouthWidth),
                mouthHeight: lerpD(from.mouthHeight, to.mouthHeight),
                jawLeft: lerp(from.jawLeft, to.jawLeft),
                jawRight: lerp(from.jawRight, to.jawRight),
                leftBrow: lerpO(from.leftBrow, to.leftBrow),
                rightBrow: lerpO(from.rightBrow, to.rightBrow),
                nose: lerpO(from.nose, to.nose)
            )
        }
        return last
    }
}
