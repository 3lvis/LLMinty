// swift-tools-version: 6.0
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
        // Match your Swift 6.1 toolchain. 601.x == SwiftSyntax for Swift 6.1
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "601.0.1")
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
            path: "Tests/LLMintyTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
