import CCCore
import Foundation
import GRDB

public struct ManualIntentSample: Sendable {
    public let id: String
    public let text: String
    public let truth: Intent
    public let storedProbabilities: [Intent: Double]?
    public init(id: String, text: String, truth: Intent, storedProbabilities: [Intent: Double]?) {
        self.id = id; self.text = text; self.truth = truth; self.storedProbabilities = storedProbabilities
    }
}

/// Opens an existing database in readonly mode without migration, directory creation or media access.
public struct ReadOnlyIntentDataset: Sendable {
    public let totalRecords: Int
    public let samples: [ManualIntentSample]

    public static func load(databaseURL: URL) throws -> Self {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(10)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records") ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT json FROM records WHERE intent IS NOT NULL
                  AND json_extract(json, '$.triage.model') = 'user'
                  AND COALESCE(json_extract(json, '$.extra.dev_fixture'), '') != 'true'
                ORDER BY captured_at, id
                """)
            let samples = try rows.compactMap { row -> ManualIntentSample? in
                let json: String = row["json"]
                let record = try CCJSON.decoder().decode(ContextRecord.self, from: Data(json.utf8))
                guard let truth = record.triage?.intent, !record.annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ManualIntentSample(id: record.id, text: record.annotation.text, truth: truth,
                                          storedProbabilities: record.triage?.intentProbabilities)
            }
            return Self(totalRecords: count, samples: samples)
        }
    }
}
