import ArgumentParser
import CCCore
import CCModels

/// モデル準備 CLI（`cc-models prepare all`）。Wave 0 ではサブコマンドの枠だけ。
@main
struct CCModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cc-models",
        abstract: "Context Capture のモデルを取得・変換・検証する",
        subcommands: [Paths.self, Prepare.self]
    )

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
