// Tests/LLMintyTests/GoldenSnapshotTests.swift
import XCTest
@testable import llminty

final class GoldenSnapshotTests: XCTestCase {

    // MARK: - Paths & discovery

    /// Repo root from this source file (works in SPM + Xcode).
    private func repoRoot(_ file: StaticString = #filePath) -> URL {
        return URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // .../Tests/LLMintyTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Fixtures directory resolution with env override, #file anchor, and repo-root fallback.
    private func fixturesDir() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["LLMINTY_FIXTURES_DIR"], !override.isEmpty {
            let u = URL(fileURLWithPath: override, isDirectory: true)
            if fm.fileExists(atPath: u.path) { return u }
        }
        // #file anchored
        let byFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()                    // .../Tests/LLMintyTests
            .appendingPathComponent("Fixtures", isDirectory: true)
        if fm.fileExists(atPath: byFile.path) { return byFile }

        // repo-root fallback: ./Tests/LLMintyTests/Fixtures
        let byRoot = repoRoot()
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("LLMintyTests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
        return byRoot
    }

    private func fixturesPath(_ name: String) -> URL {
        fixturesDir().appendingPathComponent(name)
    }

    // MARK: - Models

    private struct RegenSpec: Codable { var should_generate: Bool }

    // MARK: - Tests

    func testGoldenAgainstSnapshotFixtures() throws {
        let fm = FileManager.default
        let fixtures = fixturesDir()
        let zipURL = fixtures.appendingPathComponent("LLMinty-nohidden.zip")
        let expectedURL = fixtures.appendingPathComponent("expected_minty.txt")

        // Helpful diagnostics so you can see the paths it used.
        print("📦 Fixtures dir:", fixtures.path)

        guard fm.fileExists(atPath: zipURL.path) else {
            throw XCTSkip("No \(zipURL.lastPathComponent) at \(zipURL.path); skipping")
        }
        guard fm.fileExists(atPath: expectedURL.path) else {
            throw XCTSkip("No expected_minty.txt at \(expectedURL.path); run regeneration once.")
        }

        let actual = try runMintyOnZippedSnapshot(zipURL)
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)

        if actual != expected {
            // Point to first differing line to make diffs actionable.
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
        let fm = FileManager.default
        let fixtures = fixturesDir()
        let flagURL: URL = {
            // Allow override for custom setups.
            if let override = ProcessInfo.processInfo.environment["LLMINTY_REGENERATE_FLAG_PATH"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            // Default: Tests/LLMintyTests/Fixtures/regenerate_contract.json
            return fixtures.appendingPathComponent("regenerate_contract.json")
        }()

        print("🧾 Looking for regenerate flag at:", flagURL.path)

        // Read the flag; skip if absent or not true.
        guard
            let data = try? Data(contentsOf: flagURL),
            var spec = try? JSONDecoder().decode(RegenSpec.self, from: data),
            spec.should_generate == true
        else {
            throw XCTSkip("No regenerate_contract.json with {\"should_generate\": true} at \(flagURL.path); skipping regeneration.")
        }

        // Always flip back to false after we *accept* the flag.
        defer {
            spec.should_generate = false
            if let out = try? JSONEncoder().encode(spec) {
                do {
                    try out.write(to: flagURL, options: [.atomic])
                    print("🔁 Flipped regenerate flag back to false at:", flagURL.path)
                } catch {
                    // Non-fatal for the test outcome, but visible.
                    fputs("WARN: Failed to write \(flagURL.path): \(error)\n", stderr)
                }
            } else {
                fputs("WARN: Failed to encode flipped flag for \(flagURL.path)\n", stderr)
            }
        }

        // Need the zipped fixture to regenerate.
        let zipURL = fixtures.appendingPathComponent("LLMinty-nohidden.zip")
        guard fm.fileExists(atPath: zipURL.path) else {
            throw XCTSkip("No \(zipURL.lastPathComponent) at \(zipURL.path); cannot regenerate")
        }
        let expectedURL = fixtures.appendingPathComponent("expected_minty.txt")

        // Regenerate expected snapshot from the zipped fixture repo.
        let actual = try runMintyOnZippedSnapshot(zipURL)
        try actual.write(to: expectedURL, atomically: true, encoding: .utf8)

        print("✅ Regenerated expected_minty.txt at:", expectedURL.path)
    }

    // MARK: - Pipeline used by both tests

    func runMintyOnZippedSnapshot(_ zip: URL) throws -> String {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        // Unzip fixture using /usr/bin/unzip (portable on macOS runners).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = [zip.path, "-d", tmpRoot.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "Failed to unzip test fixture")

        // Build ignore matcher (uses same built-ins as app).
        let outputName = "minty.txt"
        let ignoreText = (try? String(contentsOf: tmpRoot.appendingPathComponent(".mintyignore"), encoding: .utf8)) ?? ""
        let matcher = try IgnoreMatcher(
            builtInPatterns: BuiltInExcludes.defaultPatterns(outputFileName: outputName),
            userFileText: ignoreText
        )

        // Scan repo contents.
        let files = try FileScanner(root: tmpRoot, matcher: matcher).scan()

        // Analyze Swift files.
        let analyzer = SwiftAnalyzer()
        var analyzed = try analyzer.analyze(files: files.filter { $0.kind == .swift })

        // Attach non-Swift files so scoring+rendering sees them.
        for f in files where f.kind != .swift {
            let text: String
            switch f.kind {
            case .json, .text, .unknown:
                text = (try? String(contentsOf: f.absoluteURL, encoding: .utf8)) ?? ""
            case .binary:
                text = ""
            case .swift:
                continue
            }
            analyzed.append(
                AnalyzedFile(
                    file: f,
                    text: text,
                    declaredTypes: [],
                    publicAPIScoreRaw: 0,
                    referencedTypes: [:],
                    complexity: 0,
                    isEntrypoint: false,
                    outgoingFileDeps: [],
                    inboundRefCount: 0
                )
            )
        }

        // Compute inbound references to mirror app behavior.
        var inbound: [String: Int] = [:]
        for a in analyzed { for dep in a.outgoingFileDeps { inbound[dep, default: 0] += 1 } }
        for i in analyzed.indices {
            analyzed[i].inboundRefCount = inbound[analyzed[i].file.relativePath] ?? 0
        }

        // Score, order, render.
        let scored = Scoring().score(analyzed: analyzed)
        let ordered = GraphCentrality.orderDependencyAware(scored)
        let renderer = Renderer()

        var parts: [String] = []
        parts.reserveCapacity(ordered.count * 2)
        for sf in ordered {
            let rf = try renderer.render(file: sf, score: sf.score)
            parts.append("FILE: \(rf.relativePath)")
            parts.append("") // exactly one blank after header
            parts.append(rf.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let joined = parts.joined(separator: "\n")

        // Match app’s final framing: drop extra blanks, ensure trailing newline.
        return postProcessMinty(joined)
    }
}
