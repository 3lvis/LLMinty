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
