import PhotosUI
import SwiftUI

struct ExportSheet: View {
    let model: EditorModel
    /// 导出完成后点「完成」：关闭导出页并回到 App 主页
    let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage("export.kind") private var kindRaw = ExportKind.live.rawValue
    @AppStorage("export.liveLength") private var liveLength = 2.0
    @AppStorage("export.liveAudio") private var liveAudio = true
    @AppStorage("export.format") private var formatRaw = StillFormat.heic.rawValue

    @State private var page: UUID?
    @State private var livePreview: LivePreview?
    @State private var stills: [UUID: UIImage] = [:]
    @State private var stage: Stage = .configure

    enum Stage: Equatable { case configure, working(Int, Int), done(Int), failed(String, permission: Bool) }

    struct LivePreview {
        let key: String
        let files: LiveFiles
        let photo: PHLivePhoto
    }

    private var kind: ExportKind { ExportKind(rawValue: kindRaw) ?? .live }
    private var format: StillFormat { StillFormat(rawValue: formatRaw) ?? .heic }
    private var current: Capture? { model.captures.first { $0.id == page } ?? model.captures.first }
    private var kindName: String { kind == .live ? "实况照片" : "照片" }
    private var isWorking: Bool { if case .working = stage { true } else { false } }

    private func liveKey(_ c: Capture) -> String { "\(c.id)-\(liveLength)-\(liveAudio)" }
    private var previewKey: String { "\(kindRaw)-\(current.map(liveKey) ?? "")" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出").font(.system(size: 28, weight: .heavy, design: .rounded))
                    Text("已收录 \(model.captures.count) 帧").font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if !isWorking {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                            .glass(in: Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel("关闭")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Group {
                switch stage {
                case .configure: configure
                case let .working(done, total): WorkingView(done: done, total: total, kind: kind)
                case let .done(count): doneView(count)
                case let .failed(message, permission): failedView(message, permission: permission)
                }
            }
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.4), value: stage)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { page = model.captures.first?.id }
        .onDisappear { livePreview?.files.discard() }
    }

    // MARK: 配置

    private var configure: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                ForEach(model.captures) { capture in
                    PreviewPage(capture: capture, aspect: model.aspect, kind: kind,
                                live: livePreview?.key == liveKey(capture) ? livePreview?.photo : nil,
                                still: stills[capture.id], size: model.pixelSize, format: format, hdr: model.isHDR)
                        .padding(.horizontal, 20)
                        .tag(Optional(capture.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)
            .task(id: previewKey) { await preparePreview() }

            if model.captures.count > 1, let current, let i = model.captures.firstIndex(of: current) {
                Text("\(i + 1) / \(model.captures.count)  ·  左右滑动切换")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiary)
            }

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    KindCard(title: "实况照片", icon: "livephoto", selected: kind == .live) {
                        kindRaw = ExportKind.live.rawValue
                    }
                    KindCard(title: "静态照片", icon: "photo", selected: kind == .still) {
                        kindRaw = ExportKind.still.rawValue
                    }
                }

                VStack(spacing: 12) {
                    if kind == .live {
                        OptionRow(title: "实况时长") {
                            ChipPicker(options: [1.5, 2.0, 3.0], selection: $liveLength) { String(format: "%g 秒", $0) }
                        }
                        OptionRow(title: "保留声音") {
                            Toggle("保留声音", isOn: $liveAudio).labelsHidden().tint(Theme.accent)
                                .disabled(model.exporter?.hasAudio != true)
                        }
                    } else {
                        OptionRow(title: "格式") {
                            ChipPicker(options: StillFormat.allCases, selection: Binding(get: { format }, set: { formatRaw = $0.rawValue })) { $0.rawValue }
                        }
                    }
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .animation(.snappy, value: kindRaw)

                Button { Task { await run() } } label: {
                    PrimaryButtonLabel(title: "保存 \(model.captures.count) 张\(kindName)到相册", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func preparePreview() async {
        guard let capture = current, let exporter = model.exporter else { return }
        if kind == .live {
            let key = liveKey(capture)
            guard livePreview?.key != key else { return }
            try? await Task.sleep(for: .milliseconds(180))   // 快速滑动时不浪费算力
            guard !Task.isCancelled else { return }
            guard let files = try? await exporter.makeLive(at: capture.time, length: liveLength, audio: liveAudio) else { return }
            guard !Task.isCancelled, let photo = await FrameExporter.livePhoto(from: files) else { files.discard(); return }
            livePreview?.files.discard()
            withAnimation(.smooth) { livePreview = LivePreview(key: key, files: files, photo: photo) }
        } else if stills[capture.id] == nil {
            if let image = try? await exporter.still(at: capture.time, maxDimension: 1600) {
                withAnimation(.smooth) { stills[capture.id] = UIImage(cgImage: image) }
            }
        }
    }

    // MARK: 导出

    private func run() async {
        guard let exporter = model.exporter else { return }
        guard await FrameExporter.requestAccess() else {
            stage = .failed(ExportError.denied.localizedDescription, permission: true)
            return
        }
        let items = model.captures
        let kind = kind, format = format, length = liveLength, audio = liveAudio && exporter.hasAudio
        stage = .working(0, items.count)
        do {
            for (n, capture) in items.enumerated() {
                if kind == .live {
                    let files: LiveFiles
                    if let preview = livePreview, preview.key == liveKey(capture) {
                        files = preview.files
                        livePreview = nil
                    } else {
                        files = try await exporter.makeLive(at: capture.time, length: length, audio: audio)
                    }
                    defer { files.discard() }   // 相册已移走文件；失败时也确保清理
                    try await FrameExporter.saveLive(files)
                } else {
                    let image = try await exporter.still(at: capture.time)
                    guard let (data, actual) = FrameExporter.encode(image, as: format) else { throw ExportError.encodeFailed }
                    try await FrameExporter.saveStill(data, format: actual)
                }
                stage = .working(n + 1, items.count)
            }
            try? await Task.sleep(for: .milliseconds(250))
            stage = .done(items.count)
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, permission: false)
        }
    }

    // MARK: 结果

    private func doneView(_ count: Int) -> some View {
        VStack(spacing: 14) {
            Spacer()
            SuccessBadge()
            Text("已存入相册").font(.system(size: 26, weight: .heavy, design: .rounded)).padding(.top, 8)
            Spacer()
            Button { openURL(URL(string: "photos-redirect://")!) } label: {
                PrimaryButtonLabel(title: "打开相册", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(PressableStyle())
            Button(action: onFinish) {
                Text("完成")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Capsule())   // 整个胶囊都可点，而不只是文字
                    .glass(in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .sensoryFeedback(.success, trigger: count)
    }

    private func failedView(_ message: String, permission: Bool) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: permission ? "lock.shield" : "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: message)
            Text(permission ? "需要相册权限" : "导出没有完成").font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if permission {
                Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: {
                    PrimaryButtonLabel(title: "前往设置", systemImage: "gear")
                }
                .buttonStyle(PressableStyle())
            }
            Button { stage = .configure } label: {
                Text("返回")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Capsule())   // 整个胶囊都可点，而不只是文字
                    .glass(in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

// MARK: - 组件

private struct PreviewPage: View {
    let capture: Capture
    let aspect: CGFloat
    let kind: ExportKind
    let live: PHLivePhoto?
    let still: UIImage?
    let size: CGSize
    let format: StillFormat
    let hdr: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            Color.white.opacity(0.05)
            if let image = still ?? capture.thumbnail {
                Image(uiImage: image).resizable().scaledToFit().allowedDynamicRange(.high)
            }
            if kind == .live, let live {
                LivePhotoPlayer(livePhoto: live).transition(.opacity)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .overlay(alignment: .topLeading) { badge.padding(12) }
        .overlay(alignment: .bottom) {
            if kind == .live, live != nil {
                Text("按住画面播放实况")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: live != nil)
    }

    @ViewBuilder private var badge: some View {
        if kind == .live {
            HStack(spacing: 6) {
                if live == nil {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("正在生成实况…")
                } else {
                    Image(systemName: "livephoto")
                    Text(hdr ? "实况 · HDR" : "实况")
                }
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 10).frame(height: 28)
            .background(.black.opacity(0.45), in: Capsule())
        } else {
            Text(verbatim: "\(Int(size.width))×\(Int(size.height)) · \(format.rawValue)\(hdr ? " · HDR" : "")")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10).frame(height: 28)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }
}

private struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        guard view.livePhoto !== livePhoto else { return }
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
    }
}

private struct KindCard: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.7))
                    .symbolEffect(.bounce, value: selected)
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(selected ? Theme.accent.opacity(0.12) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                    .padding(12)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .foregroundStyle(.white)
        .animation(.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            content
        }
    }
}

private struct ChipPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { selection = option } } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(on ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            if on { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "chip", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct WorkingView: View {
    let done: Int
    let total: Int
    let kind: ExportKind

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(done) / CGFloat(max(1, total)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 10)
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.12)
                        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
                }
                VStack(spacing: 2) {
                    Text("\(done)/\(total)")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(kind == .live ? "实况" : "照片").font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 170, height: 170)
            .animation(.smooth, value: done)
            VStack(spacing: 6) {
                Text(kind == .live ? "正在合成实况照片…" : "正在写入原画质照片…").font(.headline)
                Text("请保持在此页面").font(.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SuccessBadge: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.15)).frame(width: 150, height: 150)
                .scaleEffect(shown ? 1 : 0.4)
            Circle().fill(Theme.accent).frame(width: 104, height: 104)
                .shadow(color: Theme.accent.opacity(0.6), radius: 24)
                .scaleEffect(shown ? 1 : 0.2)
            Image(systemName: "checkmark")
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(.black)
                .scaleEffect(shown ? 1 : 0.1)
                .rotationEffect(.degrees(shown ? 0 : -40))
        }
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.5)) { shown = true } }
    }
}
