import Foundation

// MARK: - Public entry point expected by tests
// NOTE: keep this as a top-level (module scoped) function so `@testable import llminty` can call it.
// Internals live in a tiny helper type to avoid leaking globals.
//
// Behavior (derived from tests):
// - Arrays longer than `arrayThreshold` are trimmed to: first 3 items, a comment `/* trimmed N items */`, last 2 items.
// - Objects: keep ALL collection-valued entries (arrays / objects), plus up to `dictThreshold` scalar entries.
//   If any keys are dropped, append `/* trimmed X keys */` at the end of the object.
// - Scalars/booleans/null: passed through unchanged.
// - If `input` is not valid JSON (fragments allowed), return it unchanged.
// - Formatting: one-line output; arrays like `[ 1, 2, 3 ]`, objects like `{ "k": v, "k2": v2, /* trimmed N keys */ }`.
func reduceJSONPreservingStructure(_ input: String, arrayThreshold: Int, dictThreshold: Int) -> String {
    guard
        let data = input.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
        return input // pass-through on invalid JSON
    }
    let reduced = _JSONReducer.reduceNode(obj, arrayLimit: arrayThreshold, dictScalarLimit: dictThreshold)
    return _JSONReducer.stringify(reduced)
}

// MARK: - Implementation

private enum J {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case array([J])
    case object([(String, J)], trimmed: Int) // trimmed = number of keys dropped
    case arrayTrimmed(head: [J], trimmedCount: Int, tail: [J])
}

private enum _JSONReducer {

    // Convert Foundation JSON to our AST, reducing as we go.
    static func reduceNode(_ any: Any, arrayLimit: Int, dictScalarLimit: Int) -> J {
        switch any {
        case let n as NSNumber:
            // NSNumber can be bool or number. Distinguish by objCType.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            } else {
                return .number(n.doubleValue)
            }
        case let s as NSString:
            return .string(s as String)
        case _ as NSNull:
            return .null
        case let arr as [Any]:
            return reduceArray(arr.map { $0 }, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)
        case let dict as [String: Any]:
            return reduceObject(dict, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)
        default:
            // Fallback: stringify whatever it is
            return .string("\(any)")
        }
    }

    // Arrays: trim if strictly longer than limit.
    private static func reduceArray(_ array: [Any], arrayLimit: Int, dictScalarLimit: Int) -> J {
        if array.count <= arrayLimit {
            let items = array.map { reduceNode($0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }
            return .array(items)
        }
        // Trim: first 3, last 2
        let headCount = min(3, array.count)
        let tailCount = min(2, array.count - headCount)
        let trimmed = array.count - headCount - tailCount
        let head = array.prefix(headCount).map { reduceNode($0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }
        let tail = array.suffix(tailCount).map { reduceNode($0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }
        return .arrayTrimmed(head: head, trimmedCount: trimmed, tail: tail)
    }

    // Objects: keep all collection-valued entries, plus up to `dictScalarLimit` scalars.
    private static func reduceObject(_ dict: [String: Any], arrayLimit: Int, dictScalarLimit: Int) -> J {
        // Stabilize order just for determinism; tests don't rely on key ordering.
        let keys = Array(dict.keys).sorted()

        var kept: [(String, J)] = []
        kept.reserveCapacity(min(dict.count, dictScalarLimit + 4))

        // First pass: collect (reduced) entries and classify.
        var collections: [(String, J)] = []
        var scalars: [(String, J)] = []

        for k in keys {
            let v = dict[k]!
            let reduced = reduceNode(v, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)
            switch reduced {
            case .array, .arrayTrimmed, .object:
                collections.append((k, reduced))
            default:
                scalars.append((k, reduced))
            }
        }

        // Keep all collections.
        kept.append(contentsOf: collections)
        // Keep up to dictScalarLimit scalars.
        if dictScalarLimit >= scalars.count {
            kept.append(contentsOf: scalars)
        } else {
            kept.append(contentsOf: scalars.prefix(dictScalarLimit))
        }

        let trimmed = dict.count - kept.count
        return .object(kept, trimmed: max(0, trimmed))
    }

    // MARK: - Stringify

    static func stringify(_ j: J) -> String {
        switch j {
        case .number(let d):
            if d.rounded(.towardZero) == d {
                return String(Int(d))
            }
            return String(d)
        case .string(let s):
            return "\"" + escapeString(s) + "\""
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[ " + items.map(stringify).joined(separator: ", ") + " ]"
        case .arrayTrimmed(let head, let trimmed, let tail):
            var parts: [String] = []
            parts.append(contentsOf: head.map(stringify))
            parts.append("/* trimmed \(trimmed) items */")
            parts.append(contentsOf: tail.map(stringify))
            return "[ " + parts.joined(separator: ", ") + " ]"
        case .object(let entries, let trimmed):
            var pieces: [String] = []
            pieces.reserveCapacity(entries.count + (trimmed > 0 ? 1 : 0))
            for (k, v) in entries {
                pieces.append("\"\(escapeString(k))\": \(stringify(v))")
            }
            if trimmed > 0 {
                pieces.append("/* trimmed \(trimmed) keys */")
            }
            if pieces.isEmpty { return "{}" }
            return "{ " + pieces.joined(separator: ", ") + " }"
        }
    }

    private static func escapeString(_ s: String) -> String {
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
