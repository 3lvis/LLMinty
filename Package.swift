// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LLMinty",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "llminty", targets: ["llminty"])
    ],
    dependencies: [
        // Match your toolchain version. 510.x = Swift 5.10
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.2")
    ],
    targets: [
        .executableTarget(
            name: "llminty",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            path: "Sources/llminty"
        ),
        .testTarget(
            name: "LLMintyTests",
            dependencies: ["llminty"],
            path: "Tests/LLMintyTests"
        )
    ]
)
