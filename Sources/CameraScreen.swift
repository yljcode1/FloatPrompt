import SwiftUI

struct CameraScreen: View {
    @ObservedObject var model: PromptModel
    @StateObject private var camera = CameraCapture()
    @Environment(\.dismiss) private var dismiss
    @State private var anchor = CGPoint(x: 0.5, y: 0.34)
    @GestureState private var drag = CGSize.zero
    @State private var opacity = 0.35
    @State private var panelHeight = 220.0
    @State private var showAdjustments = false
    @State private var confirmExit = false
    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(geometry.size.width - 32, 420)
            let x = min(max(panelWidth / 2, anchor.x * geometry.size.width + drag.width), geometry.size.width - panelWidth / 2)
            let y = min(max(panelHeight / 2 + 70, anchor.y * geometry.size.height + drag.height), max(panelHeight / 2 + 70, geometry.size.height - panelHeight / 2 - 160))
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(layer: camera.previewLayer).ignoresSafeArea()
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "line.3.horizontal").font(.caption)
                        Text(model.paused ? "已暂停" : model.followState).font(.caption).lineLimit(1)
                        Spacer()
                        Button { showAdjustments.toggle() } label: { Image(systemName: "textformat.size").frame(width: 44, height: 36) }.accessibilityLabel("调整提词框")
                    }
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                        anchor = CGPoint(
                            x: min(max(panelWidth / 2, anchor.x * geometry.size.width + value.translation.width), geometry.size.width - panelWidth / 2) / geometry.size.width,
                            y: min(max(panelHeight / 2 + 70, anchor.y * geometry.size.height + value.translation.height), max(panelHeight / 2 + 70, geometry.size.height - panelHeight / 2 - 160)) / geometry.size.height)

                    })
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(model.lines.enumerated()), id: \.offset) { index, text in
                                    Text(text).font(.system(size: model.fontSize, weight: .semibold))
                                        .foregroundStyle(index < model.current ? .white.opacity(0.5) : model.yellowText ? .yellow : .white)
                                        .frame(maxWidth: .infinity, alignment: .leading).id(index)
                                }
                            }.padding(.horizontal, 16).padding(.bottom, 20)
                        }
                        .onAppear { proxy.scrollTo(model.current, anchor: .top) }
                        .onChange(of: model.current) { _, index in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .top) } }
                    }
                }
                .frame(width: panelWidth, height: panelHeight)
                .background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white).position(x: x, y: y)
                VStack {
                    HStack {
                        Button { if camera.recording || camera.saving { confirmExit = true } else { dismiss() } } label: { Image(systemName: "xmark").frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle()) }.accessibilityLabel("退出拍摄")
                        Spacer()
                        Text(camera.recording ? "● 正在录像" : camera.comparing ? "原图对比" : "自然美颜 · 1080p").font(.subheadline.weight(.semibold)).padding(10).background(.black.opacity(0.35), in: Capsule())
                        Spacer()
                        Button { showAdjustments.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle()) }.accessibilityLabel("拍摄设置")
                    }
                    Spacer()
                    Text(camera.faceStatus).font(.caption).padding(8).background(.black.opacity(0.45), in: Capsule())
                    Button { camera.comparing.toggle() } label: {
                        Label(camera.comparing ? "正在看原图 · 点此恢复美颜" : "对比原图", systemImage: "circle.lefthalf.filled")
                            .font(.subheadline.weight(.semibold)).padding(12).background(.black.opacity(0.5), in: Capsule())
                    }
                    Text(camera.message).font(.caption).multilineTextAlignment(.center).padding(10).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 35) {
                        Button { model.paused ? model.resumeReading() : model.pauseReading() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel(model.paused ? "继续提词" : "暂停提词")
                        Button { camera.toggleRecording() } label: {
                            ZStack {
                                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                                RoundedRectangle(cornerRadius: camera.recording ? 7 : 34).fill(.red).frame(width: camera.recording ? 30 : 64, height: camera.recording ? 30 : 64)
                            }
                        }.disabled(!camera.ready || camera.saving).opacity(camera.ready && !camera.saving ? 1 : 0.4).accessibilityLabel(camera.recording ? "停止录像" : "开始录像")
                        if let url = camera.savedURL {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle()) }
                        } else {
                            Button { model.seek(0) } label: { Image(systemName: "backward.end.fill").frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("回到开头")
                        }
                    }.padding(.vertical, 14)
                }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 8)
            }
        }
        .task {
            model.stopAll(); model.cameraInputActive = true
            camera.onAudio = model.cameraAudioConsumer()
            await camera.prepare()
        }
        .onChange(of: camera.ready) { _, ready in
            if ready && model.readingMode == .voice { model.resumeReading() }
            else if ready { model.selectMode(model.readingMode) }
        }
        .onDisappear { model.stopAll(); model.cameraInputActive = false; camera.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.pauseReading()
            if camera.recording { camera.toggleRecording() }
        }
        .sheet(isPresented: $showAdjustments) {
            NavigationStack {
                Form {
                    Section("人脸美型") {
                        Text(camera.faceStatus).font(.caption).foregroundStyle(.secondary)
                        Text("瘦脸 \(Int(camera.faceSlim * 100))%")
                        Slider(value: $camera.faceSlim, in: 0...0.6, step: 0.01)
                        Text("大眼 \(Int(camera.eyeEnlarge * 100))%")
                        Slider(value: $camera.eyeEnlarge, in: 0...0.6, step: 0.01)
                        Text("瘦鼻 \(Int(camera.noseSlim * 100))%")
                        Slider(value: $camera.noseSlim, in: 0...0.5, step: 0.01)
                        Toggle("眼镜模式（减弱眼部变形）", isOn: $camera.glassesMode)
                    }
                    Section("自然美颜") {
                        Text("磨皮 \(Int(camera.beautyAmount * 100))%")
                        Slider(value: $camera.beautyAmount, in: 0...0.8, step: 0.01).accessibilityLabel("磨皮强度")
                        Text("肤色提亮 \(Int(camera.brightening / 0.4 * 100))%")
                        Slider(value: $camera.brightening, in: 0...0.4, step: 0.01).accessibilityLabel("提亮强度")
                        Button("关闭美颜") { camera.beautyAmount = 0; camera.brightening = 0; camera.faceSlim = 0; camera.eyeEnlarge = 0; camera.noseSlim = 0 }
                        Button("自然口播预设") { camera.beautyAmount = 0.4; camera.brightening = 0.06; camera.faceSlim = 0.15; camera.eyeEnlarge = 0.08; camera.noseSlim = 0.05; camera.comparing = false }
                        Toggle("原图对比（仅预览）", isOn: $camera.comparing)
                        Text("对比只切换预览，录像仍按上方美颜强度保存。关闭美颜才会录制原图。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("自由提词框") {
                        Text("拖动提词框顶部可移动；框内可手动滚动。")
                        Text("背景透明度"); Slider(value: $opacity, in: 0...0.8)
                        Text("提词框高度"); Slider(value: $panelHeight, in: 140...360)
                        Text("字号 \(Int(model.fontSize))"); Slider(value: $model.fontSize, in: 16...40, step: 1)
                    }
                    Section("阅读方式") {
                        Button("跟随声音") { model.selectMode(.voice); if camera.ready { model.resumeReading() } }
                        Button("匀速滚动") { model.selectMode(.constant) }
                        Button("手动阅读") { model.selectMode(.manual) }
                    }
                }.navigationTitle("拍摄设置").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { showAdjustments = false } }
            }.presentationDetents([.medium, .large])
        }
        .confirmationDialog("请先停止录像并等待保存完成", isPresented: $confirmExit, titleVisibility: .visible) {
            if camera.recording { Button("停止录像并保存") { camera.toggleRecording() } }
            Button("返回拍摄", role: .cancel) { }
        }
    }
}
