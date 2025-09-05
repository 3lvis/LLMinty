import Foundation

enum JSONReducer {

    // Head/Tail sample sizes
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String {
        guard let data = text.data(using: .utf8) else { return text }
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let json = obj else { return text } // pass-through on invalid JSON

        let reduced = reduce(json, seen: [])
        return stringify(reduced)
    }

    private static func reduce(_ v: Any, seen: Set<ObjectIdentifier>) -> Any {
        if let a = v as? [Any] { return reduceArray(a, seen: seen) }
        if let d = v as? [String: Any] { return reduceDict(d, seen: seen) }
        return v
    }

    private static func reduceArray(_ a: [Any], seen: Set<ObjectIdentifier>) -> Any {
        if a.count <= head + tail {
            return a.map { reduce($0, seen: seen) }
        }
        let prefix = a.prefix(head).map { reduce($0, seen: seen) }
        let suffix = a.suffix(tail).map { reduce($0, seen: seen) }
        let omitted = a.count - (head + tail)
        return ["__trimmed_array__": [
            "head": prefix,
            "omitted": omitted,
            "tail": suffix
        ]]
    }

    private static func reduceDict(_ d: [String: Any], seen: Set<ObjectIdentifier>) -> Any {
        // Keep at most dictKeep keys; preserve key order by sorting keys to keep determinism
        let keys = d.keys.sorted()
        var out: [String: Any] = [:]
        var kept = 0
        for k in keys {
            if kept >= dictKeep { break }
            out[k] = reduce(d[k] as Any, seen: seen)
            kept += 1
        }
        if d.count > dictKeep {
            out["__trimmed_dict_keys__"] = Array(keys.dropFirst(dictKeep))
        }
        return out
    }

    private static func stringify(_ v: Any) -> String {
        // Pretty-print deterministic JSON-ish text with comments embedded as fields
        if let a = v as? [Any] {
            return "[\n" + a.enumerated().map { (i, e) in
                "  " + stringify(e)
            }.joined(separator: ",\n") + "\n]"
        } else if let d = v as? [String: Any] {
            let keys = d.keys.sorted()
            let body = keys.map { k in
                "  " + "\"\(escape(k))\": " + stringify(d[k] as Any)
            }.joined(separator: ",\n")
            return "{\n" + body + "\n}"
        } else if let s = v as? String {
            return "\"\(escape(s))\""
        } else if v is NSNull {
            return "null"
        } else {
            // numbers, bools
            return "\(v)"
        }
    }
    
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
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
