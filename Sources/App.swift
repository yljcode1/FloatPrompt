import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main struct FloatPromptApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
struct PreviewView: UIViewRepresentable {
    let pip: PromptPiP
    func makeUIView(context: Context) -> UIView {
        let view = LayerHost(); view.content = pip.layer
        view.backgroundColor = .clear; view.isOpaque = false
        view.layer.addSublayer(pip.layer); pip.sourceView = view; pip.prepare(); return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
final class LayerHost: UIView {
    var content: CALayer?
    override func layoutSubviews() { super.layoutSubviews(); content?.frame = bounds }
}
private enum PromptStyle {
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.15)
    static let accent = Color(red: 0.20, green: 0.39, blue: 0.32)
    static let canvas = Color(red: 0.96, green: 0.96, blue: 0.93)
}
struct ContentView: View {
    @StateObject private var model = PromptModel()
    @State private var cameraPresented = false
    @State private var edit = false
    @State private var library = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var renamePresented = false
    @State private var deletingDocument: UUID?
    @State private var confirmDelete = false
    @State private var settings = false
    @State private var logs = false
    @State private var locate = false
    @State private var sentenceSearch = ""
    @State private var importFile = false
    @State private var importedScript: String?
    @State private var confirmImport = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Button { cameraPresented = true } label: {
                        Label("打开相机拍摄", systemImage: "camera.fill").font(.headline).frame(maxWidth: .infinity).padding(18)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    }.disabled(model.lines.isEmpty)
                    preview
                    controls
                    HStack {
                        Text("我的稿件").font(.headline)
                        Spacer()
                        Button("全部 \(model.documents.count) 份") { library = true }.font(.subheadline)
                        Button { model.newDocument(); edit = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }.accessibilityLabel("新增稿件")
                    }
                    scriptCard
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("稿件保存在本机 · 没有使用倒计时")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
            }
            .background(PromptStyle.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .onAppear { model.startClock(); model.render(); model.runValidationIfRequested()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--validate-beauty") { CameraCapture().validateBeautyPipeline() }
                #endif
            }
            .fullScreenCover(isPresented: $cameraPresented) { CameraScreen(model: model) }
            .sheet(isPresented: $edit) { editor }
            .sheet(isPresented: $library) { libraryView }
            .sheet(isPresented: $settings) { settingsView }
            .sheet(isPresented: $logs) { logView }
            .sheet(isPresented: $locate) { sentencePicker }

        }.tint(PromptStyle.accent).preferredColorScheme(.light)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("拾言").font(.system(size: 34, weight: .bold, design: .rounded)).tracking(2)
                Text("把注意力，留给表达。").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
                    .frame(width: 48, height: 48).background(.white, in: Circle())
            }.accessibilityLabel("提词设置")
        }.foregroundStyle(PromptStyle.ink)
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Label("提词预览", systemImage: "viewfinder").font(.caption.weight(.medium))
                Spacer()
                Button { model.fontSize = max(16, model.fontSize - 2); model.render() } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 44, height: 44)
                }.accessibilityLabel("缩小文字").disabled(model.fontSize <= 16)
                Button { model.fontSize = min(40, model.fontSize + 2); model.render() } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 44, height: 44)
                }.accessibilityLabel("放大文字").disabled(model.fontSize >= 40)
            }.foregroundStyle(.white.opacity(0.6)).padding(20)
            PreviewView(pip: model.pip)
                .aspectRatio(model.shape.size.width / model.shape.size.height, contentMode: .fit)
                .padding(.horizontal, 8)
            HStack {
                Button { model.move(-1) } label: {
                    Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("上一句").disabled(model.current == 0)
                Spacer()
                Button { locate = true } label: {
                    Label("第 \(model.lines.isEmpty ? 0 : model.current + 1) / \(model.lines.count) 句", systemImage: "list.bullet")
                        .font(.caption.monospacedDigit()).frame(minHeight: 44)
                }.accessibilityIdentifier("progressLabel").accessibilityHint("打开稿件，选择从哪一句开始")
                Spacer()
                Button { model.move(1) } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("下一句").disabled(model.current >= model.lines.count - 1)
            }.foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 16).padding(.top, 10)
            if model.lines.count > 1 {
                Slider(value: Binding(get: { Double(model.current) }, set: { model.seek(Int($0.rounded())) }), in: 0...Double(model.lines.count - 1), step: 1)
                    .tint(Color(red: 0.72, green: 0.86, blue: 0.62))
                    .accessibilityLabel("稿件进度").padding(.horizontal, 24).padding(.bottom, 14)
            }
        }
        .background(LinearGradient(colors: [PromptStyle.ink, Color(red: 0.07, green: 0.10, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("阅读节奏").font(.headline)
                Spacer()
                Button("回到开头") { model.seek(0) }.font(.caption.weight(.medium))
            }
            HStack(spacing: 10) {
                modeButton("手动", icon: "hand.draw", selected: model.readingMode == .manual) {
                    model.selectMode(.manual)
                }
                modeButton("匀速", icon: "arrow.up", selected: model.readingMode == .constant) {
                    model.selectMode(.constant)
                }
                modeButton("跟随声音", icon: "waveform", selected: model.readingMode == .voice) {
                    model.selectMode(.voice)
                }
            }
            if model.floating || model.voice || model.automatic || model.paused {
                Button {
                    if model.paused { model.resumeReading() } else { model.pauseReading() }
                } label: {
                    Label(model.paused ? "继续提词" : "暂停提词", systemImage: model.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.bordered)
            }
            if model.paused {
                Label(model.followState, systemImage: "pause.circle").font(.subheadline).foregroundStyle(.secondary)
            } else if model.automatic && !model.voice {
                HStack {
                    Text("滚动速度").font(.subheadline).foregroundStyle(.secondary)
                    Slider(value: $model.speed, in: 5...80, step: 1).accessibilityLabel("滚动速度")
                    Text("\(Int(model.speed))").font(.subheadline.monospacedDigit()).frame(width: 30)
                }
            } else if model.voice || model.startingVoice {
                Label(model.followState, systemImage: "mic.fill")
                    .font(.caption).foregroundStyle(PromptStyle.accent)
                if !model.transcript.isEmpty {
                    Text(String(model.transcript.suffix(80))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if model.readingMode == .voice {
                Text("开启悬浮后自动跟随声音；停顿或临时发挥时，保留当前位置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("用预览下方的按钮或进度条，找到要讲的那一句。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24))
    }
    private func modeButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption.weight(.semibold))
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundStyle(selected ? Color.white : PromptStyle.ink)
                .background(selected ? PromptStyle.accent : PromptStyle.canvas, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var scriptCard: some View {
        Button { edit = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(PromptStyle.accent)
                    .frame(width: 52, height: 58).background(PromptStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.currentTitle)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(model.script.count) 字 · 点击编辑完整稿件").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityLabel("编辑稿件")
    }
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.stopAll() } label: {
                    Image(systemName: "stop.fill").frame(width: 54, height: 54)
                        .background(PromptStyle.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }.accessibilityLabel("停止提词")
                Button { model.startFloating() } label: {
                    HStack {
                        Image(systemName: "pip.enter")
                        Text(model.floating ? "悬浮已开启" : "开启悬浮提词").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(.horizontal, 22).frame(height: 54).foregroundStyle(.white)
                        .background(PromptStyle.accent, in: RoundedRectangle(cornerRadius: 18))
                }.disabled(model.lines.isEmpty || model.floating).accessibilityLabel(model.floating ? "悬浮已开启" : "开启悬浮")
            }
            Text(model.floating && model.status == "悬浮已开启" ? "现在切换到相机，就能边看稿边拍摄" : model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8).background(.regularMaterial)
    }
    private var libraryView: some View {
        NavigationStack {
            List {
                ForEach(model.documents) { document in
                    Button {
                        model.selectDocument(document.id)
                        library = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(document.title).foregroundStyle(PromptStyle.ink).lineLimit(1)
                                Text("\(document.text.count) 字").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if document.id == model.selectedDocumentID { Image(systemName: "checkmark.circle.fill") }
                        }.padding(.vertical, 6)
                    }
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") { renameID = document.id; renameTitle = document.title; renamePresented = true }
                        Button("复制稿件", systemImage: "doc.on.doc") { model.duplicateDocument(document.id); library = false }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deletingDocument = document.id; confirmDelete = true }
                    }
                }
                Section {
                    NavigationLink {
                        List {
                            ForEach(model.recentlyDeleted) { document in
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(document.title).lineLimit(2)
                                        Text("\(document.text.count) 字").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("恢复") { model.restoreDocument(document.id) }.buttonStyle(.bordered)
                                }
                            }
                        }
                        .overlay { if model.recentlyDeleted.isEmpty { ContentUnavailableView("没有已删除的稿件", systemImage: "trash") } }
                        .navigationTitle("最近删除")
                    } label: { Label("最近删除（\(model.recentlyDeleted.count)）", systemImage: "trash") }
                } footer: { Text("已删除稿件保留在这里，可随时恢复。长按列表中的稿件可重命名或复制。") }
            }
            .navigationTitle("我的稿件").navigationBarTitleDisplayMode(.inline)
            .alert("稿件名称", isPresented: $renamePresented) {
                TextField("输入标题", text: $renameTitle)
                Button("保存") { if let id = renameID { model.renameDocument(id, title: renameTitle) } }
                Button("取消", role: .cancel) { }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { library = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新增", systemImage: "plus") {
                        model.newDocument(); library = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { edit = true }
                    }
                }
            }
            .confirmationDialog("删除这份稿件？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除稿件", role: .destructive) { if let id = deletingDocument { model.deleteDocument(id) }; deletingDocument = nil }
                Button("取消", role: .cancel) { deletingDocument = nil }
            } message: { Text("稿件将移入“最近删除”，可随时恢复。") }
        }
    }
    private var editor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("写下来，再自然地说出来。")
                    Spacer()
                    Text("\(model.script.count) 字").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
                TextEditor(text: $model.script).font(.system(size: 20)).lineSpacing(8)
                    .scrollContentBackground(.hidden).padding(.horizontal, 16)
            }.padding(.top, 16).background(PromptStyle.canvas)
                .navigationTitle("我的稿件").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("重命名", systemImage: "pencil") { renameID = model.selectedDocumentID; renameTitle = model.currentTitle; renamePresented = true }
                            Button("复制稿件", systemImage: "doc.on.doc") { if let id = model.selectedDocumentID { model.duplicateDocument(id) } }
                            Button("新增稿件", systemImage: "plus") { model.newDocument() }
                            Button("删除当前稿件", systemImage: "trash", role: .destructive) { deletingDocument = model.selectedDocumentID; confirmDelete = true }
                            Button("从文件导入", systemImage: "square.and.arrow.down") { importFile = true }
                            if UserDefaults.standard.string(forKey: "scriptBeforeImport") != nil {
                                Button("恢复导入前的稿件", systemImage: "arrow.uturn.backward") {
                                    if let previous = UserDefaults.standard.string(forKey: "scriptBeforeImport") {
                                        UserDefaults.standard.set(model.script, forKey: "scriptBeforeImport")
                                        model.script = previous; model.seek(0)
                                    }
                                }
                            }
                            ShareLink(item: model.script) { Label("分享稿件", systemImage: "square.and.arrow.up") }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("稿件操作")
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.render(); edit = false }.fontWeight(.semibold) }
                }
                .alert("稿件名称", isPresented: $renamePresented) {
                    TextField("输入标题", text: $renameTitle)
                    Button("保存") { if let id = renameID { model.renameDocument(id, title: renameTitle) } }
                    Button("取消", role: .cancel) { }
                }
                .confirmationDialog("删除当前稿件？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除稿件", role: .destructive) { if let id = deletingDocument { model.deleteDocument(id) }; deletingDocument = nil; edit = false }
                    Button("取消", role: .cancel) { deletingDocument = nil }
                } message: { Text("稿件将移入“最近删除”，可随时恢复。") }
                .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        guard data.count <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                        importedScript = text
                        confirmImport = true
                    } catch CocoaError.userCancelled { }
                    catch { importError = "无法读取稿件，请选择 UTF-8 或 UTF-16 编码的 TXT、Markdown 文本文件。" }
                }
                .confirmationDialog("如何导入这份稿件？", isPresented: $confirmImport, titleVisibility: .visible) {
                    Button("追加到当前稿件") {
                        if let text = importedScript { model.script += (model.script.isEmpty ? "" : "\n\n") + text; model.render() }
                        importedScript = nil
                    }
                    Button("替换当前稿件", role: .destructive) {
                        if let text = importedScript {
                            UserDefaults.standard.set(model.script, forKey: "scriptBeforeImport")
                            model.script = text; model.seek(0)
                        }
                        importedScript = nil
                    }
                    Button("取消", role: .cancel) { importedScript = nil }
                } message: { Text("替换前会保留一份原稿，可从稿件操作中恢复。") }
                .alert("导入未完成", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("知道了", role: .cancel) { importError = nil }
                } message: { Text(importError ?? "") }
        }
    }
    private var sentencePicker: some View {
        NavigationStack {
            List {
                ForEach(Array(model.lines.enumerated()).filter { sentenceSearch.isEmpty || $0.element.localizedCaseInsensitiveContains(sentenceSearch) }, id: \.offset) { index, line in
                    Button {
                        model.automatic = false
                        model.seek(index)
                        locate = false
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                            Text(line).foregroundStyle(PromptStyle.ink)
                            Spacer(minLength: 0)
                            if index == model.current { Image(systemName: "checkmark.circle.fill") }
                        }.padding(.vertical, 8)
                    }.accessibilityLabel("从第 \(index + 1) 句开始：\(line)")
                }
            }
            .overlay { if model.lines.isEmpty { ContentUnavailableView("还没有稿件", systemImage: "doc.text", description: Text("先写一段稿子，再选择起读位置。")) } }
            .overlay {
                if !sentenceSearch.isEmpty && !model.lines.contains(where: { $0.localizedCaseInsensitiveContains(sentenceSearch) }) {
                    ContentUnavailableView.search(text: sentenceSearch)
                }
            }
            .searchable(text: $sentenceSearch, prompt: "搜索稿件中的一句话")
            .navigationTitle("从这里开始").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { locate = false } }
        }
    }
    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("窗口外观") {
                    Picker("窗口形状", selection: $model.shape) { ForEach(PromptShape.allCases) { Text($0.rawValue).tag($0) } }
                    HStack { Text("文字大小"); Spacer(); Text("\(Int(model.fontSize))").foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $model.fontSize, in: 16...40, step: 1).accessibilityLabel("文字大小")
                    Toggle("暖黄色文字", isOn: $model.yellowText)
                }
                Section("语音跟随") {
                    Toggle("理解改写和扩展", isOn: $model.semanticEnabled)
                    Text(model.aiStatus).font(.caption).foregroundStyle(.secondary)
                    Text("匹配不上时先停留，讲回稿件后再继续跟随。语义理解需要设备端 AI 可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于拾言") {
                    Label("稿件自动保存在本机", systemImage: "doc.badge.arrow.up")
                    Label("无试用倒计时", systemImage: "infinity")
                    NavigationLink("开源许可 · FaceBeauty") {
                        ScrollView { Text(Bundle.main.url(forResource: "FaceBeauty-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "FaceBeauty · MIT License · Copyright (c) 2026 David Sherlock") .font(.caption).padding() }.navigationTitle("开源许可")
                    }
                    NavigationLink("开源许可 · MetalPetal") {
                        ScrollView { Text(Bundle.main.url(forResource: "MetalPetal-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MetalPetal · MIT License · Copyright (c) 2017 Yu Ao") .font(.caption).padding() }.navigationTitle("开源许可")
                    }
                    Button("运行记录与诊断") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { logs = true } }
                }
            }.navigationTitle("提词设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { settings = false; model.render() } }
        }
    }
    private var logView: some View {
        NavigationStack {
            List {
                Section("显示诊断") { Toggle("不透明对照", isOn: $model.opaqueControl) }
                Section("运行记录") { ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in Text(event).font(.caption) } }
            }.navigationTitle("运行记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { logs = false } }
        }
    }
}
