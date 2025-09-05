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
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
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
        for raw in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { _ = line.removeLast() }
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// Mechanically elide Swift bodies according to the policy.
    /// This implementation is intentionally generic and project-agnostic.
    func renderSwift(text: String, policy: SwiftPolicy) throws -> String {
        // We’ll scan the raw source to find function-like bodies and perform textual replacements.
        // This keeps the mechanics deterministic without project-specific logic.
        struct Fn {
            let range: Range<String.Index>    // entire { ... } including braces
            let bodyRange: Range<String.Index>// inside braces
            let isPublic: Bool
            let typePath: [String]            // nesting stack of types
            let lines: Int
        }

        // 1) Build a simple stack of type names and collect function bodies.
        var fns: [Fn] = []
        fns.reserveCapacity(64)

        var typeStack: [String] = []
        typeStack.reserveCapacity(8)

        // We’ll scan once, tracking braces to identify both type and function scopes.
        let src = text
        let scalars = Array(src) // enables O(1) index stepping by character
        var i = src.startIndex

        @inline(__always)
        func advance(_ idx: inout String.Index, by n: Int = 1) {
            for _ in 0..<n { guard idx < src.endIndex else { return }; idx = src.index(after: idx) }
        }

        // Tiny helpers
        func isIdentifierChar(_ c: Character) -> Bool {
            return c.isLetter || c.isNumber || c == "_" // simple enough for our inputs
        }

        func peekWord(from start: String.Index) -> (String, String.Index) {
            var j = start
            var word = ""
            while j < src.endIndex, isIdentifierChar(src[j]) {
                word.append(src[j]); advance(&j)
            }
            return (word, j)
        }

        // Next braces from position
        func matchBraces(from start: String.Index) -> String.Index? {
            var depth = 0
            var j = start
            while j < src.endIndex {
                let c = src[j]
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return j
                    }
                }
                advance(&j)
            }
            return nil
        }

        // Count lines in a range
        func lineCount(_ r: Range<String.Index>) -> Int {
            var n = 1
            var j = r.lowerBound
            while j < r.upperBound {
                if src[j] == "\n" { n += 1 }
                advance(&j)
            }
            return n
        }

        // Light tokenizer to find type/func keywords and brace blocks.
        while i < src.endIndex {
            // Skip whitespace
            if src[i].isWhitespace {
                advance(&i)
                continue
            }

            // Capture modifiers and keyword
            var j = i
            var modifiers: [String] = []
            // Collect zero or more modifiers (public/open/internal/private/static/final/etc.)
            while j < src.endIndex {
                // Skip spaces
                while j < src.endIndex, src[j].isWhitespace { advance(&j) }
                let (word, after) = peekWord(from: j)
                if word.isEmpty { break }
                let known = ["public","open","internal","private","fileprivate",
                             "static","class","final","mutating","nonmutating","override"]
                if known.contains(word) {
                    modifiers.append(word)
                    j = after
                } else {
                    break
                }
            }
            // Now expect a keyword (struct/class/enum/protocol/func/init/subscript) or skip
            let (kw, afterKW) = peekWord(from: j)
            if kw == "struct" || kw == "class" || kw == "enum" || kw == "protocol" {
                // Read name
                var nameStart = afterKW
                while nameStart < src.endIndex, src[nameStart].isWhitespace { advance(&nameStart) }
                let (name, afterName) = peekWord(from: nameStart)
                // Find opening brace of the type
                var k = afterName
                while k < src.endIndex, src[k] != "{" { advance(&k) }
                if k < src.endIndex, src[k] == "{", let end = matchBraces(from: k) {
                    typeStack.append(name.isEmpty ? "<anon>" : name)
                    // Recurse into body: we’ll process inner items as we scan; jump into type body
                    // but we still need to keep scanning linearly; we won’t skip.
                    // We’ll pop when we pass the closing brace.
                    // To detect pop, we’ll push a sentinel with end index.
                }
                // Move i forward a bit to avoid reprocessing the same token
                i = k < src.endIndex ? src.index(after: k) : afterName
                continue
            } else if kw == "func" || kw == "init" || kw == "subscript" {
                // Find the opening brace for the body
                var k = afterKW
                // Advance to first '{' that begins the body (skip generics/args/throws -> {...})
                while k < src.endIndex, src[k] != "{" && src[k] != "\n" { advance(&k) }
                if k < src.endIndex, src[k] == "{", let bodyEnd = matchBraces(from: k) {
                    let bodyStart = k
                    let endIdx = src.index(after: bodyEnd)
                    let isPub = modifiers.contains("public") || modifiers.contains("open")
                    let lines = lineCount(bodyStart..<endIdx)
                    fns.append(Fn(range: bodyStart..<endIdx,
                                  bodyRange: src.index(after: bodyStart)..<bodyEnd,
                                  isPublic: isPub,
                                  typePath: typeStack,
                                  lines: lines))
                    i = endIdx
                    continue
                }
            }

            // On unmatched/other tokens just advance
            advance(&i)
        }

        // 2) Decide which bodies to elide based on policy and generic size heuristics.
        let shortKeepAllPolicies = 8   // ≤ 8 lines are kept even if non-public in mid bin
        let shortKeepInSignOnly  = 3   // ≤ 3 lines are kept even in signaturesOnly

        var toElide: [Range<String.Index>] = []
        toElide.reserveCapacity(fns.count)

        switch policy {
        case .keepAllBodiesLightlyCondensed:
            // Keep all bodies, just lightly condense whitespace later.
            break

        case .keepPublicBodiesElideOthers:
            for fn in fns {
                if fn.isPublic { continue }
                if fn.lines <= shortKeepAllPolicies { continue } // keep short private/internal bodies
                toElide.append(fn.bodyRange)
            }

        case .keepOneBodyPerTypeElideRest:
            // Group by type path; keep shortest body in each group, elide the others.
            var bestByType: [String: Fn] = [:]
            bestByType.reserveCapacity(16)
            func key(for path: [String]) -> String { path.joined(separator: ".") }

            for fn in fns {
                let k = key(for: fn.typePath)
                if let prev = bestByType[k] {
                    if fn.lines < prev.lines {
                        bestByType[k] = fn
                    }
                } else {
                    bestByType[k] = fn
                }
            }
            let keepSet: Set<ObjectIdentifier> = Set(bestByType.values.map { ObjectIdentifier($0 as AnyObject) }) // not usable with struct
            // Instead, mark all others that are not the chosen one for their type.
            for fn in fns {
                if let chosen = bestByType[key(for: fn.typePath)], chosen.range == fn.range {
                    // keep
                } else {
                    toElide.append(fn.bodyRange)
                }
            }

        case .signaturesOnly:
            for fn in fns {
                if fn.lines <= shortKeepInSignOnly { continue } // keep ultra-short even here
                toElide.append(fn.bodyRange)
            }
        }

        // 3) Apply elisions (replace body contents with "{...}" preserving surrounding braces).
        // Sort ranges high→low to keep indices valid as we mutate.
        toElide.sort { $0.lowerBound > $1.lowerBound }

        var rendered = src
        for r in toElide {
            // r is body-only: replace interior with "..."; keep single spaces around if present.
            rendered.replaceSubrange(r, with: " ... ")
        }

        // 4) Whitespace pass if keeping all bodies
        switch policy {
        case .keepAllBodiesLightlyCondensed:
            rendered = lightlyCondenseWhitespace(rendered)
        default:
            break
        }

        return rendered
    }
}

// MARK: - Small helpers (kept for parity with earlier structure)

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

extension StringProtocol {
    var isNewline: Bool { return self == "\n" || self == "\r\n" }
}
