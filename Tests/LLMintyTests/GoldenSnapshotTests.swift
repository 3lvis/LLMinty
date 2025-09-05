// Tests/LLMintyTests/GoldenSnapshotTests.swift
import XCTest
@testable import llminty

final class GoldenSnapshotTests: XCTestCase {

    private struct RegenSpec: Codable { var should_generate: Bool }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // GoldenSnapshotTests.swift
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private var zipURL: URL { fixturesDir.appendingPathComponent("LLMinty-nohidden.zip") }
    private var expectedURL: URL { fixturesDir.appendingPathComponent("expected_minty.txt") }
    private var regenURL: URL { fixturesDir.appendingPathComponent("regenerate_contract.json") }

    func testGoldenAgainstSnapshotFixtures() throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw XCTSkip("No Fixtures/LLMinty-nohidden.zip; skipping")
        }
        guard FileManager.default.fileExists(atPath: expectedURL.path) else {
            throw XCTSkip("No Fixtures/expected_minty.txt; run regeneration once.")
        }

        let actual = try runMintyOnZippedSnapshot(zipURL)
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)

        if actual != expected {
            let aLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
            let eLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
            let maxLines = min(aLines.count, eLines.count)
            var firstDiff = -1
            for i in 0..<maxLines where aLines[i] != eLines[i] { firstDiff = i; break }
            if firstDiff == -1, aLines.count != eLines.count { firstDiff = maxLines }
            let explain: String
            if firstDiff >= 0 {
                let e = firstDiff < eLines.count ? eLines[firstDiff] : "<EOF>"
                let a = firstDiff < aLines.count ? aLines[firstDiff] : "<EOF>"
                explain = """
                Golden mismatch.
                First difference at line \(firstDiff + 1):
                   EXPECTED: \(e)
                     ACTUAL: \(a)
                """
            } else {
                explain = "Golden mismatch."
            }
            XCTFail(explain)
        }
    }

    func testRegenerateExpectedAndContractIfRequested() throws {
        guard let data = try? Data(contentsOf: regenURL),
              let spec = try? JSONDecoder().decode(RegenSpec.self, from: data),
              spec.should_generate
        else {
            throw XCTSkip("No regenerate_contract.json with {\"should_generate\": true}; skipping regeneration.")
        }
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw XCTSkip("No Fixtures/LLMinty-nohidden.zip; cannot regenerate")
        }

        let actual = try runMintyOnZippedSnapshot(zipURL)
        try actual.write(to: expectedURL, atomically: true, encoding: .utf8)

        // Flip the flag back off.
        let turnedOff = RegenSpec(should_generate: false)
        let out = try JSONEncoder().encode(turnedOff)
        try out.write(to: regenURL)

        print("Regenerated expected_minty.txt; left contract_spec.json untouched; disabled regenerate flag.")
    }

    // MARK: - Shared helper used by ChecklistContractTests too

    func runMintyOnZippedSnapshot(_ zip: URL) throws -> String {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        // Unzip
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = [zip.path, "-d", tmpRoot.path]
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "Failed to unzip test fixture")

        // Pipeline: scan → analyze → score → order → render → post
        let fm = FileManager.default
        let root = tmpRoot
        let outputName = "minty.txt"

        let ignoreText = (try? String(contentsOf: root.appendingPathComponent(".mintyignore"), encoding: .utf8)) ?? ""
        let matcher = try IgnoreMatcher(
            builtInPatterns: BuiltInExcludes.defaultPatterns(outputFileName: outputName),
            userFileText: ignoreText
        )
        let scanner = FileScanner(root: root, matcher: matcher)
        let files = try scanner.scan()

        let analyzer = SwiftAnalyzer()
        let analyzed = try analyzer.analyze(files: files)

        let scoring = Scoring()
        let scored = scoring.score(analyzed: analyzed)

        let ordered = GraphCentrality.orderDependencyAware(scored)
        let renderer = Renderer()

        var parts: [String] = []
        parts.reserveCapacity(ordered.count * 2)
        for sf in ordered {
            let rf = try renderer.render(file: sf, score: sf.score)
            parts.append("FILE: \(rf.relativePath)")
            parts.append("")
            parts.append(rf.content)
        }
        let joined = parts.joined(separator: "\n")
        return postProcessMinty(joined)
    }
}
