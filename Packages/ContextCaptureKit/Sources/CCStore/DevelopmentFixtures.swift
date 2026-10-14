import CCCore
import Foundation

/// Text-only development fixture envelope, shared with the authored search corpus.
/// Media is deliberately not copied; a separate temporary database is supplied explicitly by CLI.
public struct DevelopmentFixtures: Decodable, Sendable {
    public struct Entry: Decodable, Sendable { public var record: ContextRecord }
    public var records: [Entry]

    public static func load(_ data: Data) throws -> [ContextRecord] {
        let entries = try CCJSON.decoder().decode(Self.self, from: data).records
        return try entries.map { entry in
            var record = entry.record
            guard record.screenshotPath == nil, record.maskedScreenshotPath == nil, record.audioPath == nil else {
                throw FixtureError.mediaNotSupported
            }
            record.extra["dev_fixture"] = "true"
            return record
        }
    }

    public enum FixtureError: Error { case mediaNotSupported }
}
