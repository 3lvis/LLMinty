import XCTest
@testable import llminty

// Tiny shim so we always call the reducer via the module namespace.
private func reduceJSON(_ input: String) -> String {
    // Call the new namespaced entry point with explicit thresholds.
    return llminty.JSONReducer.reduceJSONPreservingStructure(
        input,
        arrayThreshold: 5,
        dictThreshold: 6
    )
}

/// Canonicalize reducer output & expectation for strict 1:1 *logical* equality:
/// - removes ALL whitespace outside of string literals (so formatting differences don't fail)
/// - normalizes whitespace *inside* /* ... */ comments to a single space
/// - preserves string literal contents exactly (including escaped characters)
///
/// This keeps the assertion strict (no regex/contains) while making it robust to
/// purely formatting differences in either the expected string or the reducer output.
private func canonicalizeReducerOutput(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)

    var inString = false
    var escaped = false
    var inComment = false
    var prevWasSpaceInComment = false

    let scalars = Array(s.unicodeScalars)
    var i = 0

    func appendScalar(_ scalar: UnicodeScalar) {
        out.unicodeScalars.append(scalar)
    }

    while i < scalars.count {
        let ch = scalars[i]

        if inString {
            appendScalar(ch)
            if escaped {
                // escaped char inside string - consume and reset
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
            i += 1
            continue
        }

        if inComment {
            // detect end '*/'
            if ch == "*" && i + 1 < scalars.count && scalars[i + 1] == "/" {
                appendScalar(ch)
                appendScalar(scalars[i + 1])
                i += 2
                inComment = false
                prevWasSpaceInComment = false
                continue
            }
            // collapse whitespace in comment to single space
            if CharacterSet.whitespacesAndNewlines.contains(ch) {
                if !prevWasSpaceInComment {
                    appendScalar(" ")
                    prevWasSpaceInComment = true
                }
            } else {
                appendScalar(ch)
                prevWasSpaceInComment = false
            }
            i += 1
            continue
        }

        // not in string or comment
        if ch == "\"" {
            inString = true
            appendScalar(ch)
            i += 1
            continue
        }

        // start comment?
        if ch == "/" && i + 1 < scalars.count && scalars[i + 1] == "*" {
            inComment = true
            appendScalar(ch)
            appendScalar(scalars[i + 1])
            i += 2
            continue
        }

        // drop ALL whitespace outside strings & comments
        if CharacterSet.whitespacesAndNewlines.contains(ch) {
            i += 1
            continue
        }

        appendScalar(ch)
        i += 1
    }

    return out
}

/// Assert that reducer output and expected string are identical after canonicalization.
/// This is a strict, deterministic comparison (no regex/contains) but robust to formatting.
private func XCTAssertReducerEqual(_ got: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    let g = canonicalizeReducerOutput(got)
    let e = canonicalizeReducerOutput(expected)
    XCTAssertEqual(g, e, """
    Reducer output did not match expected (canonicalized).
    --- GOT (canonical) ---
    \(g)
    --- EXPECTED (canonical) ---
    \(e)
    --- GOT (raw) ---
    \(got)
    --- EXPECTED (raw) ---
    \(expected)
    """, file: file, line: line)
}

final class JSONReducerTests: XCTestCase {

    func testArrayAndDictReduction_addsTrimSentinelsAndCounts() {
        let input = """
        {
          "arr": [1,2,3,4,5,6,7,8,9,10],
          "b": 1, "c": 2, "d": 3, "e": 4,
          "f": 5, "g": 6, "h": 7, "i": 8
        }
        """
        let reduced = reduceJSON(input)

        let expected = #"{ "arr": [ 1, 2, 3, /* trimmed 5 items */, 9, 10 ], "b": 1, "c": 2, "d": 3, "e": 4, "f": 5, "g": 6, /* trimmed 2 keys */ }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    func testDictJustOverThreshold_addsSentinel() {
        // 1 collection + 7 scalars (total 8) with dictThreshold=6 → trimmed 1
        let input = #"{ "arr": [1,2,3,9,10], "a":1, "b":2, "c":3, "d":4, "e":5, "f":6, "g":7 }"#
        let reduced = reduceJSON(input)

        let expected = #"{ "arr": [ 1, 2, 3, 9, 10 ], "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, /* trimmed 1 keys */ }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    func testNestedCollections_getTrimmedWhereApplicable() {
        let input = """
        {
          "outer": [1,2,3,4,5,6,7,8,9],
          "obj": { "k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7 },
          "a":0, "b":1, "c":2, "d":3, "e":4, "f":5, "g":6
        }
        """
        let reduced = reduceJSON(input)

        let expected = #"{ "obj": { "k1": 1, "k2": 2, "k3": 3, "k4": 4, "k5": 5, "k6": 6, /* trimmed 1 keys */ }, "outer": [ 1, 2, 3, /* trimmed 4 items */, 8, 9 ], "a": 0, "b": 1, "c": 2, "d": 3, "e": 4, "f": 5, /* trimmed 1 keys */ }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    func testPassThroughOnInvalidJSON() {
        let input = #"not json at all"#
        let reduced = reduceJSON(input)
        // when input is invalid, reducer returns the same raw input (don't canonicalize here;
        // preserve exact equality to ensure callers don't get unexpected subtle changes)
        XCTAssertEqual(reduced, input)
    }

    func testScalarsAndBooleansPassThrough() {
        XCTAssertEqual(reduceJSON("1"), "1")
        XCTAssertEqual(reduceJSON("true"), "true")
        XCTAssertEqual(reduceJSON(#""hello""#), #""hello""#)
    }

    func testShortCollections_doNotAddSentinels() {
        let input = #"{ "arr": [1,2,3,9,10], "a":1, "b":2, "c":3, "d":4, "e":5 }"#
        let reduced = reduceJSON(input)

        let expected = #"{ "arr": [ 1, 2, 3, 9, 10 ], "a": 1, "b": 2, "c": 3, "d": 4, "e": 5 }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    // MARK: - Boundary & selection tests

    func testArrayExactlyAtBoundary_isNotTrimmed() {
        // head(3) + tail(2) = 5; exactly at boundary → no marker
        let input = #"{ "arr": [1,2,3,4,5] }"#
        let reduced = reduceJSON(input)
        let expected = #"{ "arr": [ 1, 2, 3, 4, 5 ] }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    func testObjectExactlyAtBoundary_isNotTrimmed() {
        // dictThreshold = 6 → no marker when total scalar keys == 6
        let input = #"{ "a":1, "b":2, "c":3, "d":4, "e":5, "f":6 }"#
        let reduced = reduceJSON(input)
        let expected = #"{ "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6 }"#
        XCTAssertReducerEqual(reduced, expected)
    }

    func testLargeObject_prefersCollectionsBeforeScalars() {
        // 3 collections + 8 scalars (total 11); keep 3 collections and 6 scalars → trimmed 2
        let input = #"{ "a":1, "b":2, "c":3, "A":[1,2,3], "B":{"x":1}, "C":[4], "d":4, "e":5, "f":6, "g":7, "h":8 }"#
        let reduced = reduceJSON(input)

        let expected = #"{ "A": [ 1, 2, 3 ], "B": { "x": 1 }, "C": [ 4 ], "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, /* trimmed 2 keys */ }"#
        XCTAssertReducerEqual(reduced, expected)
    }
}
