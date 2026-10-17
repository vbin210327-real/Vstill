import AVFoundation
import Observation
import UIKit

/// 一个项目 = 一份视频副本 + 已收录的帧。
struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    let created: Date
    var updated: Date
    let fileName: String
    let duration: Double
    let bytes: Int64
    var frames: [Int]
}

/// 项目存放在 Application Support/Projects/<id>/，索引是同目录下的 index.json。
@MainActor @Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    @ObservationIgnored private var thumbs: [UUID: UIImage] = [:]

    private static let root = URL.applicationSupportDirectory.appending(path: "Projects", directoryHint: .isDirectory)
    private static let index = root.appending(path: "index.json")

    init() {
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved.filter { FileManager.default.fileExists(atPath: videoURL($0).path) }
        }
    }

    func videoURL(_ project: Project) -> URL { Self.folder(project.id).appending(path: project.fileName) }

    func thumbnail(_ project: Project) -> UIImage? {
        if let cached = thumbs[project.id] { return cached }
        let image = UIImage(contentsOfFile: Self.folder(project.id).appending(path: "thumb.jpg").path)
        thumbs[project.id] = image
        return image
    }

    /// 相册导入：把系统给的临时文件直接移进项目目录。文件导入：复制一份进来。
    func create(from source: URL, move: Bool) async throws -> Project {
        let id = UUID()
        let folder = Self.folder(id)
        let fileName = "video." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
        let destination = folder.appending(path: fileName)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if move {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }.value

            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            if let image = try? await generator.image(at: CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)).image,
               let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: folder.appending(path: "thumb.jpg"))
            }
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0

            let project = Project(id: id, created: .now, updated: .now, fileName: fileName,
                                  duration: duration, bytes: bytes, frames: [])
            projects.insert(project, at: 0)
            save()
            return project
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func updateFrames(_ id: UUID, _ frames: [Int]) {
        guard let i = projects.firstIndex(where: { $0.id == id }), projects[i].frames != frames else { return }
        projects[i].frames = frames
        projects[i].updated = .now
        save()
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        thumbs[project.id] = nil
        try? FileManager.default.removeItem(at: Self.folder(project.id))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(projects).write(to: Self.index, options: .atomic)
    }

    private static func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
}
