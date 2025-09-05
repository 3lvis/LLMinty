
import XCTest
@testable import llminty

final class SwiftAnalyzerTests: XCTestCase {
    func testEntrypointPublicAPIAndRefs() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let aURL = dir.appendingPathComponent("AppType.swift")
        let bURL = dir.appendingPathComponent("UsesApp.swift")

        let aSrc = """
        import SwiftUI
        public struct MyApp: App {
            public init() {}
            public var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let bSrc = """
        struct Helper {}
        func take(_ v: MyApp) -> Bool { return true }
        """

        try aSrc.write(to: aURL, atomically: true, encoding: .utf8)
        try bSrc.write(to: bURL, atomically: true, encoding: .utf8)

        let files: [RepoFile] = [
            RepoFile(relativePath: "AppType.swift", absoluteURL: aURL, isDirectory: false, kind: .swift, size: 0),
            RepoFile(relativePath: "UsesApp.swift", absoluteURL: bURL, isDirectory: false, kind: .swift, size: 0)
        ]
        let analyzed = try SwiftAnalyzer().analyze(files: files)

        guard let appFile = analyzed.first(where: { $0.file.relativePath == "AppType.swift" }) else {
            return XCTFail("Missing analyzed app file")
        }
        guard let usesFile = analyzed.first(where: { $0.file.relativePath == "UsesApp.swift" }) else {
            return XCTFail("Missing analyzed use file")
        }

        XCTAssertTrue(appFile.declaredTypes.contains("MyApp"))
        XCTAssertGreaterThan(appFile.publicAPIScoreRaw, 0)
        XCTAssertTrue(appFile.isEntrypoint)

        // Cross-file dependency: UsesApp references MyApp -> edge to AppType.swift
        XCTAssertTrue(usesFile.outgoingFileDeps.contains("AppType.swift"))
        XCTAssertEqual(appFile.inboundRefCount, 1)
    }
}
