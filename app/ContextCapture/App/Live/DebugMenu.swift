import AppKit
import Observation
import SwiftUI

/// デバッグメニューに出す各モデルの状態（`LiveServices.refreshDebugStatus()` が 5 秒ごとに更新。メニューを出しているときだけ）。
/// d1 の無使用解放（既定 10 分）が効いているかをここで確かめる。
@Observable
@MainActor
final class ModelDebugStatus {
    private(set) var whisper = "-"
    private(set) var d1 = "-"
    private(set) var embedding = "-"
    private(set) var triage = "-"
    private(set) var mlxActive = "-"
    private(set) var resident = "-"

    func update(whisper: String, d1: String, embedding: String, triage: String, mlxActiveBytes: Int, residentBytes: Int) {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        self.whisper = whisper
        self.d1 = d1
        self.embedding = embedding
        self.triage = triage
        mlxActive = f.string(fromByteCount: Int64(mlxActiveBytes))
        resident = residentBytes >= 0 ? f.string(fromByteCount: Int64(residentBytes)) : "-"
    }

    var report: String {
        "whisper: \(whisper)\nd1: \(d1)\nembedding: \(embedding)\ntriage: \(triage)\nMLX active: \(mlxActive)\nRSS: \(resident)"
    }
}

/// メニューバーのメニューに足すデバッグ項目（`--debug` 起動か、⌥ を押しながらメニューを開いたときだけ）。
/// M1 の実機確認用: CaptureDiagnostics の 3 関数・計測値（直近 20 件の p50/p90）・データフォルダ。
struct DebugMenu: View {
    let model: AppModel
    let live: LiveServices

    var body: some View {
        Menu("デバッグ") {
            Text("ホットキー: \(model.hotKeyStatus.debugDescription)")
            Divider()
            Text("文字起こし: \(live.debugStatus.whisper)")
            Text("意図（d1）: \(live.debugStatus.d1)")
            Text("検索: \(live.debugStatus.embedding)")
            Text("トリアージ: \(live.debugStatus.triage)")
            Text("MLX アクティブ: \(live.debugStatus.mlxActive)・RSS: \(live.debugStatus.resident)")
            Button("モデルの状態を更新") { Task { await live.refreshDebugStatus() } }
            Button("モデルの状態をコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(live.debugStatus.report, forType: .string)
            }
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
