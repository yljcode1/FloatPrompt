import SwiftUI
import AVFoundation
import Photos
import MetalPetal
import FaceBeauty

final class CameraCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let previewLayer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "shiyan.camera.processing")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var configured = false
    private var cancelled = false
    private var context: MTIContext?
    private let smoothing = MTIHighPassSkinSmoothingFilter()
    private let exposure = MTIExposureFilter()
    private let reshape = LiveFaceReshape()
    private var previousTrackingStatus = ""
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var requestedRecording = false
    private var finishing = false
    private var firstVideoTime: CMTime?
    private var strength: Float = 0.4
    private var brightness: Float = 0.06
    private var rawPreview = false
    private var previewPending = false
    private let previewLock = NSLock()
    @Published var ready = false
    @Published var recording = false
    @Published var saving = false
    @Published var message = "正在准备相机…"
    @Published var savedURL: URL?
    @Published var beautyAmount: Double = 0.4 { didSet { let value = Float(beautyAmount); queue.async { self.strength = value } } }
    @Published var brightening: Double = 0.06 { didSet { let value = Float(brightening); queue.async { self.brightness = value } } }
    @Published var comparing = false { didSet { let value = comparing; queue.async { self.rawPreview = value } } }
    @Published var faceSlim: Double = 0.15 { didSet { let value = faceSlim; queue.async { self.reshape.faceSlim = value } } }
    @Published var eyeEnlarge: Double = 0.08 { didSet { let value = eyeEnlarge; queue.async { self.reshape.eyeEnlarge = value } } }
    @Published var noseSlim: Double = 0.05 { didSet { let value = noseSlim; queue.async { self.reshape.noseSlim = value } } }
    @Published var glassesMode = false { didSet { let value = glassesMode; queue.async { self.reshape.glassesMode = value } } }
    @Published var faceStatus = "正在寻找人脸"
    var onAudio: ((CMSampleBuffer) -> Void)?

    func prepare() async {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard camera && mic else { await MainActor.run { message = "请在系统设置中允许相机和麦克风权限" }; return }
        queue.async { [self] in
            guard !cancelled, !configured else { return }
            do {
                guard let device = MTLCreateSystemDefaultDevice() else { throw CameraError.unavailable }
                context = try MTIContext(device: device)
                session.beginConfiguration()
                do {
                    session.sessionPreset = .hd1920x1080
                    session.automaticallyConfiguresApplicationAudioSession = false
                    try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [])
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.unavailable }
                    try camera.lockForConfiguration()
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    }
                    camera.unlockForConfiguration()
                    for device in [camera, mic] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw CameraError.unavailable }
                        session.addInput(input)
                    }
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else { throw CameraError.unavailable }
                    session.addOutput(videoOutput); session.addOutput(audioOutput)
                    videoOutput.setSampleBufferDelegate(self, queue: queue)
                    audioOutput.setSampleBufferDelegate(self, queue: queue)
                    if let c = videoOutput.connection(with: .video) {
                        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                        if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = true }
                    }
                    session.commitConfiguration()
                } catch { session.commitConfiguration(); throw error }
                configured = true
                session.startRunning()
                DispatchQueue.main.async { self.ready = true; self.message = "自然美颜 · 前置 1080p" }
            } catch { DispatchQueue.main.async { self.message = "相机无法启动：\(error.localizedDescription)" } }
        }
    }
    func toggleRecording() {
        queue.async { [self] in
            guard configured, !cancelled, !finishing else { return }
            if requestedRecording { finishRecording() }
            else {
                requestedRecording = true
                DispatchQueue.main.async { self.recording = true; self.message = "正在录像 · 美颜效果会保存到视频" }
            }
        }
    }
    private func beginWriter(pixel: CVPixelBuffer, time: CMTime) throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = try AVAssetWriter(outputURL: folder.appendingPathComponent(UUID().uuidString + ".mov"), fileType: .mov)
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
        video.expectsMediaDataInRealTime = true
        let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) ?? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        guard asset.canAdd(video), asset.canAdd(audio) else { throw CameraError.unavailable }
        asset.add(video); asset.add(audio)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard asset.startWriting() else { throw asset.error ?? CameraError.unavailable }
        asset.startSession(atSourceTime: time)
        writer = asset; videoInput = video; audioInput = audio; adaptor = adapter; firstVideoTime = time
    }
    private func processed(_ pixel: CVPixelBuffer) throws -> CVPixelBuffer {
        guard strength > 0 || brightness > 0 else { return pixel }
        guard let context else { throw CameraError.unavailable }
        var image = MTIImage(cvPixelBuffer: pixel, alphaType: .alphaIsOne)
        if strength > 0 {
            smoothing.inputImage = image; smoothing.amount = strength; smoothing.radius = 8
            // This filter smooths via a masked tone curve; an identity curve cancels the effect.
            smoothing.toneCurveControlPoints = [MTIVector(x: 0, y: 0), MTIVector(x: 120.0/255.0, y: 146.0/255.0), MTIVector(x: 1, y: 1)]
            guard let output = smoothing.outputImage else { throw CameraError.unavailable }; image = output
        }
        if brightness > 0 { exposure.inputImage = image; exposure.exposure = brightness; guard let output = exposure.outputImage else { throw CameraError.unavailable }; image = output }
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        if pool == nil || size != poolSize {
            poolSize = size
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { throw CameraError.unavailable }
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw CameraError.unavailable }
        try context.render(image, to: buffer)
        return buffer
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !cancelled else { return }
        if output === audioOutput {
            onAudio?(sample)
            if requestedRecording, let writer, writer.status == .writing, let start = firstVideoTime, CMSampleBufferGetPresentationTimeStamp(sample) >= start, audioInput?.isReadyForMoreMediaData == true {
                if audioInput?.append(sample) == false { failRecording(writer.error ?? CameraError.unavailable) }
            }
            return
        }
        guard let raw = CMSampleBufferGetImageBuffer(sample) else { return }
        autoreleasepool {
            do {
                let smoothed = try processed(raw)
                let pixel = try reshape.process(smoothed)
                if reshape.trackingStatus != previousTrackingStatus {
                    previousTrackingStatus = reshape.trackingStatus
                    let state = previousTrackingStatus
                    DispatchQueue.main.async { self.faceStatus = state }
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                display(rawPreview ? raw : pixel, time: time)
                if requestedRecording {
                    if writer == nil { try beginWriter(pixel: pixel, time: time) }
                    if let writer, writer.status == .failed { throw writer.error ?? CameraError.unavailable }
                    if let writer, writer.status == .writing, videoInput?.isReadyForMoreMediaData == true {
                        if adaptor?.append(pixel, withPresentationTime: time) == false { failRecording(writer.error ?? CameraError.unavailable) }
                    }
                }
            } catch {
                display(raw, time: CMSampleBufferGetPresentationTimeStamp(sample))
                if requestedRecording { failRecording(error) }
                else { DispatchQueue.main.async { self.message = "美颜处理失败，请关闭美颜后重试" } }
            }
        }
    }
    private func display(_ pixel: CVPixelBuffer, time: CMTime) {
        previewLock.lock()
        if previewPending { previewLock.unlock(); return }
        previewPending = true; previewLock.unlock()
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if let format { CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) }
        DispatchQueue.main.async { [self] in
            defer { previewLock.lock(); previewPending = false; previewLock.unlock() }
            guard let sample else { return }
            let renderer = previewLayer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        }
    }
    private func failRecording(_ error: Error) {
        requestedRecording = false; writer?.cancelWriting(); writer = nil; videoInput = nil; audioInput = nil; adaptor = nil; firstVideoTime = nil
        DispatchQueue.main.async { self.recording = false; self.saving = false; self.message = "录像失败：\(error.localizedDescription)" }
    }
    private func finishRecording() {
        requestedRecording = false
        guard let asset = writer else { DispatchQueue.main.async { self.recording = false }; return }
        finishing = true
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil; firstVideoTime = nil
        DispatchQueue.main.async { self.recording = false; self.saving = true; self.message = "正在保存视频…" }
        asset.finishWriting { [self] in
            queue.async { self.finishing = false }
            guard asset.status == .completed else { DispatchQueue.main.async { self.saving = false; self.message = "视频保存失败：\(asset.error?.localizedDescription ?? "录制未完成")" }; return }
            saveToPhotos(asset.outputURL)
        }
    }
    private func saveToPhotos(_ url: URL) {
        Task {
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                await MainActor.run { savedURL = url; saving = false; message = "视频已保存在应用内，可点分享导出；保存相册需授权" }; return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                await MainActor.run { savedURL = url; saving = false; message = "美颜视频已保存到相册，提词不会出现在视频里" }
            } catch { await MainActor.run { savedURL = url; saving = false; message = "相册保存失败，视频仍在应用内，可分享导出" } }
        }
    }
    func stop() {
        queue.async { [self] in
            if requestedRecording { finishRecording() }
            cancelled = true; session.stopRunning()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
    #if DEBUG
    func validateBeautyPipeline() {
        queue.async { [self] in
            var report: [String: Any] = [:]
            func save() {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("beauty-check.json"), options: .atomic) }
            }
            do {
                guard let device = MTLCreateSystemDefaultDevice() else { throw CameraError.unavailable }
                context = try MTIContext(device: device)
                var raw: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, 192, 320, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &raw) == kCVReturnSuccess, let raw else { throw CameraError.unavailable }
                CVPixelBufferLockBaseAddress(raw, [])
                let bytes = CVPixelBufferGetBaseAddress(raw)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(raw)
                for y in 0..<320 { for x in 0..<192 {
                    let p = y * stride + x * 4
                    bytes[p] = UInt8(75 + x % 20); bytes[p+1] = UInt8(100 + y % 30); bytes[p+2] = UInt8(140 + (x+y) % 30); bytes[p+3] = 255
                } }
                CVPixelBufferUnlockBaseAddress(raw, [])
                strength = 0; brightness = 0
                let passthrough = try processed(raw)
                report["offPassthrough"] = CFEqual(raw, passthrough)
                strength = 0.65; brightness = 0
                let smoothingOnly = try processed(raw)
                CVPixelBufferLockBaseAddress(raw, .readOnly)
                CVPixelBufferLockBaseAddress(smoothingOnly, .readOnly)
                let sourceBytes = CVPixelBufferGetBaseAddress(raw)!.assumingMemoryBound(to: UInt8.self)
                let smoothBytes = CVPixelBufferGetBaseAddress(smoothingOnly)!.assumingMemoryBound(to: UInt8.self)
                let smoothStride = CVPixelBufferGetBytesPerRow(smoothingOnly)
                var delta = 0, changed = 0
                for y in 0..<320 { for x in 0..<192 { for channel in 0..<3 {
                    let d = abs(Int(sourceBytes[y * stride + x * 4 + channel]) - Int(smoothBytes[y * smoothStride + x * 4 + channel]))
                    delta += d; if d > 0 { changed += 1 }
                } } }
                report["smoothingOnlyMeanAbsoluteDifference"] = Double(delta) / Double(192 * 320 * 3)
                report["smoothingOnlyChangedChannels"] = changed
                report["smoothingWithoutBrightening"] = changed > 0
                CVPixelBufferUnlockBaseAddress(smoothingOnly, .readOnly)
                CVPixelBufferUnlockBaseAddress(raw, .readOnly)
                brightness = 0.12
                let result = try processed(raw)
                CVPixelBufferLockBaseAddress(result, .readOnly)
                let output = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
                report["outputFirstPixel"] = [Int(output[0]), Int(output[1]), Int(output[2])]
                report["processedDiffers"] = output[0] != 75 || output[1] != 100 || output[2] != 140
                CVPixelBufferUnlockBaseAddress(result, .readOnly)
                report["width"] = CVPixelBufferGetWidth(result); report["height"] = CVPixelBufferGetHeight(result)
                let landmarks = FaceLandmarkFrame(time: 0, leftEye: FacePoint(x: 0.35, y: 0.35), rightEye: FacePoint(x: 0.65, y: 0.35), eyeSpan: 0.3, mouth: FacePoint(x: 0.5, y: 0.65), mouthWidth: 0.2, mouthHeight: 0.08, jawLeft: FacePoint(x: 0.2, y: 0.55), jawRight: FacePoint(x: 0.8, y: 0.55), nose: FacePoint(x: 0.5, y: 0.49))
                for name in ["faceSlim", "eyeEnlarge", "noseSlim"] {
                    reshape.faceSlim = name == "faceSlim" ? 0.5 : 0
                    reshape.eyeEnlarge = name == "eyeEnlarge" ? 0.5 : 0
                    reshape.noseSlim = name == "noseSlim" ? 0.5 : 0
                    let warped = try reshape.render(raw, frame: landmarks)
                    CVPixelBufferLockBaseAddress(raw, .readOnly); CVPixelBufferLockBaseAddress(warped, .readOnly)
                    let a = CVPixelBufferGetBaseAddress(raw)!.assumingMemoryBound(to: UInt8.self)
                    let b = CVPixelBufferGetBaseAddress(warped)!.assumingMemoryBound(to: UInt8.self)
                    let row = CVPixelBufferGetBytesPerRow(warped)
                    var changed = 0
                    for y in 0..<320 { for x in 0..<192 { for c in 0..<3 {
                        if a[y * stride + x * 4 + c] != b[y * row + x * 4 + c] { changed += 1 }
                    } } }
                    CVPixelBufferUnlockBaseAddress(warped, .readOnly); CVPixelBufferUnlockBaseAddress(raw, .readOnly)
                    report[name + "ChangedChannels"] = changed
                }
                reshape.faceSlim = 0; reshape.eyeEnlarge = 0; reshape.noseSlim = 0
                report["reshapeOffPassthrough"] = CFEqual(raw, try reshape.process(raw))
                reshape.faceSlim = 0.2
                report["noFacePassthrough"] = CFEqual(raw, try reshape.process(raw))
                report["trackingStateOnGeneratedFrame"] = reshape.trackingStatus
                // Exercise the exact pixel-buffer adaptor used by recording with a generated frame.
                try beginWriter(pixel: result, time: .zero)
                guard let asset = writer, adaptor?.append(result, withPresentationTime: .zero) == true else { throw CameraError.unavailable }
                videoInput?.markAsFinished(); audioInput?.markAsFinished()
                asset.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
                writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
                report["gpuRender"] = true
                save()
                asset.finishWriting {
                    report["encodedVideo"] = asset.status == .completed
                    report["encodedBytes"] = (try? FileManager.default.attributesOfItem(atPath: asset.outputURL.path)[.size]) ?? 0
                    report["encoderError"] = asset.error?.localizedDescription ?? ""
                    save()
                    try? FileManager.default.removeItem(at: asset.outputURL)
                }
            } catch { report["error"] = error.localizedDescription; save() }
        }
    }
    #endif
    enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法准备相机、美颜或视频编码，请重试" }
    }
}
struct CameraPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHost {
        let view = LayerHost(); view.content = layer; layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); return view
    }
    func updateUIView(_ view: LayerHost, context: Context) { }
}
