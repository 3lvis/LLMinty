// Sources/llminty/JSONReducer.swift
import Foundation

enum JSONReducer {

    // Head/Tail sample sizes & dict key limit
    private static let head = 3
    private static let tail = 2
    private static let dictKeep = 6

    // Public entry point used by Renderer
    static func reduceJSONPreservingStructure(text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            // Pass-through on invalid JSON (also tested)
            return text
        }
        let reduced = reduce(obj)
        return stringify(reduced)
    }

    // MARK: - Structural reduction

    // Dispatch preserving arrays/objects; leave scalars alone
    private static func reduce(_ v: Any) -> Any {
        switch v {
        case let a as [Any]:
            return reduceArray(a)
        case let d as [String: Any]:
            return reduceDict(d)
        default:
            return v
        }
    }

    private static func reduceArray(_ a: [Any]) -> Any {
        // If short, just reduce elements recursively
        if a.count <= head + tail {
            return a.map { reduce($0) }
        }

        // Long array: head + sentinel + tail
        let k = a.count - head - tail
        let headSlice = a.prefix(head).map { reduce($0) }
        let tailSlice = a.suffix(tail).map { reduce($0) }
        // Use a unique marker type we handle in stringify
        let marker: Any = TrimMarker.items(k)

        return headSlice + [marker] + tailSlice
    }

    private static func reduceDict(_ d: [String: Any]) -> Any {
        // JSONSerialization dictionaries aren’t ordered, but in practice Foundation
        // preserves insertion order for decoding from JSON on Apple platforms today.
        // We still treat it defensively: iterate keys() as given.
        let keys = Array(d.keys)
        if keys.count <= dictKeep {
            var out: [String: Any] = [:]
            out.reserveCapacity(keys.count)
            for k in keys {
                out[k] = reduce(d[k]!)
            }
            return out
        }

        // Keep first dictKeep keys; attach a trailing "trimmed" comment at stringify time
        var kept: [String: Any] = [:]
        kept.reserveCapacity(dictKeep)
        for k in keys.prefix(dictKeep) {
            kept[k] = reduce(d[k]!)
        }
        // Wrap with a marker so stringify knows to append the comment
        return DictWithTrim(kept: kept, trimmedCount: keys.count - dictKeep)
    }

    // MARK: - Stringification with "trimmed" notes

    // Internal marker types
    private enum TrimMarker {
        case items(Int) // arrays
    }
    private struct DictWithTrim {
        let kept: [String: Any]
        let trimmedCount: Int
    }

    private static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String:
            return "\"\(escape(s))\""
        case let n as NSNumber:
            // NSNumber can be bool or number; preserve JSON bool spelling
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.description
        case _ as NSNull:
            return "null"
        case let a as [Any]:
            return stringifyArray(a)
        case let d as [String: Any]:
            return stringifyDict(d, trailingTrimComment: nil)
        case let marker as TrimMarker:
            switch marker {
            case .items(let k):
                // Middle-of-array sentinel; JSON-unsafe comment is fine for our output
                return "/* trimmed \(k) items */"
            }
        case let wrapped as DictWithTrim:
            return stringifyDict(wrapped.kept, trailingTrimComment: "/* trimmed \(wrapped.trimmedCount) keys */")
        default:
            // Best-effort fallback via JSONSerialization (scalar or unknown)
            if JSONSerialization.isValidJSONObject(v),
               let data = try? JSONSerialization.data(withJSONObject: v, options: []),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            // Last resort: quoted debug
            return "\"\(escape(String(describing: v)))\""
        }
    }

    private static func stringifyArray(_ a: [Any]) -> String {
        var out = "["
        for (i, el) in a.enumerated() {
            if i > 0 { out.append(", ") }
            out.append(stringify(el))
        }
        out.append("]")
        return out
    }

    private static func stringifyDict(_ d: [String: Any], trailingTrimComment: String?) -> String {
        var out = "{ "
        var first = true
        for (k, v) in d {
            if !first { out.append(", ") }
            first = false
            out.append("\"\(escape(k))\": \(stringify(v))")
        }
        if let c = trailingTrimComment {
            if !first { out.append(", ") }
            out.append(c)
        }
        out.append(" }")
        return out
    }

    // Basic JSON string escaper
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
