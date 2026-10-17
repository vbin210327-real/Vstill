import SwiftUI

struct EditorView: View {
    @State private var model: EditorModel
    let frames: [Int]
    let onFramesChange: ([Int]) -> Void
    let onClose: () -> Void
    @State private var showExport = false

    init(url: URL, frames: [Int], onFramesChange: @escaping ([Int]) -> Void, onClose: @escaping () -> Void) {
        _model = State(initialValue: EditorModel(url: url))
        self.frames = frames
        self.onFramesChange = onFramesChange
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch model.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("正在解析视频").font(.subheadline).foregroundStyle(Theme.secondary)
                }
            case .failed(let message):
                FailureState(message: message, onClose: onClose)
            case .ready:
                content.transition(.opacity)
            }
        }
        .task {
            await model.load()
            model.restore(frames)
        }
        .onChange(of: model.captures.map(\.frame)) { _, frames in onFramesChange(frames) }
        .onDisappear { model.tearDown() }
        .fullScreenCover(isPresented: $showExport) {
            ExportSheet(model: model) {
                showExport = false
                // 等导出页收起后再离开编辑页，回到主页
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onClose() }
            }
        }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: model.flashTick)
        .sensoryFeedback(.warning, trigger: model.rejectTick)
        .sensoryFeedback(.selection, trigger: model.stepTick)
    }

    private var content: some View {
        VStack(spacing: 0) {
            TopBar(model: model) {
                model.pause()
                onClose()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            PreviewStage(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity)

            TimecodeBar(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            FilmstripScrubber(model: model)
                .frame(height: FilmstripControl.stripHeight + 12)
                .overlay(alignment: .top) { Playhead() }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                           .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                    .padding(.vertical, -20)
                )
                .padding(.top, 6)

            CaptureTray(model: model)
                .padding(.top, 12)

            ControlBar(model: model) {
                model.pause()
                showExport = true
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - 顶栏

private struct TopBar: View {
    let model: EditorModel
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glass(in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("关闭")

            Spacer()

            Text(verbatim: "\(Int(model.pixelSize.width))×\(Int(model.pixelSize.height))  ·  \(model.displayFPS) fps\(model.isHDR ? "  ·  HDR" : "")  ·  \(Timecode.short(model.duration))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .glass(in: Capsule(), interactive: false)

            Spacer()

            Menu {
                Section("均匀抽帧") {
                    ForEach([6, 12, 24], id: \.self) { n in
                        Button("自动收录 \(n) 帧", systemImage: "square.grid.3x2") {
                            withAnimation(.snappy) { model.autoCapture(n) }
                        }
                    }
                }
                if !model.captures.isEmpty {
                    Button("清空胶片夹", systemImage: "trash", role: .destructive) {
                        withAnimation(.snappy) { model.removeAll() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glass(in: Circle())
            }
            .accessibilityLabel("更多")
        }
    }
}

// MARK: - 预览

private struct PreviewStage: View {
    let model: EditorModel
    @State private var zoom: CGFloat = 1
    @State private var resetToken = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZoomablePlayer(player: model.player, zoom: $zoom, resetToken: resetToken) { model.togglePlay() }
            .aspectRatio(model.aspect, contentMode: .fit)
            .background(Color.black)
            .keyframeAnimator(initialValue: 0.0, trigger: model.flashTick) { content, flash in
                content
                    .overlay(Color.white.opacity(flash).allowsHitTesting(false))
                    .scaleEffect(1 - flash * 0.03)
            } keyframes: { _ in
                LinearKeyframe(0.75, duration: 0.04)
                CubicKeyframe(0, duration: 0.38)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if model.isCurrentCaptured {
                    CapturedChip(rejectTick: model.rejectTick)
                        .padding(12)
                        .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if zoom > 1.05 {
                    Button { resetToken += 1 } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                            Text(String(format: "%.1f×", zoom)).monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.black.opacity(0.5), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .padding(12)
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                    .accessibilityLabel("已放大 \(String(format: "%.1f", zoom)) 倍，轻点还原")
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.4), value: model.isCurrentCaptured)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: zoom > 1.05)
            .sensoryFeedback(.impact(weight: .light), trigger: resetToken)
            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CapturedChip: View {
    let rejectTick: Int

    var body: some View {
        Label("已收录", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.accent, in: Capsule())
            .keyframeAnimator(initialValue: 0.0, trigger: rejectTick) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                LinearKeyframe(-7, duration: 0.05)
                LinearKeyframe(7, duration: 0.08)
                LinearKeyframe(-4, duration: 0.08)
                LinearKeyframe(0, duration: 0.07)
            }
    }
}

// MARK: - 时间码

private struct TimecodeBar: View {
    let model: EditorModel

    var body: some View {
        let parts = Timecode.parts(model.currentTime, fps: model.fps)
        HStack {
            RepeatButton(systemImage: "chevron.left", label: "上一帧") { model.step(-1) }
            Spacer()
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    Text(parts.clock)
                    Text(":").foregroundStyle(Theme.tertiary)
                    Text(parts.frame).foregroundStyle(Theme.accent)
                }
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                Text("第 \(model.frameIndex + 1) 帧 / 共 \(model.frameCount) 帧")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            RepeatButton(systemImage: "chevron.right", label: "下一帧") { model.step(1) }
        }
    }
}

// MARK: - 胶片夹

private struct CaptureTray: View {
    let model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.captures) { capture in
                        TrayThumb(capture: capture, fps: model.fps, isCurrent: capture.frame == model.frameIndex)
                            .id(capture.id)
                            .onTapGesture { model.jump(to: capture) }
                            .contextMenu {
                                Button("定位到这一帧", systemImage: "scope") { model.jump(to: capture) }
                                Button("移出胶片夹", systemImage: "minus.circle", role: .destructive) {
                                    withAnimation(.snappy) { model.remove(capture) }
                                }
                            }
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 0, maxHeight: .infinity)
            }
            .onChange(of: model.lastAddedID) { _, id in
                guard let id else { return }
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 64)
        .overlay {
            if model.captures.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                    Text("按下快门收录当前帧，可多帧批量导出")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.captures.isEmpty)
    }
}

private struct TrayThumb: View {
    let capture: Capture
    let fps: Double
    let isCurrent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Color.white.opacity(0.08)
            .frame(width: 48, height: 64)
            .overlay {
                if let image = capture.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottom) {
                Text(Timecode.precise(capture.time))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
        .clipShape(shape)
        .overlay(shape.strokeBorder(isCurrent ? Theme.accent : .white.opacity(0.12), lineWidth: isCurrent ? 2 : 1))
        .animation(.spring(duration: 0.3), value: isCurrent)
        .accessibilityLabel("已收录帧 \(Timecode.precise(capture.time))")
    }
}

// MARK: - 底部控制

private struct ControlBar: View {
    let model: EditorModel
    let onExport: () -> Void

    var body: some View {
        HStack {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .glass(in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放")

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.4, bounce: 0.35)) { model.captureCurrent() }
            } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.92), lineWidth: 4).frame(width: 80, height: 80)
                    Circle().fill(Theme.accent).frame(width: 64, height: 64)
                        .shadow(color: Theme.accent.opacity(0.5), radius: 14)
                }
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .accessibilityLabel("收录当前帧")

            Spacer()

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .offset(y: -1)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .glass(in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if !model.captures.isEmpty {
                            Text("\(model.captures.count)")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 4, y: -4)
                                .contentTransition(.numericText())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(model.captures.isEmpty)
            .opacity(model.captures.isEmpty ? 0.45 : 1)
            .accessibilityLabel("导出 \(model.captures.count) 帧")
        }
    }
}

private struct FailureState: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text("打不开这个视频").font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button(action: onClose) {
                PrimaryButtonLabel(title: "换一个视频", systemImage: "arrow.uturn.left")
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 8)
        }
        .padding(32)
    }
}
