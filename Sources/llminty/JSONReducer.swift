// Sources/llminty/JSONReducer.swift
import Foundation

enum JSONReducer {
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    static func reduceJSONPreservingStructure(text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            // Pass-through on invalid JSON
            return text
        }
        let reduced = reduce(obj)
        return stringify(reduced)
    }

    // MARK: - Core

    private static func reduce(_ v: Any) -> Any {
        switch v {
        case let a as [Any]: return reduceArray(a)
        case let d as [String: Any]: return reduceDict(d)
        default: return v
        }
    }

    private static func reduceArray(_ a: [Any]) -> Any {
        if a.count <= head + tail {
            return a.map { reduce($0) }
        }
        var out: [Any] = []
        out.reserveCapacity(head + 1 + tail)
        for x in a.prefix(head) { out.append(reduce(x)) }
        out.append(ElidedArray(count: a.count - (head + tail)))
        for x in a.suffix(tail) { out.append(reduce(x)) }
        return out
    }

    private static func reduceDict(_ d: [String: Any]) -> Any {
        // Keep up to dictKeep keys in a deterministic order (lexicographic).
        let keys = d.keys.sorted()
        let kept = keys.prefix(dictKeep)
        var out: [(String, Any)] = []
        out.reserveCapacity(kept.count + 1)
        for k in kept {
            out.append((k, reduce(d[k]!)))
        }
        if d.count > kept.count {
            out.append(("//", "… \(d.count - kept.count) keys omitted …"))
        }
        return OrderedObject(pairs: out)
    }

    // MARK: - Printable forms

    // Marker types used only during stringify
    private struct ElidedArray { let count: Int }
    private struct OrderedObject { let pairs: [(String, Any)] }

    private static func stringify(_ v: Any) -> String {
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        case let s as String:
            return "\"\(escape(s))\""
        case is NSNull:
            return "null"
        case let a as [Any]:
            return "[" + a.enumerated().map { i, x in stringify(x) }.joined(separator: ", ") + "]"
        case let o as OrderedObject:
            return "{" + o.pairs.map { "\"\(escape($0.0))\": \(stringify($0.1))" }.joined(separator: ", ") + "}"
        case let e as ElidedArray:
            return "/* ... \(e.count) items omitted ... */"
        default:
            // Try to encode unknowns via JSONSerialization (scalars like Date/Nil won’t appear here)
            if JSONSerialization.isValidJSONObject(v),
               let data = try? JSONSerialization.data(withJSONObject: v, options: []),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            // Fallback to quoted description
            return "\"\(escape(String(describing: v)))\""
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
