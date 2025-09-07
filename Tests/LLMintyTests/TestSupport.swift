// Tests/LLMintyTests/TestSupport.swift
import Foundation
import XCTest
@testable import llminty

enum TestSupport {
    // Locate repo root by walking up to Package.swift
    static func projectRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<1024 {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            let next = url.deletingLastPathComponent()
            if next.path == url.path { break }
            url = next
        }
        fatalError("Could not locate Package.swift from \(file)")
    }

    static func fixturesDir() -> URL {
        projectRoot().appendingPathComponent("Tests/LLMintyTests/Fixtures")
    }

    static func fixtureURLIfExists(_ name: String) -> URL? {
        let u = fixturesDir().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // Unzip with /usr/bin/unzip (available on macOS CI)
    @discardableResult
    static func unzip(_ zip: URL, to dest: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", zip.path, "-d", dest.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "unzip", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: out])
        }

        // If a single top-level directory was produced, return it; else dest
        let listing = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey])
        if listing.count == 1, (try? listing[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return listing[0]
        }
        return dest
    }

    // Run the app in given directory and return minty.txt contents
    static func runLLMinty(in dir: URL) throws -> String {
        let fm = FileManager.default
        let prev = fm.currentDirectoryPath
        fm.changeCurrentDirectoryPath(dir.path)
        defer { fm.changeCurrentDirectoryPath(prev) }

        try? fm.removeItem(at: dir.appendingPathComponent("minty.txt"))
        try LLMintyApp().run()
        let outURL = dir.appendingPathComponent("minty.txt")
        return try String(contentsOf: outURL, encoding: .utf8)
    }

    // Ensure framing is normalized the same way production does
    static func normalized(_ s: String) -> String {
        postProcessMinty(s)
    }

    // Simple line diff with small context; returns nil if equal
    static func diffLines(expected: String, actual: String, context: Int = 2) -> String? {
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let n = max(e.count, a.count)
        for i in 0..<n {
            let el = i < e.count ? e[i] : "∅"
            let al = i < a.count ? a[i] : "∅"
            if el != al {
                var out: [String] = []
                out.append("First difference at line \(i+1):")
                let start = max(0, i - context), end = min(n - 1, i + context)
                for j in start...end {
                    let mark = (j == i) ? ">>" : "  "
                    let le = j < e.count ? e[j] : "∅"
                    let la = j < a.count ? a[j] : "∅"
                    out.append("\(mark) EXPECTED: \(le)")
                    out.append("\(mark)   ACTUAL: \(la)")
                }
                return out.joined(separator: "\n")
            }
        }
        return nil
    }

    // Parse minty into { "path" : "content" }
    static func parseMintySections(_ s: String) -> [String: String] {
        var dict: [String: String] = [:]
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var current: String?
        var buf: [String] = []
        func flush() {
            if let k = current {
                dict[k] = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            current = nil
            buf.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if line.hasPrefix("FILE: ") {
                flush()
                let path = String(line.dropFirst("FILE: ".count)).trimmingCharacters(in: .whitespaces)
                current = path
                continue
            }
            if current != nil { buf.append(line) }
        }
        flush()
        return dict
    }

    // MARK: - Contracts

    struct ContractSpec: Codable, Equatable {
        var version: Int
        var must_include_files: [String]
        var must_have_tokens: [String: [String]]
    }

    struct RegenerateConfig: Codable, Equatable {
        var should_generate: Bool
    }

    static func defaultContract() -> ContractSpec {
        ContractSpec(
            version: 1,
            must_include_files: [
                "Sources/llminty/IgnoreMatcher.swift",
                "Sources/llminty/FileScanner.swift",
                "Sources/llminty/SwiftAnalyzer.swift",
                "Sources/llminty/Rendering.swift",
                "Sources/llminty/GraphCentrality.swift",
                "Sources/llminty/Scoring.swift",
                "Sources/llminty/JSONReducer.swift",
                "Sources/llminty/App.swift",
                "Sources/llminty/main.swift",
                "Package.swift"
            ],
            must_have_tokens: [
                "Sources/llminty/IgnoreMatcher.swift": [
                    "parse(line:", "func isIgnored(", "matchFrom("
                ],
                "Sources/llminty/FileScanner.swift": [
                    "func scan()", "seemsBinary(", "relativePath(from", "path(replacingBase"
                ],
                "Sources/llminty/SwiftAnalyzer.swift": [
                    "final class SwiftAnalyzer", "func analyze(", "IdentifierTypeSyntax", "MemberTypeSyntax", "TokenSyntax"
                ],
                "Sources/llminty/Rendering.swift": [
                    "SwiftPolicy", "func policyFor(", "func renderSwift(", "lightlyCondenseWhitespace(", "compactText("
                ],
                "Sources/llminty/GraphCentrality.swift": [
                    "static func pageRank", "orderDependencyAware("
                ],
                "Sources/llminty/Scoring.swift": [
                    "func score("
                ],
                "Sources/llminty/JSONReducer.swift": [
                    "reduceJSONPreservingStructure(", "reduceArray(", "reduceDict(", "stringify("
                ],
                "Sources/llminty/App.swift": [
                    "BuiltInExcludes", "LLMintyApp", "func run(", "postProcessMinty("
                ]
            ]
        )
    }

    static func loadContractSpecIfAny() -> ContractSpec? {
        guard let u = fixtureURLIfExists("contract_spec.json"),
              let data = try? Data(contentsOf: u)
        else { return nil }
        return try? JSONDecoder().decode(ContractSpec.self, from: data)
    }

    static func saveContractSpec(_ spec: ContractSpec) throws {
        let url = fixturesDir().appendingPathComponent("contract_spec.json")
        let data = try JSONEncoder.withPretty.encode(spec)
        try data.write(to: url, options: .atomic)
    }

    static func loadRegenerateConfig() -> RegenerateConfig? {
        guard let u = fixtureURLIfExists("regenerate_contract.json"),
              let data = try? Data(contentsOf: u)
        else { return nil }
        return try? JSONDecoder().decode(RegenerateConfig.self, from: data)
    }

    static func saveRegenerateConfig(_ cfg: RegenerateConfig) throws {
        let url = fixturesDir().appendingPathComponent("regenerate_contract.json")
        let data = try JSONEncoder.withPretty.encode(cfg)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var withPretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }
}

enum TestTemplateAssert {

    // MARK: Placeholders

    /// Matches just the rich sentinel comment (no braces).
    /// Example in source: `{ /* elided-implemented; lines=1; h=deadbeef12 */ }`
    static let sentinelRegex =
    #"/\*\s*elided-implemented;\s*lines=\d+;\s*h=[0-9a-f]{8,12}\s*\*/"#

    /// Matches just the empty-block comment (no braces).
    /// Example in source: `{ /* empty */ }`
    static let emptyRegex = #"/\*\s*empty\s*\*/"#

    /// A small non-greedy "match anything".
    static let anyRegex = #"[\s\S]*?"#

    // MARK: Template compiler

    /// Builds a tolerant regex from a human-friendly expected template.
    ///
    /// Replaces:
    /// - `«SENTINEL»` → rich sentinel regex (comment only)
    /// - `«EMPTY»` → empty comment regex (comment only)
    /// - `«ANY»` → any content (non-greedy)
    ///
    /// Collapses *all* whitespace in the template to `\s*` so spacing (including
    /// presence/absence of spaces) is flexible across renderers/formatters.
    static func regexFromTemplate(_ template: String) -> String {
        // Protect placeholders with easy-to-find sentinels
        let temp = template
            .replacingOccurrences(of: "«SENTINEL»", with: "__SENTINEL__")
            .replacingOccurrences(of: "«EMPTY»", with: "__EMPTY__")
            .replacingOccurrences(of: "«ANY»", with: "__ANY__")

        // Escape the rest so the template is literal text
        let escaped = NSRegularExpression.escapedPattern(for: temp)

        // Make all whitespace flexible (including newlines)
        let range = NSRange(escaped.startIndex..., in: escaped)
        let whitespaceFlexible = try! NSRegularExpression(
            pattern: #"(?:\s|\R)+"#,
            options: [.dotMatchesLineSeparators]
        ).stringByReplacingMatches(in: escaped, options: [], range: range, withTemplate: #"(?:\s|\R)*"#)

        // Expand placeholders back into regex fragments
        return whitespaceFlexible
            .replacingOccurrences(of: "__SENTINEL__", with: TestTemplateAssert.sentinelRegex)
            .replacingOccurrences(of: "__EMPTY__", with: TestTemplateAssert.emptyRegex)
            .replacingOccurrences(of: "__ANY__", with: #"(?s:.*?)"#)
    }
}

// MARK: - XCTestCase extensions

extension XCTestCase {

    func assertRenderContainsTemplate(
        source: String,
        policy: Renderer.RenderPolicy,
        expectedTemplate: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try Renderer().renderSwift(text: source, policy: policy)
        let pattern = TestTemplateAssert.regexFromTemplate(expectedTemplate)
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(result.startIndex..., in: result)
        let matched = regex.firstMatch(in: result, range: range) != nil

        XCTAssertTrue(
            matched,
            """
            🔎 Template did not match rendered output.
            
            — Source (input) —
            \(source)
            
            — Expected shape (template) —
            \(expectedTemplate)
            
            — Rendered (actual) —
            \(result)
            """,
            file: file,
            line: line
        )
    }

    func assertRenderNotMatchTemplate(
        source: String,
        policy: Renderer.RenderPolicy,
        unexpectedTemplate: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try Renderer().renderSwift(text: source, policy: policy)
        let pattern = TestTemplateAssert.regexFromTemplate(unexpectedTemplate)
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(result.startIndex..., in: result)
        let matched = regex.firstMatch(in: result, range: range) != nil

        XCTAssertFalse(
            matched,
            """
            🔎 Unexpected template matched rendered output.
            
            — Source (input) —
            \(source)
            
            — This template should NOT match —
            \(unexpectedTemplate)
            
            — Rendered (actual) —
            \(result)
            """,
            file: file,
            line: line
        )
    }

    func assertTextMatchesTemplate(
        actual: String,
        expectedTemplate: String,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pattern = TestTemplateAssert.regexFromTemplate(expectedTemplate)
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(actual.startIndex..., in: actual)
        let matched = regex.firstMatch(in: actual, range: range) != nil

        XCTAssertTrue(
            matched,
            """
            🔎 Template did not match text.
            
            — Source (input) —
            \(source)
            
            — Expected shape (template) —
            \(expectedTemplate)
            
            — Actual text —
            \(actual)
            """,
            file: file,
            line: line
        )
    }

    func assertTextNotMatchTemplate(
        actual: String,
        unexpectedTemplate: String,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pattern = TestTemplateAssert.regexFromTemplate(unexpectedTemplate)
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(actual.startIndex..., in: actual)
        let matched = regex.firstMatch(in: actual, range: range) != nil

        XCTAssertFalse(
            matched,
            """
            🔎 Unexpected template matched text.
            
            — Source (input) —
            \(source)
            
            — This template should NOT match —
            \(unexpectedTemplate)
            
            — Actual text —
            \(actual)
            """,
            file: file,
            line: line
        )
    }
}
