import Foundation
import SwiftParser
import SwiftSyntax

struct RenderedFile {
    let relativePath: String
    let content: String
}

final class Renderer {

    func render(file: ScoredFile, score: Double) throws -> RenderedFile {
        switch file.analyzed.file.kind {
        case .swift:
            let policy = policyFor(score: score)
            let content = try renderSwift(text: file.analyzed.text, policy: policy)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: content)

        case .json:
            let reduced = JSONReducer.reduceJSONPreservingStructure(text: file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: reduced)

        case .text, .unknown:
            let compact = compactText(file.analyzed.text)
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: compact)

        case .binary:
            let size = file.analyzed.file.size
            let type = (file.analyzed.file.relativePath as NSString).pathExtension.lowercased()
            let placeholder = "/* binary \(type.isEmpty ? "file" : type) — \(size) bytes (omitted) */\n"
            return RenderedFile(relativePath: file.analyzed.file.relativePath, content: placeholder)
        }
    }

    // MARK: - Text compaction

    /// For .text / .unknown: trim trailing spaces per line, collapse runs of blank lines to a single blank.
    private func compactText(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(s.count / 24)
        var lastBlank = false
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            if isBlank {
                if !lastBlank { out.append("") }
                lastBlank = true
            } else {
                out.append(line)
                lastBlank = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// For Swift bodies we sometimes want a gentler pass.
    private func lightlyCondenseWhitespace(_ s: String) -> String {
        var out: [String] = []
        out.reserveCapacity(s.count / 24)
        var lastBlank = false
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            if isBlank {
                if !lastBlank { out.append("") }
                lastBlank = true
            } else {
                out.append(line)
                lastBlank = false
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Swift policies

    enum SwiftPolicy {
        case keepAllBodiesLightlyCondensed            // s ≥ 0.75
        case keepPublicBodiesElideOthers              // 0.50 ≤ s < 0.75
        case keepOneBodyPerTypeElideRest              // 0.25 ≤ s < 0.50
        case signaturesOnly                           // s < 0.25
    }

    func policyFor(score: Double) -> SwiftPolicy {
        if score >= 0.75 { return .keepAllBodiesLightlyCondensed }
        if score >= 0.50 { return .keepPublicBodiesElideOthers }
        if score >= 0.25 { return .keepOneBodyPerTypeElideRest }
        return .signaturesOnly
    }

    // MARK: - Swift rendering (mechanical elision)

    /// Mechanically elide Swift bodies according to the policy (generic & deterministic).
    /// - Keeps short bodies everywhere (thresholds below), and keeps the shortest body per type in the 0.25–0.50 bin.
    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        struct Fn {
            let range: Range<String.Index>      // full { ... } including braces
            let bodyRange: Range<String.Index>  // interior text between braces
            let isPublic: Bool
            let typePath: [String]              // nesting types
            let lines: Int
        }

        let src = text

        // Total lines (for small-file exemption)
        let totalLines: Int = {
            var n = 1
            for ch in src where ch == "\n" { n += 1 }
            return n
        }()

        // --- thresholds (mechanical) ---
        var shortKeepAllPolicies = 12
        var shortKeepInSignOnly  = 5
        if totalLines <= 120 {
            // small-file exemption: be a bit more lenient
            shortKeepAllPolicies = max(shortKeepAllPolicies, 16)
            shortKeepInSignOnly  = max(shortKeepInSignOnly, 8)
        }

        // Scan once; maintain a type context stack using matched braces.
        var fns: [Fn] = []
        fns.reserveCapacity(64)

        struct TypeCtx { let name: String; let end: String.Index }
        var typeCtx: [TypeCtx] = []

        @inline(__always)
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        func skipSpaces(_ i: String.Index) -> String.Index {
            var j = i
            while j < src.endIndex, src[j].isWhitespace { j = src.index(after: j) }
            return j
        }

        func readWord(_ i: String.Index) -> (String, String.Index) {
            var j = i
            var w = ""
            while j < src.endIndex, isIdent(src[j]) {
                w.append(src[j])
                j = src.index(after: j)
            }
            return (w, j)
        }

        func matchBraces(from start: String.Index) -> String.Index? {
            var depth = 0
            var j = start
            while j < src.endIndex {
                let ch = src[j]
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return j }
                }
                j = src.index(after: j)
            }
            return nil
        }

        func lineCount(in r: Range<String.Index>) -> Int {
            var n = 1
            var j = r.lowerBound
            while j < r.upperBound {
                if src[j] == "\n" { n += 1 }
                j = src.index(after: j)
            }
            return n
        }

        var i = src.startIndex
        while i < src.endIndex {
            // pop expired type contexts
            while let last = typeCtx.last, i >= last.end { _ = typeCtx.popLast() }

            if src[i].isWhitespace {
                i = src.index(after: i); continue
            }

            // gather modifiers
            var j = i
            var modifiers: [String] = []
            let knownMods: Set<String> = ["public","open","internal","private","fileprivate","static","class","final","mutating","nonmutating","override"]
            while j < src.endIndex {
                j = skipSpaces(j)
                let (w, afterW) = readWord(j)
                if w.isEmpty || !knownMods.contains(w) { break }
                modifiers.append(w)
                j = afterW
            }

            // keyword after modifiers
            let (kw, afterKW) = readWord(j)
            if kw == "struct" || kw == "class" || kw == "enum" || kw == "protocol" {
                var nameStart = afterKW
                nameStart = skipSpaces(nameStart)
                let (name, afterName) = readWord(nameStart)

                var k = afterName
                while k < src.endIndex, src[k] != "{" { k = src.index(after: k) }
                if k < src.endIndex, src[k] == "{", let end = matchBraces(from: k) {
                    let endPlusOne = src.index(after: end)
                    typeCtx.append(.init(name: name.isEmpty ? "<anon>" : name, end: endPlusOne))
                    i = src.index(after: k)
                    continue
                }
                i = afterName
                continue
            }

            if kw == "func" || kw == "init" || kw == "subscript" {
                var k = afterKW
                while k < src.endIndex, src[k] != "{" && src[k] != "\n" { k = src.index(after: k) }
                if k < src.endIndex, src[k] == "{", let end = matchBraces(from: k) {
                    let isPub = modifiers.contains("public") || modifiers.contains("open")
                    let endPlusOne = src.index(after: end)
                    let fullRange: Range<String.Index> = k..<endPlusOne
                    let bodyStart = src.index(after: k)
                    let bodyRange: Range<String.Index> = bodyStart..<end
                    let lines = lineCount(in: fullRange)
                    let typePath = typeCtx.map { $0.name }
                    fns.append(.init(range: fullRange, bodyRange: bodyRange, isPublic: isPub, typePath: typePath, lines: lines))
                    i = endPlusOne
                    continue
                }
            }

            i = src.index(after: i)
        }

        // --- Decide what to elide ---
        var toElide: [Range<String.Index>] = []
        toElide.reserveCapacity(fns.count)

        switch policy {
        case .keepAllBodiesLightlyCondensed:
            // keep all
            break

        case .keepPublicBodiesElideOthers:
            for fn in fns {
                if fn.isPublic { continue }
                if fn.lines <= shortKeepAllPolicies { continue }
                toElide.append(fn.bodyRange)
            }

        case .keepOneBodyPerTypeElideRest:
            // keep shortest per type path
            var shortest: [String: Fn] = [:]
            shortest.reserveCapacity(16)
            func key(_ path: [String]) -> String { path.joined(separator: ".") }
            for fn in fns {
                let k = key(fn.typePath)
                if let prev = shortest[k] {
                    if fn.lines < prev.lines { shortest[k] = fn }
                } else {
                    shortest[k] = fn
                }
            }
            for fn in fns {
                if let chosen = shortest[key(fn.typePath)], chosen.range == fn.range {
                    // keep the chosen one
                } else {
                    toElide.append(fn.bodyRange)
                }
            }

        case .signaturesOnly:
            for fn in fns {
                if fn.lines <= shortKeepInSignOnly { continue }
                toElide.append(fn.bodyRange)
            }
        }

        // --- Apply replacements (body -> " ... ") high→low to keep indices stable
        toElide.sort { $0.lowerBound > $1.lowerBound }
        var rendered = src
        for r in toElide {
            rendered.replaceSubrange(r, with: " ... ")
        }

        // --- Whitespace light pass for the top policy only
        if case .keepAllBodiesLightlyCondensed = policy {
            rendered = lightlyCondenseWhitespace(rendered)
        }

        return rendered
    }
}

// MARK: - Small helpers (parity with existing structure)

private extension String {
    func trimRightSpaces() -> String {
        var s = self
        while s.last == " " { _ = s.removeLast() }
        return s
    }
}

private extension DeclModifierListSyntax {
    var containsPublicOrOpen: Bool {
        for m in self {
            let k = m.name.text
            if k == "public" || k == "open" { return true }
        }
        return false
    }
}
private extension Optional where Wrapped == DeclModifierListSyntax {
    var containsPublicOrOpen: Bool { self?.containsPublicOrOpen ?? false }
}
