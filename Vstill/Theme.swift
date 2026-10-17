import SwiftUI

enum Theme {
    static let accent = Color(red: 0.80, green: 1.0, blue: 0.26)
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let surface = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
}

extension View {
    /// iOS 26 用 Liquid Glass，旧系统退回到毛玻璃材质。
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.stroke, lineWidth: 1))
        }
    }
}

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// 主操作按钮：荧光绿胶囊。
struct PrimaryButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.accent, in: Capsule())
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 6)
    }
}

/// 按住连发的按钮（逐帧步进）。
struct RepeatButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .bold))
            .frame(width: 46, height: 46)
            .contentShape(Circle())
            .glass(in: Circle())
            .scaleEffect(pressed ? 0.88 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.5), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        repeater = Task {
                            try? await Task.sleep(for: .milliseconds(380))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(60))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

enum Timecode {
    /// 00:03:12 —— 分:秒:帧
    static func parts(_ t: Double, fps: Double) -> (clock: String, frame: String) {
        let total = max(0, t)
        let sec = Int(total)
        let ff = min(Int((total - Double(sec)) * fps), max(0, Int(fps.rounded()) - 1))
        return (String(format: "%02d:%02d", sec / 60, sec % 60), String(format: "%02d", ff))
    }

    static func short(_ t: Double) -> String {
        let sec = Int(max(0, t))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    static func precise(_ t: Double) -> String {
        let sec = Int(max(0, t))
        let cs = Int((t - Double(sec)) * 100)
        return String(format: "%d:%02d.%02d", sec / 60, sec % 60, cs)
    }
}
