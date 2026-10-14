import Foundation
import SearchContracts
@main struct SearchContract {
    static func main() async {
        do {
            guard CommandLine.arguments.count==3 else { throw NSError(domain:"usage: cc-search-contract FIXTURES OUTPUT",code:1) }
            let report=try await Contracts.evaluate(fixtures:URL(fileURLWithPath:CommandLine.arguments[1]))
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            try encoder.encode(report).write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
            for (mode,result) in report.modes.sorted(by:{$0.key<$1.key}) { let s=result.summaries["split:holdout"]!;print("\(mode): Recall@3 \(s.recall["3"]!), MRR \(s.mrr!)") }
        } catch { FileHandle.standardError.write(Data("cc-search-contract: \(error)\n".utf8));exit(1) }
    }
}
