import AVKit
import UIKit
import CoreText

final class PromptPiP: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let layer = AVSampleBufferDisplayLayer()
    weak var sourceView: UIView?
    private let useCallPresentation = !ProcessInfo.processInfo.arguments.contains("--legacy-pip")
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var callLayer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private var startRequest = UUID()
    private var cachedLines: [String] = []
    private var cachedFont: Double = 0
    private var cachedSize = CGSize.zero
    private var rowRects: [CGRect] = []
    private var offset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var totalHeight: CGFloat = 0
    private var lastIndex = -1
    private var pool: CVPixelBufferPool?
    private var cornerAlpha: UInt8 = 255
    var opaqueDiagnostic = ProcessInfo.processInfo.arguments.contains("--opaque-control")
    private var frames = 0
    private var playbackPaused = false
    private var playbackRequests = 0
    private var visiblePixelCount = 0
    private var lastPixel: CVPixelBuffer?
    var onActiveChanged: ((Bool) -> Void)?
    var onPlayback: ((Bool) -> Void)?
    var onSkip: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var isActive: Bool { controller?.isPictureInPictureActive == true }
    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var diagnosticState: [String: Any] {
        ["callRendererStatus": callLayer?.sampleBufferRenderer.status.rawValue ?? -1, "callReady": callLayer?.isReadyForDisplay ?? false, "presentation": useCallPresentation ? "videoCall" : "sampleBuffer", "timebaseRate": layer.controlTimebase.map { CMTimebaseGetRate($0) } ?? -1, "playbackPaused": playbackPaused, "playbackRequests": playbackRequests, "liveRangeEndValid": CMTimeRangeGetEnd(liveTimeRange).isValid, "opaqueControl": opaqueDiagnostic, "readyForDisplay": layer.isReadyForDisplay, "captureProtected": layer.preventsCapture, "outputObscured": layer.isOutputObscuredDueToInsufficientExternalProtection, "requiresFlush": layer.sampleBufferRenderer.requiresFlushToResumeDecoding, "visiblePixelCount": visiblePixelCount, "alphaRequested": true, "frameCornerAlpha": Int(cornerAlpha), "frames": frames,
         "supported": supported, "possible": controller?.isPictureInPicturePossible ?? false,
         "active": isActive, "rendererStatus": layer.sampleBufferRenderer.status.rawValue,
         "rendererError": layer.sampleBufferRenderer.error?.localizedDescription ?? "",
         "offset": offset, "width": cachedSize.width, "height": cachedSize.height]
    }
    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        layer.isOpaque = false
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
        }
    }
    func prepare() {
        guard controller == nil else { return }
        let source: AVPictureInPictureController.ContentSource
        if useCallPresentation {
            guard let sourceView else { return }
            let vc = AVPictureInPictureVideoCallViewController()
            vc.preferredContentSize = cachedSize == .zero ? CGSize(width: 720, height: 320) : cachedSize
            let host = LayerHost()
            let display = AVSampleBufferDisplayLayer()
            display.videoGravity = .resizeAspect
            display.backgroundColor = UIColor.clear.cgColor
            display.isOpaque = false
            display.controlTimebase = layer.controlTimebase
            host.content = display
            host.layer.addSublayer(display)
            host.backgroundColor = .clear
            host.isOpaque = false
            vc.view = host
            callLayer = display
            callViewController = vc
            source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: sourceView, contentViewController: vc)
        } else {
            source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        }
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.requiresLinearPlayback = true
    }
    func start() {
        prepare()
        playbackPaused = false
        if let timebase = layer.controlTimebase { CMTimebaseSetRate(timebase, rate: 1) }
        controller?.invalidatePlaybackState()
        guard supported else { onStatus?("此设备不支持悬浮。"); return }
        let token = UUID(); startRequest = token
        startWhenReady(token: token, retries: 30)
    }
    private func startWhenReady(token: UUID, retries: Int) {
        guard token == startRequest else { return }
        if controller?.isPictureInPicturePossible == true { controller?.startPictureInPicture(); return }
        guard retries > 0 else { onStatus?("悬浮准备超时，请返回应用后重试。"); return }
        if retries == 30 { onStatus?("正在准备悬浮文字…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startWhenReady(token: token, retries: retries - 1) }
    }
    func stop() { startRequest = UUID(); controller?.stopPictureInPicture() }
    func resetOffset() { lastIndex = -1 }
    @discardableResult func advance(points: Double) -> Bool {
        let limit = max(0, totalHeight - cachedSize.height + 36)
        offset = min(limit, offset + CGFloat(points)); targetOffset = offset
        return limit > 0 && offset >= limit
    }
    var visibleIndex: Int { rowRects.lastIndex(where: { $0.minY <= offset + 45 }) ?? 0 }
    private func layout(lines: [String], fontSize: Double, size: CGSize) {
        cachedLines = lines; cachedFont = fontSize; cachedSize = size
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, CGFloat(fontSize) * 1.5, nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10
        var y: CGFloat = 64
        rowRects = lines.map { text in
            // Measure with the same font and shaping engine used to draw the frame.
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, .paragraphStyle: paragraph])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: attributed.length), nil, CGSize(width: size.width - 56, height: .greatestFiniteMagnitude), nil)
            let rect = CGRect(x: 28, y: y, width: size.width - 56, height: ceil(measured.height) + 12)
            y += rect.height + 24; return rect
        }
        totalHeight = y
        offset = min(offset, max(0, totalHeight - size.height)); targetOffset = offset; lastIndex = -1
        callViewController?.preferredContentSize = size
        pool = nil
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    func update(lines: [String], index: Int, fontSize: Double, shape: PromptShape = .wide, automatic: Bool = false, yellowText: Bool = false, stateText: String = "") {
        let size = shape.size
        if lines != cachedLines || fontSize != cachedFont || size != cachedSize { layout(lines: lines, fontSize: fontSize, size: size) }
        if index != lastIndex {
            if !automatic, rowRects.indices.contains(index) { targetOffset = max(0, rowRects[index].minY - 64) }
            lastIndex = index
        }
        if !automatic { offset += (targetOffset - offset) * 0.28 }
        guard let pool else { return }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        var locked = true
        defer { if locked { CVPixelBufferUnlockBaseAddress(pixel, []) } }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.clear(CGRect(origin: .zero, size: size))
        if opaqueDiagnostic {
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        CVBufferSetAttachment(pixel, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        // CoreText draws directly into the pixel buffer, including while backgrounded.
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, CGFloat(fontSize) * 1.5, nil)
        for i in lines.indices {
            var rect = rowRects[i]; rect.origin.y -= offset
            guard rect.maxY > 0, rect.minY < size.height else { continue }
            let color: UIColor = yellowText ? .systemYellow : .white
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): (i < index ? color.withAlphaComponent(0.45) : color).cgColor,
                .paragraphStyle: paragraph
            ]
            let text = NSAttributedString(string: lines[i], attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: CGRect(x: rect.minX, y: size.height - rect.maxY - 4, width: rect.width, height: rect.height + 8), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: UIColor.black.withAlphaComponent(0.9).cgColor)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
        if !stateText.isEmpty {
            context.saveGState()
            context.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x: 0, y: size.height - 44, width: size.width, height: 44))
            let label = NSAttributedString(string: stateText, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Medium" as CFString, 21, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.withAlphaComponent(0.85).cgColor])
            context.textPosition = CGPoint(x: 28, y: size.height - 30)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.restoreGState()
        }
        if let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) {
            cornerAlpha = bytes[3]
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            var count = 0
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) where bytes[y * stride + x * 4 + 3] > 32 { count += 1 }
            }
            visiblePixelCount = count
        }
        // Release CPU access before the video compositor reads this IOSurface.
        CVPixelBufferUnlockBaseAddress(pixel, [])
        locked = false
        lastPixel = pixel
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 20), presentationTimeStamp: layer.controlTimebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        // DisplayImmediately is a per-sample attachment, not a buffer-level attachment.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.sampleBufferRenderer.status == .failed || layer.sampleBufferRenderer.requiresFlushToResumeDecoding { layer.sampleBufferRenderer.flush() }
        if layer.sampleBufferRenderer.isReadyForMoreMediaData { layer.sampleBufferRenderer.enqueue(sample); frames += 1 }
        if let renderer = callLayer?.sampleBufferRenderer {
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        }
    }
    func saveRenderedFrame(to url: URL) {
        guard let pixel = lastPixel else { return }
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = CIContext().createCGImage(image, from: image.extent), let data = UIImage(cgImage: cg).pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }
    // A live range must have a finite origin: -infinity + infinity has an invalid end.
    private var liveTimeRange: CMTimeRange { CMTimeRange(start: .zero, duration: .positiveInfinity) }
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        playbackPaused = !playing
        // Preserve the current frame when Camera asks playback to pause.
        if let timebase = layer.controlTimebase { CMTimebaseSetRate(timebase, rate: playing ? 1 : 0) }
        playbackRequests += 1
        onPlayback?(playing)
        c.invalidatePlaybackState()
        onStatus?(playing ? "系统请求继续播放提词" : "系统请求暂停提词滚动")
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange { liveTimeRange }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { playbackPaused }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval interval: CMTime, completion: @escaping () -> Void) { onSkip?(interval.seconds > 0); completion() }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { onActiveChanged?(true); onStatus?("悬浮已开启") }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { onStatus?("悬浮失败：\(error.localizedDescription)") }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onActiveChanged?(false); onStatus?("悬浮已关闭") }
}
