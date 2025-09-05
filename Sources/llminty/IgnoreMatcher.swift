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

    // MARK: - Parser

    private static func parse(line: String) -> Pattern? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { return nil }

        var neg = false
        if s.first == "!" {
            neg = true
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
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

        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Normalize duplicate slashes
        let segs = s.split(separator: "/").map { String($0) }
        return Pattern(negated: neg, dirOnly: dirOnly, anchorRoot: anchorRoot, raw: line, segments: segs)
    }

    // MARK: - Eval

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        // Normalize path segments (no leading './')
        let norm = relativePath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"^\.\/"#, with: "", options: .regularExpression)
        let pathSegs = norm.split(separator: "/").map { String($0) }

        var ignored = false
        for p in ordered {
            if p.dirOnly && !isDirectory { continue }
            let matched = match(pattern: p, pathSegments: pathSegs)
            if matched {
                ignored = !p.negated
            }
        }
        return ignored
    }

    private static func matchSegment(_ pat: String, _ txt: String) -> Bool {
        // '*' matches any (including empty), '?' matches one (no '/': segments already split)
        var pi = pat.startIndex
        var ti = txt.startIndex

        func recurse(_ nextPi: String.Index, _ tFrom: String.Index) -> Bool {
            var t = tFrom
            while true {
                if matchCore(nextPi, t) { return true }
                if t == txt.endIndex { break }
                t = txt.index(after: t)
            }
            return false
        }

        func matchCore(_ pFrom: String.Index, _ tFrom: String.Index) -> Bool {
            var p = pFrom
            var t = tFrom
            while p < pat.endIndex {
                let ch = pat[p]
                if ch == "*" {
                    let afterStar = pat.index(after: p)
                    if afterStar == pat.endIndex { return true } // trailing *
                    return recurse(afterStar, t)
                } else if ch == "?" {
                    if t == txt.endIndex { return false }
                    t = txt.index(after: t)
                    p = pat.index(after: p)
                } else {
                    if t == txt.endIndex || txt[t] != ch { return false }
                    t = txt.index(after: t)
                    p = pat.index(after: p)
                }
            }
            return t == txt.endIndex
        }

        return matchCore(pi, ti)
    }

    private func match(pattern p: Pattern, pathSegments: [String]) -> Bool {
        if p.anchorRoot {
            return Self.matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
        } else {
            if p.segments.first == "**" {
                // '**' at start can match from 0
                if Self.matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0) { return true }
            }
            // Try each possible start offset
            for i in 0...(pathSegments.count) {
                if Self.matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: i) { return true }
            }
            return false
        }
    }

    // '**' matches zero or more segments. '*' matches within a segment (no '/').
    private static func matchFrom(patternSegs: [String], pathSegs: [String], startAt: Int) -> Bool {
        func helper(_ pi: Int, _ si: Int) -> Bool {
            if pi == patternSegs.count { return si == pathSegs.count }
            let p = patternSegs[pi]

            if p == "**" {
                // '**' eats zero..n segments
                if pi + 1 == patternSegs.count { return true } // trailing '**' matches rest
                var k = si
                while k <= pathSegs.count {
                    if helper(pi + 1, k) { return true }
                    k += 1
                }
                return false
            } else {
                if si >= pathSegs.count { return false }
                if matchSegment(p, pathSegs[si]) {
                    return helper(pi + 1, si + 1)
                }
                return false
            }
        }
        return helper(0, startAt)
    }
}
