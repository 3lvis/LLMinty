// Tests/LLMintyTests/ChecklistContractTests.swift
import XCTest
@testable import llminty

final class ChecklistContractTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private var contractSpecURL: URL { fixturesDir.appendingPathComponent("contract_spec.json") }
    private var zipURL: URL { fixturesDir.appendingPathComponent("LLMinty-nohidden.zip") }

    struct Contract: Codable {
        struct Entry: Codable { var file: String; var symbols: [String] }
        var need: [Entry]
        var can_elide: [Entry]
    }

    func testChecklistAgainstSnapshotFixtures() throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw XCTSkip("No Fixtures/LLMinty-nohidden.zip; skipping")
        }
        guard FileManager.default.fileExists(atPath: contractSpecURL.path) else {
            throw XCTSkip("No Fixtures/contract_spec.json; provide your spec.")
        }

        let contractData = try Data(contentsOf: contractSpecURL)
        let contract = try JSONDecoder().decode(Contract.self, from: contractData)

        let minty = try GoldenSnapshotTests().runMintyOnZippedSnapshot(zipURL)

        for need in contract.need {
            guard let section = findSection(in: minty, forPath: need.file) else {
                XCTFail("Missing FILE section for \(need.file)"); continue
            }
            for sym in need.symbols {
                XCTAssertTrue(section.contains(sym), "Expected \(need.file) to contain \(sym)")
            }
        }
        for allow in contract.can_elide {
            guard let section = findSection(in: minty, forPath: allow.file) else {
                XCTFail("Missing FILE section for \(allow.file)"); continue
            }
            for sym in allow.symbols {
                XCTAssertTrue(section.contains(sym), "Expected \(allow.file) to contain signature \(sym)")
            }
        }
    }

    private func findSection(in minty: String, forPath path: String) -> String? {
        let tag = "FILE: \(path)"
        let lines = minty.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == tag }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].starts(with: "FILE: ") { end += 1 }
        return lines[start..<end].joined(separator: "\n")
    }
}
