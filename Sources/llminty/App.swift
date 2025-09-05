import Foundation

enum BuiltInExcludes {
    static func defaultPatterns(outputFileName: String) -> [String] {
        // Users can re-include via .mintyignore negation (!) as usual.
        return [
            // VCS / editor
            ".git/", ".gitignore", ".gitattributes", ".DS_Store", ".idea/", ".vscode/", ".svn/", ".hg/",
            // SwiftPM
            ".build/", ".swiftpm/",
            // Xcode
            "DerivedData/", "*.xcodeproj/", "*.xcworkspace/", "xcuserdata/",
            // Apple bundles/outputs
            "*.app/", "*.appex/", "*.framework/", "*.dSYM/", "*.xcarchive/",
            // Dependency managers
            "Pods/", "Carthage/",
            // Assets / common binaries (leave generic *.dat alone so SnapshotE2E can see bin.dat)
            "*.xcassets/", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.heic", "*.pdf",
            "*.svg", "*.webp", "*.ttf", "*.otf", "*.woff", "*.woff2",
            "*.zip", "*.tar", "*.tar.gz", "*.rar", "*.7z",
            "*.mp3", "*.wav", "*.aiff", "*.m4a", "*.mp4", "*.mov",
            // Self-exclude
            outputFileName
        ]
    }
}

/// Aggressively trims blank lines for final output while keeping exactly one
/// blank line after each "FILE: " header. Also:
/// - trims trailing spaces,
/// - collapses 3+ newlines to 2 during pre-pass,
/// - removes all other blank-only lines.
/// Returns a string that always ends with a single trailing newline.
func postProcessMinty(_ s: String) -> String {
    // 1) Trim trailing spaces and collapse extreme newline runs
    let pre = s
        .replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

    // 2) Keep exactly one blank after each header; drop other blank-only lines
    let lines = pre.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var result: [String] = []
    result.reserveCapacity(lines.count)
    var justSawHeader = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("FILE: ") {
            result.append(trimmed)       // header without trailing spaces
            justSawHeader = true
            continue
        }
        if trimmed.isEmpty {
            if justSawHeader {
                result.append("")        // keep one blank after the header
            }
            // else: drop blank line
        } else {
            result.append(trimmed)       // keep non-blank (trimmed)
            justSawHeader = false
        }
    }

    // 3) Single trailing newline
    let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined + "\n"
}

public struct LLMintyApp {
    public init() {}
}

public extension LLMintyApp {
    func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Read ignore file (optional)
        let ignoreURL = root.appendingPathComponent(".mintyignore")
        let ignoreText = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""

        // Build matcher with built-ins first, then user lines (last match wins)
        let matcher = try IgnoreMatcher(
            builtInPatterns: BuiltInExcludes.defaultPatterns(outputFileName: "minty.txt"),
            userFileText: ignoreText
        )

        // 1) Scan repository
        let files = try FileScanner(root: root, matcher: matcher).scan()

        // 2) Analyze Swift files
        let swiftFiles = files.filter { $0.kind == .swift }
        var analyzed = try SwiftAnalyzer().analyze(files: swiftFiles)

        // 3) Attach non-Swift files so they flow through scoring+rendering too
        for f in files where f.kind != .swift {
            let text: String
            switch f.kind {
            case .json, .text, .unknown:
                text = (try? String(contentsOf: f.absoluteURL, encoding: .utf8)) ?? ""
            case .binary:
                text = "" // placeholder handled in Renderer
            case .swift:
                continue
            }
            let af = AnalyzedFile(
                file: f,
                text: text,
                declaredTypes: [],
                publicAPIScoreRaw: 0,
                referencedTypes: [:],
                complexity: 0,
                isEntrypoint: false,
                outgoingFileDeps: [],
                inboundRefCount: 0
            )
            analyzed.append(af)
        }

        // 4) Backfill inboundRefCount
        var inbound: [String: Int] = [:]
        for a in analyzed {
            for dep in a.outgoingFileDeps {
                inbound[dep, default: 0] += 1
            }
        }
        for i in analyzed.indices {
            analyzed[i].inboundRefCount = inbound[analyzed[i].file.relativePath] ?? 0
        }

        // 5) Score + order
        let scored = Scoring().score(analyzed: analyzed)
        let ordered = GraphCentrality.orderDependencyAware(scored)

        // 6) Render
        let renderer = Renderer()
        var parts: [String] = []
        parts.reserveCapacity(ordered.count * 2)
        for sf in ordered {
            let rf = try renderer.render(file: sf, score: sf.score)
            parts.append("FILE: \(rf.relativePath)")
            parts.append("") // one blank line after header; postProcessMinty enforces exactly one
            parts.append(rf.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 7) Post-process framing + write
        let finalText = postProcessMinty(parts.joined(separator: "\n"))
        let outURL = root.appendingPathComponent("minty.txt")
        try finalText.write(to: outURL, atomically: true, encoding: .utf8)

        // Success message (tests match this exact prefix/shape)
        print("Created ./minty.txt (\(ordered.count) files)")
    }
}
