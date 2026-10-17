import ArgumentParser
import CCCore
import CCIntent
import CCModels
import CCStore
import CCTriage
import CoreGraphics
import Foundation

struct ReprocessIntentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reprocess-intents", abstract: "既存自動意図を集計する。--apply はアプリを終了した保守時だけ、バックアップ後に intent のみ再推論する")
    @Option(help: "既存 ContextCapture.sqlite のあるデータルート") var dataRoot: String?
    @Option(help: "準備済みモデルのルート。取得・変換はしない") var modelsRoot: String?
    @Flag(help: "読み取り専用の集計（既定）。モデルは不要") var dryRun = false
    @Flag(help: "アプリを終了した保守時だけ実行。既存自動意図を再推論する") var apply = false
    @Option(help: "--apply に必須。データ・モデル領域外の新規SQLiteバックアップ先（上書き不可）") var backup: String?
    @Option(help: "件数のみの集計 JSON。新規ファイルだけ作成する") var output: String?

    private struct Report: Encodable {
        let schemaVersion = 1
        let mode: String
        let threshold = Intent.confidenceThreshold
        let snapshot: IntentMaintenanceSnapshot
        let storedComparison = "classification counts only; stored question/model provenance may be unknown"
        var requested = 0
        var succeeded = 0
        var skipped: [String: Int] = [:]
        var failed = 0
        var unreported = 0
        var changedResults = 0
        var changedClassifications = 0
        var backupCompleted = false
        var status = "preview_only"
    }

    mutating func run() async throws {
        do { try await execute() }
        catch let code as ExitCode { throw code }
        catch let error as ValidationError { throw error }
        // SQLite/model errors may include record IDs, paths, or input. Never print those payloads.
        catch { throw ValidationError("意図の保守処理に失敗しました（\(type(of: error))）。DB・準備済みモデル・出力先を確認してください") }
    }

    private func execute() async throws {
        guard !(apply && dryRun) else { throw ValidationError("--apply と --dry-run は併用できません") }
        guard apply == (backup != nil) else { throw ValidationError("--apply と --backup は一緒に指定してください") }
        let defaults = CCPaths.resolve()
        func directory(_ value: String?, fallback: URL) -> URL {
            value.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? fallback
        }
        let paths = CCPaths(dataRoot: directory(dataRoot, fallback: defaults.dataRoot), modelsRoot: directory(modelsRoot, fallback: defaults.modelsRoot))
        let backupURL = backup.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        let outputURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        if let backupURL { try IntentMaintenance.validateDestination(backupURL, paths: paths, protected: [outputURL].compactMap { $0 }) }
        if let outputURL { try IntentMaintenance.validateDestination(outputURL, paths: paths, protected: [backupURL].compactMap { $0 }) }
        let snapshot = try IntentMaintenance.preview(paths: paths, isAnnotationEmpty: { AnnotationPreprocessor.prepare($0).isEmpty })
        var report = Report(mode: apply ? "apply" : "dry-run", snapshot: snapshot)
        if apply {
            // Verify only; this never calls prepare/download and does not create a missing model directory.
            guard case .ready = try D1ModelPreparer(destination: paths.modelDirectory(.d1)).verify(level: .sha256) else {
                throw ValidationError("準備済みd1モデルの検証に失敗しました。モデルを取得せず終了します")
            }
            let classifier = D1IntentClassifier(modelDirectory: paths.modelDirectory(.d1))
            do {
                // Fail on missing/incompatible model files before the backup or any source write.
                _ = try await classifier.load()
                try IntentMaintenance.backup(paths: paths, to: backupURL!)
                report.backupCompleted = true
                let store = try IntentOnlyRecordStore(paths: paths)
                let unused = IntentOnlyUnusedServices()
                let queue = TriageQueue(store: store, classifier: classifier, scanner: unused, embedder: unused, screenshots: unused)
                report.requested = snapshot.eligibleIDs.count
                // At most 32 jobs * (step + record + idle) < the stream's 256-event buffer,
                // even if every job finishes before the consumer resumes. No per-record output.
                for start in stride(from: 0, to: snapshot.eligibleIDs.count, by: 32) {
                    let ids = Array(snapshot.eligibleIDs[start..<min(start + 32, snapshot.eligibleIDs.count)])
                    let stream = await queue.events()
                    for id in ids { await queue.reprocess(id: id, steps: [.intent]) }
                    await queue.waitUntilIdle()
                    var remaining = Set(ids)
                    for await event in stream {
                        if case let .stepFinished(id, .intent, outcome) = event, remaining.remove(id) != nil {
                            switch outcome {
                            case .succeeded: report.succeeded += 1
                            case .failed: report.failed += 1
                            case .skipped(let reason): report.skipped[reason.rawValue, default: 0] += 1
                            }
                        }
                        if remaining.isEmpty { break }
                    }
                    report.unreported += remaining.count
                }
                report.changedResults = store.changedResults
                report.changedClassifications = store.changedClassifications
                let incomplete = report.failed + report.unreported + (report.skipped["notReady"] ?? 0) + (report.skipped["annotationChanged"] ?? 0) + (report.skipped["emptyAnnotation"] ?? 0)
                report.status = incomplete == 0 ? "completed" : "partial_failure"
                await classifier.unload()
            } catch { await classifier.unload(); throw error }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let outputURL { try IntentMaintenance.writeReport(data, to: outputURL, paths: paths, protected: [backupURL].compactMap { $0 }) }
        else { print(String(decoding: data, as: UTF8.self)) }
        if report.status == "partial_failure" { throw ExitCode(2) }
    }
}

private struct IntentOnlyUnusedServices: SecretScanning, Embedder, ScreenshotLoading {
    let dimension = 256
    func scan(image: CGImage) async throws -> [SecretFinding] { throw IntentMaintenanceError.forbiddenOperation }
    func embedQuery(_ text: String) async throws -> [Float] { throw IntentMaintenanceError.forbiddenOperation }
    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] { throw IntentMaintenanceError.forbiddenOperation }
    func loadScreenshot(relativePath: String) async throws -> CGImage { throw IntentMaintenanceError.forbiddenOperation }
}
