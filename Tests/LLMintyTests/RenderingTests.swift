import XCTest
@testable import llminty

final class RenderingTests: XCTestCase {

    // MARK: - Shared Regex Helper (kept minimal; used in multiple tests)

    /// Regex used when a rich sentinel replaces an implementation body.
    private static let richSentinelPattern =
    #"\{\s*/\*\s*elided-implemented;\s*lines=\d+;\s*h=[0-9a-f]{8,12}\s*\*/\s*\}"#

    private func containsMatch(in text: String, pattern: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Existing baseline tests

    /// Verifies the score → policy thresholds.
    func testPolicyForThresholds() {
        let renderer = Renderer()
        XCTAssertEqual(renderer.policyFor(score: 0.80), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(renderer.policyFor(score: 0.60), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.30), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.10), .signaturesOnly)
    }

    /// Verifies `.keepPublicBodiesElideOthers` keeps public bodies and elides non-public bodies without using the rich sentinel.
    func testRenderSwiftElidesNonPublicBodiesUnderPolicy() throws {
        let longInternalBody = (0..<20).map { _ in "print(\"x\")" }.joined(separator: "\n        ")

        let swiftSource = """
        public struct S {
            public init() {}
            public func pub() { let x = 1; print(x) }
            func internalOne() {
                \(longInternalBody)
            }
        }
        """

        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepPublicBodiesElideOthers)

        XCTAssertTrue(rendered.contains("public func pub()"))
        XCTAssertTrue(rendered.contains("func internalOne()"))

        XCTAssertFalse(containsMatch(in: rendered, pattern: Self.richSentinelPattern))
        XCTAssertTrue(rendered.contains("{ ... }"))
    }

    /// Verifies whitespace compaction collapses 3+ consecutive blank lines to 1 for text/unknown content.
    func testRenderTextCompactsWhitespace() throws {
        let analyzedTextFile = AnalyzedFile(
            file: RepoFile(
                relativePath: "Notes.txt",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .text,
                size: 0
            ),
            text: "a\n\n\n b\n",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let scoredTextFile = ScoredFile(analyzed: analyzedTextFile, score: 0.1, fanIn: 0, pageRank: 0.0)

        let renderedContent = try Renderer().render(file: scoredTextFile, score: scoredTextFile.score).content

        XCTAssertFalse(renderedContent.contains("\n\n\n"))
        XCTAssertTrue(renderedContent.contains("\n\n"))
    }

    /// Verifies `.signaturesOnly` replaces bodies with the rich sentinel.
    func testElidedFuncUsesRichSentinel() throws {
        let swiftSource = """
        struct T {
            func recompute(_ n: Int) -> Int {
                var sum = 0
                for i in 0..<n { sum += i }
                return sum
            }
        }
        """

        let rendered = try Renderer().renderSwift(text: swiftSource, policy: .signaturesOnly)

        XCTAssertTrue(rendered.contains("func recompute"))
        XCTAssertTrue(containsMatch(in: rendered, pattern: Self.richSentinelPattern))
    }

    /// Verifies the sentinel’s short hash is stable for identical input.
    func testSentinelHashIsStableForSameInput() throws {
        let swiftSource = """
        func foo() {
            let items = (0..<10).map { $0 * 2 }
            print(items.reduce(0, +))
        }
        """

        let renderer = Renderer()
        let firstRender = try renderer.renderSwift(text: swiftSource, policy: .signaturesOnly)
        let secondRender = try renderer.renderSwift(text: swiftSource, policy: .signaturesOnly)

        let hashCapturePattern = #"h=([0-9a-f]{8,12})"#
        let regex = try! NSRegularExpression(pattern: hashCapturePattern)

        let firstRange = NSRange(firstRender.startIndex..., in: firstRender)
        let secondRange = NSRange(secondRender.startIndex..., in: secondRender)

        guard let firstMatch = regex.firstMatch(in: firstRender, range: firstRange) else {
            XCTFail("Expected to capture a hash from the first rendering")
            return
        }
        guard let secondMatch = regex.firstMatch(in: secondRender, range: secondRange) else {
            XCTFail("Expected to capture a hash from the second rendering")
            return
        }

        let firstHash = (firstRender as NSString).substring(with: firstMatch.range(at: 1))
        let secondHash = (secondRender as NSString).substring(with: secondMatch.range(at: 1))

        XCTAssertEqual(firstHash, secondHash)
    }

    // MARK: - Core additions

    /// Verifies policy boundaries are inclusive at cutoffs.
    func testPolicyBoundariesAreInclusiveAtCutoffs() {
        let renderer = Renderer()
        XCTAssertEqual(renderer.policyFor(score: 0.8000), .keepAllBodiesLightlyCondensed)
        XCTAssertEqual(renderer.policyFor(score: 0.7999), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.6000), .keepPublicBodiesElideOthers)
        XCTAssertEqual(renderer.policyFor(score: 0.5999), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.3000), .keepOneBodyPerTypeElideRest)
        XCTAssertEqual(renderer.policyFor(score: 0.2999), .signaturesOnly)
    }

    /// Verifies render(file:score:) routes to the correct policy.
    func testRenderRoutingUsesScoreToSelectPolicy() throws {
        let analyzedSwiftFile = AnalyzedFile(
            file: RepoFile(
                relativePath: "R.swift",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .swift,
                size: 0
            ),
            text:
            """
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

        let renderer = Renderer()

        let keepAll = try renderer.render(file: ScoredFile(analyzed: analyzedSwiftFile, score: 0.85, fanIn: 0, pageRank: 0), score: 0.85).content
        XCTAssertTrue(keepAll.contains("PUBLIC_BODY"))
        XCTAssertTrue(keepAll.contains("INTERNAL_BODY"))

        let keepPublic = try renderer.render(file: ScoredFile(analyzed: analyzedSwiftFile, score: 0.65, fanIn: 0, pageRank: 0), score: 0.65).content
        XCTAssertTrue(keepPublic.contains("PUBLIC_BODY"))
        XCTAssertFalse(keepPublic.contains("INTERNAL_BODY"))
        XCTAssertFalse(containsMatch(in: keepPublic, pattern: Self.richSentinelPattern))
        XCTAssertTrue(keepPublic.contains("{ ... }"))

        let signaturesOnly = try renderer.render(file: ScoredFile(analyzed: analyzedSwiftFile, score: 0.25, fanIn: 0, pageRank: 0), score: 0.25).content
        XCTAssertFalse(signaturesOnly.contains("PUBLIC_BODY"))
        XCTAssertFalse(signaturesOnly.contains("INTERNAL_BODY"))
        XCTAssertTrue(containsMatch(in: signaturesOnly, pattern: Self.richSentinelPattern))
    }

    /// Verifies `.keepAllBodiesLightlyCondensed` keeps bodies and does not canonicalize `{}`.
    func testKeepAllBodiesDoesNotElideOrCanonicalize() throws {
        let swiftSource = """
        struct K {
            func empty() {}
            func nonEmpty() { print("X") }
        }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepAllBodiesLightlyCondensed)
        XCTAssertTrue(rendered.contains("print(\"X\")"))
        XCTAssertTrue(rendered.contains("{}"))
        XCTAssertFalse(containsMatch(in: rendered, pattern: Self.richSentinelPattern))
    }

    /// Verifies `open` is kept and `internal`/`package` are elided under `.keepPublicBodiesElideOthers`.
    func testOpenIsKept_InternalAndPackageAreElided() throws {
        let swiftSource = """
        open class OC { open func of() { print("O") } }
        struct IC { func i() { print("I") } }
        package func pkg() { print("P") }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepPublicBodiesElideOthers)

        XCTAssertTrue(rendered.contains("open func of()"))
        XCTAssertTrue(rendered.contains("print(\"O\")"))

        XCTAssertTrue(rendered.contains("func i()"))
        XCTAssertFalse(rendered.contains("print(\"I\")"))

        XCTAssertTrue(rendered.contains("package func pkg()"))
        XCTAssertFalse(rendered.contains("print(\"P\")"))

        XCTAssertFalse(containsMatch(in: rendered, pattern: Self.richSentinelPattern))
        XCTAssertTrue(rendered.contains("{ ... }"))
    }

    /// Verifies sentinels only appear under `.signaturesOnly`.
    func testKeepPublicBodiesDoesNotEmitSentinel() throws {
        let swiftSource = """
        public struct A {
            public func f() { print("A") }
            func g() { print("B") }
        }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepPublicBodiesElideOthers)
        XCTAssertFalse(containsMatch(in: rendered, pattern: Self.richSentinelPattern))
    }

    /// Verifies `.keepOneBodyPerTypeElideRest` keeps only the first executable per container.
    func testOneBodyPerContainerOnlyFirstExecutableIsKept() throws {
        let swiftSource = """
        struct C {
            init() { print("FIRST") }
            func second() { print("SECOND") }
            func third() { print("THIRD") }
        }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(rendered.contains("print(\"FIRST\")"))
        XCTAssertFalse(rendered.contains("print(\"SECOND\")"))
        XCTAssertFalse(rendered.contains("print(\"THIRD\")"))
        XCTAssertTrue(rendered.contains("{ ... }"))
    }

    /// Verifies computed properties do not claim the “one body” slot under `.keepOneBodyPerTypeElideRest`.
    func testComputedPropertiesDoNotCountTowardOne() throws {
        let swiftSource = """
        struct D {
            var v: Int { get { 1 } set { _ = newValue } }
            func kept() { print("KEPT") }
            func elided() { print("ELIDED") }
        }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(rendered.contains("print(\"KEPT\")"))
        XCTAssertFalse(rendered.contains("print(\"ELIDED\")"))
        XCTAssertTrue(rendered.contains("{ ... }"))
    }

    /// Verifies extensions are treated as separate containers for “one body”.
    func testExtensionsAreSeparateContainers() throws {
        let swiftSource = """
        struct E {
            func e1() { print("E1") }
            func e2() { print("E2") }
        }
        extension E {
            func x1() { print("X1") }
            func x2() { print("X2") }
        }
        """
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepOneBodyPerTypeElideRest)
        XCTAssertTrue(rendered.contains("print(\"E1\")"))
        XCTAssertFalse(rendered.contains("print(\"E2\")"))
        XCTAssertTrue(rendered.contains("print(\"X1\")"))
        XCTAssertFalse(rendered.contains("print(\"X2\")"))
    }

    /// Verifies accessors emit a sentinel only under `.signaturesOnly`.
    func testAccessorsSentinelOnlyUnderSignaturesOnly() throws {
        let swiftSource = """
        public struct A {
            public var value: Int {
                get { 1 }
                set { _ = newValue + 1 }
            }
        }
        """
        let renderer = Renderer()

        let signaturesOnly = try renderer.renderSwift(text: swiftSource, policy: .signaturesOnly)
        XCTAssertTrue(containsMatch(in: signaturesOnly, pattern: Self.richSentinelPattern))

        let keepPublic = try renderer.renderSwift(text: swiftSource, policy: .keepPublicBodiesElideOthers)
        XCTAssertFalse(containsMatch(in: keepPublic, pattern: Self.richSentinelPattern))
    }

    /// Verifies empty blocks are canonicalized to `{ ... }` when policy is not `keepAllBodiesLightlyCondensed`.
    func testCanonicalizeEmptyBlocksOnlyWhenPolicyIsNotKeepAll() throws {
        let swiftSource = """
        struct Z {
            func empty() {}
            func nonEmpty() { print("Z") }
        }
        """
        let renderer = Renderer()

        let keepAll = try renderer.renderSwift(text: swiftSource, policy: .keepAllBodiesLightlyCondensed)
        XCTAssertTrue(keepAll.contains("{}"))

        let keepPublic = try renderer.renderSwift(text: swiftSource, policy: .keepPublicBodiesElideOthers)
        XCTAssertFalse(keepPublic.contains("{}"))
        XCTAssertTrue(keepPublic.contains("{ ... }"))
    }

    /// Verifies Swift whitespace normalization: CRLF→LF, trailing spaces trimmed, multiple blanks collapsed.
    func testSwiftWhitespaceNormalization() throws {
        let swiftSource = "struct N {\r\n    func f() { let a = 1   \r\n\r\n\r\n        print(a) }\r\n}\r\n"
        let renderer = Renderer()
        let rendered = try renderer.renderSwift(text: swiftSource, policy: .keepAllBodiesLightlyCondensed)
        XCTAssertFalse(rendered.contains("\r\n"))
        XCTAssertFalse(rendered.contains("1   \n"))
        XCTAssertFalse(rendered.contains("\n\n\n"))
        XCTAssertTrue(rendered.contains("\n\n"))
    }

    /// Verifies binary files emit a size placeholder.
    func testBinaryFilesEmitSizePlaceholder() throws {
        let analyzedBinary = AnalyzedFile(
            file: RepoFile(
                relativePath: "blob.dat",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .binary,
                size: 1234
            ),
            text: "",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let scoredBinary = ScoredFile(analyzed: analyzedBinary, score: 0.5, fanIn: 0, pageRank: 0)
        let rendered = try Renderer().render(file: scoredBinary, score: scoredBinary.score).content
        XCTAssertTrue(rendered.contains("binary omitted; size=1234 bytes"))
    }

    /// Verifies unknown files get whitespace compaction like text files.
    func testUnknownFilesWhitespaceCompaction() throws {
        let analyzedUnknown = AnalyzedFile(
            file: RepoFile(
                relativePath: "blob.unknown",
                absoluteURL: URL(fileURLWithPath: "/dev/null"),
                isDirectory: false,
                kind: .unknown,
                size: 0
            ),
            text: "x\n\n\n y\n",
            declaredTypes: [],
            publicAPIScoreRaw: 0,
            referencedTypes: [:],
            complexity: 0,
            isEntrypoint: false,
            outgoingFileDeps: [],
            inboundRefCount: 0
        )
        let scoredUnknown = ScoredFile(analyzed: analyzedUnknown, score: 0.2, fanIn: 0, pageRank: 0)
        let rendered = try Renderer().render(file: scoredUnknown, score: scoredUnknown.score).content
        XCTAssertFalse(rendered.contains("\n\n\n"))
        XCTAssertTrue(rendered.contains("\n\n"))
    }
}
