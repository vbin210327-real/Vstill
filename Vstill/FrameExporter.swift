import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import VideoToolbox

enum ExportKind: String { case live, still }

enum StillFormat: String, CaseIterable, Identifiable {
    case heic = "HEIC", jpeg = "JPEG", png = "PNG"

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

enum ExportError: LocalizedError {
    case noVideoTrack, encodeFailed, denied

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "这个文件里没有可用的视频画面。"
        case .encodeFailed: "编码失败，请换一帧或稍后再试。"
        case .denied: "没有相册写入权限。请在「设置 › 隐私与安全性 › 照片」中允许 Vstill 添加照片。"
        }
    }
}

/// 一组配对的实况照片文件（静态图 + 短视频），由同一个内容标识符绑定。
struct LiveFiles: Sendable {
    let photo: URL
    let video: URL

    func discard() {
        try? FileManager.default.removeItem(at: photo)
        try? FileManager.default.removeItem(at: video)
    }
}

/// 抽帧与导出引擎：分辨率始终与原视频一致；HDR 视频导出 HDR 照片与 HDR 实况，SDR 视频保持 SDR。
final class FrameExporter: @unchecked Sendable {
    let asset: AVAsset
    let composition: AVVideoComposition
    let hdrComposition: AVVideoComposition?
    let duration: Double
    let hasAudio: Bool

    var isHDR: Bool { hdrComposition != nil }

    init(asset: AVAsset, composition: AVVideoComposition, hdrComposition: AVVideoComposition?, duration: Double, hasAudio: Bool) {
        self.asset = asset
        self.composition = composition
        self.hdrComposition = hdrComposition
        self.duration = duration
        self.hasAudio = hasAudio
    }

    // MARK: 静态帧

    /// HDR 视频取出的是 HDR 帧（保留原始传递函数与色域）；SDR 视频取出 BT.709 帧。
    func still(at t: Double, maxDimension: CGFloat? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        if isHDR {
            generator.appliesPreferredTrackTransform = true
            generator.dynamicRangePolicy = .matchSource
        } else {
            generator.videoComposition = composition
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxDimension { generator.maximumSize = CGSize(width: maxDimension, height: maxDimension) }
        return try await generator.image(at: Self.cm(t)).image
    }

    /// 编码为目标格式。HDR 帧写成「SDR 底图 + ISO 增益图」（HEIC/JPEG），任何设备都能正常显示，
    /// HDR 屏幕上还原高光；PNG 写入完整 HDR 数据。HDR 编码失败时退回 SDR，HEIC 不可用时退回 JPEG。
    static func encode(_ image: CGImage, as format: StillFormat, extra: [CFString: Any] = [:]) -> (Data, StillFormat)? {
        if isHDR(image), let data = write(image, as: format, extra: extra, hdr: true) { return (data, format) }
        if let data = write(image, as: format, extra: extra, hdr: false) { return (data, format) }
        return format == .heic ? encode(image, as: .jpeg, extra: extra) : nil
    }

    private static func write(_ image: CGImage, as format: StillFormat, extra: [CFString: Any], hdr: Bool) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props = extra
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        if hdr {
            props[kCGImageDestinationEncodeRequest] = format == .png ? kCGImageDestinationEncodeToISOHDR : kCGImageDestinationEncodeToISOGainmap
        } else if isHDR(image) {
            props[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToSDR
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func isHDR(_ image: CGImage) -> Bool {
        guard let space = image.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(space) || CGColorSpaceUsesExtendedRange(space)
    }

    static func saveStill(_ data: Data, format: StillFormat) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = format.utType.identifier
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }

    // MARK: 实况照片

    func makeLive(at t: Double, length: Double, audio: Bool) async throws -> LiveFiles {
        let identifier = UUID().uuidString
        let len = min(length, duration)
        let start = min(max(0, t - len / 2), max(0, duration - len))
        let range = CMTimeRange(start: Self.cm(start), duration: Self.cm(len))
        let image = try await still(at: t)
        // MakerApple 字典里的 "17" 是实况照片的配对标识；HDR 封面用 HEIC 增益图，与 iPhone 原生实况一致
        let maker: [CFString: Any] = [kCGImagePropertyMakerAppleDictionary: ["17": identifier]]
        guard let (data, format) = Self.encode(image, as: Self.isHDR(image) ? .heic : .jpeg, extra: maker) else {
            throw ExportError.encodeFailed
        }
        let files = LiveFiles(photo: TempStore.newURL(format == .heic ? "heic" : "jpg"), video: TempStore.newURL("mov"))

        do {
            try data.write(to: files.photo)
            try await writeVideo(to: files.video, range: range, stillTime: Self.cm(t), identifier: identifier, audio: audio && hasAudio)
            return files
        } catch {
            files.discard()
            throw error
        }
    }

    static func saveLive(_ files: LiveFiles) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.shouldMoveFile = true   // 直接移动进相册，不额外复制一份
            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: files.photo, options: photoOptions)
            request.addResource(with: .pairedVideo, fileURL: files.video, options: videoOptions)
        }
    }

    static func livePhoto(from files: LiveFiles) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            var resumed = false
            PHLivePhoto.request(withResourceFileURLs: [files.photo, files.video], placeholderImage: nil,
                                targetSize: .zero, contentMode: .aspectFit) { live, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || live == nil else { return }
                resumed = true
                continuation.resume(returning: live)
            }
        }
    }

    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    // MARK: 实况视频写入

    private func writeVideo(to url: URL, range: CMTimeRange, stillTime: CMTime, identifier: String, audio: Bool) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // 实况视频与原视频同分辨率；HDR 源输出 10-bit HEVC HLG，设备不支持时退回 8-bit SDR
        let render = composition.renderSize
        let width = Self.even(render.width), height = Self.even(render.height)
        let hdrSettings: [String: Any]? = hdrComposition.map { _ in [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 5,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
        ] }
        let useHDR = hdrSettings.map { writer.canApply(outputSettings: $0, forMediaType: .video) } ?? false

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                useHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOut.videoComposition = useHDR ? hdrComposition : composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError.encodeFailed }
        reader.add(videoOut)

        writer.metadata = [Self.metadataItem("com.apple.quicktime.content.identifier",
                                             value: identifier as NSString, type: kCMMetadataBaseDataType_UTF8)]

        var settings: [String: Any] = hdrSettings.flatMap { useHDR ? $0 : nil } ?? [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 4],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw ExportError.encodeFailed }
        writer.add(videoIn)

        let stillIn = try Self.stillImageTimeInput()
        let stillAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillIn)
        writer.add(stillIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if audio, let track = try await asset.loadTracks(withMediaType: .audio).first {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layoutData,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layoutData,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output); writer.add(input)
                audioOut = output; audioIn = input
            }
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.encodeFailed }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? ExportError.encodeFailed }
        writer.startSession(atSourceTime: range.start)

        let marker = Self.metadataItem("com.apple.quicktime.still-image-time",
                                       value: NSNumber(value: Int8(-1)), type: kCMMetadataBaseDataType_SInt8)
        stillAdaptor.append(AVTimedMetadataGroup(items: [marker],
                                                 timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 100))))
        stillIn.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            Self.pump(videoOut, into: videoIn, group: group)
            if let audioOut, let audioIn { Self.pump(audioOut, into: audioIn, group: group) }
            group.notify(queue: .global(qos: .userInitiated)) {
                if reader.status == .failed || writer.status == .failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(throwing: writer.error ?? reader.error ?? ExportError.encodeFailed)
                    return
                }
                writer.endSession(atSourceTime: range.end)
                nonisolated(unsafe) let finished = writer
                writer.finishWriting {
                    if finished.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: finished.error ?? ExportError.encodeFailed)
                    }
                }
            }
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, group: DispatchGroup) {
        group.enter()
        var finished = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "vstill.pump.\(input.mediaType.rawValue)")) {
            guard !finished else { return }
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    private static func stillImageTimeInput() throws -> AVAssetWriterInput {
        let spec = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String,
        ] as NSDictionary
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw ExportError.encodeFailed }
        return AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
    }

    private static func metadataItem(_ key: String, value: NSCopying & NSObjectProtocol, type: CFString) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value
        item.dataType = type as String
        return item
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }

    static func cm(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 90_000) }
}
