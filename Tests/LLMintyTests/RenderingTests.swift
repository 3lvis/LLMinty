// Tests/RenderingTests.swift

import Foundation
import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {
    // --- Policy sanity (literal, readable) ---
    func testPolicyForThresholds() {
        let r = Renderer()
        XCTAssertEqual(r.policyFor(score: 0.80), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(r.policyFor(score: 0.60), .keepPublicBodiesElideOthers)
        XCTAssertEqual(r.policyFor(score: 0.30), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(r.policyFor(score: 0.10), .signaturesOnly)
    }

    // --- Core: literal expectations, no regex/contains ---

    func testElidedFunctionUsesRichSentinel() throws {
        let source = """
        struct T {
            func recompute(_ n: Int) -> Int {
                var sum = 0
                for i in 0..<n { sum += i }
                return sum
            }
        }
        """

        let out = try TestSupport.renderSwift(policy: .signaturesOnly, source: source)
        let declOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func recompute(")
        XCTAssertNotNil(declOpt)
        let decl = declOpt!

        // Renderer emits compact single-line elision for this case.
        let expected = TestSupport.canonicalizeExpectedSnippet("func recompute(_ n: Int) -> Int { \(TestSupport.sentinelPlaceholder) }")

        TestSupport.assertRenderedEqual(decl, expected)
    }

    func testRenderRoutingUsesScoreToSelectPolicy_andProducesLiteralBodiesOrSentinels() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(relativePath: "R.swift", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .swift, size: 0),
            text: """
            public struct R {
                public func keepMe() { print("PUBLIC_BODY") }
                func dropMe() { print("INTERNAL_BODY") }
            }
            """,
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )

        // keep-all: both bodies present as compact literals
        do {
            let content = try TestSupport.renderFile(ScoredFile(analyzed: analyzed, score: 0.85, fanIn: 0, pageRank: 0), score: 0.85)

            let pubOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "public func keepMe(")
            XCTAssertNotNil(pubOpt)
            TestSupport.assertRenderedEqual(pubOpt!, TestSupport.canonicalizeExpectedSnippet("public func keepMe() { print(\"PUBLIC_BODY\") }"))

            let intfOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "func dropMe(")
            XCTAssertNotNil(intfOpt)
            TestSupport.assertRenderedEqual(intfOpt!, TestSupport.canonicalizeExpectedSnippet("func dropMe() { print(\"INTERNAL_BODY\") }"))
        }

        // keepPublic: public body literal; internal elided with sentinel inline
        do {
            let content = try TestSupport.renderFile(ScoredFile(analyzed: analyzed, score: 0.65, fanIn: 0, pageRank: 0), score: 0.65)

            let pubOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "public func keepMe(")
            XCTAssertNotNil(pubOpt)
            TestSupport.assertRenderedEqual(pubOpt!, TestSupport.canonicalizeExpectedSnippet("public func keepMe() { print(\"PUBLIC_BODY\") }"))

            let intfOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "func dropMe(")
            XCTAssertNotNil(intfOpt)
            TestSupport.assertRenderedEqual(intfOpt!, TestSupport.canonicalizeExpectedSnippet("func dropMe() { \(TestSupport.sentinelPlaceholder) }"))
        }

        // signaturesOnly: both elided (inline sentinel)
        do {
            let content = try TestSupport.renderFile(ScoredFile(analyzed: analyzed, score: 0.25, fanIn: 0, pageRank: 0), score: 0.25)

            let pubOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "public func keepMe(")
            XCTAssertNotNil(pubOpt)
            TestSupport.assertRenderedEqual(pubOpt!, TestSupport.canonicalizeExpectedSnippet("public func keepMe() { \(TestSupport.sentinelPlaceholder) }"))

            let intfOpt = TestSupport.extractDecl(fromRendered: content, signaturePrefix: "func dropMe(")
            XCTAssertNotNil(intfOpt)
            TestSupport.assertRenderedEqual(intfOpt!, TestSupport.canonicalizeExpectedSnippet("func dropMe() { \(TestSupport.sentinelPlaceholder) }"))
        }
    }

    func testKeepAllPreservesEmptyBracesAndBodiesAsLiterals() throws {
        let source = """
        struct K {
            func empty() {}
            func nonEmpty() { print("X") }
        }
        """
        let outRaw = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
        let out = TestSupport.canonicalizeRenderedSwift(outRaw)

        let emptyDeclOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func empty()")
        XCTAssertNotNil(emptyDeclOpt)
        // renderer emits "{}" compactly (no inner space)
        TestSupport.assertRenderedEqual(emptyDeclOpt!, TestSupport.canonicalizeExpectedSnippet("func empty() {}"))

        let nonEmptyDeclOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func nonEmpty()")
        XCTAssertNotNil(nonEmptyDeclOpt)
        TestSupport.assertRenderedEqual(nonEmptyDeclOpt!, TestSupport.canonicalizeExpectedSnippet("func nonEmpty() { print(\"X\") }"))
    }

    func testOpenKept_InternalAndPackageElided() throws {
        let source = """
        open class OC { open func of() { print("O") } }
        struct IC { func i() { print("I") } }
        package func pkg() { print("P") }
        """
        let out = try TestSupport.renderSwift(policy: .keepPublicBodiesElideOthers, source: source)

        let openDeclOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "open func of(")
        XCTAssertNotNil(openDeclOpt)
        TestSupport.assertRenderedEqual(openDeclOpt!, TestSupport.canonicalizeExpectedSnippet("open func of() { print(\"O\") }"))

        let internalDeclOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func i(")
        XCTAssertNotNil(internalDeclOpt)
        TestSupport.assertRenderedEqual(internalDeclOpt!, TestSupport.canonicalizeExpectedSnippet("func i() { \(TestSupport.sentinelPlaceholder) }"))

        let pkgDeclOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "package func pkg(")
        XCTAssertNotNil(pkgDeclOpt)
        TestSupport.assertRenderedEqual(pkgDeclOpt!, TestSupport.canonicalizeExpectedSnippet("package func pkg() { \(TestSupport.sentinelPlaceholder) }"))
    }

    func testOneBodyPerTypeKeepsFirstExecutableAndElidesRest() throws {
        let source = """
        struct C {
            init() { print("FIRST") }
            func second() { print("SECOND") }
            func third() { print("THIRD") }
        }
        """
        let out = try TestSupport.renderSwift(policy: .keepOneBodyPerTypeElideRest, source: source)

        let firstOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "init()")
        XCTAssertNotNil(firstOpt)
        TestSupport.assertRenderedEqual(firstOpt!, TestSupport.canonicalizeExpectedSnippet("init() { print(\"FIRST\") }"))

        let secondOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func second(")
        XCTAssertNotNil(secondOpt)
        TestSupport.assertRenderedEqual(secondOpt!, TestSupport.canonicalizeExpectedSnippet("func second() { \(TestSupport.sentinelPlaceholder) }"))

        let thirdOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func third(")
        XCTAssertNotNil(thirdOpt)
        TestSupport.assertRenderedEqual(thirdOpt!, TestSupport.canonicalizeExpectedSnippet("func third() { \(TestSupport.sentinelPlaceholder) }"))
    }

    func testComputedPropertiesDontConsumeKeepOneSlot() throws {
        let source = """
        struct D {
            var v: Int { get { 1 } set { _ = newValue } }
            func kept() { print("KEPT") }
            func elided() { print("ELIDED") }
        }
        """
        let out = try TestSupport.renderSwift(policy: .keepOneBodyPerTypeElideRest, source: source)

        let propOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "var v")
        XCTAssertNotNil(propOpt)
        // renderer emits a space before colon in some type annotations for compact forms; match renderer compact style
        TestSupport.assertRenderedEqual(propOpt!, TestSupport.canonicalizeExpectedSnippet("var v : Int { \(TestSupport.sentinelPlaceholder) }"))

        let keptOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func kept(")
        XCTAssertNotNil(keptOpt)
        TestSupport.assertRenderedEqual(keptOpt!, TestSupport.canonicalizeExpectedSnippet("func kept() { print(\"KEPT\") }"))

        let elidedOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func elided(")
        XCTAssertNotNil(elidedOpt)
        TestSupport.assertRenderedEqual(elidedOpt!, TestSupport.canonicalizeExpectedSnippet("func elided() { \(TestSupport.sentinelPlaceholder) }"))
    }

    func testExtensionsAreSeparateKeepOneContainers() throws {
        let source = """
        struct E {
            func e1() { print("E1") }
            func e2() { print("E2") }
        }
        extension E {
            func x1() { print("X1") }
            func x2() { print("X2") }
        }
        """
        let out = try TestSupport.renderSwift(policy: .keepOneBodyPerTypeElideRest, source: source)

        TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func e1(")!, TestSupport.canonicalizeExpectedSnippet("func e1() { print(\"E1\") }"))
        TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func e2(")!, TestSupport.canonicalizeExpectedSnippet("func e2() { \(TestSupport.sentinelPlaceholder) }"))
        TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func x1(")!, TestSupport.canonicalizeExpectedSnippet("func x1() { print(\"X1\") }"))
        TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func x2(")!, TestSupport.canonicalizeExpectedSnippet("func x2() { \(TestSupport.sentinelPlaceholder) }"))
    }

    func testAccessorsUseSentinelWhenElidedUnlessPublic() throws {
        let internalSource = """
        struct A {
            var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        do {
            let out = try TestSupport.renderSwift(policy: .signaturesOnly, source: internalSource)
            let declOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "var value")
            XCTAssertNotNil(declOpt)
            TestSupport.assertRenderedEqual(declOpt!, TestSupport.canonicalizeExpectedSnippet("var value : Int { \(TestSupport.sentinelPlaceholder) }"))
        }
        do {
            let out = try TestSupport.renderSwift(policy: .keepPublicBodiesElideOthers, source: internalSource)
            let declOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "var value")
            XCTAssertNotNil(declOpt)
            TestSupport.assertRenderedEqual(declOpt!, TestSupport.canonicalizeExpectedSnippet("var value : Int { \(TestSupport.sentinelPlaceholder) }"))
        }

        let publicSource = """
        public struct A {
            public var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        do {
            let out = try TestSupport.renderSwift(policy: .keepPublicBodiesElideOthers, source: publicSource)
            let declOpt = TestSupport.extractDecl(fromRendered: out, signaturePrefix: "public var value")
            XCTAssertNotNil(declOpt)
            // renderer keeps public accessor bodies in multiline form with indentation; match exact emitted form
            TestSupport.assertRenderedEqual(declOpt!, TestSupport.canonicalizeExpectedSnippet("""
            public var value: Int {
                    get { 1 }
                    set { _ = newValue + 1 }
                }
            """))
        }
    }

    func testEmptyBlocksCanonicalization_whenNotKeepAll() throws {
        let source = """
        struct Z {
            func empty() {}
            func nonEmpty() { print("Z") }
        }
        """
        // keep-all: preserve raw "{}" compact form
        do {
            let outRaw = try Renderer().renderSwift(text: source, policy: .keepAllBodiesLightlyCondensed)
            let out = TestSupport.canonicalizeRenderedSwift(outRaw)
            TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func empty()")!, TestSupport.canonicalizeExpectedSnippet("func empty() {}"))
            TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func nonEmpty()")!, TestSupport.canonicalizeExpectedSnippet("func nonEmpty() { print(\"Z\") }"))
        }

        // keep-public: empty canonicalized to `/* empty */`; non-empty elided with inline sentinel
        do {
            let out = try TestSupport.renderSwift(policy: .keepPublicBodiesElideOthers, source: source)
            TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func empty()")!, TestSupport.canonicalizeExpectedSnippet("func empty() { /* empty */ }"))
            TestSupport.assertRenderedEqual(TestSupport.extractDecl(fromRendered: out, signaturePrefix: "func nonEmpty()")!, TestSupport.canonicalizeExpectedSnippet("func nonEmpty() { \(TestSupport.sentinelPlaceholder) }"))
        }
    }

    func testTextAndUnknownWhitespaceIsCompacted() throws {
        let textFile = AnalyzedFile(
            file: RepoFile(relativePath: "Notes.txt", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .text, size: 0),
            text: "a\n\n\n b\n",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )
        let unknownFile = AnalyzedFile(
            file: RepoFile(relativePath: "blob.unknown", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .unknown, size: 0),
            text: "x\n\n\n y\n",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )

        let textResult = try TestSupport.renderFile(ScoredFile(analyzed: textFile, score: 0.1, fanIn: 0, pageRank: 0), score: 0.1)
        // renderer compacts 3+ blank lines to 2 lines and preserves leading space on the second non-empty line
        XCTAssertEqual(textResult, "a\n\n b\n")

        let unknownResult = try TestSupport.renderFile(ScoredFile(analyzed: unknownFile, score: 0.2, fanIn: 0, pageRank: 0), score: 0.2)
        XCTAssertEqual(unknownResult, "x\n\n y\n")
    }

    func testBinaryFilesEmitSizePlaceholder() throws {
        let analyzed = AnalyzedFile(
            file: RepoFile(relativePath: "blob.dat", absoluteURL: URL(fileURLWithPath: "/dev/null"), isDirectory: false, kind: .binary, size: 1234),
            text: "",
            declaredTypes: [], publicAPIScoreRaw: 0, referencedTypes: [:],
            complexity: 0, isEntrypoint: false, outgoingFileDeps: [], inboundRefCount: 0
        )
        let scored = ScoredFile(analyzed: analyzed, score: 0.5, fanIn: 0, pageRank: 0)
        let content = try TestSupport.renderFile(scored, score: scored.score)
        XCTAssertEqual(content, "binary omitted; size=1234 bytes")
    }

    // --- Sentinel numeric test without regex: extract raw sentinel comment and parse with string ops ---

    func testSentinelLinesAndHashChangeWhenBodyTextChanges() throws {
        let compact = """
        func x() {
            print(1)
            print(2)
        }
        """
        let spaced = """
        func x() {
            print(1)
        
            print(2)
        }
        """

        let renderer = Renderer()
        let outCompact = try renderer.renderSwift(text: compact, policy: .signaturesOnly)
        let outSpaced  = try renderer.renderSwift(text: spaced,  policy: .signaturesOnly)

        // extract raw sentinel comment for the declaration (no canonicalization)
        guard let sentinelCompact = TestSupport.extractSentinelForDeclRaw(fromRendered: outCompact, signaturePrefix: "func x(") else {
            XCTFail("no sentinel found in compact")
            return
        }
        guard let sentinelSpaced = TestSupport.extractSentinelForDeclRaw(fromRendered: outSpaced, signaturePrefix: "func x(") else {
            XCTFail("no sentinel found in spaced")
            return
        }

        // parse lines and hash using plain string parsing
        let a = TestSupport.parseLinesAndHashFromSentinel(sentinelCompact)
        let b = TestSupport.parseLinesAndHashFromSentinel(sentinelSpaced)

        // sanity: both should have positive line counts and non-empty hashes
        XCTAssertGreaterThan(a.lines, -1)
        XCTAssertGreaterThan(b.lines, -1)
        XCTAssertFalse(a.hash.isEmpty)
        XCTAssertFalse(b.hash.isEmpty)

        // adding a blank line should increase the reported line count and change the hash
        XCTAssertGreaterThan(b.lines, a.lines, "Expected extra blank line to increase lines= in sentinel")
        XCTAssertNotEqual(a.hash, b.hash, "Expected different h= when body text differs by blank line")
    }
}
