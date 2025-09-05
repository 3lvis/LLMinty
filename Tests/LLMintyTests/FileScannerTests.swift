// Tests/LLMintyTests/FileScannerTests.swift
import XCTest
@testable import llminty

final class FileScannerTests: XCTestCase {
    func testScanningKindsAndIgnores() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Create files
        let swiftURL = tmp.appendingPathComponent("A.swift")
        let jsonURL  = tmp.appendingPathComponent("config.json")
        let textURL  = tmp.appendingPathComponent("Notes.txt")
        let binURL   = tmp.appendingPathComponent("bin.bin")
        let gitDir   = tmp.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: false)

        try "struct A {}".write(to: swiftURL, atomically: true, encoding: .utf8)
        try "{\"a\":1}".write(to: jsonURL, atomically: true, encoding: .utf8)
        try "hello\n\nworld\n".write(to: textURL, atomically: true, encoding: .utf8)
        // binary (contains NUL)
        let binData = Data([0x00, 0xFF, 0x01, 0x02])
        try binData.write(to: binURL)

        let builtIns = BuiltInExcludes.defaultPatterns(outputFileName: "minty.txt")
        let matcher = try IgnoreMatcher(builtInPatterns: builtIns, userFileText: "")
        let scanner = FileScanner(root: tmp, matcher: matcher)
        let results = try scanner.scan()

        // .git should be ignored and skipped (ensure nothing under a .git component)
        XCTAssertFalse(results.contains(where: {
            URL(fileURLWithPath: $0.relativePath).pathComponents.contains(".git")
        }))

        // Ensure kinds are detected (match by basename to avoid absolute/relative path variance)
        let kindsByBasename = Dictionary(uniqueKeysWithValues: results.map {
            (URL(fileURLWithPath: $0.relativePath).lastPathComponent, $0.kind)
        })
        XCTAssertEqual(kindsByBasename["A.swift"], .swift)
        XCTAssertEqual(kindsByBasename["config.json"], .json)
        XCTAssertEqual(kindsByBasename["Notes.txt"], .text)

        // bin.bin should be ignored by built-ins (*.bin)
        XCTAssertFalse(results.contains(where: {
            URL(fileURLWithPath: $0.relativePath).lastPathComponent == "bin.bin"
        }))
    }
}
