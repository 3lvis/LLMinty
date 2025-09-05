import Foundation

enum JSONReducer {

    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String  {
        // Parse JSON; if it fails, pass through unchanged.
        guard let data = text.data(using: .utf8) else { return text }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return text
        }
        let reduced = reduce(obj, seen: [])
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any  {
        if let a = v as? [Any] { return reduceArray(a, seen: seen) }
        if let d = v as? [String: Any] { return reduceDict(d, seen: seen) }
        return v
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any  {
        if a.count <= head + tail { return a.map { reduce($0, seen: seen) } }
        var out: [Any] = []
        let headSlice = a.prefix(head)
        let tailSlice = a.suffix(tail)
        out.append(contentsOf: headSlice.map { reduce($0, seen: seen) })
        out.append("// trimmed \(a.count - head - tail) items")
        out.append(contentsOf: tailSlice.map { reduce($0, seen: seen) })
        return out
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any  {
        if d.count <= dictKeep {
            // keep all, but reduce nested
            var out: [String: Any] = [:]
            for k in d.keys.sorted() {
                out[k] = reduce(d[k]!, seen: seen)
            }
            return out
        }
        // Keep first dictKeep keys in sorted order for determinism
        let keys = d.keys.sorted()
        let kept = keys.prefix(dictKeep)
        var out: [String: Any] = [:]
        for k in kept { out[k] = reduce(d[k]!, seen: seen) }
        out["//"] = "trimmed \(d.count - dictKeep) keys"
        return out
    }

    private static func stringify(_ v: Any) -> String  {
        // Pretty-print-ish but compact; allow line comments we introduced.
        func encode(_ x: Any, _ indent: String) -> String {
            switch x {
            case let s as String:
                if s.hasPrefix("// ") || s == "//" || s.hasPrefix("// trimmed") {
                    return s // synthetic comment
                }
                return "\"\(escape(s))\""
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    return n.boolValue ? "true" : "false"
                }
                return n.description
            case let a as [Any]:
                if a.isEmpty { return "[]" }
                var parts: [String] = []
                for el in a {
                    parts.append(encode(el, indent + "  "))
                }
                return "[\n\(indent)  " + parts.joined(separator: ",\n\(indent)  ") + "\n\(indent)]"
            case let d as [String: Any]:
                if d.isEmpty { return "{}" }
                // Keep insertion order of our constructed dict (sorted)
                var parts: [String] = []
                for k in d.keys.sorted() {
                    let val = d[k]!
                    if k == "//", let s = val as? String {
                        parts.append("// \(s)")
                    } else {
                        parts.append("\"\(escape(k))\": \(encode(val, indent + "  "))")
                    }
                }
                return "{\n\(indent)  " + parts.joined(separator: ",\n\(indent)  ") + "\n\(indent)}"
            default:
                return "\"\(escape(String(describing: x)))\""
            }
        }
        return encode(v, "")
    }

    private static func escape(_ s: String) -> String  {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
