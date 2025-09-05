import Foundation

/// Minimal gitignore-like engine with globs (* ? **), dir-trailing '/', root-anchored '/' and negation '!'
/// Evaluation order: built-ins first (exclude bias), then user's .mintyignore (last match wins)
struct IgnoreMatcher {
    struct Pattern {
        let negated: Bool
        let dirOnly: Bool
        let anchorRoot: Bool
        let raw: String
        let segments: [String] // split on '/'
    }

    private let ordered: [Pattern]

    init(builtInPatterns: [String], userFileText: String) throws {
        var list: [Pattern] = []
        for p in builtInPatterns { if let pat = Self.parse(line: p) { list.append(pat) } }
        for line in userFileText.components(separatedBy: .newlines) {
            if let pat = Self.parse(line: line) { list.append(pat) }
        }
        self.ordered = list
    }

    // MARK: - Parse

    /// Parses a single .gitignore-like line into a Pattern. Returns nil for comments/blank lines.
    private static func parse(line: String) -> Pattern?  {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("#") { return nil }

        var neg = false
        if s.hasPrefix("!") {
            neg = true
            s.removeFirst()
        }

        var dirOnly = false
        if s.hasSuffix("/") {
            dirOnly = true
            s.removeLast()
        }

        var anchorRoot = false
        if s.hasPrefix("/") {
            anchorRoot = true
            s.removeFirst()
        }

        // Collapse multiple slashes and remove leading "./"
        while s.hasPrefix("./") { s.removeFirst(2) }
        s = s.replacingOccurrences(of: "//", with: "/")

        // Empty after trims is effectively a no-op
        if s.isEmpty { return nil }

        let segs = s.split(separator: "/").map { String($0) }
        return Pattern(negated: neg, dirOnly: dirOnly, anchorRoot: anchorRoot, raw: line, segments: segs)
    }

    // MARK: - Match

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool  {
        // Normalize path into segments
        let norm = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathSegs = norm.isEmpty ? [] : norm.split(separator: "/").map(String.init)

        var matched: Bool? = nil

        for p in ordered {
            if p.dirOnly && !isDirectory { continue }
            let ok = Self.match(pattern: p, pathSegments: pathSegs)
            if ok {
                // gitignore: last match wins
                if p.negated { matched = false } else { matched = true }
            }
        }
        return matched ?? false
    }

    private static func match(pattern p: Pattern, pathSegments: [String]) -> Bool  {
        if p.anchorRoot {
            return matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
        } else {
            // Try to match starting at any segment boundary
            if p.segments.first == "**" {
                // '**' at start already allows shifting inside matchFrom, so just test once
                return matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
            }
            if pathSegments.isEmpty {
                return matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
            }
            for start in 0...max(0, pathSegments.count - 1) {
                if matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: start) {
                    return true
                }
            }
            return false
        }
    }

    // '**' matches zero or more segments. '*' matches within a segment (no '/').
    private static func matchFrom(patternSegs: [String], pathSegs: [String], startAt: Int) -> Bool  {
        func segMatches(_ p: String, _ s: String) -> Bool {
            // Simple wildcard matcher with '*' and '?' inside a single segment
            // Convert to regex safely (escape, then restore wildcards)
            var rx = ""
            for ch in p {
                switch ch {
                case "*": rx.append(".*")
                case "?": rx.append(".")
                default:
                    // escape regex metachars
                    let scalars = String(ch).unicodeScalars
                    if let u = scalars.first, CharacterSet(charactersIn: ".*+?^${}()|[]\\").contains(u) {
                        rx.append("\\")
                    }
                    rx.append(ch)
                }
            }
            return s.range(of: "^" + rx + "$", options: [.regularExpression]) != nil
        }

        func rec(_ pi: Int, _ si: Int) -> Bool {
            if pi == patternSegs.count { return si == pathSegs.count }
            let pat = patternSegs[pi]

            if pat == "**" {
                // Try zero or more segments
                if rec(pi + 1, si) { return true }
                if si < pathSegs.count {
                    var k = si
                    while k < pathSegs.count {
                        if rec(pi, k + 1) { return true }
                        k += 1
                    }
                }
                return false
            }

            if si >= pathSegs.count { return false }
            if !segMatches(pat, pathSegs[si]) { return false }
            return rec(pi + 1, si + 1)
        }

        return rec(0, startAt)
    }
}
