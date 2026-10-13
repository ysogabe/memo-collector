import Foundation

/// CCSTT が投げるエラー。アプリは `noSpeech` を「声が入っていませんでした」として扱い、それ以外は失敗表示にする。
public enum STTError: Error, Equatable, Sendable {
    /// 入力が短すぎる（0.3 秒未満）・ほぼ無音・認識結果が空。WhisperKit には渡していないか、渡したが何も出なかった。
    case noSpeech(reason: NoSpeechReason)
    /// モデルファイルが見つからない（`cc-models prepare whisper` 未実行など）。path は探した場所。
    case modelNotFound(path: String)
    /// WhisperKit の読み込み・推論の失敗（元エラーの説明を持つ）。
    case engineFailure(String)

    /// 「声が入っていない」と判定した理由（ログ・テスト用）。
    public enum NoSpeechReason: String, Sendable, Equatable {
        /// 0.3 秒未満。
        case tooShort
        /// 発話らしい音量のフレームがほとんど無い。
        case silent
        /// WhisperKit に渡したが空文字（または既知の無音時の幻聴フレーズ）しか返らなかった。
        case emptyResult
    }
}

extension STTError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSpeech: return "声が入っていませんでした"
        case .modelNotFound(let path): return "音声認識モデルが見つかりません（\(path)）。cc-models prepare whisper を実行してください"
        case .engineFailure(let message): return "音声認識に失敗しました: \(message)"
        }
    }
}
