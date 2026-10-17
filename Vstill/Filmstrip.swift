import AVFoundation
import SwiftUI
import UIKit

/// 胶片式时间轴：中心固定播放头，胶片在下方滑动，自带原生惯性与逐秒触感刻度。
struct FilmstripScrubber: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> FilmstripControl {
        let control = FilmstripControl(asset: model.asset, duration: model.duration, aspect: model.aspect)
        control.onBegin = { model.beginScrub() }
        control.onScrub = { model.scrub(to: $0) }
        control.onEnd = { model.endScrub() }
        return control
    }

    func updateUIView(_ control: FilmstripControl, context: Context) {
        control.setTime(model.currentTime)
        control.setMarkers(model.captures.map(\.time))
    }
}

final class FilmstripControl: UIView, UIScrollViewDelegate {
    static let band: CGFloat = 7
    static let imageHeight: CGFloat = 48
    static let stripHeight = imageHeight + band * 2

    var onBegin: (() -> Void)?
    var onScrub: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    private let asset: AVAsset
    private let duration: Double
    private let aspect: CGFloat
    private let scrollView = UIScrollView()
    private let strip = UIView()
    private let markerLayer = CALayer()
    private var thumbViews: [UIImageView] = []
    private var thumbTask: Task<Void, Never>?
    private var builtWidth: CGFloat = 0
    private var stripWidth: CGFloat = 1
    private var markers: [Double] = []
    private var lastTime: Double = 0
    private var lastSecond = -1
    private let ticker = UISelectionFeedbackGenerator()

    init(asset: AVAsset, duration: Double, aspect: CGFloat) {
        self.asset = asset
        self.duration = duration
        self.aspect = aspect
        super.init(frame: .zero)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.delegate = self
        scrollView.clipsToBounds = false
        addSubview(scrollView)

        strip.backgroundColor = .black
        strip.layer.cornerRadius = 9
        strip.layer.cornerCurve = .continuous
        strip.clipsToBounds = true
        strip.layer.borderWidth = 1
        strip.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        scrollView.addSubview(strip)
        scrollView.layer.addSublayer(markerLayer)

        isAccessibilityElement = true
        accessibilityLabel = "时间轴"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { thumbTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let inset = bounds.width / 2
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if bounds.width > 0, abs(bounds.width - builtWidth) > 1 { rebuild() }
    }

    // MARK: 外部驱动

    func setTime(_ t: Double) {
        lastTime = t
        guard !isUserScrolling, builtWidth > 0 else { return }
        let x = CGFloat(t / duration) * stripWidth - bounds.width / 2
        if abs(scrollView.contentOffset.x - x) > 0.2 { scrollView.contentOffset.x = x }
    }

    func setMarkers(_ times: [Double]) {
        guard times != markers else { return }
        markers = times
        layoutMarkers()
    }

    // MARK: 构建

    private func rebuild() {
        builtWidth = bounds.width
        stripWidth = min(max(bounds.width * 0.92, CGFloat(duration) * 46), 6000)
        let naturalThumb = max(20, Self.imageHeight * aspect)
        let count = min(90, max(1, Int(ceil(stripWidth / naturalThumb))))
        let thumbWidth = stripWidth / CGFloat(count)

        strip.frame = CGRect(x: 0, y: 0, width: stripWidth, height: Self.stripHeight)
        scrollView.contentSize = CGSize(width: stripWidth, height: bounds.height)
        drawSprockets()

        thumbViews.forEach { $0.removeFromSuperview() }
        thumbViews = (0..<count).map { i in
            let view = UIImageView(frame: CGRect(x: CGFloat(i) * thumbWidth, y: Self.band, width: thumbWidth + 0.5, height: Self.imageHeight))
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = UIColor(white: 0.1 + 0.03 * CGFloat(i % 2), alpha: 1)
            strip.addSubview(view)
            return view
        }
        loadThumbnails(count: count, thumbWidth: thumbWidth)
        layoutMarkers()
        setTime(lastTime)
    }

    /// 胶片上下两条齿孔带
    private func drawSprockets() {
        strip.layer.sublayers?.filter { $0.name == "sprocket" }.forEach { $0.removeFromSuperlayer() }
        for y in [CGFloat(2), Self.stripHeight - Self.band + 2] {
            let hole = CALayer()
            hole.frame = CGRect(x: 4, y: y, width: 5, height: 3)
            hole.cornerRadius = 1
            hole.backgroundColor = UIColor(white: 1, alpha: 0.22).cgColor
            let row = CAReplicatorLayer()
            row.name = "sprocket"
            row.instanceCount = Int(stripWidth / 10) + 1
            row.instanceTransform = CATransform3DMakeTranslation(10, 0, 0)
            row.addSublayer(hole)
            strip.layer.addSublayer(row)
        }
    }

    private func loadThumbnails(count: Int, thumbWidth: CGFloat) {
        thumbTask?.cancel()
        let segment = duration / Double(count)
        let scale = window?.screen.scale ?? 3
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: max(thumbWidth, Self.imageHeight * aspect) * scale,
                                       height: max(Self.imageHeight, thumbWidth / aspect) * scale)
        let tolerance = CMTime(seconds: segment / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * segment, preferredTimescale: 600) }

        thumbTask = Task { [weak self] in
            for await result in generator.images(for: times) {
                guard let self, !Task.isCancelled else { return }
                guard let image = try? result.image else { continue }
                let i = min(count - 1, Int(result.requestedTime.seconds / segment))
                let view = self.thumbViews[i]
                UIView.transition(with: view, duration: 0.3, options: .transitionCrossDissolve) {
                    view.image = UIImage(cgImage: image)
                }
            }
        }
    }

    private func layoutMarkers() {
        markerLayer.sublayers = nil
        guard builtWidth > 0 else { return }
        let accent = UIColor(Theme.accent)
        for t in markers {
            let x = CGFloat(t / duration) * stripWidth
            let line = CALayer()
            line.frame = CGRect(x: x - 1, y: Self.band, width: 2, height: Self.imageHeight)
            line.backgroundColor = accent.withAlphaComponent(0.9).cgColor
            line.shadowColor = accent.cgColor
            line.shadowOpacity = 0.8
            line.shadowRadius = 3
            line.shadowOffset = .zero
            let dot = CALayer()
            dot.frame = CGRect(x: x - 2.5, y: Self.stripHeight + 5, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = accent.cgColor
            markerLayer.addSublayer(line)
            markerLayer.addSublayer(dot)
        }
    }

    // MARK: 手势

    private var isUserScrolling: Bool { scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        ticker.prepare()
        onBegin?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isUserScrolling, stripWidth > 0 else { return }
        let t = min(max(0, Double((scrollView.contentOffset.x + bounds.width / 2) / stripWidth) * duration), duration)
        let second = Int(t)
        if second != lastSecond {
            lastSecond = second
            ticker.selectionChanged()
        }
        lastTime = t
        onScrub?(t)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onEnd?() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onEnd?() }

    override func accessibilityIncrement() { onScrub?(min(duration, lastTime + 1)) }
    override func accessibilityDecrement() { onScrub?(max(0, lastTime - 1)) }
}

/// 中心播放头
struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(.white).frame(width: 12, height: 7)
            Capsule().fill(.white).frame(width: 3, height: FilmstripControl.stripHeight + 4)
        }
        .shadow(color: .black.opacity(0.6), radius: 4)
        .offset(y: -9)
        .allowsHitTesting(false)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}
