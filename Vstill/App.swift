import SwiftUI

@main
struct VstillApp: App {
    init() { TempStore.purge() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @State private var store = ProjectStore()
    @State private var open: Project?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let open {
                EditorView(url: store.videoURL(open), frames: open.frames,
                           onFramesChange: { store.updateFrames(open.id, $0) },
                           onClose: { withAnimation(.smooth(duration: 0.45)) { self.open = nil } })
                    .id(open.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1.04).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)))
            } else {
                HomeView(store: store) { project in
                    withAnimation(.smooth(duration: 0.5)) { open = project }
                }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }
}

/// 所有临时文件集中在一个目录，启动时整体清空，绝不残留。
enum TempStore {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vstill", isDirectory: true)

    static func purge() { try? FileManager.default.removeItem(at: root) }

    static func newURL(_ ext: String) -> URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
