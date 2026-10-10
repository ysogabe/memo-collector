import AppKit
import CCCore
import SwiftUI

/// 色の基準は LP（lp/assets/style.css）。撮影枠はコバルト、録音中だけマイクのオレンジ。
/// **オレンジ（`micOrange`）は録音中の HUD 以外で使わない。**
extension Color {
    /// 撮影枠・アクセント（#2f5bea）。
    static let capture = Color(nsColor: .dynamic(light: 0x2F5BEA, dark: 0x7F9DFF))
    /// 意図ラベルの地（#e4eafd）。
    static let captureSoft = Color(nsColor: .dynamic(light: 0xE4EAFD, dark: 0x24304F))
    /// 録音中のマイク（#ff9f0a）。HUD 専用。
    static let micOrange = Color(nsColor: NSColor(hex: 0xFF9F0A))
    /// 「要確認」の文字（#8a4b00）。
    static let warnText = Color(nsColor: .dynamic(light: 0x8A4B00, dark: 0xFFC46B))
    /// 「要確認」の地（#ffeccc）。
    static let warnSoft = Color(nsColor: .dynamic(light: 0xFFECCC, dark: 0x4A3214))
    /// 検出箇所のハイライト枠。
    static let findingStroke = Color(nsColor: NSColor(hex: 0xE5484D))
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

// MARK: - 共通の小物

/// 意図ラベル（mono・コバルト地）。未分類は灰色。
struct IntentTag: View {
    let intent: Intent?
    var body: some View {
        Text(intent?.rawValue ?? RecordMarkdown.unclassifiedLabel)
            .font(.system(size: 11, weight: .medium, design: intent == nil ? .default : .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(intent == nil ? Color.secondary : Color.capture)
            .background(intent == nil ? Color.secondary.opacity(0.12) : Color.captureSoft, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(intent.map { "意図 \(IntentText.title($0))" } ?? "意図 未分類")
    }
}

/// 「要確認」バッジ。
struct NeedsReviewBadge: View {
    var body: some View {
        Label("要確認", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(Color.warnText)
            .background(Color.warnSoft, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("要確認。トークンらしき文字列が写っています")
    }
}

enum IntentText {
    /// 意図の説明（LP の FAQ の言い方）。
    static func title(_ intent: Intent) -> String {
        switch intent {
        case .todo: return "todo（自分でやること）"
        case .research: return "research（調べてほしいこと）"
        case .code: return "code（コードの修正）"
        case .note: return "note（メモ）"
        case .schedule: return "schedule（予定）"
        }
    }
}

/// アプリアイコン（バンドル ID から。見つからなければ汎用アイコン）。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage {
        let key = bundleID ?? ""
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        cache[key] = image
        return image
    }
}

struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: AppIconCache.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 日付の見出し・時刻の書式。
enum DateText {
    static func time(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func dayHeading(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "今日" }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: y) { return "昨日" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.calendar = calendar
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "M月d日（E）" : "yyyy年M月d日（E）"
        return f.string(from: day)
    }

    static func full(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日（E） HH:mm"
        return f.string(from: d)
    }
}
