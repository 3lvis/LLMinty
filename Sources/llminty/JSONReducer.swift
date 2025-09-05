import Foundation

enum JSONReducer {
    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    /// Reduce arrays/objects while preserving overall shape and inserting visible `/* trimmed … */` markers.
    /// If parsing fails, return original text unchanged.
    static func reduceJSONPreservingStructure(text: String) -> String {
        guard
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return text // pass-through on invalid JSON
        }
        let reduced = reduce(root, seen: [])
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any {
        if let a = v as? [Any] {
            return reduceArray(a, seen: seen)
        } else if let d = v as? [String: Any] {
            return reduceDict(d, seen: seen)
        } else {
            return v
        }
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any {
        guard a.count > head + tail else {
            return a.map { reduce($0, seen: seen) }
        }
        var out: [Any] = []
        out.reserveCapacity(head + 1 + tail)
        for i in 0..<head { out.append(reduce(a[i], seen: seen)) }
        out.append("/* trimmed \(a.count - head - tail) items */")
        for i in (a.count - tail)..<a.count { out.append(reduce(a[i], seen: seen)) }
        return out
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any {
        if d.count <= dictKeep { // small dict: reduce values recursively
            var out: [(String, Any)] = []
            out.reserveCapacity(d.count)
            // Deterministic key order (alphabetical) since JSONSerialization doesn’t guarantee insertion order
            for k in d.keys.sorted() {
                out.append((k, reduce(d[k]!, seen: seen)))
            }
            return OrderedObject(out)
        }
        // Large dict: keep first dictKeep keys (alphabetical for determinism) + marker
        let keys = d.keys.sorted()
        var pairs: [(String, Any)] = []
        for k in keys.prefix(dictKeep) {
            pairs.append((k, reduce(d[k]!, seen: seen)))
        }
        pairs.append(("/* trimmed */", "… \(d.count - dictKeep) keys omitted"))
        return OrderedObject(pairs)
    }

    // MARK: - Stringify (lenient JSON with comment-like markers)

    /// A tiny wrapper to preserve pair order for objects during stringify.
    private struct OrderedObject {
        let pairs: [(String, Any)]
        init(_ p: [(String, Any)]) { self.pairs = p }
    }

    private static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String:
            if s.hasPrefix("/* trimmed") { return s } // already a marker; emit as-is
            return "\"\(escape(s))\""
        case let n as NSNumber:
            // NSNumber can be bool or number
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        case _ as NSNull:
            return "null"
        case let a as [Any]:
            let inner = a.map { stringify($0) }.joined(separator: ", ")
            return "[ \(inner) ]"
        case let o as OrderedObject:
            let inner = o.pairs.map { k, v in
                if k.hasPrefix("/* trimmed") {
                    return "\(k)" // comment-style marker key
                } else {
                    return "\"\(escape(k))\": \(stringify(v))"
                }
            }.joined(separator: ", ")
            return "{ \(inner) }"
        case let d as [String: Any]:
            // Shouldn’t happen (we wrap dicts as OrderedObject) but handle defensively.
            let inner = d.keys.sorted().map { "\"\(escape($0))\": \(stringify(d[$0]!))" }.joined(separator: ", ")
            return "{ \(inner) }"
        default:
            // Fallback: try to JSON-encode scalar; else string-escape description
            if JSONSerialization.isValidJSONObject([v]) {
                let data = try? JSONSerialization.data(withJSONObject: [v], options: [])
                if let data, let arr = String(data: data, encoding: .utf8), arr.hasPrefix("[") && arr.hasSuffix("]") {
                    return String(arr.dropFirst().dropLast())
                }
            }
            return "\"\(escape(String(describing: v)))\""
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out
    }
}
