//
//  FaceBeautyWarp.swift
//  FaceBeauty
//
//  Created by David Sherlock on 2026.
//

import CoreImage
import Foundation
import os

/// The beauty geometry (enlarge eyes + slim nose/face) as a single hand-written
/// Metal `CIWarpKernel`. Replaces the chained `CIBumpDistortion` /
/// `CIPinchDistortion` filters, which Core Image re-stitched into a fresh Metal
/// program every frame — one fused warp compiles once and runs in a single pass.
enum FaceBeautyWarp {

    /// One radial input for the kernel: centre, radius, and signed strength
    /// (>0 magnifies / enlarge, <0 pinches / slim). The kernel is pass-through:
    /// the sign given here is the sign applied.
    struct Region {
        var center: CGPoint
        var radius: CGFloat
        var strength: Double
    }

    private static let kernel: CIWarpKernel? = {
        guard let url = Bundle.module.url(forResource: "FaceBeautyWarp", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            Logger(subsystem: "FaceBeauty", category: "warp")
                .error("FaceBeautyWarp.metallib missing — falling back to Core Image distortions (geometry will differ subtly)")
            return nil
        }
        do {
            return try CIWarpKernel(functionName: "beautyWarp", fromMetalLibraryData: data)
        } catch {
            Logger(subsystem: "FaceBeauty", category: "warp")
                .error("beautyWarp kernel failed to load: \(error.localizedDescription) — falling back to Core Image distortions")
            return nil
        }
    }()

    /// Whether the Metal kernel loaded (else callers fall back to Core Image).
    static var isAvailable: Bool { kernel != nil }

    /// Applies slim-face + slim-nose + enlarge-eyes in one pass (inverse order
    /// of the forward chain). Each region is independent — nil contributes
    /// nothing (radius 0).
    static func apply(_ image: CIImage, extent: CGRect,
                      face: Region?, nose: Region?, leftEye: Region?, rightEye: Region?) -> CIImage? {
        guard let kernel else { return nil }
        func vec(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: p.y) }
        let regions = [face, nose, leftEye, rightEye]
            .map { $0 ?? Region(center: .zero, radius: 0, strength: 0) }
        guard regions.contains(where: { $0.radius > 0 && $0.strength != 0 }) else { return image }
        let args: [Any] = regions.flatMap { [vec($0.center), $0.radius, $0.strength] }
        // The warp pulls a pixel from up to ~one radius away, so the input ROI
        // for an output tile is the tile grown by the largest region radius.
        let margin = regions.map(\.radius).max() ?? 0
        return kernel.apply(extent: extent,
                            roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) },
                            image: image.clampedToExtent(), arguments: args)
    }
}
