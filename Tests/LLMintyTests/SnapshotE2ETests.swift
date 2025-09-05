// Tests/LLMintyTests/SnapshotE2ETests.swift
import XCTest
@testable import llminty

final class SnapshotE2ETests: XCTestCase {
    func testMiniRepoEndToEndContract() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llminty-mini-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Build a tiny, representative repo
        try fm.createDirectory(at: tmp.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        let alpha = """
        import Foundation
        
        public struct Alpha {
            public init() {}
            public func greet(name: String) -> String {
                if name.isEmpty { return "Hello" }
                return "Hello, \\(name)"
            }
        
            func helper(_ x: Int) -> Int {
                var s = 0
                for i in 0..<x { s += i }
                return s
            }
        }
        """
        try alpha.write(to: tmp.appendingPathComponent("Sources/Alpha.swift"), atomically: true, encoding: .utf8)

        let beta = """
        import Foundation
        
        struct Beta {
            let a: Alpha
            init(a: Alpha) { self.a = a }
        
            func run() -> String {
                return a.greet(name: "world")
            }
        }
        """
        try beta.write(to: tmp.appendingPathComponent("Sources/Beta.swift"), atomically: true, encoding: .utf8)

        let json = """
        { "items": [1,2,3,4,5,6,7,8], "meta": { "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7 } }
        """
        try json.write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let readme = "Title\\n\\n\\nThis has extra\\n\\n\\n\\nblank lines and trailing spaces   \\n"
        try readme.write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let bin = Data([0,1,2,3,4,0,5,6,7,8,0]) // includes NULs to trigger binary
        fm.createFile(atPath: tmp.appendingPathComponent("bin.dat").path, contents: bin, attributes: nil)

        let mintyignore = """
        *.md
        !README.md
        """
        try mintyignore.write(to: tmp.appendingPathComponent(".mintyignore"), atomically: true, encoding: .utf8)

        // Run LLMinty
        let text = try TestSupport.runLLMinty(in: tmp)
        let sections = TestSupport.parseMintySections(text)

        // Presence
        for p in ["Sources/Alpha.swift","Sources/Beta.swift","config.json","README.md","bin.dat"] {
            XCTAssertNotNil(sections[p], "Expected FILE section for \(p)")
        }

        // Binary placeholder
        XCTAssertTrue(sections["bin.dat"]?.contains("/* binary") == true)

        // JSON reduced
        XCTAssertTrue(sections["config.json"]?.contains("trimmed") == true)

        // README compaction
        if let md = sections["README.md"] {
            XCTAssertFalse(md.contains("\n\n\n"))
            let hasTrailingSpaces = md.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") }
            XCTAssertFalse(hasTrailingSpaces)
        }

        // Swift signatures preserved
        XCTAssertTrue(sections["Sources/Alpha.swift"]?.contains("struct Alpha") == true)
        XCTAssertTrue(sections["Sources/Alpha.swift"]?.contains("func greet(name: String) -> String") == true)
        XCTAssertTrue(sections["Sources/Alpha.swift"]?.contains("func helper(_ x: Int) -> Int") == true)

        // Dep-aware ordering: Alpha before Beta
        let order = Array(sections.keys)
        if let iA = order.firstIndex(of: "Sources/Alpha.swift"),
           let iB = order.firstIndex(of: "Sources/Beta.swift") {
            XCTAssertLessThan(iA, iB)
        }
    }
}
