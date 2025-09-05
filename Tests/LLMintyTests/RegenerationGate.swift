// Tests/LLMintyTests/TestSupport/RegenerationGate.swift
import Foundation
import XCTest

/// Toggle file at repo root (by default) with shape: {"should_generate": true|false}
/// You can override the location by setting the env var LLMINTY_REGENERATE_FLAG_PATH.
enum RegenerationGate {
    struct Flag: Codable, Equatable {
        var should_generate: Bool
    }

    /// Resolve the JSON flag URL deterministically relative to the repo root, unless overridden.
    static func flagURL(filePath: StaticString = #filePath) -> URL {
        if let override = ProcessInfo.processInfo.environment["LLMINTY_REGENERATE_FLAG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // Repo root = …/Tests/LLMintyTests/… → …/Tests → repo root
        let repoRoot = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()  // …/LLMintyTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // repo root
        return repoRoot.appendingPathComponent("regenerate_contract.json")
    }

    static func read(_ url: URL) -> Flag? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Flag.self, from: data)
    }

    @discardableResult
    static func write(_ flag: Flag, to url: URL) throws -> URL {
        let data = try JSONEncoder().encode(flag)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Runs `work()` if flag exists and is true, and **always** flips it back to false afterward.
    /// Returns `true` iff the regeneration branch was executed.
    @discardableResult
    static func withGate(filePath: StaticString = #filePath, _ work: () throws -> Void) throws -> Bool {
        let url = flagURL(filePath: filePath)
        guard var flag = read(url), flag.should_generate == true else {
            throw XCTSkip("No \(url.lastPathComponent) with {\"should_generate\": true}; skipping regeneration.")
        }

        // Always flip back to false, even if work() throws.
        defer {
            flag.should_generate = false
            // Swallow errors on flip so test result depends on `work()`, not file I/O.
            try? write(flag, to: url)
        }

        try work()
        return true
    }
}
