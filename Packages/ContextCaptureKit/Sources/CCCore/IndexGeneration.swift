import CoreGraphics
import CryptoKit
import Foundation

/// Artifact provenance and the vector-space contract. Compute units belong to a tested compatibility family, not a new space.
public struct EmbeddingPipeline: Codable, Equatable, Sendable {
    public var modelID: String
    public var revision: String
    public var runtime: String
    public var quantization: String
    public var dimension: Int
    public var imageTokens: Int
    public var preprocessingVersion: String
    public var vectorSchemaVersion: Int
    public init(modelID: String, revision: String, runtime: String, quantization: String, dimension: Int,
                imageTokens: Int, preprocessingVersion: String, vectorSchemaVersion: Int = 1) {
        self.modelID = modelID; self.revision = revision; self.runtime = runtime; self.quantization = quantization
        self.dimension = dimension; self.imageTokens = imageTokens; self.preprocessingVersion = preprocessingVersion
        self.vectorSchemaVersion = vectorSchemaVersion
    }
    public var compatibilityKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "embedding/" + SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct IndexGeneration: Codable, Equatable, Sendable {
    public var id: String
    public var pipeline: EmbeddingPipeline
    public var state: String
    public init(id: String, pipeline: EmbeddingPipeline, state: String) { self.id = id; self.pipeline = pipeline; self.state = state }
}
public struct EmbeddingInput: Sendable {
    public var record: ContextRecord
    public var version: Int64
    public var generationID: String?
    public init(record: ContextRecord, version: Int64, generationID: String?) { self.record = record; self.version = version; self.generationID = generationID }
    public var hash: String {
        struct Input: Encodable { var version: Int64; var text: String; var title: String?; var image: String? }
        let input = Input(version: version, text: record.annotation.text, title: record.window?.title, image: record.screenshotPath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct SignedEmbedding: Sendable {
    public var vector: [Float]
    public var compatibilityKey: String
    public init(vector: [Float], compatibilityKey: String) { self.vector = vector; self.compatibilityKey = compatibilityKey }
}
public protocol SignatureReportingEmbedder: Embedder {
    func embedQueryWithSignature(_ text: String) async throws -> SignedEmbedding
    func embedDocumentWithSignature(text: String, title: String?, image: CGImage?) async throws -> SignedEmbedding
}
public protocol VersionedEmbeddingStoring: Sendable {
    /// Record, input version and the write generation are read in one transaction before loading the image.
    func embeddingInput(id: String) async throws -> EmbeddingInput?
    /// The version and vector-space key are checked in the same transaction as the write. False means obsolete/missing.
    func commitEmbedding(_ embedding: SignedEmbedding, input: EmbeddingInput) async throws -> Bool
}
public protocol IndexGenerationManaging: VersionedEmbeddingStoring {
    func beginGeneration(_ pipeline: EmbeddingPipeline) async throws -> IndexGeneration
    func activeGeneration() async throws -> IndexGeneration?
    func targetGeneration() async throws -> IndexGeneration?
    func missingGenerationIDs(_ id: String, limit: Int) async throws -> [String]
    /// Activates only if every current input is indexed; leaves both generations intact on failure.
    func activateGeneration(_ id: String) async throws -> Bool
    func rollbackGeneration(_ id: String) async throws -> Bool
}

public protocol GenerationFilteredSearching: Sendable {
    func search(vector: [Float], limit: Int, statuses: Set<RecordStatus>, compatibilityKey: String) async throws -> [SearchHit]
}
