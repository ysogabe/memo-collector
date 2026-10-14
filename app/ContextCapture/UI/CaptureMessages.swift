import CCCore
import Foundation

/// トーストに出す内容。文言は PRD §6.3 に合わせる。ボタンは動作をそのまま言い、結果は同じ言葉で返す（取り消す → 取り消しました）。
struct ToastContent: Equatable {
    enum Kind: Equatable {
        case saved
        case info
        case error
    }

    enum Action: Equatable {
        case undo(recordID: String)
        case retryTranscription(recordID: String)
        case openSystemSettings(PermissionKind)

        var title: String {
            switch self {
            case .undo: return "取り消す"
            case .retryTranscription: return "再試行"
            case .openSystemSettings: return "システム設定を開く"
            }
        }
    }

    var kind: Kind
    var title: String
    /// アプリ名・タイトル。
    var subtitle: String?
    /// 文字起こし（「」で囲んで出す）または補足。
    var body: String?
    /// 追加の注意（保存は続けたが伝えたいこと）。
    var note: String?
    var actions: [Action] = []
    /// [取り消す] を受け付ける記録。
    var undoRecordID: String? {
        actions.lazy.compactMap { if case let .undo(id) = $0 { return id } else { return nil } }.first
    }
}

enum CaptureMessages {
    static func saved(_ record: ContextRecord, notice: CaptureNotice?) -> ToastContent {
        var content = ToastContent(
            kind: .saved,
            title: "保存しました",
            subtitle: subtitle(record),
            body: record.annotation.text.isEmpty ? nil : "「\(record.annotation.text)」",
            actions: [.undo(recordID: record.id)]
        )
        if notice == .screenRecordingDenied || notice == .recordingInterruptedAndScreenRecordingDenied {
            content.note = "スクショを撮るには画面収録の許可が必要です。注釈とアプリの情報だけで保存しました。"
            content.actions.append(.openSystemSettings(.screenRecording))
        }
        if notice == .recordingInterrupted || notice == .recordingInterruptedAndScreenRecordingDenied {
            let interruption = "録音が途中で止まりました。止まるまでの音声を保存しました。必要ならもう一度録音してください。"
            content.note = [interruption, content.note].compactMap { $0 }.joined(separator: "\n")
        }
        return content
    }

    static func undone() -> ToastContent {
        ToastContent(kind: .info, title: "取り消しました")
    }

    static func failure(_ f: CaptureFailure, hotkey: String) -> ToastContent {
        switch f {
        case .noVoice:
            return ToastContent(kind: .error, title: "声が入っていませんでした",
                                body: "もう一度 \(hotkey) を押して話してください")
        case let .transcriptionFailed(id):
            return ToastContent(kind: .error, title: "文字起こしに失敗しました",
                                body: "音声は残して保存しました。",
                                actions: [.retryTranscription(recordID: id)])
        case .recordingInterrupted:
            return ToastContent(kind: .error, title: "録音が途中で止まりました",
                                body: "声を認識できませんでした。マイクを確認して、もう一度録音してください。")
        case .microphoneUnavailable:
            return ToastContent(kind: .error, title: "マイクを使えません",
                                body: "録音するにはマイクの許可が必要です。",
                                actions: [.openSystemSettings(.microphone)])
        case .saveFailed:
            return ToastContent(kind: .error, title: "保存できませんでした",
                                body: "ディスクの空きを確かめて、もう一度 \(hotkey) を押して話してください")
        }
    }

    /// 「アプリ名 · ウインドウタイトル」。
    static func subtitle(_ r: ContextRecord) -> String {
        if let t = r.window?.title, !t.isEmpty { return "\(r.app.name) · \(t)" }
        return r.app.name
    }
}
