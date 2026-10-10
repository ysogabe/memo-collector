// テキスト塔の入力の作り方（トークン表の bf16 行 × √512 を fp16 で渡す、固定長関数 `embed_<S>` の選び方、マスク）は
// FluidInference/FluidUse（https://github.com/FluidInference/FluidUse、commit e974b3841aaa438cd4d35dcbc5ba385b4c720643）の
// Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Manager.swift を基にしている。
// Copyright FluidInference. Licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
// Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// Context Capture での変更: 画像トークンの差し込み（融合）を足した / 同期 API にして autoreleasepool の中で呼べるようにした /
// pack_256 と音声は使わないので外した / `EMBEDDINGGEMMA2_MODEL_DIR` で検証を飛ばす経路は持たない。
@preconcurrency import CoreML
import Foundation

/// `<models>/embeddinggemma-2/` に置くファイル名（CCModels の `EmbeddingModelPreparer` と同じ。CCModels は CCEmbedding に
/// 依存できないので定数は重複している）。
public enum EmbeddingModelFiles {
    public static let textModel = "EmbeddingGemma2Text.mlmodelc"
    public static let visionModel = "EmbeddingGemma2Vision.mlmodelc"
    public static let tokenTable = "embeddings.bf16"
    public static let positionTable = "position_embeddings.f16"
    public static let tokenizer = "tokenizer.json"
    /// テキストだけ使うときに要るもの。
    public static let textRequired = [textModel, tokenTable, tokenizer]
    /// 画像も使うときに要るもの。
    public static let visionRequired = [visionModel, positionTable]

    /// `directory` に無いファイル名。
    public static func missing(_ names: [String], in directory: URL, fileManager: FileManager = .default) -> [String] {
        names.filter { !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

/// 計算ユニット（設定に保存できるよう CoreML の型を表に出さない）。
public enum EmbeddingComputeUnits: String, CaseIterable, Codable, Sendable {
    /// CPU + Neural Engine（既定。d1・WhisperKit と GPU を取り合わない。初回ロードは ANE 向けコンパイルで数分）。
    case cpuAndNeuralEngine
    /// CPU + GPU（初回ロードが速い。GPU は他モデルと共有）。
    case cpuAndGPU
    case all
    case cpuOnly

    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .all: return .all
        case .cpuOnly: return .cpuOnly
        }
    }
}

/// 特殊トークンの id（`config.json` の vision 節と Gemma の tokenizer.json）。
enum EmbeddingGemma2Tokens {
    /// 画像のソフトトークン（`<|image|>` を展開した中身。テキスト塔には画像トークンの行を入れる）。
    static let softImage: Int32 = 258_880
    /// `<|image>`
    static let beginImage: Int32 = 255_999
    /// `<image|>`
    static let endImage: Int32 = 258_882
}

/// トークン列の組み立て（HF の processor と同じ並び。モデル無しでテストできるよう分けてある）。
struct EmbeddingSequenceBuilder: Sendable {
    /// テキスト塔の最長（これを超える分は切り詰め）。
    static let maxLength = 512
    let tokenizer: EmbeddingGemma2Tokenizer

    /// テキストのみ: `<bos> … <eos>`（512 を超える分は末尾を捨てる）。
    func text(_ s: String) -> [Int32] { tokenizer.encode(s, maxLength: Self.maxLength) }

    /// 画像のみ: `<bos> <|image> soft×n <image|> <eos>`。
    func image(softTokens n: Int) -> [Int32] {
        [tokenizer.bosId, EmbeddingGemma2Tokens.beginImage]
            + [Int32](repeating: EmbeddingGemma2Tokens.softImage, count: n)
            + [EmbeddingGemma2Tokens.endImage, tokenizer.eosId]
    }

    /// 融合: `prompt` は `… <|image|>` で終わる文字列（`EmbeddingPrompt.fused`）。HF と同じく直前の空白は残し、
    /// `<|image|>` を `<|image> soft×n <image|>` に置き換えて `<eos>` を付ける。
    /// 長いときは画像トークンを残して**テキストの末尾を**切り詰める（HF は列の末尾を切るので画像が欠けるが、それは避ける）。
    func fused(_ prompt: String, softTokens n: Int) -> [Int32] {
        let placeholder = EmbeddingPrompt.imagePlaceholder
        let head = prompt.hasSuffix(placeholder) ? String(prompt.dropLast(placeholder.count)) : prompt
        // encode は <bos> と <eos> を含めて maxLength 以内。<eos> を外して <|image> soft×n <image|> <eos> を足す
        var ids = tokenizer.encode(head, maxLength: max(Self.maxLength - n - 2, 3))
        if ids.last == tokenizer.eosId { ids.removeLast() }
        return ids + [EmbeddingGemma2Tokens.beginImage]
            + [Int32](repeating: EmbeddingGemma2Tokens.softImage, count: n)
            + [EmbeddingGemma2Tokens.endImage, tokenizer.eosId]
    }
}

/// テキスト塔（`EmbeddingGemma2Text.mlmodelc` の `embed_32 … embed_512`）。ロード後は不変なので複数スレッドから使える。
final class EmbeddingGemma2TextTower: @unchecked Sendable {
    static let lengths = [32, 48, 64, 128, 256, 512]
    static let hiddenSize = 512
    static let outputDimension = 768

    let tokenizer: EmbeddingGemma2Tokenizer
    let sequences: EmbeddingSequenceBuilder
    private let models: [Int: MLModel]
    private let table: Data
    private let embedScale = Float(hiddenSize).squareRoot()

    private init(tokenizer: EmbeddingGemma2Tokenizer, models: [Int: MLModel], table: Data) {
        self.tokenizer = tokenizer
        self.sequences = EmbeddingSequenceBuilder(tokenizer: tokenizer)
        self.models = models
        self.table = table
    }

    /// 6 関数を順に読み込む（ANE 向けの初回コンパイルは合計 2 分前後。キャッシュは実行バイナリ単位）。
    static func load(directory: URL, computeUnits: EmbeddingComputeUnits) async throws -> EmbeddingGemma2TextTower {
        let missing = EmbeddingModelFiles.missing(EmbeddingModelFiles.textRequired, in: directory)
        guard missing.isEmpty else { throw EmbeddingError.modelFilesMissing(directory: directory.path, missing: missing) }
        let tableURL = directory.appendingPathComponent(EmbeddingModelFiles.tokenTable)
        let table = try Data(contentsOf: tableURL, options: .alwaysMapped)
        guard table.count > 0, table.count % (hiddenSize * 2) == 0 else {
            throw EmbeddingError.invalidAsset("\(EmbeddingModelFiles.tokenTable) has \(table.count) bytes")
        }
        let tokenizer = try EmbeddingGemma2Tokenizer(
            tokenizerJsonURL: directory.appendingPathComponent(EmbeddingModelFiles.tokenizer))
        let modelURL = directory.appendingPathComponent(EmbeddingModelFiles.textModel)
        var models: [Int: MLModel] = [:]
        for length in lengths {
            let c = MLModelConfiguration()
            c.computeUnits = computeUnits.mlComputeUnits
            c.functionName = "embed_\(length)"
            models[length] = try await MLModel.load(contentsOf: modelURL, configuration: c)
        }
        return EmbeddingGemma2TextTower(tokenizer: tokenizer, models: models, table: table)
    }

    /// 768 次元・L2 正規化済みの埋め込み（同期。呼び出し側が autoreleasepool で囲む）。
    /// `ids` 中の `softImage` の位置には `imageTokens`（[1, T, 512] の先頭から順に）の行を入れる。
    func embed(ids: [Int32], imageTokens: MLMultiArray? = nil) throws -> [Float] {
        #if arch(arm64)
        guard !ids.isEmpty, let length = Self.lengths.first(where: { $0 >= ids.count }), let model = models[length] else {
            throw EmbeddingError.predictionFailed("\(ids.count) tokens do not fit")
        }
        let H = Self.hiddenSize
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: H)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        let xp = embeds.dataPointer.assumingMemoryBound(to: Float16.self)
        let mp = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        let padded = ids + [Int32](repeating: tokenizer.padId, count: length - ids.count)
        let rows = table.count / (H * 2)
        let soft = EmbeddingGemma2Tokens.softImage
        let softCount = ids.lazy.filter { $0 == soft }.count
        if softCount > 0 {
            guard let imageTokens, imageTokens.shape.count >= 2,
                  imageTokens.shape[imageTokens.shape.count - 2].intValue >= softCount,
                  imageTokens.shape[imageTokens.shape.count - 1].intValue == H
            else { throw EmbeddingError.predictionFailed("image tokens missing or too few for \(softCount)") }
        }
        let imageStride = imageTokens.map { $0.strides[$0.strides.count - 2].intValue } ?? 0
        let imageIsHalf = imageTokens?.dataType == .float16
        var k = 0
        table.withUnsafeBytes { raw in
            let bf16 = raw.bindMemory(to: UInt16.self)
            for (j, id) in padded.enumerated() {
                let target = xp + j * H
                if id == soft, let imageTokens {
                    let base = k * imageStride
                    if imageIsHalf {
                        let src = imageTokens.dataPointer.assumingMemoryBound(to: Float16.self) + base
                        for d in 0..<H { target[d] = src[d] }
                    } else {
                        let src = imageTokens.dataPointer.assumingMemoryBound(to: Float.self) + base
                        for d in 0..<H { target[d] = Float16(src[d]) }
                    }
                    k += 1
                } else {
                    let row = min(max(Int(id), 0), rows - 1) * H
                    for d in 0..<H { target[d] = Float16(Float(bitPattern: UInt32(bf16[row + d]) << 16) * embedScale) }
                }
            }
        }
        for j in 0..<length { mp[j] = j < ids.count ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: embeds), "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try model.prediction(from: input)
        guard let v = output.featureValue(for: "embedding")?.multiArrayValue, v.count == Self.outputDimension else {
            throw EmbeddingError.predictionFailed("missing embedding output")
        }
        var r = [Float](repeating: 0, count: Self.outputDimension)
        if v.dataType == .float16 {
            let p = v.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<r.count { r[i] = Float(p[i]) }
        } else {
            let p = v.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<r.count { r[i] = p[i] }
        }
        return EmbeddingVector.normalize(r)
        #else
        // Float16 は x86_64 の macOS では使えない。アプリは Apple Silicon 専用（PRD §3）で x86_64 では動かさないが、
        // Xcode は Release（Any Mac）でパッケージを universal でビルドするので、x86_64 でもコンパイルだけは通す。
        throw EmbeddingError.predictionFailed("Apple Silicon (arm64) only")
        #endif
    }
}

/// 視覚塔（`EmbeddingGemma2Vision.mlmodelc` の `vision_<T>`）。
final class EmbeddingGemma2VisionTower: @unchecked Sendable {
    let budget: ImageTokenBudget
    private let model: MLModel
    private let positionTable: Data

    private init(budget: ImageTokenBudget, model: MLModel, positionTable: Data) {
        self.budget = budget
        self.model = model
        self.positionTable = positionTable
    }

    static func load(directory: URL, budget: ImageTokenBudget, computeUnits: EmbeddingComputeUnits) async throws
        -> EmbeddingGemma2VisionTower
    {
        let missing = EmbeddingModelFiles.missing(EmbeddingModelFiles.visionRequired, in: directory)
        guard missing.isEmpty else { throw EmbeddingError.modelFilesMissing(directory: directory.path, missing: missing) }
        let table = try Data(contentsOf: directory.appendingPathComponent(EmbeddingModelFiles.positionTable))
        guard table.count == 2 * ImagePreprocessor.positionTableRows * ImagePreprocessor.patchValues * 2 else {
            throw EmbeddingError.invalidAsset("\(EmbeddingModelFiles.positionTable) has \(table.count) bytes")
        }
        let c = MLModelConfiguration()
        c.computeUnits = computeUnits.mlComputeUnits
        c.functionName = budget.functionName
        let model = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(EmbeddingModelFiles.visionModel), configuration: c)
        return EmbeddingGemma2VisionTower(budget: budget, model: model, positionTable: table)
    }

    /// 前処理（同期。呼び出し側が autoreleasepool で囲む）。
    func preprocess(_ image: CGImage) throws -> ImagePreprocessor.Prepared {
        try ImagePreprocessor.prepare(image, budget: budget, positionTable: positionTable)
    }

    /// 画像トークン [1, T, 512]（先頭 `prepared.softTokens` 行が有効）。
    func imageTokens(_ p: ImagePreprocessor.Prepared) throws -> MLMultiArray {
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "patches": p.patches, "positions": p.positions, "pool": p.pool, "valid": p.valid,
            "position_embeddings": p.positionEmbeddings,
        ]))
        guard let tokens = output.featureValue(for: "image_tokens")?.multiArrayValue else {
            throw EmbeddingError.predictionFailed("missing image_tokens output")
        }
        return tokens
    }
}
