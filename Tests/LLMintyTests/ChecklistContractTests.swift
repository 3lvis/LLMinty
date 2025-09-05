// Tests/LLMintyTests/ChecklistContractTests.swift
import XCTest
@testable import llminty

final class ChecklistContractTests: XCTestCase {

    func testChecklistAgainstSnapshotFixtures() throws {
        guard let zip = TestSupport.fixtureURLIfExists("LLMinty-nohidden.zip") else {
            throw XCTSkip("Place snapshot at Tests/LLMintyTests/Fixtures/LLMinty-nohidden.zip to run this test.")
        }

        // Load contract spec (or default)
        let spec = TestSupport.loadContractSpecIfAny() ?? TestSupport.defaultContract()

        // Prepare sandbox and run app
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llminty-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let root = try TestSupport.unzip(zip, to: tmp)
        let text = try TestSupport.runLLMinty(in: root)
        let sections = TestSupport.parseMintySections(text)
        let all = Set(sections.keys)

        // MUST include files
        let missing = spec.must_include_files.filter { !all.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Missing required FILE sections: \(missing)")

        // Key signatures present (bodies may be elided)
        for (path, tokens) in spec.must_have_tokens {
            guard let body = sections[path] else {
                XCTFail("Missing FILE section for token check: \(path)")
                continue
            }
            for t in tokens {
                XCTAssertTrue(body.contains(t), "Expected token '\(t)' in \(path)")
            }
        }
    }
}
