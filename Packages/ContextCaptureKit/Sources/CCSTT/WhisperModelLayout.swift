import CCCore
import Foundation

/// `<models>/whisperkit/` の中身の配置（計画書 §2）。
///
/// WhisperKit / Hub の既定レイアウト（`<downloadBase>/models/<repo id>/...`）をそのまま使う。
/// こうしておくと `WhisperKit.download(downloadBase:)` の出力をそのまま読め、スパイクの
/// `spikes/runtime/models/stt/whisperkit/` も同じ形なので `CC_MODELS_DIR=spikes/runtime/models/stt` で指せる。
///
/// ```
/// <models>/whisperkit/
/// ├── manifest.json                                   … CCModels.WhisperModelPreparer が書く
/// └── models/
///     ├── argmaxinc/whisperkit-coreml/<variant>/      … MelSpectrogram / AudioEncoder / TextDecoder (.mlmodelc)
///     └── openai/whisper-large-v3/                    … tokenizer.json ほか
/// ```
///
/// - Note: CCModels 側にも同じ定数がある（`WhisperModelPreparer`）。CCModels は CCSTT に依存できない
///   （Package.swift の依存関係）ため重複させている。変えるときは両方を直すこと。
public struct WhisperModelLayout: Sendable, Equatable {
    /// large-v3-turbo（WhisperKit の Core ML 版。1.5GB）。
    public static let defaultVariant = "openai_whisper-large-v3-v20240930"
    public static let modelRepo = "argmaxinc/whisperkit-coreml"
    /// large-v3 系（turbo を含む）のトークナイザ。
    public static let tokenizerRepo = "openai/whisper-large-v3"
    /// WhisperKit が読み込む 3 モデル。
    public static let requiredModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// `<models>/whisperkit/`。
    public let root: URL
    public let variant: String

    public init(root: URL, variant: String = Self.defaultVariant) {
        self.root = root.standardizedFileURL
        self.variant = variant
    }

    public init(paths: CCPaths, variant: String = Self.defaultVariant) {
        self.init(root: paths.modelDirectory(.whisper), variant: variant)
    }

    /// `<root>/models/argmaxinc/whisperkit-coreml/<variant>/`。
    public var modelFolder: URL {
        root.appendingPathComponent("models/\(Self.modelRepo)/\(variant)", isDirectory: true)
    }

    /// `<root>/models/openai/whisper-large-v3/`。
    public var tokenizerFolder: URL {
        root.appendingPathComponent("models/\(Self.tokenizerRepo)", isDirectory: true)
    }

    /// 読み込みに必要なのに見つからないファイル（相対パス）。空なら揃っている。
    public func missingFiles(fileManager: FileManager = .default) -> [String] {
        var missing: [String] = []
        for name in Self.requiredModelNames {
            let compiled = modelFolder.appendingPathComponent("\(name).mlmodelc")
            let package = modelFolder.appendingPathComponent("\(name).mlpackage")
            if !fileManager.fileExists(atPath: compiled.path), !fileManager.fileExists(atPath: package.path) {
                missing.append("\(name).mlmodelc")
            }
        }
        if !fileManager.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path) {
            missing.append("tokenizer.json")
        }
        return missing
    }
}
