import XCTest
@testable import llminty

final class LLMintyTests: XCTestCase {

    // End-to-end: builds a mini project, runs the app, checks minty.txt framing and ignore behavior.
    func testEndToEndRunCreatesMintyFile() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("llminty-int-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Project files
        let srcDir = dir.appendingPathComponent("src")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let aURL = srcDir.appendingPathComponent("A.swift")
        let bURL = srcDir.appendingPathComponent("B.swift")
        let notes = dir.appendingPathComponent("Notes.txt")
        let secretDir = dir.appendingPathComponent("Secret")
        try fm.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secretFile = secretDir.appendingPathComponent("hidden.txt")

        try "struct B {}".write(to: bURL, atomically: true, encoding: .utf8)
        try "struct A { let b = B() }".write(to: aURL, atomically: true, encoding: .utf8)
        try "hello\n\nworld".write(to: notes, atomically: true, encoding: .utf8)
        try "top secret".write(to: secretFile, atomically: true, encoding: .utf8)

        // .mintyignore to exclude Secret/
        let mintyIgnore = dir.appendingPathComponent(".mintyignore")
        try "Secret/\n".write(to: mintyIgnore, atomically: true, encoding: .utf8)

        // Run app in that directory
        let cwdBefore = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(dir.path))
        defer { _ = fm.changeCurrentDirectoryPath(cwdBefore) }

        try LLMintyApp().run()

        // Assert output exists and has expected structure
        let outURL = dir.appendingPathComponent("minty.txt")
        XCTAssertTrue(fm.fileExists(atPath: outURL.path))

        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains("FILE: src/B.swift"))
        XCTAssertTrue(text.contains("FILE: src/A.swift"))
        XCTAssertTrue(text.contains("FILE: Notes.txt"))
        // Should not include Secret files
        XCTAssertFalse(text.contains("Secret/hidden.txt"))
    }

    // Compaction policy: keep exactly one blank line after each FILE header, drop others,
    // but allow a single terminal blank line (trailing newline in the file).
    func testKeepsOneBlankAfterHeadersAndDropsOthers() {
        let input = """
        FILE: a.swift
        
        
        import Foundation
        
        struct A {}
        
        // END
        FILE: b.txt
        
        
        line one
        
        line two
        
        // END
        """

        let compact = postProcessMinty(input)

        // 1) No triple newlines remain
        XCTAssertFalse(compact.contains("\n\n\n"))

        // 2) There should be exactly one blank line after each FILE header
        let lines = compact.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var headerIndices: [Int] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("FILE: ") {
            headerIndices.append(i)
        }
        XCTAssertEqual(headerIndices.count, 2, "Should find exactly two FILE headers")
        for idx in headerIndices {
            XCTAssertTrue(idx + 1 < lines.count)
            XCTAssertEqual(lines[idx + 1], "", "There must be exactly one blank line after FILE header")
        }

        // 3) Any blank-only line must be either:
        //    (a) directly after a FILE header, or
        //    (b) the final terminal blank from the trailing newline
        for i in 0..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                let isTerminalBlank = (i == lines.count - 1) // allow single trailing newline
                let isAfterHeader = (i > 0 && lines[i - 1].hasPrefix("FILE: "))
                XCTAssertTrue(isAfterHeader || isTerminalBlank,
                              "Blank line found that is not directly after a FILE header nor the terminal trailing newline")
            }
        }

        // 4) Trailing newline preserved
        XCTAssertTrue(compact.hasSuffix("\n"))
    }
}
