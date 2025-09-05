// Tests/LLMintyTests/GoldenSnapshotTests.swift
import XCTest
@testable import llminty

final class GoldenSnapshotTests: XCTestCase {

    func testGoldenAgainstSnapshotFixtures() throws {
        guard let zip = TestSupport.fixtureURLIfExists("LLMinty-nohidden.zip") else {
            throw XCTSkip("Missing Fixtures/LLMinty-nohidden.zip; skipping golden test.")
        }
        guard let expectedURL = TestSupport.fixtureURLIfExists("expected_minty.txt") else {
            throw XCTSkip("Missing Fixtures/expected_minty.txt; skipping golden test.")
        }

        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llminty-golden-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let root = try TestSupport.unzip(zip, to: tmp)
        let actualText = TestSupport.normalized(try TestSupport.runLLMinty(in: root))
        let expectedText = TestSupport.normalized(try String(contentsOf: expectedURL, encoding: .utf8))

        if let diff = TestSupport.diffLines(expected: expectedText, actual: actualText) {
            XCTFail("Golden mismatch.\n" + diff)
        }
    }

    /// If Fixtures/regenerate_contract.json contains {"should_generate": true},
    /// regenerate both expected_minty.txt and contract_spec.json, then set should_generate=false.
    func testRegenerateExpectedAndContractIfRequested() throws {
        guard let zip = TestSupport.fixtureURLIfExists("LLMinty-nohidden.zip") else {
            throw XCTSkip("Missing Fixtures/LLMinty-nohidden.zip; cannot regenerate.")
        }
        guard var cfg = TestSupport.loadRegenerateConfig(), cfg.should_generate == true else {
            throw XCTSkip("No regenerate_contract.json with {\"should_generate\": true}; skipping regeneration.")
        }

        let fm = FileManager.default
        let fixtures = TestSupport.fixturesDir()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llminty-regenerate-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let root = try TestSupport.unzip(zip, to: tmp)
        let actualText = TestSupport.normalized(try TestSupport.runLLMinty(in: root))

        // 1) Write expected golden
        let expectedURL = fixtures.appendingPathComponent("expected_minty.txt")
        try actualText.write(to: expectedURL, atomically: true, encoding: .utf8)

        // 2) Write contract_spec.json based on our canonical checklist
        let spec = TestSupport.defaultContract()
        try TestSupport.saveContractSpec(spec)

        // 3) Flip should_generate -> false
        cfg.should_generate = false
        try TestSupport.saveRegenerateConfig(cfg)

        // Sanity
        let roundTrip = try String(contentsOf: expectedURL, encoding: .utf8)
        XCTAssertFalse(roundTrip.isEmpty, "Regenerated expected_minty.txt is empty?")
    }
}
