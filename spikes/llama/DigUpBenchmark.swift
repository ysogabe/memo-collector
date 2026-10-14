import Darwin
import DigUpKit
import Foundation
import LlamaRuntime
struct Input: Codable { var id:String; var kind:String; var text:String?; var title:String?; var image:String? }
struct Inputs: Decodable { var inputs:[Input] }
struct Row: Codable { var id:String; var kind:String; var vector:[Float]; var milliseconds:[Double]; var tokenIDs:[Int32]?; var imageInputHash:String? }
struct Output: Codable { var runtime:String; var units:String; var modelRevision:String; var loadMilliseconds:Double; var idleFootprintMB:Double; var peakFootprintMB:Double; var peakRSSMB:Double; var cpuSeconds:Double; var batchMilliseconds:Double; var batchStrategy:String; var maxTextTokens:Int; var afterUnloadFootprintMB:Double; var rows:[Row] }
func footprint(peak:Bool = false) -> Double {
    var info=task_vm_info_data_t(); var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
    let result=withUnsafeMutablePointer(to:&info) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
    return result == KERN_SUCCESS ? (peak ? Double(info.ledger_phys_footprint_peak) : Double(info.phys_footprint))/1e6 : -1
}
let args=CommandLine.arguments
let inputURL=URL(fileURLWithPath:args[1]), outputURL=URL(fileURLWithPath:args[2])
let root=inputURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let textOnly=args.contains("--text-only")
let inputs=try JSONDecoder().decode(Inputs.self,from:Data(contentsOf:inputURL)).inputs.filter { !textOnly || $0.kind == "query" || $0.kind == "document" }
let idle=footprint(), t=DispatchTime.now().uptimeNanoseconds
let e=try LlamaEmbedder(models:LlamaModels.locate(),textOnly:textOnly)
let load=Double(DispatchTime.now().uptimeNanoseconds-t)/1e6
var rows:[Row]=[], peak=footprint(peak:true)
for input in inputs {
    var vector:[Float]=[], times:[Double]=[]
    for _ in 0..<3 {
        let start=DispatchTime.now().uptimeNanoseconds
        switch input.kind {
        case "query": vector=try e.embedTexts([Prompts.query(input.text!)])[0]
        case "document": vector=try e.embedTexts([Prompts.document(title:input.title,text:input.text!)])[0]
        case "image": vector=try e.embedImages([root.appendingPathComponent(input.image!).path],budget:280)[0].vector!
        case "fused": vector=try e.embedFused(text:input.text!,title:input.title,path:root.appendingPathComponent(input.image!).path,budget:280)
        default: fatalError("unknown input")
        }
        times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6); peak=max(peak,footprint(peak:true))
    }
    var tokens:[Int32]?
    if input.kind == "query" { tokens=e.debugTextTokens(Prompts.query(input.text!)) }
    if input.kind == "document" { tokens=e.debugTextTokens(Prompts.document(title:input.title,text:input.text!)) }
    let hash=try input.image.map { try e.debugImageHash(root.appendingPathComponent($0).path,budget:280) }
    rows.append(Row(id:input.id,kind:input.kind,vector:vector,milliseconds:times,tokenIDs:tokens,imageInputHash:hash))
}
let batchStart=DispatchTime.now().uptimeNanoseconds
_ = try e.embedTexts(inputs.filter { $0.kind == "query" }.map { Prompts.query($0.text!) })
let batchMs=Double(DispatchTime.now().uptimeNanoseconds-batchStart)/1e6
e.close()
var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
let output=Output(runtime:"llama.cpp b11461 + no-logits + fused spike",units:"Metal/Q8_0",modelRevision:LlamaModels.revision,loadMilliseconds:load,idleFootprintMB:idle,peakFootprintMB:peak,peakRSSMB:Double(usage.ru_maxrss)/1e6,cpuSeconds:cpu,batchMilliseconds:batchMs,batchStrategy:"native sequence packing, max16 sequences",maxTextTokens:textOnly ? 512 : 2048,afterUnloadFootprintMB:footprint(),rows:rows)
let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
try encoder.encode(output).write(to:outputURL,options:.atomic)
