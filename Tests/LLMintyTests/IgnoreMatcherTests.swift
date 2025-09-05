
import XCTest
@testable import llminty

final class IgnoreMatcherTests: XCTestCase {
    func testGlobAnchorsAndNegation() throws {
        let userPatterns = """
        build/
        *.png
        !Assets/logo.png
        /rootOnly.txt
        **/*.tmp
        Docs/**
        notes?.md
        """
        let matcher = try IgnoreMatcher(builtInPatterns: [], userFileText: userPatterns)

        // dirOnly should only match directories (files under ignored dirs are handled by scanner's skipDescendants)
        XCTAssertTrue(matcher.isIgnored("build", isDirectory: true))
        XCTAssertFalse(matcher.isIgnored("build/app.o", isDirectory: false))

        // simple glob + negation
        XCTAssertTrue(matcher.isIgnored("file.png", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored("Assets/logo.png", isDirectory: false)) // re-included

        // root anchored
        XCTAssertTrue(matcher.isIgnored("rootOnly.txt", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored("nested/rootOnly.txt", isDirectory: false))

        // ** any depth + segment globs
        XCTAssertTrue(matcher.isIgnored("x/y/z/a.tmp", isDirectory: false))
        XCTAssertTrue(matcher.isIgnored("Docs/guide.md", isDirectory: false))

        // single-char '?'
        XCTAssertTrue(matcher.isIgnored("notes1.md", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored("notes10.md", isDirectory: false))
    }
}
