import Foundation
import Vision
import CoreImage
import FaceBeauty

/// Used only from the camera processing queue. Frames already have portrait rotation and mirroring.
final class LiveFaceReshape {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var count = 0
    private var trackingGain = 0.0
    private var tracked: FaceLandmarkFrame?
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private(set) var trackingStatus = "正在寻找人脸"
    var faceSlim = 0.15
    var eyeEnlarge = 0.08
    var noseSlim = 0.05
    var glassesMode = false
    var active: Bool { faceSlim > 0 || eyeEnlarge > 0 || noseSlim > 0 }
    func process(_ pixel: CVPixelBuffer) throws -> CVPixelBuffer {
        guard active else { tracked = nil; trackingGain = 0; trackingStatus = "美型已关闭"; return pixel }
        count += 1
        if count % 3 == 1 || tracked == nil { detect(pixel) }
        guard let frame = tracked else { trackingGain = 0; return pixel }
        trackingGain = min(1, trackingGain + 0.18)
        return try render(pixel, frame: frame, strengthScale: trackingGain)
    }
    func render(_ pixel: CVPixelBuffer, frame: FaceLandmarkFrame, strengthScale: Double = 1) throws -> CVPixelBuffer {
        let image = CIImage(cvPixelBuffer: pixel)
        func point(_ p: FacePoint) -> CGPoint { CGPoint(x: p.x * image.extent.width, y: (1-p.y) * image.extent.height) }
        let output: CIImage
        if active {
            guard let warped = ShiyanContourWarp.apply(image,
                leftJaw: point(frame.jawLeft), rightJaw: point(frame.jawRight),
                leftEye: point(frame.leftEye), rightEye: point(frame.rightEye), mouth: point(frame.mouth), nose: point(frame.nose ?? frame.mouth),
                eyeSpan: CGFloat(frame.eyeSpan) * image.extent.width, mouthWidth: CGFloat(frame.mouthWidth) * image.extent.width,
                slim: faceSlim * strengthScale, eyes: eyeEnlarge * strengthScale * (glassesMode ? 0.2 : 1), noseAmount: frame.nose == nil ? 0 : noseSlim * strengthScale) else { throw CameraCapture.CameraError.unavailable }
            output = warped
        } else { return pixel }

        if pool == nil || size != image.extent.size {
            size = image.extent.size
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { throw CameraCapture.CameraError.unavailable }
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw CameraCapture.CameraError.unavailable }
        context.render(output, to: buffer, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }
    private func detect(_ pixel: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 640 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(ciImage: small, orientation: .up).perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }), face.confidence >= 0.6, let landmarks = face.landmarks else {
                tracked = nil; trackingStatus = "未识别人脸 · 美型暂不应用"; return
            }
            guard abs(face.yaw?.doubleValue ?? 0) < 0.55, abs(face.roll?.doubleValue ?? 0) < 0.65 else {
                tracked = nil; trackingStatus = "侧脸角度较大 · 美型暂不应用"; return
            }
            guard var next = FaceLandmarkTracker.frame(from: landmarks, imageSize: small.extent.size, time: 1) else {
                tracked = nil; trackingStatus = "五官被遮挡 · 美型暂不应用"; return
            }
            // Anchor each cheek near mouth height instead of using the widest temple points.
            if let contour = landmarks.faceContour?.pointsInImage(imageSize: small.extent.size) {
                let points = contour.map { FacePoint(x: $0.x / small.extent.width, y: 1 - $0.y / small.extent.height) }
                let mid = (next.leftEye.x + next.rightEye.x) / 2
                let desiredY = next.mouth.y - CGFloat(next.eyeSpan) * 0.12
                let left = points.filter { $0.x < mid && $0.y > min(next.leftEye.y,next.rightEye.y) }
                let right = points.filter { $0.x >= mid && $0.y > min(next.leftEye.y,next.rightEye.y) }
                if let a = left.min(by: { abs($0.y-desiredY) < abs($1.y-desiredY) }), let b = right.min(by: { abs($0.y-desiredY) < abs($1.y-desiredY) }) { next.jawLeft = a; next.jawRight = b }
            }
            if var old = tracked, hypot(old.mouth.x-next.mouth.x, old.mouth.y-next.mouth.y) < 0.12 {
                old.time = 0
                next = FaceLandmarkTrack.sample(at: 0.65, keyframes: [old,next]) ?? next
            }
            next.time = 0
            tracked = next; trackingStatus = "人脸已锁定 · 美型生效中"
        } catch { tracked = nil; trackingStatus = "人脸检测暂不可用" }
    }
}
