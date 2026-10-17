import AVFoundation
import Observation
import SwiftUI

struct Capture: Identifiable, Equatable {
    let id = UUID()
    let frame: Int
    let time: Double
    var thumbnail: UIImage?
}

@MainActor @Observable
final class EditorModel {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let asset: AVURLAsset
    let player = AVPlayer()

    private(set) var phase: Phase = .loading
    private(set) var duration: Double = 0
    private(set) var fps: Double = 30
    private(set) var pixelSize = CGSize(width: 16, height: 9)
    private(set) var exporter: FrameExporter?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var captures: [Capture] = []
    private(set) var lastAddedID: UUID?
    /// 动画 / 触感触发器
    private(set) var flashTick = 0
    private(set) var rejectTick = 0
    private(set) var stepTick = 0

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeek: CMTime?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var thumbGenerator: AVAssetImageGenerator

    init(url: URL) {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        thumbGenerator = AVAssetImageGenerator(asset: asset)
        thumbGenerator.appliesPreferredTrackTransform = true
        thumbGenerator.maximumSize = CGSize(width: 240, height: 240)
        thumbGenerator.requestedTimeToleranceBefore = .zero
        thumbGenerator.requestedTimeToleranceAfter = .zero
    }

    // MARK: 派生数据

    var aspect: CGFloat { pixelSize.width / max(1, pixelSize.height) }
    var frameCount: Int { max(1, Int((duration * fps).rounded(.down))) }
    var frameIndex: Int { index(for: currentTime) }
    var isCurrentCaptured: Bool { captures.contains { $0.frame == frameIndex } }
    var isHDR: Bool { exporter?.isHDR ?? false }
    var displayFPS: String { abs(fps - fps.rounded()) < 0.05 ? "\(Int(fps.rounded()))" : String(format: "%.2f", fps) }

    func index(for t: Double) -> Int { min(frameCount - 1, max(0, Int((t * fps + 1e-6).rounded(.down)))) }
    /// 取帧时刻落在帧区间正中，避免浮点误差取到相邻帧
    func frameTime(_ i: Int) -> Double { min(duration - 0.0005, (Double(i) + 0.5) / fps) }

    // MARK: 加载

    func load() async {
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
            let (rate, natural, transform, traits) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform, .mediaCharacteristics)
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty

            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

            // HDR 源（iPhone 默认拍摄的 HLG / 杜比视界）额外准备一条 HDR 管线，导出时保留高光与广色域
            var hdrComposition: AVMutableVideoComposition?
            if traits.contains(.containsHDRVideo) {
                let hdr = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
                hdr.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
                hdr.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
                hdr.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
                hdrComposition = hdr
            }

            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            pixelSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            self.duration = max(duration, 0.04)
            fps = rate > 1 ? Double(rate) : 30
            exporter = FrameExporter(asset: asset, composition: composition, hdrComposition: hdrComposition,
                                     duration: self.duration, hasAudio: hasAudio)

            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.actionAtItemEnd = .pause
            observePlayer()
            currentTime = frameTime(0)
            seek(to: currentTime)
            withAnimation(.smooth) { phase = .ready }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "无法读取这个视频，可能格式不受支持或文件已损坏。")
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = min(self.duration, max(0, time.seconds))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.frameTime(self.frameCount - 1)
            }
        }
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: 播放 / 定位

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard phase == .ready else { return }
        if frameIndex >= frameCount - 1 {
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        currentTime = frameTime(index(for: player.currentTime().seconds))
        seek(to: currentTime)
    }

    func beginScrub() { pause() }

    func scrub(to t: Double) {
        currentTime = min(max(0, t), duration)
        seek(to: frameTime(frameIndex))
    }

    func endScrub() { currentTime = frameTime(frameIndex) }

    func step(_ delta: Int) {
        pause()
        let target = min(frameCount - 1, max(0, frameIndex + delta))
        guard target != frameIndex else { return }
        currentTime = frameTime(target)
        seek(to: currentTime)
        stepTick += 1
    }

    func jump(to capture: Capture) {
        pause()
        currentTime = capture.time
        seek(to: capture.time)
        stepTick += 1
    }

    /// 追帧式 seek：同一时刻只有一个精确 seek 在飞，拖动时永远追最新位置，不堆积。
    private func seek(to t: Double) {
        pendingSeek = FrameExporter.cm(t)
        guard !isSeeking else { return }
        runSeek()
    }

    private func runSeek() {
        guard let target = pendingSeek else { isSeeking = false; return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.runSeek() }
        }
    }

    // MARK: 收录帧

    func captureCurrent() {
        let frame = frameIndex
        guard !captures.contains(where: { $0.frame == frame }) else { rejectTick += 1; return }
        add([frame])
    }

    func autoCapture(_ n: Int) {
        let frames = (0..<n).map { k in min(frameCount - 1, Int((Double(k) + 0.5) * Double(frameCount) / Double(n))) }
        let fresh = Array(Set(frames)).filter { f in !captures.contains { $0.frame == f } }
        guard !fresh.isEmpty else { rejectTick += 1; return }
        add(fresh.sorted())
    }

    func remove(_ capture: Capture) { captures.removeAll { $0.id == capture.id } }

    /// 打开项目时恢复已收录的帧（不闪光、不震动）。
    func restore(_ frames: [Int]) {
        guard phase == .ready, !frames.isEmpty else { return }
        let valid = Array(Set(frames.filter { $0 >= 0 && $0 < frameCount })).sorted()
        captures = valid.map { Capture(frame: $0, time: frameTime($0)) }
        loadThumbnails(for: captures)
    }

    func removeAll() { captures.removeAll() }

    private func add(_ frames: [Int]) {
        let added = frames.map { Capture(frame: $0, time: frameTime($0)) }
        captures.append(contentsOf: added)
        captures.sort { $0.frame < $1.frame }
        lastAddedID = added.last?.id
        flashTick += 1
        loadThumbnails(for: added)
    }

    private func loadThumbnails(for added: [Capture]) {
        Task {
            for capture in added {
                guard let image = try? await thumbGenerator.image(at: FrameExporter.cm(capture.time)).image else { continue }
                if let i = captures.firstIndex(where: { $0.id == capture.id }) {
                    withAnimation(.easeOut(duration: 0.25)) { captures[i].thumbnail = UIImage(cgImage: image) }
                }
            }
        }
    }
}
