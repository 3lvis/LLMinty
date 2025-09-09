import Foundation
import XCTest
@testable import llminty

enum TestSupport {
    // MARK: - File / CI helpers

    /// Locate repo root by walking up to Package.swift (starts from the file path of the caller).
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

    static func fixturesDir(file: String = #filePath) -> URL {
        projectRoot(file: file).appendingPathComponent("Tests/LLMintyTests/Fixtures")
    }

    static func fixtureURLIfExists(_ name: String) -> URL? {
        let u = fixturesDir().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Unzip with /usr/bin/unzip (common on macOS CI). Returns the top-level directory (or dest).
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

        let listing = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey])
        if listing.count == 1, (try? listing[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return listing[0]
        }
        return dest
    }

    /// Run the app in given directory and return minty.txt contents (used in some integration tests).
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

    /// Normalize text as production post-processing would (keeps one place to modify later).
    static func normalized(_ s: String) -> String {
        postProcessMinty(s)
    }

    /// A compact line-by-line diff snippet helper (returns nil if equal).
    static func diffLines(expected: String, actual: String, context: Int = 2) -> String? {
        let exp = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let act = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if exp == act { return nil }

        // naive diff: find first and last differing index
        let count = max(exp.count, act.count)
        var firstDiff: Int? = nil
        var lastDiff: Int? = nil
        for i in 0..<count {
            let e = i < exp.count ? exp[i] : nil
            let a = i < act.count ? act[i] : nil
            if e != a {
                if firstDiff == nil { firstDiff = i }
                lastDiff = i
            }
        }
        guard let first = firstDiff, let last = lastDiff else { return nil }
        let start = max(0, first - context)
        let end = min(count - 1, last + context)
        var out = [String]()
        for i in start...end {
            let e = i < exp.count ? exp[i] : "<missing>"
            let a = i < act.count ? act[i] : "<missing>"
            out.append(String(format: "%4d  - %s", i, e))
            out.append(String(format: "%4d  + %s", i, a))
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Canonicalization helpers (rendered Swift + JSON reducer)
extension TestSupport {
    // sentinel placeholder commonly used across tests
    static var sentinelPlaceholder: String { "/* elided-implemented; lines=<N>; h=<H> */" }

    // Normalize rendered Swift for deterministic comparisons:
    // - normalize newlines to '\n'
    // - trim trailing whitespace on every line (preserve leading indentation)
    // - replace sentinel `h=...` with `h=<H>` and `lines=...` with `lines=<N>`
    static func canonicalizeRenderedSwift(_ s: String) -> String {
        // Normalize newlines
        var out = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // Trim trailing whitespace on each line (preserve indentation)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        out = lines.map { rtrim(String($0)) }.joined(separator: "\n")

        // Replace "lines=<digits>" => "lines=<N>"
        out = replaceNumericSuffix(after: "lines=", in: out, placeholder: "lines=<N>")

        // Replace "h=<hex>" => "h=<H>"
        out = replaceHexSuffix(after: "h=", in: out, placeholder: "h=<H>")

        return out
    }

    // Canonicalize JSON reducer output & expectation:
    // - removes ALL whitespace outside of string literals (so formatting differences don't fail)
    // - normalizes whitespace *inside* /* ... */ comments to a single space
    // - preserves string literal contents exactly (including escaped characters)
    static func canonicalizeReducerOutput(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)

        var inString = false
        var escaped = false
        var inComment = false
        var prevWasSpaceInComment = false

        let scalars = Array(s.unicodeScalars)
        var i = 0

        func appendScalar(_ scalar: UnicodeScalar) {
            out.unicodeScalars.append(scalar)
        }

        while i < scalars.count {
            let ch = scalars[i]

            if inString {
                appendScalar(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if inComment {
                // detect end '*/'
                if ch == "*" && i + 1 < scalars.count && scalars[i + 1] == "/" {
                    appendScalar(ch)
                    appendScalar(scalars[i + 1])
                    i += 2
                    inComment = false
                    prevWasSpaceInComment = false
                    continue
                }
                // collapse whitespace in comment to single space
                if CharacterSet.whitespacesAndNewlines.contains(ch) {
                    if !prevWasSpaceInComment {
                        appendScalar(" ")
                        prevWasSpaceInComment = true
                    }
                } else {
                    appendScalar(ch)
                    prevWasSpaceInComment = false
                }
                i += 1
                continue
            }

            // not in string or comment
            if ch == "\"" {
                inString = true
                appendScalar(ch)
                i += 1
                continue
            }

            // start comment?
            if ch == "/" && i + 1 < scalars.count && scalars[i + 1] == "*" {
                inComment = true
                appendScalar(ch)
                appendScalar(scalars[i + 1])
                i += 2
                continue
            }

            // drop ALL whitespace outside strings & comments
            if CharacterSet.whitespacesAndNewlines.contains(ch) {
                i += 1
                continue
            }

            appendScalar(ch)
            i += 1
        }

        return out
    }

    // MARK: - low-level helpers used above

    private static func rtrim(_ s: String) -> String {
        var copy = s
        while let last = copy.last, last == " " || last == "\t" {
            copy.removeLast()
        }
        return copy
    }

    private static func replaceNumericSuffix(after prefix: String, in s: String, placeholder: String) -> String {
        // regex-based replacement is concise and safe for tests
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + "\\d+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: placeholder)
    }

    private static func replaceHexSuffix(after prefix: String, in s: String, placeholder: String) -> String {
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + "[0-9A-Fa-f]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: placeholder)
    }
}

// MARK: - Rendering helpers (wrappers around Renderer + decl extraction)
extension TestSupport {
    static func renderSwift(policy: Renderer.RenderPolicy, source: String) throws -> String {
        let raw = try Renderer().renderSwift(text: source, policy: policy)
        return canonicalizeRenderedSwift(raw)
    }

    static func renderFile(_ scored: ScoredFile, score: Double) throws -> String {
        let rendered = try Renderer().render(file: scored, score: score)
        return canonicalizeRenderedSwift(rendered.content)
    }

    /// Extract a full declaration snippet (from signaturePrefix through matching closing brace),
    /// returning canonicalized snippet or nil.
    static func extractDecl(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let raw = extractDeclRaw(fromRendered: rendered, signaturePrefix: signaturePrefix) else { return nil }
        return canonicalizeRenderedSwift(raw)
    }

    /// Like `extractDecl` but returns the raw (uncanonicalized) snippet.
    static func extractDeclRaw(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let sigRange = rendered.range(of: signaturePrefix) else { return nil }
        guard let openRange = rendered.range(of: "{", range: sigRange.upperBound..<rendered.endIndex) else { return nil }

        var depth = 0
        var i = openRange.lowerBound
        var endIndex: String.Index? = nil
        while i < rendered.endIndex {
            let ch = rendered[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = rendered.index(after: i)
                    break
                }
            }
            i = rendered.index(after: i)
        }
        guard let end = endIndex else { return nil }
        return String(rendered[sigRange.lowerBound..<end])
    }

    /// Extract the sentinel comment (canonicalized) for the declaration that starts at signaturePrefix.
    static func extractSentinelForDecl(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let decl = extractDecl(fromRendered: rendered, signaturePrefix: signaturePrefix) else { return nil }
        guard let start = decl.range(of: "/*") else { return nil }
        guard let end = decl.range(of: "*/", range: start.upperBound..<decl.endIndex) else { return nil }
        return String(decl[start.lowerBound...end.upperBound])
    }

    /// Extract the sentinel comment raw (no canonicalization) — used by numeric-sentinel tests.
    static func extractSentinelForDeclRaw(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let decl = extractDeclRaw(fromRendered: rendered, signaturePrefix: signaturePrefix) else { return nil }
        guard let start = decl.range(of: "/*") else { return nil }
        guard let end = decl.range(of: "*/", range: start.upperBound..<decl.endIndex) else { return nil }
        return String(decl[start.lowerBound...end.upperBound])
    }
}

// MARK: - Sentinel parsing helpers & assertions
extension TestSupport {
    /// Parse lines= and h= from a sentinel comment string like:
    /// "/* elided-implemented; lines=12; h=deadbeef12 */"
    /// Returns (lines, hash). Parsing uses plain string operations for resilience.
    static func parseLinesAndHashFromSentinel(_ sentinel: String) -> (lines: Int, hash: String) {
        var linesVal = -1
        if let r = sentinel.range(of: "lines=") {
            var i = r.upperBound
            var digits = ""
            while i < sentinel.endIndex, sentinel[i].isWholeNumber {
                digits.append(sentinel[i])
                i = sentinel.index(after: i)
            }
            if let n = Int(digits) { linesVal = n }
        }

        var hash = ""
        if let r2 = sentinel.range(of: "h=") {
            var i = r2.upperBound
            var hex = ""
            let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            while i < sentinel.endIndex {
                if let us = sentinel[i].unicodeScalars.first, hexChars.contains(us) {
                    hex.append(sentinel[i])
                    i = sentinel.index(after: i)
                } else {
                    break
                }
            }
            hash = hex
        }

        return (linesVal, hash)
    }

    /// Assert two rendered snippets are equal after canonicalization.
    static func assertRenderedEqual(_ got: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let g = canonicalizeRenderedSwift(got)
        let e = canonicalizeRenderedSwift(expected)
        XCTAssertEqual(g, e, """
        Rendered output did not match expected (canonicalized).
        --- GOT (canonical) ---
        \(g)
        --- EXPECTED (canonical) ---
        \(e)
        --- GOT (raw) ---
        \(got)
        --- EXPECTED (raw) ---
        \(expected)
        """, file: file, line: line)
    }

    /// Assert that reducer output and expected string are identical after canonicalization.
    /// This is a strict, deterministic comparison (no regex/contains) but robust to formatting.
    static func XCTAssertReducerEqual(_ got: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let g = canonicalizeReducerOutput(got)
        let e = canonicalizeReducerOutput(expected)
        XCTAssertEqual(g, e, """
        Reducer output did not match expected (canonicalized).
        --- GOT (canonical) ---
        \(g)
        --- EXPECTED (canonical) ---
        \(e)
        --- GOT (raw) ---
        \(got)
        --- EXPECTED (raw) ---
        \(expected)
        """, file: file, line: line)
    }

    /// Convenience to canonicalize expected small snippet (keeps existing test ergonomics).
    static func canonicalizeExpectedSnippet(_ s: String) -> String {
        return canonicalizeRenderedSwift(s)
    }
}
