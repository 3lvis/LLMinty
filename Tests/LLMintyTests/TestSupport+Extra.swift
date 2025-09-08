// Tests/TestSupport.swift
import Foundation
import XCTest
@testable import llminty

extension TestSupport {
    // MARK: - Canonicalization (no-regex)

    /// Normalize rendered Swift for deterministic comparisons:
    /// - normalize newlines to '\n'
    /// - trim trailing whitespace on every line (preserve leading indentation)
    /// - replace sentinel `h=...` with `h=<H>` and `lines=...` with `lines=<N>`
    /// Implemented with plain String operations (no regex).
    static func canonicalizeRenderedSwift(_ s: String) -> String {
        // Normalize newlines
        var out = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // Trim **trailing** whitespace on each line (preserve indentation)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        out = lines.map { rtrim(String($0)) }.joined(separator: "\n")

        // Replace "lines=<digits>" => "lines=<N>"
        out = replaceNumericSuffix(after: "lines=", in: out, placeholder: "lines=<N>")

        // Replace "h=<hex>" => "h=<H>"
        out = replaceHexSuffix(after: "h=", in: out, placeholder: "h=<H>")

        return out
    }

    private static func rtrim(_ s: String) -> String {
        var copy = s
        while let last = copy.last, last == " " || last == "\t" {
            copy.removeLast()
        }
        return copy
    }

    private static func replaceNumericSuffix(after prefix: String, in s: String, placeholder: String) -> String {
        var cur = s
        var searchStart = cur.startIndex
        while let range = cur.range(of: prefix, options: [], range: searchStart..<cur.endIndex) {
            var i = range.upperBound
            let digitsStart = i
            while i < cur.endIndex, cur[i].isNumber {
                i = cur.index(after: i)
            }
            let digitsEnd = i
            if digitsStart == digitsEnd {
                searchStart = range.upperBound
                continue
            }
            let replaceRange = range.lowerBound..<digitsEnd
            cur.replaceSubrange(replaceRange, with: placeholder)
            searchStart = cur.index(range.lowerBound, offsetBy: placeholder.count)
        }
        return cur
    }

    private static func replaceHexSuffix(after prefix: String, in s: String, placeholder: String) -> String {
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var cur = s
        var searchStart = cur.startIndex
        while let range = cur.range(of: prefix, options: [], range: searchStart..<cur.endIndex) {
            var i = range.upperBound
            let hexStart = i
            while i < cur.endIndex {
                let us = cur[i].unicodeScalars.first!
                if hexChars.contains(us) {
                    i = cur.index(after: i)
                } else {
                    break
                }
            }
            let hexEnd = i
            if hexStart == hexEnd {
                searchStart = range.upperBound
                continue
            }
            let replaceRange = range.lowerBound..<hexEnd
            cur.replaceSubrange(replaceRange, with: placeholder)
            searchStart = cur.index(range.lowerBound, offsetBy: placeholder.count)
        }
        return cur
    }

    // MARK: - Helpers used by tests

    static func canonicalizeExpectedSnippet(_ s: String) -> String {
        return canonicalizeRenderedSwift(s)
    }

    static var sentinelPlaceholder: String { "/* elided-implemented; lines=<N>; h=<H> */" }

    static func renderSwift(policy: Renderer.RenderPolicy, source: String) throws -> String {
        let raw = try Renderer().renderSwift(text: source, policy: policy)
        return canonicalizeRenderedSwift(raw)
    }

    static func renderFile(_ scored: ScoredFile, score: Double) throws -> String {
        let rendered = try Renderer().render(file: scored, score: score)
        return canonicalizeRenderedSwift(rendered.content)
    }

    /// Extract a full declaration snippet (from signaturePrefix through matching closing brace).
    /// Returns canonicalized snippet or nil.
    static func extractDecl(fromRendered rendered: String, signaturePrefix: String) -> String? {
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
        let rawSnippet = String(rendered[sigRange.lowerBound..<end])
        return canonicalizeRenderedSwift(rawSnippet)
    }

    /// Like `extractDecl` but returns the raw (uncanonicalized) snippet.
    /// Useful for tests that need to parse numeric/hex sentinel values.
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

    /// Extract the sentinel comment (the `/* elided-implemented; ... */`) for the declaration that starts at signaturePrefix.
    /// Uses canonicalized extraction (for most tests).
    static func extractSentinelForDecl(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let decl = extractDecl(fromRendered: rendered, signaturePrefix: signaturePrefix) else { return nil }
        guard let start = decl.range(of: "/*") else { return nil }
        guard let end = decl.range(of: "*/", range: start.upperBound..<decl.endIndex) else { return nil }
        return String(decl[start.lowerBound...end.upperBound])
    }

    /// Extract sentinel raw (no canonicalization) — used by the numeric sentinel test.
    static func extractSentinelForDeclRaw(fromRendered rendered: String, signaturePrefix: String) -> String? {
        guard let decl = extractDeclRaw(fromRendered: rendered, signaturePrefix: signaturePrefix) else { return nil }
        guard let start = decl.range(of: "/*") else { return nil }
        guard let end = decl.range(of: "*/", range: start.upperBound..<decl.endIndex) else { return nil }
        return String(decl[start.lowerBound...end.upperBound])
    }

    /// Parse lines= and h= from a sentinel comment string like:
    /// "/* elided-implemented; lines=12; h=deadbeef12 */"
    /// Returns (lines, hash). Parsing uses plain string operations.
    static func parseLinesAndHashFromSentinel(_ sentinel: String) -> (lines: Int, hash: String) {
        var linesVal = -1
        if let r = sentinel.range(of: "lines=") {
            var i = r.upperBound
            var digits = ""
            while i < sentinel.endIndex, sentinel[i].isNumber {
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
}
