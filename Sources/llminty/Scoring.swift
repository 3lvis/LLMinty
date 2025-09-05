import Foundation

struct ScoredFile {
    let analyzed: AnalyzedFile
    let score: Double
    let fanIn: Int
    let pageRank: Double
}

final class Scoring {

    struct Norm {
        var fanInMax = 0
        var pageRankMax = 0.0
        var apiMax = 0
        var influenceMax = 0
        var complexityMax = 0
    }

    /// Compute a composite [0,1] score for each file.
    /// Heuristics balance inbound references, PageRank, public API surface, "influence"
    /// (outgoing refs) and measured complexity; + entrypoint bonus.
    func score(analyzed: [AnalyzedFile]) -> [ScoredFile] {
        // Precompute PR and fan-in
        let pr = GraphCentrality.pageRank(analyzed)
        var fanIn: [String: Int] = [:]
        for a in analyzed {
            fanIn[a.file.relativePath] = a.inboundRefCount
        }

        // Collect maxima for normalization
        var norm = Norm()
        for a in analyzed {
            norm.fanInMax = max(norm.fanInMax, fanIn[a.file.relativePath] ?? 0)
            norm.pageRankMax = max(norm.pageRankMax, pr[a.file.relativePath] ?? 0.0)
            norm.apiMax = max(norm.apiMax, a.publicAPIScoreRaw)
            // "Influence": number of distinct outgoing file deps (fan-out)
            norm.influenceMax = max(norm.influenceMax, a.outgoingFileDeps.count)
            norm.complexityMax = max(norm.complexityMax, a.complexity)
        }

        // Safe division
        func nzDiv(_ num: Double, by den: Double) -> Double { den == 0 ? 0 : (num / den) }

        var out: [ScoredFile] = []
        out.reserveCapacity(analyzed.count)

        for a in analyzed {
            let fanInN   = nzDiv(Double(fanIn[a.file.relativePath] ?? 0), by: Double(norm.fanInMax))
            let prN      = nzDiv(pr[a.file.relativePath] ?? 0.0, by: norm.pageRankMax)
            let apiN     = nzDiv(Double(a.publicAPIScoreRaw), by: Double(norm.apiMax))
            let inflN    = nzDiv(Double(a.outgoingFileDeps.count), by: Double(norm.influenceMax))
            let cxN      = nzDiv(Double(a.complexity), by: Double(norm.complexityMax))
            let entry    = a.isEntrypoint ? 1.0 : 0.0

            // Weights: 5 equally weighted primary signals + entrypoint bonus
            let score =
            0.18 * fanInN +
            0.18 * prN +
            0.18 * apiN +
            0.18 * inflN +
            0.18 * cxN +
            0.10 * entry

            out.append(
                ScoredFile(
                    analyzed: a,
                    score: max(0.0, min(1.0, score)),
                    fanIn: fanIn[a.file.relativePath] ?? 0,
                    pageRank: pr[a.file.relativePath] ?? 0.0
                )
            )
        }
        return out
    }
}
