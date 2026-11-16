//
//  FaceLandmarkTracker.swift
//  FaceBeauty
//
//  Created by David Sherlock on 2026.
//

import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Follows the largest face through a video and produces a smoothed landmark
/// track (eye centers, mouth, jaw) for ``FaceBeautyFilter``. On-device Vision
/// throughout; samples ~4 fps and interpolates between.
public enum FaceLandmarkTracker {

    /// Samples the video, detects the largest face's landmarks per sample, and
    /// returns a lightly-smoothed track. Empty when no face is found.
    public static func track(videoURL: URL, fps: Double = 4) async throws -> [FaceLandmarkFrame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)

        let step = 1.0 / max(1, fps)
        let times = stride(from: 0.1, to: duration, by: step)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        var samples: [FaceLandmarkFrame] = []
        for await result in generator.images(for: times) {
            guard let frame = try? result.image else { continue }
            let size = CGSize(width: frame.width, height: frame.height)
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: frame)
            try? handler.perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
                  let lm = face.landmarks,
                  let frameSample = Self.frame(from: lm, imageSize: size, time: result.requestedTime.seconds)
            else { continue }
            samples.append(frameSample)
        }
        guard !samples.isEmpty else { return [] }
        return smoothed(samples)
    }

    // MARK: - Landmark extraction

    public static func frame(from lm: VNFaceLandmarks2D, imageSize: CGSize, time: TimeInterval) -> FaceLandmarkFrame? {
        guard let leftEye = lm.leftEye, let rightEye = lm.rightEye,
              let lips = lm.outerLips, let contour = lm.faceContour else { return nil }

        // Vision returns image-pixel points, bottom-left origin → normalize + flip Y.
        func norm(_ p: CGPoint) -> FacePoint {
            FacePoint(x: p.x / imageSize.width, y: 1 - p.y / imageSize.height)
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> FacePoint {
            let pts = region.pointsInImage(imageSize: imageSize)
            guard !pts.isEmpty else { return FacePoint(x: 0.5, y: 0.5) }
            let mx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            let my = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
            return norm(CGPoint(x: mx, y: my))
        }

        let leftC = center(leftEye), rightC = center(rightEye), mouthC = center(lips)
        let eyeSpan = abs(Double(leftC.x - rightC.x))

        let lipPts = lips.pointsInImage(imageSize: imageSize)
        let mouthW = lipPts.isEmpty ? 0 : Double((lipPts.map(\.x).max()! - lipPts.map(\.x).min()!) / imageSize.width)
        let mouthH = lipPts.isEmpty ? 0 : Double((lipPts.map(\.y).max()! - lipPts.map(\.y).min()!) / imageSize.height)

        // Jaw sides = extreme points of the face contour.
        let jaw = contour.pointsInImage(imageSize: imageSize)
        guard let jl = jaw.min(by: { $0.x < $1.x }), let jr = jaw.max(by: { $0.x < $1.x }) else { return nil }

        // Newer, optional landmarks — brows and nose (skip if not detected).
        let leftBrow = lm.leftEyebrow.map(center)
        let rightBrow = lm.rightEyebrow.map(center)
        let nose = (lm.nose ?? lm.noseCrest).map(center)

        return FaceLandmarkFrame(
            time: time,
            leftEye: leftC, rightEye: rightC, eyeSpan: max(0.02, eyeSpan),
            mouth: mouthC, mouthWidth: max(0.02, mouthW), mouthHeight: max(0.01, mouthH),
            jawLeft: norm(jl), jawRight: norm(jr),
            leftBrow: leftBrow, rightBrow: rightBrow, nose: nose
        )
    }

    // MARK: - Smoothing (±2-sample moving average)

    private static func smoothed(_ s: [FaceLandmarkFrame]) -> [FaceLandmarkFrame] {
        guard s.count > 2 else { return s }
        var out: [FaceLandmarkFrame] = []
        for i in s.indices {
            let w = s[max(0, i - 3)...min(s.count - 1, i + 3)]   // ±3 = steadier
            let n = CGFloat(w.count), nd = Double(w.count)
            func pt(_ key: (FaceLandmarkFrame) -> FacePoint) -> FacePoint {
                FacePoint(x: w.map { key($0).x }.reduce(0, +) / n, y: w.map { key($0).y }.reduce(0, +) / n)
            }
            func ptO(_ key: (FaceLandmarkFrame) -> FacePoint?) -> FacePoint? {
                let pts = w.compactMap(key)
                guard !pts.isEmpty else { return nil }
                let m = CGFloat(pts.count)
                return FacePoint(x: pts.map(\.x).reduce(0, +) / m, y: pts.map(\.y).reduce(0, +) / m)
            }
            func d(_ key: (FaceLandmarkFrame) -> Double) -> Double { w.map(key).reduce(0, +) / nd }
            out.append(FaceLandmarkFrame(
                time: s[i].time,
                leftEye: pt { $0.leftEye }, rightEye: pt { $0.rightEye }, eyeSpan: d { $0.eyeSpan },
                mouth: pt { $0.mouth }, mouthWidth: d { $0.mouthWidth }, mouthHeight: d { $0.mouthHeight },
                jawLeft: pt { $0.jawLeft }, jawRight: pt { $0.jawRight },
                leftBrow: ptO { $0.leftBrow }, rightBrow: ptO { $0.rightBrow }, nose: ptO { $0.nose }
            ))
        }
        return out
    }
}
