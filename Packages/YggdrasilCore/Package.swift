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
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter.git", exact: "0.25.10"),
        .package(
            url: "https://github.com/iliaskarim/tree-sitter-yaml.git",
            revision: "36c673c7f3f0da95e8e300b0875a3b8c12e4fee6"
        )
    ],
    targets: [
        .target(
            name: "YggdrasilCore",
            dependencies: [
                "Yams",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml")
            ]
        ),
        .testTarget(name: "YggdrasilCoreTests", dependencies: ["YggdrasilCore"])
    ]
)
