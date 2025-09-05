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
            errorHandler: { _, _ in true } // keep going
        ) else {
            throw NSError(domain: "llminty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate directory"])
        }

        for case let url as URL in enumerator {
            let rel = (url.path).path(replacingBase: root.path)
            // Never include leading slash
            let relClean = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel

            let rIsDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if matcher.isIgnored(relClean, isDirectory: rIsDir) {
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
            results.append(RepoFile(relativePath: relClean, absoluteURL: url, isDirectory: false, kind: kind, size: size))
        }

        // Deterministic stable path sort
        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    static func seemsBinary(url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let data = try? h.read(upToCount: 8192) ?? Data()
        guard let bytes = data, !bytes.isEmpty else { return false }
        if bytes.contains(0) { return true }
        // Try UTF-8 decode conservatively
        if String(data: bytes, encoding: .utf8) != nil { return false }
        // Heuristic: too many high bytes
        let high = bytes.filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        return Double(high) / Double(bytes.count) > 0.05
    }
}

// MARK: - Path helpers
private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }

    func relativePath(from root: String) -> String {
        let normRoot = root.hasSuffix("/") ? root : root + "/"
        if self == root { return "" }
        if hasPrefix(normRoot) { return String(dropFirst(normRoot.count)) }
        return self
    }
}

extension String {
    func path(replacingBase base: String) -> String {
        // Normalize both to real paths (no trailing slash behavior)
        return (self as NSString).standardizingPath.relativePath(from: (base as NSString).standardizingPath)
    }
}
