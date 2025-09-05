import Foundation

enum JSONReducer {

    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String  {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            // Pass-through if not valid JSON
            return text
        }
        let reduced = reduce(json, seen: [])
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any  {
        if let a = v as? [Any] {
            return reduceArray(a, seen: seen)
        } else if let d = v as? [String: Any] {
            return reduceDict(d, seen: seen)
        } else {
            return v
        }
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any  {
        if a.count <= head + tail {
            return a.map { reduce($0, seen: seen) }
        }
        var out: [Any] = []
        for i in 0..<head {
            out.append(reduce(a[i], seen: seen))
        }
        let omitted = a.count - head - tail
        out.append("… \(omitted) items trimmed …")
        for i in (a.count - tail)..<a.count {
            out.append(reduce(a[i], seen: seen))
        }
        return out
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any  {
        // Keep up to dictKeep keys (sorted for determinism)
        var out: [String: Any] = [:]
        let keys = d.keys.sorted()
        if keys.count <= dictKeep {
            for k in keys { out[k] = reduce(d[k]!, seen: seen) }
            return out
        }
        for k in keys.prefix(dictKeep) {
            out[k] = reduce(d[k]!, seen: seen)
        }
        out["…"] = "… \(keys.count - dictKeep) keys trimmed …"
        return out
    }

    private static func stringify(_ v: Any) -> String  {
        // Use JSONSerialization for valid JSON when possible; strings like the "… trimmed …" marker are fine.
        if JSONSerialization.isValidJSONObject(v) {
            if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        // Fallback manual
        switch v {
        case let s as String:
            return "\"\(escape(s))\""
        case let n as NSNumber:
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        case let arr as [Any]:
            return "[" + arr.map { stringify($0) }.joined(separator: ",") + "]"
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().map { "\"\(escape($0))\":" + stringify(dict[$0]!) }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            return "null"
        }
    }

    private static func escape(_ s: String) -> String  {
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
