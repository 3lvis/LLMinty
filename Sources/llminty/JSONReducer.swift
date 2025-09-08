import Foundation

/// Public, single entry point. Everything else is internal by default.
public struct JSONReducer {

    /// Reduces a JSON string while preserving overall structure.
    /// - Parameters:
    ///   - input: UTF-8 JSON (fragments allowed). If invalid, returned unchanged.
    ///   - arrayThreshold: Arrays longer than this are trimmed to first 3, comment, last 2.
    ///   - dictThreshold: Objects keep all collection entries and up to this many scalar entries.
    /// - Returns: One-line JSON string with optional trim comments.
    public static func reduceJSONPreservingStructure(_ input: String, arrayThreshold: Int, dictThreshold: Int) -> String {
        guard
            let data = input.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return input
        }

        let node = Reducer.reduce(any: json, arrayLimit: arrayThreshold, dictScalarLimit: dictThreshold)
        return Stringifier.stringify(node)
    }

    // MARK: - Internal model

    enum Node {
        case number(Double)
        case string(String)
        case bool(Bool)
        case null
        case array([Node])
        case object([(String, Node)], trimmed: Int) // trimmed = number of keys dropped
        case arrayTrimmed(head: [Node], trimmedCount: Int, tail: [Node])
    }

    // MARK: - Reduction

    enum Reducer {

        static func reduce(any: Any, arrayLimit: Int, dictScalarLimit: Int) -> Node {
            switch any {
            case let n as NSNumber:
                // NSNumber can represent both numbers and booleans; disambiguate via CFTypeID.
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    return .bool(n.boolValue)
                } else {
                    return .number(n.doubleValue)
                }

            case let s as NSString:
                return .string(s as String)

            case _ as NSNull:
                return .null

            case let array as [Any]:
                return reduceArray(array, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)

            case let dict as [String: Any]:
                return reduceObject(dict, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)

            default:
                // Fallback: stringify unknowns
                return .string("\(any)")
            }
        }

        private static func reduceArray(_ array: [Any], arrayLimit: Int, dictScalarLimit: Int) -> Node {
            if array.count <= arrayLimit {
                let items = array.map { reduce(any: $0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }
                return .array(items)
            }

            // Trim: first 3, comment, last 2
            let headCount = min(3, array.count)
            let tailCount = min(2, array.count - headCount)
            let trimmedCount = array.count - headCount - tailCount

            let head = array.prefix(headCount).map { reduce(any: $0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }
            let tail = array.suffix(tailCount).map { reduce(any: $0, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit) }

            return .arrayTrimmed(head: head, trimmedCount: trimmedCount, tail: tail)
        }

        private static func reduceObject(_ dict: [String: Any], arrayLimit: Int, dictScalarLimit: Int) -> Node {
            // Deterministic key order
            let keys = dict.keys.sorted()

            var kept: [(String, Node)] = []
            kept.reserveCapacity(min(dict.count, dictScalarLimit + 4))

            var collections: [(String, Node)] = []
            var scalars: [(String, Node)] = []

            for key in keys {
                guard let value = dict[key] else { continue }
                let reduced = reduce(any: value, arrayLimit: arrayLimit, dictScalarLimit: dictScalarLimit)

                switch reduced {
                case .array, .arrayTrimmed, .object:
                    collections.append((key, reduced))
                default:
                    scalars.append((key, reduced))
                }
            }

            kept.append(contentsOf: collections)

            if dictScalarLimit >= scalars.count {
                kept.append(contentsOf: scalars)
            } else {
                kept.append(contentsOf: scalars.prefix(dictScalarLimit))
            }

            let trimmed = max(0, dict.count - kept.count)
            return .object(kept, trimmed: trimmed)
        }
    }

    // MARK: - Stringify

    enum Stringifier {

        static func stringify(_ node: Node) -> String {
            switch node {
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

        static func escapeString(_ s: String) -> String {
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
}
