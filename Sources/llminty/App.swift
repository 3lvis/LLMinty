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

public struct LLMintyApp {
    public init() {}

    public func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let outputURL = root.appendingPathComponent("minty.txt", isDirectory: false)

        // 1) Establish root; load built-ins; merge `.mintyignore`
        let builtIns = BuiltInExcludes.defaultPatterns(outputFileName: "minty.txt")
        let userIgnorePath = root.appendingPathComponent(".mintyignore").path
        let userPatterns = (try? String(contentsOfFile: userIgnorePath, encoding: .utf8)) ?? ""
        let matcher = try IgnoreMatcher(
            builtInPatterns: builtIns,
            userFileText: userPatterns
        )

        // 2) Scan files with directory short-circuiting and size caps
        let scanner = FileScanner(root: root, matcher: matcher)
        let files = try scanner.scan()

        // 3) Analyze Swift structure and cross-file references
        let analyzer = SwiftAnalyzer()
        let analyzed = try analyzer.analyze(files: files)

        // 4) Score each file (0–1)
        let scorer = Scoring()
        let scored = scorer.score(analyzed: analyzed)

        // 5) Dependency-aware ordering, tie-break by score then path
        let ordering = GraphCentrality.orderDependencyAware(scored)

        // 6) Render compact bundle with score-aware retention
        let renderer = Renderer()
        var renderedFiles = [RenderedFile]()
        renderedFiles.reserveCapacity(ordering.count)
        for info in ordering {
            let rf = try renderer.render(file: info, score: info.score)
            renderedFiles.append(rf)
        }

        // 7) Write output with deterministic framing
        var out = ""
        out.reserveCapacity(1_000_000)
        for rf in renderedFiles {
            out += "FILE: \(rf.relativePath)\n"
            out += rf.content
            if !rf.content.hasSuffix("\n") { out += "\n" }
            out += "// END\n"
        }
        try out.write(to: outputURL, atomically: true, encoding: .utf8)

        // 8) CLI UX: exact success line
        print("Created ./minty.txt (\(renderedFiles.count) files)")
    }
}
