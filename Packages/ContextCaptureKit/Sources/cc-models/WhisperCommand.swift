import ArgumentParser
import CCCore
import CCModels
import Foundation

/// `cc-models whisper [prepare|verify|warm-up]`（サブコマンド省略時は prepare）。
///
/// `cc-models prepare whisper` の形にするには、`prepare` グループ（全モデル共通。担当をまたぐので main が持つ）の
/// subcommands に `PrepareWhisperCommand.self` を足す。中身は `cc-models whisper prepare` と同じ。
struct WhisperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whisper",
        abstract: "WhisperKit の音声認識モデル（large-v3-turbo, 約 1.5GB）を用意する",
        subcommands: [Prepare.self, Verify.self, WarmUp.self],
        defaultSubcommand: Prepare.self
    )

    struct Options: ParsableArguments {
        @Option(help: "WhisperKit のモデル名（argmaxinc/whisperkit-coreml のディレクトリ名）")
        var variant: String = WhisperModelPreparer.defaultVariant

        func preparer() -> WhisperModelPreparer {
            WhisperModelPreparer(paths: CCPaths.resolve(), variant: variant)
        }
    }

    /// 取得 → manifest → 検証 → ANE 特殊化。既に揃っていれば検証だけ。
    struct Prepare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: PrepareWhisperCommand.abstract)

        @OptionGroup var options: Options
        @Flag(help: "ANE 特殊化（初回ロード、約 1 分）を省く")
        var skipWarmUp = false

        func run() async throws {
            try await PrepareWhisperCommand.prepare(options.preparer(), skipWarmUp: skipWarmUp)
        }
    }

    /// manifest と突き合わせるだけ（書き込まない）。
    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "manifest とファイルを突き合わせる（書き込まない）")

        @OptionGroup var options: Options
        @Flag(help: "sha256 を省いてサイズだけ比べる")
        var quick = false

        func run() async throws {
            let p = options.preparer()
            switch try p.verify(level: quick ? .size : .sha256) {
            case .ready(let m):
                print("ok: \(m.variant) @ \(m.revision) (\(m.files.count) files)")
            case .missing(let paths):
                print("missing: \(paths.joined(separator: ", "))")
                throw ExitCode(1)
            case .unmanifested:
                print("files present but no manifest.json (run: cc-models whisper prepare)")
                throw ExitCode(1)
            case .mismatched(let paths):
                print("mismatched: \(paths.joined(separator: ", "))")
                throw ExitCode(1)
            }
        }
    }

    /// ANE 特殊化だけ行う。
    struct WarmUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "warm-up", abstract: "モデルを一度読み込んで ANE 特殊化を済ませる")

        @OptionGroup var options: Options

        func run() async throws {
            let r = try await options.preparer().warmUp()
            print(String(format: "warm-up done in %.1fs", r.loadSeconds))
        }
    }
}

/// `cc-models prepare whisper` 用（`prepare` グループの subcommands に足す）。
struct PrepareWhisperCommand: AsyncParsableCommand {
    static let abstract = "取得・manifest 作成・検証・ANE 特殊化（揃っていれば検証のみ）"
    static let configuration = CommandConfiguration(commandName: "whisper", abstract: abstract)

    @OptionGroup var options: WhisperCommand.Options
    @Flag(help: "ANE 特殊化（初回ロード、約 1 分）を省く")
    var skipWarmUp = false

    func run() async throws {
        try await Self.prepare(options.preparer(), skipWarmUp: skipWarmUp)
    }

    static func prepare(_ p: WhisperModelPreparer, skipWarmUp: Bool) async throws {
        print("whisper: \(p.root.path)")
        let printer = ProgressPrinter()
        let outcome = try await p.prepare { stage, fraction in printer.update(stage: stage, fraction: fraction) }
        switch outcome {
        case .alreadyPrepared(let m):
            print("already prepared: \(m.variant) @ \(m.revision) (\(m.files.count) files, sha256 verified)")
        case .prepared(let m):
            print("prepared: \(m.variant) @ \(m.revision) (\(m.files.count) files) → \(p.manifestURL.path)")
        }
        if !skipWarmUp {
            print("warming up (ANE specialization)…")
            let r = try await p.warmUp()
            print(String(format: "warm-up done in %.1fs", r.loadSeconds))
        }
    }
}

/// 段階ごとに 10% 刻みで進捗を出す。
private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: Int] = [:]

    func update(stage: String, fraction: Double) {
        let step = Int((fraction * 10).rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard step != last[stage] else { return }
        last[stage] = step
        print("  \(stage): \(step * 10)%")
    }
}
