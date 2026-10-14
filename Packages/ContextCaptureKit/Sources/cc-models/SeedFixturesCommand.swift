import ArgumentParser
import CCCore
import CCStore
import Foundation

struct SeedFixturesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seed-fixtures", abstract: "著作したtext-only fixtureを明示した開発DBへ投入する（全件transaction）")
    @Option(help: "開発用データディレクトリ（必須。既定の本番DBには投入しない）") var dataDir: String
    @Option(help: "records[].record形式のJSON（例: evals/search/records.json）") var input: String

    func run() async throws {
        let target = URL(fileURLWithPath: (dataDir as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let protectedRoots = [CCPaths.resolve().dataRoot, CCPaths.resolve(environment: [:]).dataRoot]
            .map { $0.resolvingSymlinksInPath() }
        guard !protectedRoots.contains(target) else {
            throw ValidationError("既定のデータディレクトリとは別の開発用ディレクトリを指定してください")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: (input as NSString).expandingTildeInPath))
        let records = try DevelopmentFixtures.load(data)
        let store = try SQLiteRecordStore(paths: CCPaths(dataRoot: target, modelsRoot: CCPaths.resolve().modelsRoot))
        try await store.insertBatch(records)
        print("Inserted \(records.count) development fixtures atomically; media and models were not copied.")
    }
}
