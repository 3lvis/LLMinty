// Tests/LLMintyTests/SnapshotE2ETests.swift
import XCTest
@testable import llminty

final class SnapshotE2ETests: XCTestCase {

    // MARK: - Helpers

    /// Capture the content of a FILE: <path> block directly from the full output text.
    /// Tolerates \n or \r\n and zero or more blank lines after the header.
    private func captureFileSection(fullText: String, path: String) -> String? {
        let pathEsc = NSRegularExpression.escapedPattern(for: path)
        // (?ms) = dot matches newline + multiline anchors
        let pattern = "(?ms)^FILE:\\s+\(pathEsc)[ \\t]*\\r?\\n(?:[ \\t]*\\r?\\n)*(.*?)(?=^FILE:\\s+|\\z)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)
        guard let m = re.firstMatch(in: fullText, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: fullText) else { return nil }
        return String(fullText[r])
    }

    /// Find the byte offset of a "FILE: <path>" header inside the full minty text.
    private func fileHeaderOffset(in fullText: String, path: String) -> Int? {
        let needle = "FILE: \(path)"
        guard let range = fullText.range(of: needle) else { return nil }
        return fullText.distance(from: fullText.startIndex, to: range.lowerBound)
    }

    /// List all FILE headers in the full text (for targeted debugging on failure).
    private func listAllHeaders(in fullText: String) -> [String] {
        let pattern = #"(?m)^FILE:\s+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)
        return re.matches(in: fullText, options: [], range: range).compactMap { m in
            guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: fullText) else { return nil }
            return String(fullText[r])
        }
    }

    /// Assert a regex exists in text; on failure, print a short preview.
    private func assertRegex(
        _ text: String,
        _ pattern: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .anchorsMatchLines])
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let ok = re.firstMatch(in: text, options: [], range: range) != nil
            XCTAssertTrue(ok, message, file: file, line: line)
            if !ok {
                let preview = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(80).joined(separator: "\n")
                fputs("\n---- Section Preview ----\n\(preview)\n-------------------------\n", stderr)
            }
        } catch {
            XCTFail("Invalid regex: \(pattern) — \(error)", file: file, line: line)
        }
    }

    // MARK: - Test

    func testMiniRepoEndToEndContract() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llminty-mini-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Build a tiny repo
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

        // Run LLMinty and get full minty text
        let full = try TestSupport.runLLMinty(in: tmp)

        // Validate presence of each FILE header
        for p in ["Sources/Alpha.swift","Sources/Beta.swift","config.json","README.md","bin.dat"] {
            XCTAssertNotNil(fileHeaderOffset(in: full, path: p), "Expected FILE header for \(p)")
        }

        // Extract exact Alpha.swift section directly from full text
        guard let alphaSection = captureFileSection(fullText: full, path: "Sources/Alpha.swift") else {
            let headers = listAllHeaders(in: full)
            XCTFail("Could not capture section for Sources/Alpha.swift from full output.\nHeaders seen:\n- " + headers.joined(separator: "\n- "))
            return
        }

        // Binary placeholder present
        if let binSection = captureFileSection(fullText: full, path: "bin.dat") {
            XCTAssertTrue(binSection.contains("/* binary"), "Expected binary placeholder in bin.dat section")
        } else {
            XCTFail("Could not capture section for bin.dat")
        }

        // JSON reduced
        if let jsonSection = captureFileSection(fullText: full, path: "config.json") {
            XCTAssertTrue(jsonSection.contains("trimmed"), "Expected reduction note in config.json section")
        } else {
            XCTFail("Could not capture section for config.json")
        }

        // README compaction (no triple blanks, no trailing spaces)
        if let md = captureFileSection(fullText: full, path: "README.md") {
            XCTAssertFalse(md.contains("\n\n\n"), "README should have collapsed blank lines")
            let hasTrailingSpaces = md.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") }
            XCTAssertFalse(hasTrailingSpaces, "README lines should not end with trailing whitespace")
        } else {
            XCTFail("Could not capture section for README.md")
        }

        // ——— Semantic API checks (regex, multi-line, whitespace tolerant) ———

        // 1) struct Alpha exists
        assertRegex(
            alphaSection,
            #"(?m)^\s*(public\s+)?struct\s+Alpha\b"#,
            "Expected 'struct Alpha' signature in Alpha.swift"
        )

        // 2) public func greet(name: String) -> String (label `name` and return type String)
        assertRegex(
            alphaSection,
            #"(?m)^\s*public\s+func\s+greet\s*\(\s*name\s*:\s*String\s*\)\s*->\s*String\b"#,
            "Expected public 'func greet(name: String) -> String' signature in Alpha.swift"
        )

        // 3) internal helper that returns Int — accept any param formatting but require -> Int
        assertRegex(
            alphaSection,
            #"(?m)^\s*(internal\s+|fileprivate\s+|private\s+)?func\s+helper\s*\(\s*.*Int\s*\)\s*->\s*Int\b"#,
            "Expected 'func helper(...) -> Int' signature in Alpha.swift"
        )

        // 4) Dependency-aware emission order: Alpha before Beta in the *full* output
        if let offA = fileHeaderOffset(in: full, path: "Sources/Alpha.swift"),
           let offB = fileHeaderOffset(in: full, path: "Sources/Beta.swift") {
            XCTAssertLessThan(offA, offB, "Expected Alpha to be emitted before Beta")
        } else {
            XCTFail("Could not locate FILE headers for Alpha/Beta in the full output")
        }
    }
}
