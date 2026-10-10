import AppKit
import CCCore
import SwiftUI

/// 確認用のレンダリング（画面ロック中でもスクショ代わりの PNG を作る）。
///
///     ContextCapture --fake --render-snapshots docs/ui-snapshots
///
/// `ImageRenderer` は macOS では List・Form・TextEditor・Button など AppKit 由来のコントロールを描かない（プレースホルダになる）ため、
/// 画面外の NSWindow に NSHostingView を載せて `cacheDisplay(in:to:)` で書き出す。時計とサンプルは固定。
@MainActor
struct SnapshotRenderer {
    let model: AppModel

    static func requestedDirectory(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let i = arguments.firstIndex(of: "--render-snapshots"), i + 1 < arguments.count else { return nil }
        let raw = (arguments[i + 1] as NSString).expandingTildeInPath
        return URL(fileURLWithPath: raw, isDirectory: true, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).absoluteURL
    }

    /// 固定の「今」（端末のタイムゾーンで 2026-10-08 23:30）。
    static let fixedNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 8; c.hour = 23; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    static func makeEnvironment(seed: Bool = true) -> AppEnvironment {
        var env = AppEnvironment.fake(now: fixedNow, seed: seed)
        var s = AppSettings()
        s.vocabulary = ["Hermes", "Claude Code", "EmbeddingGemma", "WhisperKit"]
        env.settings = InMemorySettingsStore(s)
        return env
    }

    /// 書き出して終了コードを返す。
    func renderAll(to dir: URL) async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let env = model.env
            let all = try await env.store.list(InboxFilter(statuses: [], limit: 100))
            func record(_ bundleID: String, _ status: GuardStatus) -> ContextRecord? {
                all.first { $0.app.bundleID == bundleID && $0.guardInfo.status == status }
            }

            // Inbox（通常）
            let inbox = InboxViewModel(store: env.store, search: env.search, now: env.now)
            await inbox.load()
            inbox.selection = inbox.visibleRecords.dropFirst().first?.id
            try await write(InboxView(app: model, vm: inbox), "inbox", size: NSSize(width: 780, height: 600), to: dir)

            // Inbox（ダーク）
            let inboxDark = InboxViewModel(store: env.store, search: env.search, now: env.now)
            await inboxDark.load()
            try await write(InboxView(app: model, vm: inboxDark), "inbox-dark", size: NSSize(width: 780, height: 600),
                            appearance: .darkAqua, to: dir)

            // Inbox（空）
            let emptyModel = AppModel(env: Self.makeEnvironment(seed: false))
            let empty = InboxViewModel(store: emptyModel.env.store, search: emptyModel.env.search, now: emptyModel.env.now)
            await empty.load()
            try await write(InboxView(app: emptyModel, vm: empty), "inbox-empty", size: NSSize(width: 780, height: 460), to: dir)

            // Inbox（検索結果）
            let searching = InboxViewModel(store: env.store, search: env.search, now: env.now)
            await searching.load()
            searching.query = "ビデオ会議の画面"
            await searching.runSearch()
            try await write(InboxView(app: model, vm: searching), "inbox-search", size: NSSize(width: 780, height: 460), to: dir)

            // 詳細（通常・要確認）
            if let r = all.first(where: { $0.app.bundleID == "com.google.Chrome" && !$0.notes.isEmpty }) {
                let vm = DetailViewModel(record: r, store: env.store, guardReview: env.guardReview)
                await vm.load()
                try await write(DetailView(app: model, vm: vm, close: {}), "detail", size: NSSize(width: 720, height: 900), to: dir)
            }
            if let r = record("com.apple.Terminal", .needsReview) {
                let vm = DetailViewModel(record: r, store: env.store, guardReview: env.guardReview)
                await vm.load()
                try await write(DetailView(app: model, vm: vm, close: {}), "detail-needs-review", size: NSSize(width: 720, height: 860), to: dir)
            }

            // 録音 HUD
            let hud = HUDModel()
            for i in 0..<HUDModel.barCount {
                hud.push(Float(0.25 + 0.6 * abs(sin(Double(i) * 0.55)) * (0.6 + 0.4 * cos(Double(i) * 0.21))))
            }
            try await write(Backdrop { RecordingHUDView(model: hud).frame(width: 300, height: 64) },
                            "hud", size: NSSize(width: 420, height: 130), to: dir)

            // 保存トースト・エラー
            if let saved = all.first(where: { $0.app.bundleID == "com.apple.Safari" }) {
                let t = ToastModel()
                t.content = CaptureMessages.saved(saved, notice: nil)
                try await write(Backdrop { SaveToastView(model: t, perform: { _ in }) }, "toast-saved",
                                size: NSSize(width: 440, height: 170), to: dir)
            }
            let e = ToastModel()
            e.content = CaptureMessages.failure(.noVoice, hotkey: model.settings.hotkey.display)
            try await write(Backdrop { SaveToastView(model: e, perform: { _ in }) }, "toast-error",
                            size: NSSize(width: 440, height: 130), to: dir)

            // 設定
            let settings = SettingsViewModel(store: env.settings)
            try await write(SettingsView(vm: settings), "settings", size: NSSize(width: 560, height: 820), to: dir)

            // オンボーディング（権限・モデル）
            let perms = OnboardingViewModel(permissions: env.permissions, models: env.models, onFinish: {})
            await perms.load()
            perms.step = .permissions
            try await write(OnboardingView(vm: perms, hotkey: "⌥Space"), "onboarding-permissions", size: NSSize(width: 640, height: 600), to: dir)

            let models = OnboardingViewModel(permissions: env.permissions, models: env.models, onFinish: {})
            await models.load()
            models.step = .models
            let total = FakeModelPreparation.totalBytes
            models.modelState = .running(ModelPreparationProgress(phase: .downloading, fractionCompleted: 0.42,
                                                                  completedBytes: Int64(Double(total) * 0.42), totalBytes: total,
                                                                  currentItem: "意図の推定モデル"))
            try await write(OnboardingView(vm: models, hotkey: "⌥Space"), "onboarding-models", size: NSSize(width: 640, height: 600), to: dir)

            print("snapshots: \(dir.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    private func write<V: View>(_ view: V, _ name: String, size: NSSize,
                                appearance: NSAppearance.Name = .aqua, to dir: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        // .task・List のレイアウト・画像の読み込みが落ち着くのを待つ。
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        host.display()
        // 1x で書き出す（ファイルを小さく保つ）。
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.render(name) }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.render(name) }
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        print("wrote \(name).png (\(png.count / 1024) KB)")
    }
}

enum SnapshotError: Error {
    case render(String)
}

/// HUD・トーストの背景（デスクトップの代わり）。
private struct Backdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.82), Color(white: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
    }
}
