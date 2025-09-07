import XCTest
@testable import llminty

// Tiny shim so we always call the reducer via the module namespace.
private func reduceJSON(_ input: String) -> String {
    // @testable import exposes internal APIs; qualify with module name to avoid shadowing.
    return llminty.JSONReducer.reduceJSONPreservingStructure(text: input)
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

        // Array trimmed in the middle, keeps first 3 and last 2.
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #""arr": [ 1, 2, 3, «ANY»/* trimmed 5 items */«ANY», 9, 10 ]"#,
            source: input
        )
        // Dict trimmed sentinel present.
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #"/* trimmed 3 keys */"#,
            source: input
        )
    }

    func testDictJustOverThreshold_addsSentinel() {
        let input = #"{ "arr": [1,2,3,9,10], "a":1, "b":2, "c":3, "d":4, "e":5, "f":6 }"#
        let reduced = reduceJSON(input)

        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #"/* trimmed 1 keys */"#,
            source: input
        )
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

        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #""outer": [ 1, 2, 3, «ANY»/* trimmed 4 items */«ANY», 8, 9 ]"#,
            source: input
        )
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #""obj": «ANY»/* trimmed 1 keys */"#,
            source: input
        )
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #"/* trimmed 3 keys */"#,
            source: input
        )
    }

    func testPassThroughOnInvalidJSON() {
        let input = #"not json at all"#
        let reduced = reduceJSON(input)
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

        // Array untouched and no dict sentinel at this threshold (6 keys total including "arr").
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #""arr": [ 1, 2, 3, 9, 10 ]"#,
            source: input
        )
        assertTextNotMatchTemplate(
            actual: reduced,
            unexpectedTemplate: #"/* trimmed «ANY» keys */"#,
            source: input
        )
    }

    // MARK: - New boundary & selection tests

    func testArrayExactlyAtBoundary_isNotTrimmed() {
        // head(3) + tail(2) = 5; exactly at boundary → no marker
        let input = #"{ "arr": [1,2,3,4,5] }"#
        let reduced = reduceJSON(input)
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #""arr": [ 1, 2, 3, 4, 5 ]"#,
            source: input
        )
        assertTextNotMatchTemplate(
            actual: reduced,
            unexpectedTemplate: #"/* trimmed «ANY» items */"#,
            source: input
        )
    }

    func testObjectExactlyAtBoundary_isNotTrimmed() {
        // maximumDictionaryKeysKept = 6 → no marker when total keys == 6
        let input = #"{ "a":1, "b":2, "c":3, "d":4, "e":5, "f":6 }"#
        let reduced = reduceJSON(input)
        assertTextNotMatchTemplate(
            actual: reduced,
            unexpectedTemplate: #"/* trimmed «ANY» keys */"#,
            source: input
        )
    }

    func testLargeObject_prefersCollectionsBeforeScalars() {
        // 8 keys total; keep 6 → trimmed 2
        let input = #"{ "a":1, "b":2, "c":3, "A":[1,2,3], "B":{"x":1}, "C":[4], "d":4, "e":5 }"#
        let reduced = reduceJSON(input)

        // Sentinel count is right.
        assertTextMatchesTemplate(
            actual: reduced,
            expectedTemplate: #"/* trimmed 2 keys */"#,
            source: input
        )
        // All collection-valued keys remain visible somewhere in the object.
        assertTextMatchesTemplate(actual: reduced, expectedTemplate: #""A": [ 1, 2, 3 ]"#, source: input)
        assertTextMatchesTemplate(actual: reduced, expectedTemplate: #""B": «ANY»"#, source: input)
        assertTextMatchesTemplate(actual: reduced, expectedTemplate: #""C": [ 4 ]"#, source: input)
    }
}
