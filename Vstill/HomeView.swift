import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    let store: ProjectStore
    let onOpen: (Project) -> Void

    @State private var showPicker = false
    @State private var importing = false
    @State private var progress: Progress?
    @State private var pendingDelete: Project?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    NewProjectCard { showPicker = true }
                    FeatureRow()
                    projectsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .disabled(importing)

            if importing {
                ImportingCard(progress: progress)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showPicker) {
            VideoSourceSheet(
                onPhoto: { item in
                    showPicker = false
                    importFromPhotos(item)
                },
                onFile: { url in
                    showPicker = false
                    create(from: url, move: false)
                })
        }
        .confirmationDialog("删除这个项目？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { project in
            Button("删除项目", role: .destructive) {
                withAnimation(.snappy) { store.delete(project) }
            }
        } message: { project in
            Text("将释放 \(ByteCountFormatter.string(fromByteCount: project.bytes, countStyle: .file))。相册里的原视频不受影响。")
        }
        .alert("无法导入视频", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 项目

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("项目").font(.system(size: 22, weight: .bold))
                Text("\(store.projects.count)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiary)
                    .contentTransition(.numericText())
            }

            if store.projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.tertiary)
                    Text("还没有项目").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
                .transition(.opacity)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                    ForEach(store.projects) { project in
                        ProjectCard(project: project, thumbnail: store.thumbnail(project))
                            .onTapGesture { onOpen(project) }
                            .contextMenu {
                                Button("删除项目", systemImage: "trash", role: .destructive) { pendingDelete = project }
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.snappy, value: store.projects)
    }

    // MARK: 导入

    private func importFromPhotos(_ item: PhotosPickerItem) {
        let task = item.loadTransferable(type: PickedMovie.self) { result in
            Task { @MainActor in
                let cancelled = progress?.isCancelled ?? false
                progress = nil
                switch result {
                case .success(let movie?):
                    if cancelled {
                        try? FileManager.default.removeItem(at: movie.url)
                        withAnimation(.smooth) { importing = false }
                    } else {
                        create(from: movie.url, move: true)
                    }
                case .success(nil):
                    withAnimation(.smooth) { importing = false }
                    errorText = "没能读取这个视频。"
                case .failure(let error):
                    withAnimation(.smooth) { importing = false }
                    if !cancelled { errorText = error.localizedDescription }
                }
            }
        }
        progress = task
        withAnimation(.smooth) { importing = true }
    }

    private func create(from url: URL, move: Bool) {
        withAnimation(.smooth) { importing = true }
        Task {
            do {
                let project = try await store.create(from: url, move: move)
                withAnimation(.smooth) { importing = false }
                onOpen(project)
            } catch {
                withAnimation(.smooth) { importing = false }
                errorText = "这个文件无法作为视频打开。"
            }
        }
    }
}

/// 相册视频的导入表示：把系统给的临时文件移到自己的临时目录，随后再移入项目。
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = TempStore.newURL(ext)
            do {
                try FileManager.default.moveItem(at: received.file, to: destination)
            } catch {
                try FileManager.default.copyItem(at: received.file, to: destination)
            }
            return PickedMovie(url: destination)
        }
    }
}

// MARK: - 新项目

private struct NewProjectCard: View {
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 30, weight: .bold))
                Text("新项目").font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(Theme.accent)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityLabel("新项目")
    }
}

/// 选择视频来源：顶部「视频 | 文件」切换，替代系统选择器自带的「视频 | 精选集」。
private struct VideoSourceSheet: View {
    enum Source: String, CaseIterable { case photos = "视频", files = "文件" }

    let onPhoto: (PhotosPickerItem) -> Void
    let onFile: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.photos
    @State private var item: PhotosPickerItem?
    @State private var showFiles = false
    @Namespace private var ns

    var body: some View {
        PhotosPicker(selection: $item, matching: .videos, preferredItemEncoding: .current) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities([.collectionNavigation, .stagingArea, .selectionActions])
        .photosPickerAccessoryVisibility(.hidden, edges: .all)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: item) { _, picked in
            if let picked { onPhoto(picked) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { onFile(url) }
        }
        .onChange(of: showFiles) { _, shown in
            // 文件选择器取消后回到「视频」
            if !shown { withAnimation(.spring(duration: 0.3, bounce: 0.25)) { source = .photos } }
        }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(Source.allCases, id: \.self) { option in
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { source = option }
                        if option == .files { showFiles = true }
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(source == option ? 1 : 0.7))
                            .frame(width: 76, height: 36)
                            .background {
                                if source == option {
                                    Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "seg", in: ns)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == option ? .isSelected : [])
                }
            }
            .padding(3)
            .glass(in: Capsule(), interactive: false)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                        .glass(in: Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel("关闭")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - 功能

/// 三栏并排，细竖线分隔，白色线性图标，不加外框。
private struct FeatureRow: View {
    var body: some View {
        HStack(spacing: 0) {
            FeatureItem(icon: "film", title: "逐帧精准", subtitle: "精确到每一帧")
            divider
            FeatureItem(icon: "hd", title: "高清导出", subtitle: "保留原视频画质")
            divider
            FeatureItem(icon: "livephoto", title: "实况照片", subtitle: "一键转换为实况")
        }
        .padding(.vertical, 6)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 64)
    }
}

private struct FeatureItem: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if icon == "hd" {
                    Text(verbatim: "HD")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 32, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white, lineWidth: 1.6))
                } else {
                    Image(systemName: icon).font(.system(size: 24, weight: .light))
                }
            }
            .frame(height: 30)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 项目卡片

private struct ProjectCard: View {
    let project: Project
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.white.opacity(0.06)
                .aspectRatio(4 / 5, contentMode: .fit)
                .overlay {
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(Timecode.short(project.duration))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if !project.frames.isEmpty {
                        Label("\(project.frames.count)", systemImage: "film.stack")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Theme.accent, in: Capsule())
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.updated.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 14, weight: .semibold))
                Text(ByteCountFormatter.string(fromByteCount: project.bytes, countStyle: .file))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ImportingCard: View {
    let progress: Progress?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 18) {
                if let progress {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let fraction = progress.fractionCompleted
                        ZStack {
                            Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                            Circle()
                                .trim(from: 0, to: max(0.03, fraction))
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.smooth, value: fraction)
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(width: 76, height: 76)
                    }
                } else {
                    ProgressView().controlSize(.large).frame(width: 76, height: 76)
                }
                Text("正在创建项目").font(.headline)
                if let progress {
                    Button("取消") { progress.cancel() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), interactive: false)
        }
    }
}
