import AVFoundation
import SwiftUI
import UIKit

/// 可缩放的视频预览：双指缩放 1×–8×、放大后拖动查看细节、双击在点按处放大 / 还原，单击播放暂停。
/// 用系统 UIScrollView 实现，手感（惯性、回弹）与「照片」App 一致；缩放只影响查看，不影响导出画面。
struct ZoomablePlayer: UIViewRepresentable {
    let player: AVPlayer
    @Binding var zoom: CGFloat
    let resetToken: Int
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView(player: player)
        view.scrollView.delegate = context.coordinator
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            view.scrollView.setZoomScale(1, animated: true)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomablePlayer
        var resetToken: Int

        init(_ parent: ZoomablePlayer) {
            self.parent = parent
            resetToken = parent.resetToken
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView.superview as? ZoomView)?.playerView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            if abs(parent.zoom - scale) > 0.01 { parent.zoom = scale }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.zoom = scale
        }

        @objc func singleTap() { parent.onTap() }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomView else { return }
            let scrollView = view.scrollView
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: view.playerView)
                let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class ZoomView: UIView {
    let scrollView = UIScrollView()
    let playerView = PlayerView()

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.addSubview(playerView)
        addSubview(scrollView)
        isAccessibilityElement = true
        accessibilityLabel = "视频预览，轻点播放或暂停，双指或双击放大"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if scrollView.zoomScale <= 1.0001 {
            playerView.frame = bounds
            scrollView.contentSize = bounds.size
        }
    }
}
