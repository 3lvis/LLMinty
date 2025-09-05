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
            errorHandler: { (url, error) -> Bool in
                // Keep going on errors; this is a read-only pass.
                return true
            }
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
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        let data = try? h.read(upToCount: 1024) ?? Data()
        try? h.close()
        guard let d = data, !d.isEmpty else { return false }
        return d.contains(0) // crude check: any NUL byte
    }
}

private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }

    func relativePath(from root: String) -> String {
        if self == root { return "" }
        var s = self.removingPrefix(root)
        if s.hasPrefix("/") { s = String(s.dropFirst()) }
        return s
    }
}

extension String {
    func path(replacingBase base: String) -> String {
        var p = self
        if p.hasPrefix(base) {
            p = String(p.dropFirst(base.count))
            if p.hasPrefix("/") { p = String(p.dropFirst()) }
        }
        return p
    }
}
