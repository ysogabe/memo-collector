import AppKit
import SwiftUI

/// メニューバーのメニューに足すデバッグ項目（`--debug` 起動か、⌥ を押しながらメニューを開いたときだけ）。
/// M1 の実機確認用: CaptureDiagnostics の 3 関数・計測値（直近 20 件の p50/p90）・データフォルダ。
struct DebugMenu: View {
    let model: AppModel
    let live: LiveServices

    var body: some View {
        Menu("デバッグ") {
            Text("ホットキー: \(model.hotKeyStatus.debugDescription)")
            Divider()
            ForEach(CaptureLatencyMonitor.Metric.allCases, id: \.self) { m in
                Text("\(m.title): \(live.latency.summary(m))")
            }
            Button("計測値をコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(live.latency.report, forType: .string)
            }
            Divider()
            Button("診断: 前面コンテキスト（3 秒後に取得）") {
                run("前面コンテキスト") { await live.runContextDiagnostics() }
            }
            Button("診断: 録音（3 秒）") {
                run("録音") { await live.runRecordingDiagnostics() }
            }
            Button("診断: ホットキー（10 秒間の押下/解放）") {
                run("ホットキー") { await live.runHotKeyDiagnostics() }
            }
            Divider()
            Button("データフォルダを Finder で開く") { live.revealDataFolder() }
            Button("保持期間の削除を今すぐ実行") { Task { await live.purgeExpired() } }
        }
    }

    private func run(_ name: String, _ body: @escaping @MainActor () async -> URL?) {
        model.toast.show(ToastContent(kind: .info, title: "診断: \(name)", body: "実行しています…"))
        Task { @MainActor in
            if let url = await body() {
                model.toast.show(ToastContent(kind: .info, title: "診断: \(name)", body: "結果を保存しました（\(url.lastPathComponent)）"))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                model.toast.show(ToastContent(kind: .error, title: "診断: \(name)", body: "実行できませんでした（録音中・診断中の可能性）"))
            }
        }
    }
}
