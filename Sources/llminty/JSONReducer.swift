import Foundation

enum JSONReducer {

    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String  {
        guard let data = text.data(using: .utf8) else { return text }
        let opts: JSONSerialization.ReadingOptions = [.fragmentsAllowed, .mutableContainers, .mutableLeaves]
        guard let any = try? JSONSerialization.jsonObject(with: data, options: opts) else {
            // Not valid JSON: pass through
            return text
        }
        let reduced = reduce(any, seen: [])
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any  {
        if let a = v as? [Any] {
            return reduceArray(a, seen: seen)
        }
        if let d = v as? [String: Any] {
            return reduceDict(d, seen: seen)
        }
        return v
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any  {
        if a.count <= head + tail { return a.map { reduce($0, seen: seen) } }
        var out: [Any] = []
        for i in 0..<min(head, a.count) { out.append(reduce(a[i], seen: seen)) }
        out.append("/* … \(a.count - head - tail) elided … */")
        for i in max(a.count - tail, 0)..<a.count { out.append(reduce(a[i], seen: seen)) }
        return out
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any  {
        // Keep up to dictKeep keys, chosen by lexical key order for determinism
        let keys = d.keys.sorted()
        if keys.count <= dictKeep {
            var out: [String: Any] = [:]
            for k in keys { out[k] = reduce(d[k]!, seen: seen) }
            return out
        } else {
            var out: [String: Any] = [:]
            let keep = keys.prefix(dictKeep)
            for k in keep { out[k] = reduce(d[k]!, seen: seen) }
            out["/* … \(keys.count - dictKeep) keys elided … */"] = "/* structure preserved */"
            return out
        }
    }

    private static func stringify(_ v: Any) -> String  {
        // Deterministic compact-ish JSON with our inline /* elided */ markers.
        func s(_ val: Any) -> String {
            switch val {
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    return n.boolValue ? "true" : "false"
                } else {
                    return n.stringValue
                }
            case let s as String:
                // If it looks like our marker "/* ... */", leave as raw; else quote+escape
                if s.hasPrefix("/*") && s.hasSuffix("*/") { return s }
                return "\"\(escape(s))\""
            case let a as [Any]:
                return "[" + a.map { s($0) }.joined(separator: ", ") + "]"
            case let d as [String: Any]:
                // Sort keys for determinism
                let keys = d.keys.sorted()
                let pairs = keys.map { "\"\(escape($0))\": \(s(d[$0]!))" }
                return "{ " + pairs.joined(separator: ", ") + " }"
            case _ as NSNull:
                return "null"
            default:
                // Fallback to string description
                return "\"\(escape(String(describing: val)))\""
            }
        }
        return s(v) + "\n"
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
