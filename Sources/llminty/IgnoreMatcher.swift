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

    private static func parse(line: String) -> Pattern? {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { return nil }
        let neg = s.hasPrefix("!")
        let body = neg ? String(s.dropFirst()) : s
        let dirOnly = body.hasSuffix("/")
        let anchorRoot = body.hasPrefix("/")
        let trimmed = dirOnly ? String(body.dropLast()) : body
        let trimmed2 = anchorRoot ? String(trimmed.dropFirst()) : trimmed
        let segs = trimmed2.split(separator: "/").map(String.init)
        return Pattern(negated: neg, dirOnly: dirOnly, anchorRoot: anchorRoot, raw: s, segments: segs)
    }

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        // Deterministic path normalization
        let norm = relativePath.split(separator: "/").map(String.init)
        var ignored = false
        for p in ordered {
            // dirOnly patterns shouldn't match files
            if p.dirOnly && !isDirectory { continue }
            if Self.match(pattern: p, pathSegments: norm) {
                ignored = !p.negated
            }
        }
        return ignored
    }

    private static func match(pattern p: Pattern, pathSegments: [String]) -> Bool {
        // If anchored to root, match from beginning; else allow match at any path offset
        let range: Range<Int>
        if p.anchorRoot {
            range = 0..<1
        } else {
            range = 0..<(pathSegments.count == 0 ? 1 : pathSegments.count)
        }
        for start in range {
            if matchFrom(patternSegs: p.segments, pathSegs: pathSegments, startAt: start) {
                return true
            }
        }
        return false
    }

    // '**' matches zero or more segments. '*' matches within a segment (no '/').
    private static func matchFrom(patternSegs: [String], pathSegs: [String], startAt: Int) -> Bool {
        func segMatch(_ pat: String, _ str: String) -> Bool {
            // Simple '*' and '?' matcher for a single segment
            var pIdx = pat.startIndex
            var sIdx = str.startIndex
            var starIdx: String.Index? = nil
            var matchIdx: String.Index? = nil
            while sIdx < str.endIndex {
                if pIdx < pat.endIndex, pat[pIdx] == "*" {
                    starIdx = pIdx
                    pIdx = pat.index(after: pIdx)
                    matchIdx = sIdx
                } else if pIdx < pat.endIndex, pat[pIdx] == "?" || pat[pIdx] == str[sIdx] {
                    pIdx = pat.index(after: pIdx); sIdx = str.index(after: sIdx)
                } else if let star = starIdx {
                    pIdx = pat.index(after: star)
                    matchIdx = str.index(after: matchIdx!)
                    sIdx = matchIdx!
                } else { return false }
            }
            // Consume trailing '*'
            while pIdx < pat.endIndex, pat[pIdx] == "*" { pIdx = pat.index(after: pIdx) }
            return pIdx == pat.endIndex
        }

        // DP over segments, handling '**'
        func helper(_ pIdx: Int, _ sIdx: Int) -> Bool {
            if pIdx == patternSegs.count { return sIdx == pathSegs.count }
            if sIdx > pathSegs.count { return false }
            let seg = patternSegs[pIdx]
            if seg == "**" {
                // try zero or more segments
                var i = sIdx
                while i <= pathSegs.count {
                    if helper(pIdx + 1, i) { return true }
                    i += 1
                }
                return false
            } else {
                if sIdx == pathSegs.count { return false }
                if segMatch(seg, pathSegs[sIdx]) {
                    return helper(pIdx + 1, sIdx + 1)
                } else {
                    return false
                }
            }
        }
        return helper(0, startAt)
    }
}
