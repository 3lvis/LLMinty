import Foundation

enum FileKind {
    case swift, json, text, binary, unknown
}

struct RepoFile {
    let relativePath: String
    let absoluteURL: URL
    let isDirectory: Bool
    let kind: FileKind
    let size: UInt64
}

enum ScanLimits {
    static let maxFileBytes: UInt64 = 2 * 1024 * 1024 // 2 MB per file cap
}

struct FileScanner {
    let root: URL
    let matcher: IgnoreMatcher

    func scan() throws -> [RepoFile] {
        var results: [RepoFile] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw NSError(domain: "llminty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate directory"])
        }

        for case let url as URL in enumerator {
            let rel = (url.path).path(replacingBase: root.path)
            let rIsDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if matcher.isIgnored(rel, isDirectory: rIsDir) {
                if rIsDir { enumerator.skipDescendants() }
                continue
            }
            if rIsDir { continue }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
            let ext = url.pathExtension.lowercased()
            let kind: FileKind
            switch ext {
            case "swift": kind = .swift
            case "json":  kind = .json
            case "md", "yml", "yaml", "xml", "plist", "txt", "sh", "toml": kind = .text
            default:
                if size > ScanLimits.maxFileBytes { kind = .binary }
                else if Self.seemsBinary(url: url) { kind = .binary }
                else { kind = .unknown }
            }

            results.append(RepoFile(relativePath: rel, absoluteURL: url, isDirectory: false, kind: kind, size: size))
        }

        // Deterministic stable path sort
        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    static func seemsBinary(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        let sampleSize = 2048
        let data = try? fh.read(upToCount: sampleSize)
        guard let d = data, !d.isEmpty else { return false }

        // Heuristics:
        // 1) any NUL byte -> binary
        if d.contains(0) { return true }

        // 2) ratio of non-printable (excluding \t\r\n) too high -> binary
        var nonPrintable = 0
        for b in d {
            if b == 9 || b == 10 || b == 13 { continue } // \t \n \r
            if b < 32 || b == 127 { nonPrintable += 1 }
        }
        let ratio = Double(nonPrintable) / Double(d.count)
        return ratio > 0.30
    }
}

private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }

    /// Return a relative path string from the absolute root. Normalizes separators and removes leading slash.
    func relativePath(from root: String) -> String {
        var s = self
        if s.hasPrefix(root) {
            s = String(s.dropFirst(root.count))
        }
        if s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}

extension String {
    /// Replace a base prefix with "", returning a normalized relative path (no leading slash).
    func path(replacingBase base: String) -> String {
        return self.relativePath(from: base)
    }
}
