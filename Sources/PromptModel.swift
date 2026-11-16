import SwiftUI
import Speech
import AVFoundation

private final class SpeechInputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(_ value: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = value; lock.unlock() }
    func appendSample(_ buffer: CMSampleBuffer) { lock.lock(); request?.appendAudioSampleBuffer(buffer); lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
}

struct PromptDocument: Codable, Identifiable {
    var id = UUID()
    var text: String
    var position = 0
    var customTitle: String?
    var savedFontSize: Double?
    var savedSpeed: Double?
    var savedShape: String?
    var deletedAt: Date?
    var title: String { customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? customTitle! : String(text.split(whereSeparator: { $0.isNewline }).first?.prefix(32) ?? "未命名稿件") }
}

@MainActor
final class PromptModel: ObservableObject {
    @Published var documents: [PromptDocument] = []
    @Published var selectedDocumentID: UUID?
    private var switchingDocument = false
    @Published var recentlyDeleted: [PromptDocument] = []
    @Published var paused = false
    @Published var followState = "准备就绪"
    var currentTitle: String { documents.first(where: { $0.id == selectedDocumentID })?.title ?? "未命名稿件" }

    @Published var script: String {
        didSet {
            UserDefaults.standard.set(script, forKey: "script")
            linesCache = ScriptMatcher.sentences(script)
            semanticTask?.cancel(); semanticVersion = UUID()
            current = min(current, max(0, lines.count - 1))
            persistDocument()
        }
    }
    @Published var current = 0 { didSet { UserDefaults.standard.set(current, forKey: "readingPosition"); persistDocument() } }
    @Published var floating = false { didSet { updateIdleTimer() } }
    enum ReadingMode { case manual, constant, voice }
    @Published var readingMode: ReadingMode = .voice
    private var startingFloating = false
    @Published var automatic = false { didSet { updateIdleTimer() } }
    @Published var speed: Double = 18 { didSet { UserDefaults.standard.set(speed, forKey: "speed"); persistDocument() } }
    @Published var fontSize: Double = 28 { didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize"); persistDocument() } }
    @Published var shape: PromptShape = .strip { didSet { UserDefaults.standard.set(shape.rawValue, forKey: "shape"); persistDocument() } }
    @Published var yellowText = false { didSet { UserDefaults.standard.set(yellowText, forKey: "yellowText") } }
    @Published var semanticEnabled = true { didSet { UserDefaults.standard.set(semanticEnabled, forKey: "semanticEnabled"); semanticTask?.cancel() } }
    @Published var opaqueControl = false {
        didSet { pip.opaqueDiagnostic = opaqueControl; render(); log(opaqueControl ? "不透明对照已启用（仅诊断）" : "透明模式已恢复") }
    }
    @Published var voice = false { didSet { updateIdleTimer() } }
    @Published var startingVoice = false
    @Published var listening = false
    @Published var transcript = ""
    @Published var status = "准备就绪"
    @Published var aiStatus = ""
    @Published var events: [String] = []
    let pip = PromptPiP()
    private let semantic = SemanticFollower()
    private let router = SpeechInputRouter()
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var tapInstalled = false
    private var ownsInputSession = false
    var cameraInputActive = false
    func cameraAudioConsumer() -> (CMSampleBuffer) -> Void {
        let router = self.router
        return { sample in router.appendSample(sample) }
    }
    private var receivedBuffers = 0
    private var generation = UUID()
    private var permissionRequest = UUID()
    private var semanticVersion = UUID()
    private var semanticTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var retries = 0
    private var lastTick = Date()
    private var lastDiagnostics = Date.distantPast
    private var linesCache: [String] = []
    var lines: [String] { linesCache }
    init() {
        let defaults = UserDefaults.standard
        script = defaults.string(forKey: "script") ?? "欢迎使用拾言。\n你可以边看稿子边拍摄视频。\n临时扩展时，提词器会尝试保留当前位置。\n讲回稿子后，再继续跟随。"
        linesCache = ScriptMatcher.sentences(script)
        if defaults.object(forKey: "speed") != nil { speed = defaults.double(forKey: "speed") }
        if defaults.object(forKey: "fontSize") != nil { fontSize = defaults.double(forKey: "fontSize") }
        shape = PromptShape(rawValue: defaults.string(forKey: "shape") ?? "") ?? .strip
        yellowText = defaults.bool(forKey: "yellowText")
        if defaults.object(forKey: "semanticEnabled") != nil { semanticEnabled = defaults.bool(forKey: "semanticEnabled") }
        current = min(max(0, defaults.integer(forKey: "readingPosition")), max(0, linesCache.count - 1))
        if let data = defaults.data(forKey: "promptDocuments"), let saved = try? JSONDecoder().decode([PromptDocument].self, from: data), !saved.isEmpty {
            documents = saved
            let selected = saved.first(where: { $0.id.uuidString == defaults.string(forKey: "selectedDocumentID") }) ?? saved[0]
            switchingDocument = true
            selectedDocumentID = selected.id
            script = selected.text
            current = min(max(0, selected.position), max(0, lines.count - 1))
            applySettings(selected)
            switchingDocument = false
        } else {
            let migrated = PromptDocument(text: script, position: current)
            documents = [migrated]; selectedDocumentID = migrated.id
        }
        if let data = defaults.data(forKey: "deletedDocuments"), let saved = try? JSONDecoder().decode([PromptDocument].self, from: data) {
            recentlyDeleted = saved
        }
        persistDocument()
        aiStatus = semantic.availabilityText
        pip.onActiveChanged = { [weak self] active in Task { @MainActor in self?.floating = active } }
        pip.onStatus = { [weak self] message in Task { @MainActor in self?.log(message) } }
        pip.onPlayback = { [weak self] playing in
            Task { @MainActor in
                guard let self else { return }
                // Camera may send a playback pause: do not cancel independent speech input.
                if !self.voice { self.automatic = playing }
            }
        }
        pip.onSkip = { [weak self] forward in Task { @MainActor in self?.move(forward ? 1 : -1) } }
        for (notification, text) in [(UIApplication.didEnterBackgroundNotification, "应用进入后台"), (UIApplication.didBecomeActiveNotification, "应用进入前台")] {
            NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.log(text) }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.stopVoice(releaseSession: false); self.automatic = false
                    self.followState = "麦克风被占用 · 点击继续重试"
                    self.paused = true
                    self.log("麦克风被其他应用中断，已暂停跟随")
                } else { self.log("音频中断结束，可重新开启语音跟随") }
            }
        }
    }
    private func persistDocument() {
        guard !switchingDocument, let id = selectedDocumentID, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].text = script
        documents[index].position = current
        documents[index].savedFontSize = fontSize
        documents[index].savedSpeed = speed
        documents[index].savedShape = shape.rawValue
        saveLibrary()
    }
    private func saveLibrary() {
        guard let data = try? JSONEncoder().encode(documents) else { return }
        UserDefaults.standard.set(data, forKey: "promptDocuments")
        if let deleted = try? JSONEncoder().encode(recentlyDeleted) { UserDefaults.standard.set(deleted, forKey: "deletedDocuments") }
        UserDefaults.standard.set(selectedDocumentID?.uuidString, forKey: "selectedDocumentID")
    }
    func selectDocument(_ id: UUID) {
        guard let document = documents.first(where: { $0.id == id }), id != selectedDocumentID else { return }
        stopAll()
        persistDocument()
        switchingDocument = true
        selectedDocumentID = id
        script = document.text
        current = min(max(0, document.position), max(0, lines.count - 1))
        applySettings(document)
        switchingDocument = false
        transcript = ""
        pip.resetOffset(); render(); saveLibrary()
    }
    func newDocument() {
        let document = PromptDocument(text: "")
        documents.insert(document, at: 0)
        selectDocument(document.id)
    }
    func deleteDocument(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        if selectedDocumentID == id {
            if let next = documents.first(where: { $0.id != id }) { selectDocument(next.id) }
            else { newDocument() }
        }
        if var removed = documents.first(where: { $0.id == id }) { removed.deletedAt = Date(); recentlyDeleted.insert(removed, at: 0) }
        documents.removeAll(where: { $0.id == id })
        saveLibrary()
    }
    private func applySettings(_ document: PromptDocument) {
        fontSize = min(40, max(16, document.savedFontSize ?? fontSize))
        speed = min(80, max(5, document.savedSpeed ?? speed))
        shape = document.savedShape.flatMap(PromptShape.init(rawValue:)) ?? shape
    }
    func renameDocument(_ id: UUID, title: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].customTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        saveLibrary()
    }
    func duplicateDocument(_ id: UUID) {
        persistDocument()
        guard var copy = documents.first(where: { $0.id == id }) else { return }
        copy.customTitle = copy.title + " 副本"; copy.id = UUID(); copy.position = 0; copy.deletedAt = nil
        documents.insert(copy, at: 0); selectDocument(copy.id)
    }
    func restoreDocument(_ id: UUID) {
        guard var document = recentlyDeleted.first(where: { $0.id == id }) else { return }
        document.deletedAt = nil; documents.insert(document, at: 0)
        recentlyDeleted.removeAll(where: { $0.id == id }); saveLibrary()
    }
    func pauseReading() {
        paused = true; automatic = false; stopVoice(); followState = "已暂停 · 保留当前位置"
        log("已暂停，可从当前位置继续")
    }
    func resumeReading() {
        paused = false
        if readingMode == .voice { Task { await startVoice() } }
        else { automatic = readingMode == .constant; followState = automatic ? "匀速滚动中" : "手动提词" }
    }
    func log(_ text: String) {
        status = text
        events.insert(Date().formatted(date: .omitted, time: .standard) + " " + text, at: 0)
        events = Array(events.prefix(80)); saveDiagnostics()
    }
    func saveDiagnostics() {
        let audio = AVAudioSession.sharedInstance()
        let audioState: [String: Any] = ["category": audio.category.rawValue, "mode": audio.mode.rawValue, "inputGain": audio.inputGain, "sampleRate": audio.sampleRate, "inputChannels": audio.inputNumberOfChannels, "inputs": audio.currentRoute.inputs.map { $0.portType.rawValue }, "outputs": audio.currentRoute.outputs.map { $0.portType.rawValue }, "ownsInputSession": ownsInputSession]
        let report: [String: Any] = ["audio": audioState, "timestamp": Date().ISO8601Format(), "system": UIDevice.current.systemVersion, "pip": pip.diagnosticState, "voice": voice, "receivedBuffers": receivedBuffers, "engineRunning": engine.isRunning, "aiAvailable": semantic.available, "aiStatus": aiStatus, "current": current, "events": events]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
        let history = folder.appendingPathComponent("diagnostics-history.jsonl")
        if !FileManager.default.fileExists(atPath: history.path) { FileManager.default.createFile(atPath: history.path, contents: nil) }
        if let compact = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let handle = try? FileHandle(forWritingTo: history) {
            defer { try? handle.close() }
            if let length = try? handle.seekToEnd(), length > 2_000_000 { try? handle.truncate(atOffset: 0); try? handle.seek(toOffset: 0) }
            try? handle.write(contentsOf: compact + Data([10]))
        }
        pip.saveRenderedFrame(to: folder.appendingPathComponent("rendered-frame.png"))
    }
    func runValidationIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--validate-pip") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if ProcessInfo.processInfo.arguments.contains("--validate-voice") { await startVoice() }
            startFloating()
            try? await Task.sleep(for: .seconds(8))
            saveDiagnostics()
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { pip.saveRenderedFrame(to: folder.appendingPathComponent("rendered-frame.png")) }
        }
        #endif
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = cameraInputActive || floating || automatic || voice
    }
    func move(_ delta: Int) { seek(min(max(0, current + delta), max(0, lines.count - 1))) }
    func seek(_ index: Int) {
        semanticTask?.cancel(); semanticVersion = UUID()
        current = min(max(0, index), max(0, lines.count - 1)); pip.resetOffset(); render()
    }
    func selectMode(_ mode: ReadingMode) {
        readingMode = mode
        paused = false
        stopVoice()
        automatic = mode == .constant
        if mode == .voice && (floating || cameraInputActive) { Task { await startVoice() } }
    }
    func startFloating() {
        guard !startingFloating else { return }
        guard !lines.isEmpty else { log("先写一段稿子再开启悬浮"); return }
        startingFloating = true
        paused = false
        Task {
            defer { startingFloating = false }
            if readingMode == .voice && !voice {
                await startVoice()
                guard readingMode == .voice, voice else { return }
            }
            automatic = readingMode == .constant
            beginFloating()
        }
    }
    private func beginFloating() {
        guard !pip.isActive else { log("悬浮已开启，可以切换到相机拍摄"); return }
        guard !lines.isEmpty else { log("先写一段稿子再开启悬浮"); return }
        do {
            if !voice {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers]); try audio.setActive(true)
            }
            render(); pip.start()
        } catch { log("无法开启音频会话：\(error.localizedDescription)") }
    }
    func stopAll() { paused = false; automatic = false; stopVoice(); pip.stop(); log("已停止提词") }
    func render() { pip.update(lines: lines, index: current, fontSize: fontSize, shape: shape, automatic: automatic || paused, yellowText: yellowText, stateText: paused ? "已暂停" : readingMode == .voice ? followState : readingMode == .constant ? "匀速滚动" : "手动提词") }
    func startClock() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date(), elapsed = min(0.2, now.timeIntervalSince(self.lastTick)); self.lastTick = now
                if self.automatic && !self.voice {
                    if self.pip.advance(points: self.speed * elapsed) { self.automatic = false; self.log("已读到稿件结尾") }
                    self.current = min(max(0, self.lines.count - 1), self.pip.visibleIndex)
                }
                self.render()
                if now.timeIntervalSince(self.lastDiagnostics) > 3 { self.lastDiagnostics = now; self.saveDiagnostics() }
            }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func startVoice() async {
        guard !paused, !voice, !startingVoice else { return }
        startingVoice = true
        followState = "正在准备聆听…"
        let token = UUID(); permissionRequest = token
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard token == permissionRequest else { return }
        startingVoice = false
        guard speech == .authorized && mic else { followState = "需要麦克风与语音识别权限"; log("请允许麦克风和语音识别权限"); return }
        guard recognizer?.isAvailable == true else { followState = "语音识别暂不可用"; log("中文语音识别暂不可用"); return }
        if cameraInputActive {
            voice = true; automatic = false; transcript = ""; retries = 0
            beginRecognition(); listening = true; followState = "正在聆听"
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            // Speech matching needs input, but no speaker route override or measurement processing.
            try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            ownsInputSession = true
            let node = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "Microphone", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风被占用"]) }
            receivedBuffers = 0; retries = 0
            let router = self.router
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                router.append(buffer)
                Task { @MainActor in self?.receivedBuffers += 1 }
            }
            tapInstalled = true; voice = true; automatic = false
            beginRecognition()
            engine.prepare(); try engine.start(); listening = true
            followState = "正在聆听"
            aiStatus = semantic.availabilityText
            log(recognizer?.supportsOnDeviceRecognition == true ? "设备端语音跟随已开启" : "系统在线语音识别已开启")
        } catch { stopVoice(); followState = "无法开始聆听 · 请重试"; log("无法开始跟随：\(error.localizedDescription)") }
    }
    private func beginRecognition() {
        guard voice else { return }
        let token = UUID(); generation = token
        rotationTask?.cancel(); router.replace(nil); request?.endAudio(); task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest(); req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition == true
        req.contextualStrings = Array(lines.prefix(50)).map { String($0.prefix(80)) }
        request = req; router.replace(req)
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == token, self.voice else { return }
                if let result {
                    self.retries = 0; self.transcript = result.bestTranscription.formattedString
                    self.follow(self.transcript)
                    if result.isFinal { self.scheduleRenewal(token: token, delay: 0.15); return }
                }
                if let error {
                    self.retries += 1
                    if self.retries <= 3 && (self.engine.isRunning || self.cameraInputActive) { self.scheduleRenewal(token: token, delay: Double(self.retries)); self.followState = "识别恢复中…"; self.log("识别会话正在恢复") }
                    else { self.stopVoice(); self.paused = true; self.followState = "识别暂停 · 点击继续重试"; self.log("识别暂停：\(error.localizedDescription)") }
                }
            }
        }
        rotationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.generation == token, self.voice else { return }
            // Rotate only the recognition request, never reactivate Camera's audio session.
            self.beginRecognition()
        }
    }
    private func scheduleRenewal(token: UUID, delay: Double) {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.voice, self.generation == token else { return }
            self.beginRecognition()
        }
    }
    private func follow(_ speech: String) {
        guard !paused else { return }
        semanticTask?.cancel(); semanticVersion = UUID()
        if let match = ScriptMatcher.match(speech, lines: lines, current: current) {
            if match.index != current { current = match.index; render() }
            followState = "正在聆听"
            status = "跟随第 \(current + 1) 段"; return
        }
        followState = "自由发挥中 · 保留当前位置"
        status = "自由发挥中，保留当前位置"
        guard semanticEnabled, semantic.available, ScriptMatcher.normalize(speech).count >= 8 else { return }
        let token = semanticVersion, position = current, snapshot = lines
        semanticTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.voice, token == self.semanticVersion else { return }
            do {
                let index = try await self.semantic.locate(speech, lines: snapshot, current: position)
                guard !Task.isCancelled, self.voice, token == self.semanticVersion, position == self.current, snapshot == self.lines else { return }
                if let index { self.followState = "正在聆听"; self.current = index; self.status = "AI 跟随第 \(index + 1) 段"; self.render() }
            } catch {
                if !Task.isCancelled { self.aiStatus = "语义匹配暂不可用，继续文字跟随" }
            }
        }
    }
    func stopVoice(releaseSession: Bool = true) {
        permissionRequest = UUID(); generation = UUID(); semanticVersion = UUID()
        rotationTask?.cancel(); semanticTask?.cancel(); router.replace(nil)
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        voice = false; listening = false; startingVoice = false
        let shouldRelease = ownsInputSession
        ownsInputSession = false
        if shouldRelease && releaseSession {
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setActive(false, options: [.notifyOthersOnDeactivation])
                try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } catch { log("释放麦克风失败：\(error.localizedDescription)") }
        }
    }
}
