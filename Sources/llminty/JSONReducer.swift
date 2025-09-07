// Sources/llminty/JSONReducer.swift
import Foundation

/// Reduces large JSON values while preserving overall structure:
/// - Long arrays become `head + /* trimmed N items */ + tail`
/// - Large objects keep the first `maximumDictionaryKeysKept` keys and add `/* trimmed N keys */` at the end
/// - Scalars are passed through unchanged
/// If `text` is not valid JSON, it is returned as-is.
enum JSONReducer {

    // MARK: - Tunables

    private static let headCount = 3
    private static let tailCount = 2
    private static let maximumDictionaryKeysKept = 6

    // MARK: - Public API

    static func reduceJSONPreservingStructure(text: String) -> String {
        guard
            let data = text.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            // Pass-through on invalid JSON
            return text
        }

        let reduced = reduce(value)
        return stringify(reduced)
    }

    // MARK: - Structural reduction (pure)

    private static func reduce(_ value: Any) -> Any {
        switch value {
        case let array as [Any]:
            return reduceArray(array)

        case let dictionary as [String: Any]:
            return reduceDictionary(dictionary)

        default:
            return value
        }
    }

    private static func reduceArray(_ array: [Any]) -> Any {
        // Short arrays: reduce elements recursively, no sentinel.
        if array.count <= headCount + tailCount {
            return array.map { reduce($0) }
        }

        // Long arrays: head + sentinel + tail.
        let trimmedItemCount = array.count - headCount - tailCount
        let headSlice = array.prefix(headCount).map { reduce($0) }
        let tailSlice = array.suffix(tailCount).map { reduce($0) }

        // Unique marker handled in stringify.
        let marker: Any = TrimMarker.items(trimmedItemCount)

        return headSlice + [marker] + tailSlice
    }

    private static func reduceDictionary(_ dictionary: [String: Any]) -> Any {
        // Foundation preserves insertion order when decoding from JSON on Apple platforms today.
        let keysInOrder = Array(dictionary.keys)

        if keysInOrder.count <= maximumDictionaryKeysKept {
            var kept: [String: Any] = [:]
            kept.reserveCapacity(keysInOrder.count)

            for key in keysInOrder {
                kept[key] = reduce(dictionary[key]!)
            }
            return kept
        }

        // Keep first N keys; stringify will append the trailing comment.
        var kept: [String: Any] = [:]
        kept.reserveCapacity(maximumDictionaryKeysKept)

        for key in keysInOrder.prefix(maximumDictionaryKeysKept) {
            kept[key] = reduce(dictionary[key]!)
        }

        let trimmedKeyCount = keysInOrder.count - maximumDictionaryKeysKept
        return DictionaryWithTrim(kept: kept, trimmedKeyCount: trimmedKeyCount)
    }

    // MARK: - Stringification with "trimmed" notes (pure)

    private enum TrimMarker {
        case items(Int) // arrays
    }

    private struct DictionaryWithTrim {
        let kept: [String: Any]
        let trimmedKeyCount: Int
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let string as String:
            return "\"\(escape(string))\""

        case let number as NSNumber:
            // Preserve JSON booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.description

        case _ as NSNull:
            return "null"

        case let array as [Any]:
            return stringifyArray(array)

        case let dictionary as [String: Any]:
            return stringifyDictionary(dictionary, trailingTrimComment: nil)

        case let marker as TrimMarker:
            switch marker {
            case .items(let count):
                // JSON-unsafe comment is acceptable for our output contract.
                return "/* trimmed \(count) items */"
            }

        case let wrapped as DictionaryWithTrim:
            let comment = "/* trimmed \(wrapped.trimmedKeyCount) keys */"
            return stringifyDictionary(wrapped.kept, trailingTrimComment: comment)

        default:
            // Best-effort fallback via JSONSerialization for unknown-but-JSON-compatible values.
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: []),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            // Last resort: quoted debug.
            return "\"\(escape(String(describing: value)))\""
        }
    }

    private static func stringifyArray(_ array: [Any]) -> String {
        var out = "["
        for (index, element) in array.enumerated() {
            if index > 0 { out.append(", ") }
            out.append(stringify(element))
        }
        out.append("]")
        return out
    }

    private static func stringifyDictionary(
        _ dictionary: [String: Any],
        trailingTrimComment: String?
    ) -> String {
        var out = "{ "
        var isFirst = true

        for (key, value) in dictionary {
            if !isFirst { out.append(", ") }
            isFirst = false
            out.append("\"\(escape(key))\": \(stringify(value))")
        }

        if let comment = trailingTrimComment {
            if !isFirst { out.append(", ") }
            out.append(comment)
        }

        out.append(" }")
        return out
    }

    // MARK: - Escaping (pure)

    private static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count + 8)

        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
