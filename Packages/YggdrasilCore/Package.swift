// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YggdrasilCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "YggdrasilCore", targets: ["YggdrasilCore"])
    ],
    targets: [
        .target(name: "YggdrasilCore"),
        .testTarget(name: "YggdrasilCoreTests", dependencies: ["YggdrasilCore"])
    ]
)
