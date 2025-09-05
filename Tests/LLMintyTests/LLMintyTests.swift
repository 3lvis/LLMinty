
import XCTest
@testable import llminty

final class LLMintyTests: XCTestCase {
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
}
