import Foundation

enum BuiltInExcludes {
    static func defaultPatterns(outputFileName: String) -> [String] {
        // Users can re-include via .mintyignore negation (!)
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
            // Assets / binary noise (wide net by default)
            "*.xcassets/", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.heic", "*.pdf",
            "*.svg", "*.webp", "*.ttf", "*.otf", "*.woff", "*.woff2",
            "*.zip", "*.tar", "*.tar.gz", "*.rar", "*.7z",
            "*.mp3", "*.wav", "*.aiff", "*.m4a", "*.mp4", "*.mov",
            "*.bin", "*.dat",
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
    let lines = pre.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).map(String.init)
    var result: [String] = []
    result.reserveCapacity(lines.count)
    var justSawHeader = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("FILE: ") {
            result.append(trimmed)       // store header without trailing spaces
            justSawHeader = true
            continue
        }
        if trimmed.isEmpty {
            if justSawHeader {
                result.append("")        // keep one blank after the header
            }
            // else: drop blank line
        } else {
            result.append(trimmed)       // keep non-blank (trimmed right/left)
            justSawHeader = false
        }
    }

    // 3) Single trailing newline
    let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined + "\n"
}

public struct LLMintyApp {
    public init() {}

    public func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outName = "minty.txt"

        // Read user ignore
        let ignoreURL = cwd.appendingPathComponent(".mintyignore")
        let userIgnore = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""

        // Build matcher
        let builtIns = BuiltInExcludes.defaultPatterns(outputFileName: outName)
        let matcher = try IgnoreMatcher(builtInPatterns: builtIns, userFileText: userIgnore)

        // Scan
        let scanner = FileScanner(root: cwd, matcher: matcher)
        let repoFiles = try scanner.scan()

        // Analyze swift files
        let analyzer = SwiftAnalyzer()
        let analyzed = try analyzer.analyze(files: repoFiles)

        // Score + order
        let scoring = Scoring()
        let scored = scoring.score(analyzed: analyzed)
        let ordered = GraphCentrality.orderDependencyAware(scored)

        // Render
        let renderer = Renderer()
        var rendered: [RenderedFile] = []
        rendered.reserveCapacity(ordered.count)
        for s in ordered {
            let r = try renderer.render(file: s, score: s.score)
            rendered.append(r)
        }

        // Bundle
        var bundle: [String] = []
        bundle.reserveCapacity(rendered.count * 2)
        for r in rendered {
            bundle.append("FILE: \(r.relativePath)")
            bundle.append("") // one blank after header
            bundle.append(r.content.trimRightSpaces())
        }
        let joined = bundle.joined(separator: "\n")
        let final = postProcessMinty(joined)

        // Write
        let outURL = cwd.appendingPathComponent(outName)
        try final.write(to: outURL, atomically: true, encoding: .utf8)

        print("Created ./\(outName) (\(rendered.count) files)")
    }
}

private extension String {
    func trimRightSpaces() -> String {
        var s = self
        while s.last == " " { _ = s.removeLast() }
        return s
    }
}
