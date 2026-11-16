//
//  FaceBeautyFilter.swift
//  FaceBeauty
//
//  Created by David Sherlock on 2026.
//

import CoreImage
import Foundation

/// Applies the tracked ``FaceBeauty`` pass: reshape warps (enlarge eyes, slim
/// nose, slim face) then localized colour (brighten eyes / under-eyes, whiten
/// teeth, tint lips, blush, define brows). Colour effects are masked to their
/// region — the bright/dark keyed ones (teeth, eye-whites, brows) only touch
/// the right pixels, never the surrounding skin.
///
/// Runs in SOURCE space (before any reframe) so the landmark track lines up.
/// One builder, for both live preview and export.
public struct FaceBeautyFilter: @unchecked Sendable {

    public let beauty: FaceBeauty

    public init?(beauty: FaceBeauty) {
        guard beauty.isActive else { return nil }
        self.beauty = beauty
    }

    public func apply(_ image: CIImage, at time: TimeInterval, sourceSize: CGSize) -> CIImage {
        guard let k = FaceLandmarkTrack.sample(at: time, keyframes: beauty.keyframes) else { return image }
        let W = sourceSize.width, H = sourceSize.height
        let extent = image.extent
        // Honor a non-zero-origin extent (crops) — landmarks are frame-normalized.
        func px(_ p: FacePoint) -> CGPoint {
            CGPoint(x: extent.minX + Double(p.x) * W, y: extent.minY + (1 - Double(p.y)) * H)
        }

        let leftEye = px(k.leftEye), rightEye = px(k.rightEye), mouth = px(k.mouth)
        let eyeR = max(12, k.eyeSpan * W * 0.42)
        // Glasses lenses distort badly under the eye warp — soften both.
        let eyeWarp = beauty.glassesMode ? 0.2 : 1.0
        let eyeBright = beauty.glassesMode ? 0.35 : 1.0
        var out = image

        // MARK: 1) Geometry — one fused Metal warp when available (was a chain
        // of CIBumpDistortion/CIPinchDistortion that Core Image re-stitched into
        // a fresh Metal program every frame), else the Core Image fallback.
        let eyeScale = beauty.eyeEnlarge > 0 ? beauty.eyeEnlarge * 0.35 * eyeWarp : 0
        let nose = beauty.noseSlim > 0 ? k.nose.map(px) : nil
        let noseR = max(15, eyeR * 0.75)
        let facePinch: (center: CGPoint, radius: CGFloat)? = beauty.faceSlim > 0 ? {
            let eyeMidY = (leftEye.y + rightEye.y) / 2
            return (CGPoint(x: mouth.x, y: mouth.y - abs(mouth.y - eyeMidY) * 0.35), max(40, k.eyeSpan * W * 1.4))
        }() : nil

        let hasGeometry = eyeScale > 0 || nose != nil || facePinch != nil
        if hasGeometry, FaceBeautyWarp.isAvailable,
           let warped = FaceBeautyWarp.apply(
               out, extent: extent,
               face: facePinch.map { .init(center: $0.center, radius: $0.radius, strength: -beauty.faceSlim * 0.45) },
               nose: nose.map { .init(center: $0, radius: noseR, strength: -beauty.noseSlim * 0.3) },
               leftEye: eyeScale > 0 ? .init(center: leftEye, radius: eyeR, strength: eyeScale) : nil,
               rightEye: eyeScale > 0 ? .init(center: rightEye, radius: eyeR, strength: eyeScale) : nil
           ) {
            out = warped.cropped(to: extent)
        } else if hasGeometry {
            if eyeScale > 0 {
                out = bump(out, center: leftEye, radius: eyeR, scale: eyeScale, extent: extent)
                out = bump(out, center: rightEye, radius: eyeR, scale: eyeScale, extent: extent)
            }
            if let nose { out = pinch(out, center: nose, radius: noseR, scale: beauty.noseSlim * 0.3, extent: extent) }
            if let facePinch { out = pinch(out, center: facePinch.center, radius: facePinch.radius, scale: beauty.faceSlim * 0.45, extent: extent) }
        }

        // MARK: 2) Colour
        if beauty.eyeBrighten > 0 {
            let bright = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": beauty.eyeBrighten * 0.55 * eyeBright])
            let m = keyedMask(in: out, centers: [leftEye, rightEye], radiusX: eyeR * 0.6, radiusY: eyeR * 0.55, gamma: 2.2, bright: true, extent: extent)
            out = blend(bright, over: out, mask: m, extent: extent)
        }
        if beauty.underEye > 0 {
            let dy = eyeR * 0.75   // just below each eye (CI y is up)
            let luL = CGPoint(x: leftEye.x, y: leftEye.y - dy), luR = CGPoint(x: rightEye.x, y: rightEye.y - dy)
            let bright = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": beauty.underEye * 0.4])
            let m = ovalMask(centers: [luL, luR], radiusX: eyeR * 0.7, radiusY: eyeR * 0.45, in: extent)
            out = blend(bright, over: out, mask: scaled(m, by: 0.85, extent: extent), extent: extent)
        }
        if beauty.teethWhiten > 0 {
            let mw = max(10, k.mouthWidth * W * 0.42), mh = max(6, k.mouthHeight * H * 0.42)
            let white = out.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": beauty.teethWhiten * 0.05, "inputSaturation": 1 - beauty.teethWhiten * 0.55,
            ])
            let m = keyedMask(in: out, centers: [mouth], radiusX: mw, radiusY: mh, gamma: 3.0, bright: true, extent: extent)
            out = blend(white, over: out, mask: m, extent: extent)
        }
        if beauty.lipTint > 0 {
            let mw = max(10, k.mouthWidth * W * 0.5), mh = max(6, k.mouthHeight * H * 0.6)
            // Lips = the mouth oval minus the bright teeth.
            let m = keyedMask(in: out, centers: [mouth], radiusX: mw, radiusY: mh, gamma: 2.2, bright: false, extent: extent)
            out = tint(out, color: beauty.lipColor, mask: m, amount: beauty.lipTint * 0.8, blend: "CISoftLightBlendMode", extent: extent)
        }
        if beauty.blush > 0 {
            let cx = (leftEye.x + rightEye.x) / 2
            let cheekY = (leftEye.y + mouth.y) / 2
            let cheekL = CGPoint(x: leftEye.x + (leftEye.x - cx) * 0.5, y: cheekY)
            let cheekR = CGPoint(x: rightEye.x + (rightEye.x - cx) * 0.5, y: cheekY)
            let m = ovalMask(centers: [cheekL, cheekR], radiusX: eyeR * 0.95, radiusY: eyeR * 0.8, in: extent)
            out = tint(out, color: beauty.blushColor, mask: scaled(m, by: 0.7, extent: extent), amount: beauty.blush * 0.6, blend: "CISoftLightBlendMode", extent: extent)
        }
        if beauty.browDefine > 0, let lb = k.leftBrow.map(px), let rb = k.rightBrow.map(px) {
            // Brows are dark hair — darken + contrast the dark pixels in the region.
            let dark = out.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": -beauty.browDefine * 0.12, "inputContrast": 1 + beauty.browDefine * 0.25,
            ])
            let m = keyedMask(in: out, centers: [lb, rb], radiusX: eyeR * 0.8, radiusY: eyeR * 0.4, gamma: 2.0, bright: false, extent: extent)
            out = blend(dark, over: out, mask: m, extent: extent)
        }
        return out
    }

    // MARK: - Distortions

    private func bump(_ image: CIImage, center: CGPoint, radius: CGFloat, scale: Double, extent: CGRect) -> CIImage {
        image.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y), "inputRadius": radius, "inputScale": max(-1, min(1, scale)),
        ]).cropped(to: extent)
    }

    private func pinch(_ image: CIImage, center: CGPoint, radius: CGFloat, scale: Double, extent: CGRect) -> CIImage {
        image.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y), "inputRadius": radius, "inputScale": max(-1, min(1, scale)),
        ]).cropped(to: extent)
    }

    // MARK: - Masks & blends

    private func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": background, "inputMaskImage": mask,
        ]).cropped(to: extent)
    }

    /// Blends a solid `color` over `out` through `mask`, at `amount` strength.
    private func tint(_ out: CIImage, color: FaceColor, mask: CIImage, amount: Double, blend blendMode: String, extent: CGRect) -> CIImage {
        let col = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: extent)
        let blended = col.applyingFilter(blendMode, parameters: ["inputBackgroundImage": out]).cropped(to: extent)
        return blend(blended, over: out, mask: scaled(mask, by: amount, extent: extent), extent: extent)
    }

    /// Scales a grayscale mask's strength by `amount` (dims it toward black).
    private func scaled(_ mask: CIImage, by amount: Double, extent: CGRect) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
        ]).cropped(to: extent)
    }

    /// A soft white oval (or ovals) over the given centers on black — feathered.
    private func ovalMask(centers: [CGPoint], radiusX: CGFloat, radiusY: CGFloat, in extent: CGRect) -> CIImage {
        // CIRadialGradient is circular — generate at radiusX around the origin,
        // squash to radiusY, then move to the center. (The old max(rx,ry)
        // circle ignored radiusY, so flat regions like brows/lips inflated to
        // their widest dimension and spilled onto lashes and chin.)
        var mask = CIImage(color: .black).cropped(to: extent)
        for c in centers {
            let g = CIFilter(name: "CIRadialGradient")
            g?.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
            g?.setValue(radiusX * 0.5, forKey: "inputRadius0")
            g?.setValue(radiusX, forKey: "inputRadius1")
            g?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            g?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor1")
            let squash = CGAffineTransform(translationX: c.x, y: c.y)
                .scaledBy(x: 1, y: max(0.05, radiusY / max(1, radiusX)))
            if let oval = g?.outputImage?
                .cropped(to: CGRect(x: -radiusX * 2, y: -radiusX * 2, width: radiusX * 4, height: radiusX * 4))
                .transformed(by: squash)
                .cropped(to: extent) {
                mask = oval.applyingFilter("CIMaximumCompositing", parameters: ["inputBackgroundImage": mask])
            }
        }
        return mask.cropped(to: extent)
    }

    /// An oval mask multiplied by a brightness key so it only covers the bright
    /// (`bright: true` → teeth, eye-whites) or dark (`false` → lips, brows)
    /// pixels inside the region — never the surrounding skin.
    private func keyedMask(in image: CIImage, centers: [CGPoint], radiusX: CGFloat, radiusY: CGFloat, gamma: Double, bright: Bool, extent: CGRect) -> CIImage {
        let oval = ovalMask(centers: centers, radiusX: radiusX, radiusY: radiusY, in: extent)
        var key = image.applyingFilter("CIMaximumComponent").applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma]).cropped(to: extent)
        if !bright { key = key.applyingFilter("CIColorInvert").cropped(to: extent) }
        return oval.applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": key]).cropped(to: extent)
    }
}
