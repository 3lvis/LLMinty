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
        // Read a small prefix and check for NULs or a high ratio of non-text bytes.
        let chunk = 4096
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = try? fh.read(upToCount: chunk)
        guard let d = data, !d.isEmpty else { return false }

        var nul = 0
        var nonTextish = 0
        for b in d {
            if b == 0 { nul += 1 }
            // ASCII control chars except \t \n \r
            if (b < 32 && b != 9 && b != 10 && b != 13) || b == 0x7F {
                nonTextish += 1
            }
        }
        if nul > 0 { return true }
        return Double(nonTextish) / Double(d.count) > 0.3
    }
}

// MARK: - Path helpers

private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }

    func relativePath(from root: String) -> String {
        let stdSelf = self
        if stdSelf.hasPrefix(root) {
            var rel = String(stdSelf.dropFirst(root.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return stdSelf
    }
}

extension String {
    func path(replacingBase base: String) -> String {
        let rel = self.relativePath(from: base)
        return rel
    }
}
