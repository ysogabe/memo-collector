import CCCore
import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import CCEmbedding

final class RuntimeBenchmarkTests: XCTestCase {
    struct Input: Codable { var id: String; var kind: String; var text: String?; var title: String?; var image: String? }
    struct Inputs: Decodable { var inputs: [Input] }
    struct Row: Codable { var id: String; var kind: String; var vector: [Float]; var milliseconds: [Double]; var tokenIDs: [Int32]?; var imageInputHash: String? }
    struct Output: Codable { var runtime: String; var units: String; var modelRevision: String; var loadMilliseconds: Double; var idleFootprintMB: Double; var peakFootprintMB: Double; var peakRSSMB: Double; var cpuSeconds: Double; var batchMilliseconds: Double; var batchStrategy: String; var afterUnloadFootprintMB: Double; var rows: [Row] }
    func testRuntimeBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["CC_RUNTIME_BENCH_OUTPUT"],
              let inputPath = ProcessInfo.processInfo.environment["CC_RUNTIME_BENCH_INPUTS"] else { throw XCTSkip("opt-in runtime benchmark") }
        let units = EmbeddingComputeUnits(rawValue: ProcessInfo.processInfo.environment["CC_EMBEDDING_COMPUTE_UNITS"] ?? "cpuAndGPU")!
        let directory = try XCTUnwrap(try EmbeddingFixtures.modelDirectory())
        let textOnly=ProcessInfo.processInfo.environment["CC_RUNTIME_TEXT_ONLY"] == "1"
        let inputs = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath))).inputs.filter { !textOnly || $0.kind == "query" || $0.kind == "document" }
        let root = URL(fileURLWithPath: inputPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tokenizer=try EmbeddingGemma2Tokenizer(tokenizerJsonURL:directory.appendingPathComponent("tokenizer.json"))
        let e = CoreMLEmbedder(configuration: .init(modelDirectory:directory,textComputeUnits:units,visionComputeUnits:units,dimension:768))
        func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds-start)/1e6 }
        let idle=memoryFootprintMB().current
        let start=DispatchTime.now().uptimeNanoseconds
        _ = try await e.prepare(includeVision:!textOnly)
        let load=ms(start)
        if ProcessInfo.processInfo.environment["CC_RUNTIME_PRIME"] == "1" { await e.unload(); return }
        var rows: [Row]=[], peak=memoryFootprintMB().peak
        for input in inputs {
            var times: [Double]=[], vector: [Float]=[]
            let image = try input.image.map { try EmbeddingFixtures.loadImage(root.appendingPathComponent($0)) }
            for _ in 0..<3 {
                let start=DispatchTime.now().uptimeNanoseconds
                switch input.kind {
                case "query": vector=try await e.embedQuery(input.text!)
                case "document": vector=try await e.embedDocument(text:input.text!,title:input.title,image:nil)
                case "image": vector=try await e.imageEmbedding768(image!)
                case "fused": vector=try await e.embedDocument(text:input.text!,title:input.title,image:image)
                default: throw NSError(domain:"RuntimeBenchmark",code:1)
                }
                times.append(ms(start)); peak=max(peak,memoryFootprintMB().peak)
            }
            XCTAssertEqual(vector.count,768); XCTAssertTrue(vector.allSatisfy(\.isFinite))
            var tokens: [Int32]?
            if input.kind == "query" { tokens=tokenizer.encode(EmbeddingPrompt.query(input.text!),maxLength:512) }
            if input.kind == "document" { tokens=tokenizer.encode(EmbeddingPrompt.document(text:input.text!,title:input.title),maxLength:512) }
            var pixelHash: String?
            if let image {
                let (h,w)=ImagePreprocessor.targetSize(height:image.height,width:image.width,budget:.tokens280)
                let source=try ImagePreprocessor.srgbRGBX(image)
                let resized=ImagePreprocessor.resizeBicubic(rgbx:source,width:image.width,height:image.height,toWidth:w,toHeight:h)
                var rgb:[UInt8]=[]; rgb.reserveCapacity(w*h*3)
                for i in stride(from:0,to:resized.count,by:4) { rgb += resized[i..<(i+3)] }
                pixelHash="\(w)x\(h):" + SHA256.hash(data:Data(rgb)).map { String(format:"%02x",$0) }.joined()
            }
            rows.append(Row(id:input.id,kind:input.kind,vector:vector,milliseconds:times,tokenIDs:tokens,imageInputHash:pixelHash))
        }
        let batchStart=DispatchTime.now().uptimeNanoseconds
        for input in inputs where input.kind == "query" { _ = try await e.embedQuery(input.text!) }
        let batchMs=ms(batchStart)
        await e.unload()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1e6
        let result=Output(runtime:"coreml",units:units.rawValue,modelRevision:CoreMLEmbedder.Configuration.modelRevision,loadMilliseconds:load,idleFootprintMB:idle,peakFootprintMB:peak,peakRSSMB:Double(usage.ru_maxrss)/1e6,cpuSeconds:cpu,batchMilliseconds:batchMs,batchStrategy:"sequential public scalar API",afterUnloadFootprintMB:memoryFootprintMB().current,rows:rows)
        let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys]
        try enc.encode(result).write(to:URL(fileURLWithPath:output),options:.atomic)
    }
}
