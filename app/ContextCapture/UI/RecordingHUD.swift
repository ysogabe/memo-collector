import AppKit
import Observation
import SwiftUI

/// 前面アプリのフォーカスを奪わないパネル（HUD・トースト共通）。
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, clickThrough: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // フルスクリーンのアプリの上にも出す。
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUD

@Observable
@MainActor
final class HUDModel {
    static let barCount = 28
    /// 新しいものが末尾。0–1。
    var levels: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    func push(_ v: Float) {
        levels.removeFirst()
        levels.append(max(0, min(1, v)))
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// 録音中の HUD（F-06）。画面下中央に出る。クリックは下のアプリへ素通しする。
@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: OverlayPanel?
    private var levelsTask: Task<Void, Never>?
    private static let size = NSSize(width: 300, height: 64)

    func show(levels: AsyncStream<Float>) {
        model.reset()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        levelsTask?.cancel()
        levelsTask = Task { [model] in
            for await v in levels {
                if Task.isCancelled { break }
                model.push(v)
            }
        }
    }

    func hide() {
        levelsTask?.cancel()
        levelsTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size), clickThrough: true)
        let host = NSHostingView(rootView: RecordingHUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        return p
    }

    private func position(_ p: NSPanel) {
        // マウスのある画面（なければメイン）の下中央。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: vf.midX - Self.size.width / 2, y: vf.minY + 72))
    }
}

struct RecordingHUDView: View {
    let model: HUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.micOrange)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.6 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("話してください")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            Waveform(levels: model.levels)
                .frame(height: 26)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(white: 0.1, opacity: 0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .padding(4)
        .environment(\.colorScheme, .dark)
        .onAppear { pulse = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("録音中。話してください")
    }
}

struct Waveform: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            let n = max(levels.count, 1)
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Color.micOrange.opacity(0.55 + 0.45 * Double(v)))
                        .frame(width: w, height: max(3, geo.size.height * CGFloat(v)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
