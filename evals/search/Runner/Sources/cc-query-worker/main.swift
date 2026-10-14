import CCCore
import CCEmbedding
import Darwin
import Foundation

func footprint() -> Double {
    var info=task_vm_info_data_t(), count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
    let status=withUnsafeMutablePointer(to:&info) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
    return status == KERN_SUCCESS ? Double(info.phys_footprint)/1e6 : -1
}
func ms(_ start:UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds-start)/1e6 }
func write(_ value:[String:Any]) throws {
    let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
final class Lines {
    var buffer=Data()
    func next() throws -> Data? {
        while true {
            if let index=buffer.firstIndex(of:10) {
                let line=buffer.subdata(in:0..<index); buffer.removeSubrange(0...index); return line
            }
            guard buffer.count <= 16_384 else { throw NSError(domain:"oversize",code:1) }
            var bytes=[UInt8](repeating:0,count:4096)
            let n=Darwin.read(STDIN_FILENO,&bytes,bytes.count)
            if n==0 { guard !buffer.isEmpty else { return nil }; let line=buffer; buffer.removeAll(); return line }
            guard n>0 else { if errno == EINTR { continue }; throw NSError(domain:"input",code:1) }
            buffer.append(contentsOf:bytes.prefix(n))
        }
    }
}
@main struct QueryWorker {
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("cc-query-worker: failed\n".utf8)); exit(1) }
    }
    static func run() async throws {
        guard let root=ProcessInfo.processInfo.environment["CC_MODELS_DIR"] else { throw NSError(domain:"models",code:1) }
        guard let units=EmbeddingComputeUnits(rawValue:ProcessInfo.processInfo.environment["CC_EMBEDDING_COMPUTE_UNITS"] ?? "cpuAndGPU") else { throw NSError(domain:"units",code:1) }
        let configuration=CoreMLEmbedder.Configuration(modelDirectory:URL(fileURLWithPath:root).appendingPathComponent("embeddinggemma-2"),textComputeUnits:units,visionComputeUnits:units)
        if CommandLine.arguments.contains("--signature") { try write(["key":configuration.indexSignature,"dimension":configuration.dimension]); return }
        let parent=getppid()
        let watch=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
        watch.schedule(deadline:.now()+1,repeating:1)
        watch.setEventHandler { if getppid() != parent { exit(0) } }; watch.resume()
        defer { watch.cancel() }
        let e=CoreMLEmbedder(configuration:configuration), before=footprint(), start=DispatchTime.now().uptimeNanoseconds
        _ = try await e.prepare(includeVision:false)
        let load=ms(start)
        if let index=CommandLine.arguments.firstIndex(of:"--inline"), index+2<CommandLine.arguments.count {
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index+1]))
            let queries=try JSONSerialization.jsonObject(with:data) as! [String]
            var rows:[[String:Any]]=[]; var peak=footprint()
            for text in queries {
                var times:[Double]=[]; var vector:[Float]=[]
                for _ in 0..<3 { let s=DispatchTime.now().uptimeNanoseconds; vector=try await e.embedQuery(text); times.append(ms(s)); peak=max(peak,footprint()) }
                rows.append(["milliseconds":times,"vector":vector])
            }
            await e.unload()
            let report:[String:Any]=["loadMilliseconds":load,"beforeFootprintMB":before,"maxInferenceFootprintMB":peak,"afterUnloadFootprintMB":footprint(),"key":configuration.indexSignature,"rows":rows]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[index+2]),options:.atomic)
            return
        }
        try write(["event":"ready","key":configuration.indexSignature,"dimension":configuration.dimension,"loadMilliseconds":load,"beforeFootprintMB":before,"footprintMB":footprint()])
        let lines=Lines()
        while let data=try lines.next() {
            guard data.count<=16_384, let req=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let id=req["id"] as? String, id.utf8.count<128, let op=req["op"] as? String else { throw NSError(domain:"protocol",code:1) }
            // Explicit fault operations exist ONLY in this opt-in PoC executable.
            if op=="crash" { exit(86) }
            if op=="hang" { sleep(60); continue }
            if op=="quit" { await e.unload(); try write(["id":id,"ok":true,"footprintMB":footprint()]); return }
            if op=="unload" { await e.unload(); try write(["id":id,"ok":true,"footprintMB":footprint()]); continue }
            guard ["query","document"].contains(op), let text=req["text"] as? String, text.utf8.count<=8000 else {
                try write(["id":id,"error":"invalid_request"]); continue
            }
            let start=DispatchTime.now().uptimeNanoseconds
            do {
                let result:SignedEmbedding
                if op=="query" { result=try await e.embedQueryWithSignature(text) }
                else { result=try await e.embedDocumentWithSignature(text:text,title:req["title"] as? String,image:nil) }
                try write(["id":id,"vector":result.vector,"key":result.compatibilityKey,"milliseconds":ms(start),"footprintMB":footprint()])
            } catch { try write(["id":id,"error":"inference_failed"]) }
        }
        await e.unload()
    }
}
