// Sources/llminty/FileScanner.swift
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
            case "dat", "bin": kind = .binary // ensure small .dat/.bin are binary too
            default:
                if size > ScanLimits.maxFileBytes { kind = .binary }
                else if Self.seemsBinary(url: url) { kind = .binary }
                else { kind = .unknown }
            }
            results.append(RepoFile(relativePath: rel, absoluteURL: url, isDirectory: false, kind: kind, size: size))
        }
        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    static func seemsBinary(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let chunk = try? fh.read(upToCount: 4096) ?? Data()
        guard let data = chunk else { return false }
        if data.isEmpty { return false }
        // Heuristic: any NUL byte → binary
        if data.contains(0) { return true }
        // Large entropy-ish / many non-printables
        let printable = data.filter { b in
            (32...126).contains(b) || b == 9 || b == 10 || b == 13
        }
        return printable.count < (data.count / 2)
    }
}

private extension String {
    func removingPrefix(_ p: String) -> String {
        guard hasPrefix(p) else { return self }
        return String(dropFirst(p.count))
    }
    func relativePath(from root: String) -> String {
        let normSelf = (self as NSString).standardizingPath
        let normRoot = (root as NSString).standardizingPath
        if normSelf == normRoot { return "" }
        if normSelf.hasPrefix(normRoot + "/") {
            return String(normSelf.dropFirst(normRoot.count + 1))
        }
        return self
    }
}

extension String {
    func path(replacingBase base: String) -> String {
        let p = self
        let rel = p.relativePath(from: base)
        return rel.isEmpty ? (p as NSString).lastPathComponent : rel
    }
}
