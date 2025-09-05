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
            errorHandler: { (_, _) -> Bool in true }
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

    static func seemsBinary(url: URL) -> Bool  {
        // Simple heuristic: look at the first 4KB and detect NULs and a high ratio of non-printables
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let data = try? h.read(upToCount: 4096)
        guard let d = data, !d.isEmpty else { return false }
        var nul = 0, ctrl = 0
        for b in d {
            if b == 0 { nul += 1 }
            if b < 0x09 || (b >= 0x0E && b < 0x20) { ctrl += 1 }
        }
        if nul > 0 { return true }
        let ratio = Double(ctrl) / Double(d.count)
        return ratio > 0.30
    }
}

private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }

    func relativePath(from root: String) -> String  {
        var s = self
        if s.hasPrefix(root) {
            s = s.removingPrefix(root)
        }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasPrefix("./") { s.removeFirst(2) }
        if s.isEmpty { return "." }
        return s
    }
}

extension String {
    func path(replacingBase base: String) -> String  {
        let norm = self.replacingOccurrences(of: "\\", with: "/")
        var rel = norm
        if norm.hasPrefix(base) {
            rel = norm.removingPrefix(base)
        }
        while rel.hasPrefix("/") { rel.removeFirst() }
        while rel.hasPrefix("./") { rel.removeFirst(2) }
        return rel
    }
}
