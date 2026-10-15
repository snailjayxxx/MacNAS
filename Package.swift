// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacNAS", platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacNASCore", targets: ["MacNASCore"]),
        .executable(name: "macnas", targets: ["MacNASCLI"]),
        .executable(name: "hello-diagnostics", targets: ["HelloDiagnostics"]),
        .executable(name: "sample-file-index", targets: ["SampleFileIndex"])
    ],
    dependencies: [],
    targets: [
        .target(name: "MacNASCore", dependencies: []),
        .executableTarget(name: "MacNASCLI", dependencies: ["MacNASCore"]),
        .executableTarget(name: "HelloDiagnostics", dependencies: []),
        .executableTarget(name: "SampleFileIndex", dependencies: ["MacNASCore"]),
        .testTarget(name: "MacNASCoreTests", dependencies: ["MacNASCore"])
    ]
)
