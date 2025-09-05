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
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }

        var negated = false
        if s.first == "!" {
            negated = true
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)

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

        // collapse duplicate slashes for stability
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        if s.isEmpty { return nil }

        let segs = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return Pattern(negated: negated, dirOnly: dirOnly, anchorRoot: anchorRoot, raw: line, segments: segs)
    }

    // MARK: - Eval
    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        // Normalize relative path to slash-separated segments without leading "./"
        let rel = relativePath.hasPrefix("./") ? String(relativePath.dropFirst(2)) : relativePath
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        var ignored = false
        for p in ordered {
            if p.dirOnly && !isDirectory { continue }
            let matched: Bool
            if p.anchorRoot {
                matched = Self.match(pattern: p, pathSegments: parts, startAt: 0)
            } else {
                // Try matching at any starting segment boundary
                var found = false
                if parts.isEmpty {
                    found = Self.match(pattern: p, pathSegments: parts, startAt: 0)
                } else {
                    for i in 0...max(0, parts.count - 1) {
                        if Self.match(pattern: p, pathSegments: parts, startAt: i) { found = true; break }
                    }
                }
                matched = found
            }

            if matched {
                // last match wins
                ignored = !p.negated
            }
        }
        return ignored
    }

    private static func match(pattern p: Pattern, pathSegments: [String]) -> Bool {
        matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: 0)
    }

    // Segment matcher for '*' and '?'
    private static func matchSegment(_ pat: String, _ txt: String) -> Bool {
        // simple glob within segment
        var pi = pat.startIndex
        var ti = txt.startIndex

        func recurse(_ nextPi: String.Index, _ tFrom: String.Index) -> Bool {
            var i = nextPi
            var j = tFrom
            while i < pat.endIndex {
                let pc = pat[i]
                if pc == "*" {
                    // try all suffixes (including empty)
                    let afterStar = pat.index(after: i)
                    if afterStar == pat.endIndex { return true }
                    var k = j
                    while true {
                        if recurse(afterStar, k) { return true }
                        if k == txt.endIndex { break }
                        k = txt.index(after: k)
                    }
                    return false
                } else if pc == "?" {
                    if j == txt.endIndex { return false }
                    i = pat.index(after: i)
                    j = txt.index(after: j)
                } else {
                    if j == txt.endIndex || txt[j] != pc { return false }
                    i = pat.index(after: i)
                    j = txt.index(after: j)
                }
            }
            return j == txt.endIndex
        }
        return recurse(pi, ti)
    }

    // '**' matches zero or more segments. '*' matches within a segment (no '/').
    private static func matchFrom(patternSegs: [String], pathSegs: [String], startAt: Int) -> Bool {
        // Backtracking over segments
        func dfs(_ pi: Int, _ ti: Int) -> Bool {
            if pi == patternSegs.count { return ti == pathSegs.count }
            let seg = patternSegs[pi]
            if seg == "**" {
                // match zero or more segments
                if pi == patternSegs.count - 1 { return true } // trailing '**' consumes rest
                var k = ti
                while k <= pathSegs.count {
                    if dfs(pi + 1, k) { return true }
                    if k == pathSegs.count { break }
                    k += 1
                }
                return false
            } else {
                if ti >= pathSegs.count { return false }
                if !matchSegment(seg, pathSegs[ti]) { return false }
                return dfs(pi + 1, ti + 1)
            }
        }
        return dfs(0, startAt)
    }
}
