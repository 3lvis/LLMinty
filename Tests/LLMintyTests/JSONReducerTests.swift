import XCTest
@testable import llminty

// Tiny shim so we always call the reducer via the module namespace.
private func reduceJSON(_ input: String) -> String {
    // Call the namespaced entry point with explicit thresholds.
    return llminty.JSONReducer.reduceJSONPreservingStructure(
        input,
        arrayThreshold: 5,
        dictThreshold: 6
    )
}

final class JSONReducerTests: XCTestCase {

    func testArrayAndDictReduction_addsTrimSentinelsAndCounts() {
        let input = """
        {
          "arr": [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10
          ],
          "b": 1,
          "c": 2,
          "d": 3,
          "e": 4,
          "f": 5,
          "g": 6,
          "h": 7,
          "i": 8
        }
        """
        let reduced = reduceJSON(input)

        let expected = """
        {
          "arr": [
            1,
            2,
            /* trimmed 7 items */,
            10
          ],
          "b": 1,
          /* trimmed 7 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }

    func testDictJustOverThreshold_addsSentinel() {
        // 1 collection + 7 scalars (total 8) with dictThreshold=6 → trimmed aggressively
        let input = """
        {
          "arr": [1, 2, 3, 9, 10],
          "a": 1,
          "b": 2,
          "c": 3,
          "d": 4,
          "e": 5,
          "f": 6,
          "g": 7
        }
        """
        let reduced = reduceJSON(input)

        let expected = """
        {
          "arr": [
            1,
            2,
            3,
            9,
            10
          ],
          "a": 1,
          /* trimmed 6 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }

    func testNestedCollections_getTrimmedWhereApplicable() {
        let input = """
        {
          "outer": [1, 2, 3, 4, 5, 6, 7, 8, 9],
          "obj": {
            "k1": 1,
            "k2": 2,
            "k3": 3,
            "k4": 4,
            "k5": 5,
            "k6": 6,
            "k7": 7
          },
          "a": 0,
          "b": 1,
          "c": 2,
          "d": 3,
          "e": 4,
          "f": 5,
          "g": 6
        }
        """
        let reduced = reduceJSON(input)

        let expected = """
        {
          "obj": {
            "k1": 1,
            /* trimmed 6 keys */
          },
          "outer": [
            1,
            2,
            /* trimmed 6 items */,
            9
          ],
          "a": 0,
          /* trimmed 6 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
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

    func testShortCollections_doNotAddSentinels_but_scalars_get_capped() {
        let input = """
        {
          "arr": [1, 2, 3, 9, 10],
          "a": 1,
          "b": 2,
          "c": 3,
          "d": 4,
          "e": 5
        }
        """
        let reduced = reduceJSON(input)

        let expected = """
        {
          "arr": [
            1,
            2,
            3,
            9,
            10
          ],
          "a": 1,
          /* trimmed 4 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }

    func testArrayExactlyAtBoundary_isNotTrimmed() {
        let input = """
        {
          "arr": [1, 2, 3, 4, 5]
        }
        """
        let reduced = reduceJSON(input)
        let expected = """
        {
          "arr": [
            1,
            2,
            3,
            4,
            5
          ]
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }

    func testObjectExactlyAtBoundary_is_trimmed_aggressively() {
        let input = """
        {
          "a": 1,
          "b": 2,
          "c": 3,
          "d": 4,
          "e": 5,
          "f": 6
        }
        """
        let reduced = reduceJSON(input)
        let expected = """
        {
          "a": 1,
          /* trimmed 5 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }

    func testLargeObject_prefersCollectionsBeforeScalars() {
        let input = """
        {
          "a": 1,
          "b": 2,
          "c": 3,
          "A": [1, 2, 3],
          "B": { "x": 1 },
          "C": [4],
          "d": 4,
          "e": 5,
          "f": 6,
          "g": 7,
          "h": 8
        }
        """
        let reduced = reduceJSON(input)

        let expected = """
        {
          "A": [
            1,
            2,
            3
          ],
          "B": {
            "x": 1
          },
          "C": [
            4
          ],
          "a": 1,
          /* trimmed 7 keys */
        }
        """
        TestSupport.XCTAssertReducerEqual(reduced, expected)
    }
}
