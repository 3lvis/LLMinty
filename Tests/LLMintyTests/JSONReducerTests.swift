// Tests/LLMintyTests/JSONReducerTests.swift
import XCTest
@testable import llminty

final class JSONReducerTests: XCTestCase {
    
    func testArrayAndDictReduction_addsTrimSentinelsAndCounts() {
        // Top-level dict has 9 keys: arr + b..i (8) -> keep 6 -> trimmed 3 keys
        // Array has 10 items -> keep 3 head + 2 tail = 5 -> trimmed 5 items
        let json = """
        {
          "arr": [1,2,3,4,5,6,7,8,9,10],
          "b": 1, "c": 2, "d": 3, "e": 4,
          "f": 5, "g": 6, "h": 7, "i": 8
        }
        """
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)
        
        // Array sentinel
        XCTAssertTrue(
            reduced.contains("/* trimmed 5 items */"),
            "Expected array sentinel '/* trimmed 5 items */'. Got:\n\(reduced)"
        )
        // Head & tail still visible around the sentinel
        XCTAssertTrue(reduced.contains("[1, 2, 3, /* trimmed 5 items */, 9, 10]"), reduced)
        
        // Dict sentinel at the end
        XCTAssertTrue(
            reduced.contains("/* trimmed 3 keys */"),
            "Expected dict sentinel '/* trimmed 3 keys */'. Got:\n\(reduced)"
        )
        
        // Still looks like an object
        XCTAssertEqual(reduced.first, "{")
        XCTAssertEqual(reduced.last, "}")
    }
    
    func testShortCollections_doNotAddSentinels() {
        // dictKeep = 6. Include exactly 6 keys total: "arr" + 5 scalars.
        // Array length = 5 (== head+tail) -> no array sentinel; dict <= 6 -> no dict sentinel.
        let json = """
    { "arr": [1,2,3,9,10],
      "a":1, "b":2, "c":3, "d":4, "e":5 }
    """
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)
        
        // No trim sentinels anywhere
        XCTAssertFalse(reduced.contains("/* trimmed"), "No trim sentinel should appear for short collections.\n\(reduced)")
        
        // Array preserved as-is (spacing tolerant)
        XCTAssertTrue(reduced.contains("\"arr\": [1, 2, 3, 9, 10]") ||
                      reduced.contains("\"arr\":[1, 2, 3, 9, 10]") ||
                      reduced.contains("\"arr\":[1,2,3,9,10]"),
                      reduced)
    }
    
    func testDictJustOverThreshold_addsSentinel() {
        // 7 keys total: "arr" + 6 scalars -> exceeds dictKeep; expect sentinel.
        let json = """
    { "arr": [1,2,3,9,10],
      "a":1, "b":2, "c":3, "d":4, "e":5, "f":6 }
    """
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)
        XCTAssertTrue(reduced.contains("/* trimmed 1 keys */") || reduced.contains("/* trimmed"), reduced)
    }
    
    func testNestedCollections_getTrimmedWhereApplicable() {
        // Outer dict has >6 keys -> expect dict trim sentinel.
        // 'outer' array has 9 items -> keep 3 + 2 -> trimmed 4 items.
        let json = """
        {
          "outer": [1,2,3,4,5,6,7,8,9],
          "obj": { "k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7 },
          "a":0, "b":1, "c":2, "d":3, "e":4, "f":5, "g":6
        }
        """
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)
        
        // Array sentinel inside "outer"
        XCTAssertTrue(reduced.contains("/* trimmed 4 items */"), reduced)
        // Dict sentinel at the top-level
        XCTAssertTrue(reduced.contains("/* trimmed"), "Expected some dict trim sentinel at top-level.\n\(reduced)")
    }
    
    func testScalarsAndBooleansPassThrough() {
        XCTAssertEqual(JSONReducer.reduceJSONPreservingStructure(text: "42"), "42")
        XCTAssertEqual(JSONReducer.reduceJSONPreservingStructure(text: "\"hello\""), "\"hello\"")
        XCTAssertEqual(JSONReducer.reduceJSONPreservingStructure(text: "true"), "true")
        XCTAssertEqual(JSONReducer.reduceJSONPreservingStructure(text: "false"), "false")
        XCTAssertEqual(JSONReducer.reduceJSONPreservingStructure(text: "null"), "null")
    }
    
    func testPassThroughOnInvalidJSON() {
        let notJSON = "hello"
        let out = JSONReducer.reduceJSONPreservingStructure(text: notJSON)
        XCTAssertEqual(out, notJSON)
    }
}
