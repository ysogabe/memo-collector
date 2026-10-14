// swift-tools-version: 6.2
import PackageDescription
let vendor="\(Context.packageDirectory)/Vendor"
let package=Package(name:"DigUpBenchmark",platforms:[.macOS(.v14)],products:[.executable(name:"digup-bench",targets:["digup-bench"])],targets:[
    .target(name:"DigUpKit"),
    .systemLibrary(name:"CLlama",path:"Sources/CLlama"),
    .target(name:"LlamaRuntime",dependencies:["CLlama","DigUpKit"],linkerSettings:[.unsafeFlags(["-L\(vendor)/llama/lib"])]),
    .executableTarget(name:"digup-bench",dependencies:["DigUpKit","LlamaRuntime"])
])
