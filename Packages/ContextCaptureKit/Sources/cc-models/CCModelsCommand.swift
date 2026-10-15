import ArgumentParser
import CCCore
import CCModels

/// モデル準備 CLI（`cc-models prepare all`）。Wave 0 ではサブコマンドの枠だけ。
@main
struct CCModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cc-models",
        abstract: "Context Capture のモデルを取得・変換・検証する",
        subcommands: [Paths.self, Prepare.self, WhisperCommand.self, SeedFixturesCommand.self, EvaluateIntentCommand.self, ReprocessIntentsCommand.self]
    )

    /// `cc-models prepare <model>`。グループは main が持ち、各担当は葉のコマンドだけを足す。
    struct Prepare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "モデルを取得・変換する",
            subcommands: [PrepareD1.self, PrepareWhisperCommand.self, PrepareEmbeddingCommand.self]
        )
    }

    /// 解決された保存先を表示する（CC_DATA_DIR / CC_MODELS_DIR の確認用）。
    struct Paths: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "データとモデルの保存先を表示する")

        func run() throws {
            let p = CCPaths.resolve()
            print("data:   \(p.dataRoot.path)")
            print("models: \(p.modelsRoot.path)")
            for slot in ModelSlot.allCases {
                print("  \(slot.rawValue): \(p.modelDirectory(slot).path)")
            }
        }
    }
}
