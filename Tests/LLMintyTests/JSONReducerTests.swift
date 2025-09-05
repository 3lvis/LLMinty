import XCTest
@testable import llminty

final class JSONReducerTests: XCTestCase {
    func testArrayAndDictReduction() {
        let json = "{\"arr\":[1,2,3,4,5,6,7,8,9,10],\"b\":1,\"c\":2,\"d\":3,\"e\":4,\"f\":5,\"g\":6,\"h\":7,\"i\":8}"
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)

        // Array: keeps first 3 and last 2 => 5 omitted
        XCTAssertTrue(reduced.contains("/* ... 5 items omitted ... */"), reduced)

        // Dict: 8 keys, keeps 6 => 2 omitted (mind the Unicode ellipsis `…`)
        XCTAssertTrue(
            reduced.contains("\"//\": \"… 3 keys omitted …\"") ||
            reduced.contains("\"//\":\"… 3 keys omitted …\""),
            reduced
        )

        XCTAssertEqual(reduced.first, "{")
        XCTAssertEqual(reduced.last, "}")
    }

    func testPassThroughOnInvalidJSON() {
        let notJSON = "hello"
        let out = JSONReducer.reduceJSONPreservingStructure(text: notJSON)
        XCTAssertEqual(out, notJSON)
    }
}
