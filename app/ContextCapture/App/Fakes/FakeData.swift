import AppKit
import CCCore
import Foundation

/// フェイク用のサンプル記録（10 件）と、それに付ける合成スクショ。
/// 表示の分岐を一通り通るように作ってある: URL あり / 要確認（検出箇所あり）/ マスク済み / トリアージ未実行 /
/// 未分類 / 日時の言及あり / エージェントのメモあり / 手直し済み / 未インストールのアプリ（汎用アイコン）/ 昨日・一昨日。
enum FakeData {
    @MainActor
    static func records(now: Date, imageDirectory: URL) -> [ContextRecord] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(dayOffset: Int, _ h: Int, _ m: Int) -> Date {
            let day = cal.date(byAdding: .day, value: dayOffset, to: today)!
            let d = cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
            // 「今日」の分が now より後になるときは、並び順を保ったまま now より前へずらす（未来の時刻にしない）。
            guard dayOffset == 0, d > now else { return d }
            return now.addingTimeInterval(-Double(24 * 60 - (h * 60 + m)) * 60)
        }
        func triage(_ intent: Intent?, _ conf: Double, datetime: Bool = false) -> TriageResult {
            TriageResult(intent: intent, intentConfidence: conf, mentionsDatetime: datetime,
                         datetimeProbability: datetime ? 0.91 : 0.04, model: "LiquidAI/d1-3B@051bcc4")
        }
        let stt = "whisper-large-v3-turbo"

        var items: [(ContextRecord, MockScreen)] = []

        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 23, 16),
            app: AppInfo(name: "Safari", bundleID: "com.apple.Safari"),
            window: WindowInfo(title: "Support streaming events · Issue #128 · opendots/opendots", frame: nil),
            url: "https://github.com/opendots/opendots/issues/128",
            annotation: Annotation(text: "これ Hermes のアダプタに使えそう。あとで実装方法を調べる", sttEngine: stt),
            triage: triage(.research, 0.88),
            guardInfo: GuardInfo(status: .clear)
        ), .browser(title: "Support streaming events #128", url: "github.com/opendots/opendots/issues/128")))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 22, 48),
            app: AppInfo(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
            window: WindowInfo(title: "adapter.ts — mach-runtime", frame: nil),
            annotation: Annotation(text: "ここで null になる理由を調べて直しておいて", sttEngine: stt),
            triage: triage(.code, 0.93),
            guardInfo: GuardInfo(status: .clear)
        ), .editor(file: "adapter.ts")))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 21, 32),
            app: AppInfo(name: "プレビュー", bundleID: "com.apple.Preview"),
            window: WindowInfo(title: "particle-swarm-optimization.pdf（3/14 ページ）", frame: nil),
            annotation: Annotation(text: "PSO のところを明日までに読む", sttEngine: stt),
            triage: triage(.todo, 0.81, datetime: true),
            guardInfo: GuardInfo(status: .clear)
        ), .document(title: "Particle Swarm Optimization")))

        let tokenScreen = MockScreen.terminal(lines: [
            "~/works/hermes % gh auth status",
            "github.com",
            "  ✓ Logged in to github.com account ysogabe",
            "  - Token: ghp_8fK2xQ9mVb7LwZ3nT1sR4yU6pE0aHc5dJgN",
            "  - Token scopes: 'repo', 'read:org'",
            "~/works/hermes % ",
        ], secretLine: 3)
        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 18, 5),
            app: AppInfo(name: "ターミナル", bundleID: "com.apple.Terminal"),
            window: WindowInfo(title: "hermes — zsh — 120×32", frame: nil),
            annotation: Annotation(text: "gh の認証トークンが古い。更新しておく", sttEngine: stt),
            triage: triage(.todo, 0.77),
            guardInfo: GuardInfo(status: .needsReview, findings: [SecretFinding(kind: "github_token", bbox: tokenScreen.secretRect ?? .zero)])
        ), tokenScreen))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 15, 40),
            app: AppInfo(name: "zoom.us", bundleID: "us.zoom.xos.fake"),
            window: WindowInfo(title: "Zoom ミーティング — 週次の設計レビュー", frame: nil),
            extra: [FakeSearchService.visualKeywordsKey: "ビデオ会議の画面 参加者のタイル 4 人"],
            annotation: Annotation(text: "今の API 移行の話、認証設計にも関係する。あとで確認", sttEngine: stt),
            triage: nil,
            guardInfo: GuardInfo(status: .pending)
        ), .meeting(title: "週次の設計レビュー")))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: 0, 11, 2),
            app: AppInfo(name: "メモ", bundleID: "com.apple.Notes"),
            window: WindowInfo(title: "収束のグラフ", frame: nil),
            extra: [FakeSearchService.visualKeywordsKey: "折れ線のグラフ 収束の図 論文"],
            annotation: Annotation(text: "この図、実装資料に使えそう", sttEngine: stt),
            triage: triage(nil, 0.52),
            guardInfo: GuardInfo(status: .clear)
        ), .document(title: "収束のグラフ")))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: -1, 19, 24),
            app: AppInfo(name: "Safari", bundleID: "com.apple.Safari"),
            window: WindowInfo(title: "カレンダー — 10月", frame: nil),
            url: "https://calendar.example.com/week",
            annotation: Annotation(text: "金曜 15 時の打ち合わせ、議題を先に送っておく", sttEngine: stt),
            triage: triage(.schedule, 0.9, datetime: true),
            guardInfo: GuardInfo(status: .clear)
        ), .browser(title: "カレンダー", url: "calendar.example.com/week")))

        let maskedScreen = MockScreen.terminal(lines: [
            "~/works/infra % cat .env.local",
            "DATABASE_URL=postgres://localhost:5432/app",
            "OPENAI_API_KEY=sk-proj-Q2c4R7t9W1y3Z5b8D0f2H4j6",
            "LOG_LEVEL=debug",
            "~/works/infra % ",
        ], secretLine: 2)
        items.append((ContextRecord(
            capturedAt: at(dayOffset: -1, 16, 10),
            app: AppInfo(name: "ターミナル", bundleID: "com.apple.Terminal"),
            window: WindowInfo(title: "infra — zsh", frame: nil),
            annotation: Annotation(text: "このフォルダの古い設定ファイルを整理する", sttEngine: stt),
            triage: triage(.todo, 0.74),
            guardInfo: GuardInfo(status: .masked, findings: [SecretFinding(kind: "openai_api_key", bbox: maskedScreen.secretRect ?? .zero)])
        ), maskedScreen))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: -1, 10, 45),
            app: AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"),
            window: WindowInfo(title: "EmbeddingGemma 2 の画像トークン数と精度 — Tech Blog", frame: nil),
            url: "https://blog.example.com/embeddinggemma-image-tokens",
            annotation: Annotation(text: "画像トークン数を減らしたときの精度の比較。あとで詳しく調べる", sttEngine: stt),
            triage: triage(.research, 0.86),
            guardInfo: GuardInfo(status: .clear),
            notes: [Note(author: "claude-code", text: "70 トークンでも R@3 は 0.9 前後。速度は 6 倍。", at: at(dayOffset: -1, 11, 30))]
        ), .browser(title: "EmbeddingGemma 2 の画像トークン数", url: "blog.example.com/embeddinggemma-image-tokens")))

        items.append((ContextRecord(
            capturedAt: at(dayOffset: -2, 20, 12),
            app: AppInfo(name: "ターミナル", bundleID: "com.apple.Terminal"),
            window: WindowInfo(title: "memo-collector — swift build", frame: nil),
            annotation: Annotation(text: "ビルドが遅い原因、MLX の metallib かもしれない。あとで見る", sttEngine: stt, edited: true),
            triage: triage(.code, 0.79),
            guardInfo: GuardInfo(status: .clear)
        ), .terminal(lines: ["% swift build", "Compiling MLX default.metallib …", "[812/1024] Compiling Cmlx", "Build complete! (412.38s)"], secretLine: nil)))

        // 片付いた記録（Inbox には出ない。今日の件数には入らない日付）。
        items.append((ContextRecord(
            capturedAt: at(dayOffset: -3, 9, 0),
            app: AppInfo(name: "Safari", bundleID: "com.apple.Safari"),
            window: WindowInfo(title: "Release notes", frame: nil),
            annotation: Annotation(text: "リリースノートを読んだ", sttEngine: stt),
            triage: triage(.note, 0.8),
            guardInfo: GuardInfo(status: .clear),
            status: .done
        ), .document(title: "Release notes")))

        return items.map { record, screen in
            var r = record
            let rel = CCPaths.attachmentRelativePath(id: r.id, kind: .screenshot, ext: "png", capturedAt: r.capturedAt)
            if screen.write(to: imageDirectory.appendingPathComponent(rel), masked: false) {
                r.screenshotPath = rel
            }
            if r.guardInfo.status == .masked {
                let mrel = CCPaths.attachmentRelativePath(id: r.id, kind: .maskedScreenshot, ext: "png", capturedAt: r.capturedAt)
                if screen.write(to: imageDirectory.appendingPathComponent(mrel), masked: true) {
                    r.maskedScreenshotPath = mrel
                }
            }
            return r
        }
    }
}

/// 合成スクショの描き方。座標は左上原点。
enum MockScreen {
    case browser(title: String, url: String)
    case editor(file: String)
    case document(title: String)
    case terminal(lines: [String], secretLine: Int?)
    case meeting(title: String)

    static let size = CGSize(width: 960, height: 600)
    private static let chrome: CGFloat = 36
    private static let lineHeight: CGFloat = 30
    private static let termTop: CGFloat = chrome + 28

    /// 秘密情報の行の正規化 bbox（左上原点）。
    var secretRect: CGRect? {
        guard case let .terminal(lines, secretLine?) = self else { return nil }
        let r = Self.textRect(line: secretLine, text: lines[secretLine])
        return CGRect(x: r.minX / Self.size.width, y: r.minY / Self.size.height,
                      width: r.width / Self.size.width, height: r.height / Self.size.height)
    }

    private static func textRect(line: Int, text: String) -> CGRect {
        // "  - Token: " などの見出し部分の後ろ（"=" か ": " の後ろ）を秘密とみなす。
        let font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let prefixEnd = text.range(of: "=")?.upperBound ?? text.range(of: ": ")?.upperBound ?? text.startIndex
        let prefix = String(text[..<prefixEnd])
        let secret = String(text[prefixEnd...])
        let px = (prefix as NSString).size(withAttributes: [.font: font]).width
        let sw = (secret as NSString).size(withAttributes: [.font: font]).width
        return CGRect(x: 28 + px - 4, y: termTop + CGFloat(line) * lineHeight - 3, width: sw + 8, height: lineHeight - 2)
    }

    @MainActor
    func write(to url: URL, masked: Bool) -> Bool {
        let w = Int(Self.size.width), h = Int(Self.size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(masked: masked)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func draw(masked: Bool) {
        let size = Self.size
        let dark: Bool
        switch self {
        case .terminal, .meeting: dark = true
        default: dark = false
        }
        (dark ? NSColor(white: 0.11, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()

        // ウインドウのタイトルバー
        (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: Self.chrome).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 14 + CGFloat(i) * 20, y: 12, width: 12, height: 12)).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.3, alpha: 1),
        ]
        let title: String
        switch self {
        case let .browser(t, _): title = t
        case let .editor(f): title = f
        case let .document(t): title = t
        case .terminal: title = "zsh"
        case let .meeting(t): title = t
        }
        (title as NSString).draw(at: NSPoint(x: 90, y: 10), withAttributes: titleAttrs)

        switch self {
        case let .browser(t, url):
            NSColor(white: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 180, y: 46, width: 600, height: 26), xRadius: 7, yRadius: 7).fill()
            (url as NSString).draw(at: NSPoint(x: 196, y: 51), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
            (t as NSString).draw(at: NSPoint(x: 60, y: 104), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            bars(from: 160, count: 9, color: NSColor(white: 0.86, alpha: 1), x: 60, maxWidth: 820)
        case .editor:
            NSColor(white: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: Self.chrome, width: 200, height: size.height).fill()
            bars(from: 60, count: 12, color: NSColor(white: 0.85, alpha: 1), x: 20, maxWidth: 150)
            let code = ["export function lookup(name: string) {", "  const plugin = registry.get(name)", "  return plugin.adapter  // ← null", "}"]
            for (i, l) in code.enumerated() {
                (l as NSString).draw(at: NSPoint(x: 230, y: 70 + CGFloat(i) * 30),
                                     withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.55, alpha: 1)])
            }
            bars(from: 210, count: 10, color: NSColor(white: 0.88, alpha: 1), x: 230, maxWidth: 600)
        case let .document(t):
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: Self.chrome, width: size.width, height: size.height).fill()
            NSColor.white.setFill()
            NSRect(x: 220, y: 60, width: 520, height: 520).fill()
            (t as NSString).draw(at: NSPoint(x: 250, y: 84), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black])
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 260, y: 400))
            for i in 0..<12 { path.line(to: NSPoint(x: 260 + CGFloat(i) * 38, y: 400 - 230 * (1 - exp(-Double(i) / 3)))) }
            NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.92, alpha: 1).setStroke()
            path.lineWidth = 3
            path.stroke()
            bars(from: 430, count: 4, color: NSColor(white: 0.85, alpha: 1), x: 250, maxWidth: 460)
        case let .terminal(lines, secretLine):
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: NSPoint(x: 28, y: Self.termTop + CGFloat(i) * Self.lineHeight),
                                     withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular), .foregroundColor: NSColor(white: 0.88, alpha: 1)])
            }
            if masked, let s = secretLine {
                NSColor.black.setFill()
                Self.textRect(line: s, text: lines[s]).fill()
            }
        case .meeting:
            for i in 0..<4 {
                let r = NSRect(x: 40 + CGFloat(i % 2) * 450, y: 60 + CGFloat(i / 2) * 260, width: 430, height: 240)
                NSColor(white: 0.22 + CGFloat(i) * 0.03, alpha: 1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
                NSColor(white: 0.45, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 40, y: r.midY - 50, width: 80, height: 80)).fill()
            }
        }
    }

    private func bars(from y: CGFloat, count: Int, color: NSColor, x: CGFloat, maxWidth: CGFloat) {
        color.setFill()
        for i in 0..<count {
            let w = maxWidth * (0.55 + 0.45 * CGFloat((i * 37) % 10) / 10)
            NSBezierPath(roundedRect: NSRect(x: x, y: y + CGFloat(i) * 26, width: w, height: 12), xRadius: 4, yRadius: 4).fill()
        }
    }
}
