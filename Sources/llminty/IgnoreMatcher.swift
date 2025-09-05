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
        for p in builtInPatterns {
            if let pat = Self.parse(line: p) { list.append(pat) }
        }
        for line in userFileText.components(separatedBy: .newlines) {
            if let pat = Self.parse(line: line) { list.append(pat) }
        }
        self.ordered = list
    }

    /// Parse a single ignore line into a compiled Pattern
    private static func parse(line: String) -> Pattern? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
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

        var anchor = false
        if s.hasPrefix("/") {
            anchor = true
            s.removeFirst()
        }

        // normalize duplicate slashes; allow empty segs from leading/trailing which we removed
        let segs = s.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
        return Pattern(negated: neg, dirOnly: dirOnly, anchorRoot: anchor, raw: s, segments: segs)
    }

    /// Last-match-wins as in gitignore
    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        // fast-path: empty rules
        guard !ordered.isEmpty else { return false }

        // Normalize path into segments (no leading slash)
        let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathSegs = clean.isEmpty ? [] : clean.split(separator: "/").map(String.init)

        var state: Bool? = nil
        for pat in ordered {
            if pat.dirOnly && !isDirectory { continue }
            if IgnoreMatcher.match(pattern: pat, pathSegments: pathSegs) {
                // match flips depending on negation
                state = !pat.negated
            }
        }
        return state ?? false
    }

    private static func match(pattern p: Pattern, pathSegments: [String]) -> Bool {
        if p.segments.isEmpty {
            // Edge-case: pattern became empty (e.g., "/" or "!")
            return pathSegments.isEmpty
        }
        if p.anchorRoot {
            return matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
        } else {
            // try every possible start position
            for start in 0...(pathSegments.count) {
                if matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: start) {
                    return true
                }
            }
            return false
        }
    }

    // '**' matches zero or more segments. '*' matches within a segment (no '/').
    private static func matchFrom(patternSegs: [String], pathSegs: [String], startAt: Int) -> Bool {
        func segMatches(_ pat: String, _ txt: String) -> Bool {
            // glob with '*' and '?'
            let p = Array(pat), t = Array(txt)
            var pi = 0, ti = 0
            var star: Int? = nil
            var match: Int = 0

            while ti < t.count {
                if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                    pi += 1; ti += 1
                } else if pi < p.count, p[pi] == "*" {
                    star = pi
                    pi += 1
                    match = ti
                } else if let s = star {
                    pi = s + 1
                    match += 1
                    ti = match
                } else {
                    return false
                }
            }

            while pi < p.count, p[pi] == "*" { pi += 1 }
            return pi == p.count
        }

        // recursive with backtracking for '**'
        func go(_ pi: Int, _ si: Int) -> Bool {
            if pi == patternSegs.count { return si == pathSegs.count }
            let pseg = patternSegs[pi]

            if pseg == "**" {
                // try all possible consumptions
                var k = si
                while k <= pathSegs.count {
                    if go(pi + 1, k) { return true }
                    k += 1
                }
                return false
            } else {
                guard si < pathSegs.count else { return false }
                if !segMatches(pseg, pathSegs[si]) { return false }
                return go(pi + 1, si + 1)
            }
        }

        return go(0, startAt)
    }
}
