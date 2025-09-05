
import XCTest
@testable import llminty

final class JSONReducerTests: XCTestCase {
    func testArrayAndDictReduction() {
        let json = "{\"arr\":[1,2,3,4,5,6,7,8,9,10],\"b\":1,\"c\":2,\"d\":3,\"e\":4,\"f\":5,\"g\":6,\"h\":7,\"i\":8}"
        let reduced = JSONReducer.reduceJSONPreservingStructure(text: json)
        // Should include a trimmed marker for the array
        XCTAssertTrue(reduced.contains("\"//\":\"trimmed"))
        XCTAssertTrue(reduced.contains("// trimmed"))
        XCTAssertTrue(reduced.first == "{")
        XCTAssertTrue(reduced.last == "}")
    }

    func testPassThroughOnInvalidJSON() {
        let notJSON = "hello"
        let out = JSONReducer.reduceJSONPreservingStructure(text: notJSON)
        XCTAssertEqual(out, notJSON)
    }
}
