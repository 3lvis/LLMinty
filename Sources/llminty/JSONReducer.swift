import Foundation

enum JSONReducer {

    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            // Unknown or invalid JSON -> keep as plain text (already filtered upstream)
            return text
        }
        let reduced = reduce(obj, seen: Set())
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any {
        if let arr = v as? [Any] {
            return reduceArray(arr, seen: seen)
        } else if let dict = v as? [String: Any] {
            return reduceDict(dict, seen: seen)
        } else {
            return v
        }
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any {
        if a.count <= head + tail { return a.map { reduce($0, seen: seen) } }
        let prefix = a.prefix(head).map { reduce($0, seen: seen) }
        let suffix = a.suffix(tail).map { reduce($0, seen: seen) }
        var out: [Any] = []
        out.append(contentsOf: prefix)
        out.append("// trimmed \(a.count - (head + tail)) items")
        out.append(contentsOf: suffix)
        return out
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any {
        if d.isEmpty { return d }
        // Keep a minimal representative subset of keys
        let keys = d.keys.sorted()
        let keepKeys = Array(keys.prefix(dictKeep))
        var out: [String: Any] = [:]
        for k in keepKeys {
            out[k] = reduce(d[k]!, seen: seen)
        }
        if d.count > keepKeys.count {
            out["//"] = "trimmed \(d.count - keepKeys.count) keys"
        }
        return out
    }

    private static func stringify(_ v: Any) -> String {
        // Produce compact, stable ordering JSON-ish text (plus // notes)
        if let s = v as? String {
            if s.hasPrefix("// trimmed") { return s } // comment line as-is
            return "\"\(escape(s))\""
        } else if v is NSNull {
            return "null"
        } else if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        } else if let a = v as? [Any] {
            let items = a.map { stringify($0) }
            return "[\(items.joined(separator: ","))]"
        } else if let d = v as? [String: Any] {
            let pairs = d.keys.sorted().map { key -> String in
                if key == "//", let msg = d[key] as? String {
                    return "\"//\":\"\(escape(msg))\""
                }
                return "\"\(escape(key))\":\(stringify(d[key]!))"
            }
            return "{\(pairs.joined(separator: ","))}"
        } else {
            return "\"\(String(describing: v))\""
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
