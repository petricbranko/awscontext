// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AWSContext",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AWSContext", targets: ["AWSContext"]),
        .library(name: "AWSContextCore", targets: ["AWSContextCore"]),
    ],
    targets: [
        .target(name: "AWSContextCore"),
        .executableTarget(name: "AWSContext", dependencies: ["AWSContextCore"]),
        .testTarget(name: "AWSContextCoreTests", dependencies: ["AWSContextCore"]),
    ]
)
