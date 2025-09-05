import Foundation

enum GraphCentrality {

    // PageRank on file dependency graph (A -> B means A depends on B)
    static func pageRank(_ analyzed: [AnalyzedFile],
                         damping: Double = 0.85,
                         iterations: Int = 20) -> [String: Double] {
        let files: [String] = analyzed.map { $0.file.relativePath }
        let index: [String: Int] = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
        let n = files.count
        guard n > 0 else { return [:] }

        // Outgoing edges (by index)
        var outEdges: [Set<Int>] = Array(repeating: [], count: n)
        for a in analyzed {
            let i = index[a.file.relativePath]!
            for dep in a.outgoingFileDeps {
                if let j = index[dep] { outEdges[i].insert(j) }
            }
        }

        // Init PR
        var pr = Array(repeating: 1.0 / Double(n), count: n)
        var newPR = Array(repeating: 0.0, count: n)
        let base = (1.0 - damping) / Double(n)

        for _ in 0..<iterations {
            // Distribute rank
            for i in 0..<n { newPR[i] = base }
            for i in 0..<n {
                let outs = outEdges[i]
                if outs.isEmpty {
                    // Dangling node: spread evenly
                    let share = damping * pr[i] / Double(n)
                    for j in 0..<n { newPR[j] += share }
                } else {
                    let share = damping * pr[i] / Double(outs.count)
                    for j in outs { newPR[j] += share }
                }
            }
            pr = newPR
        }

        // Map back to paths
        var out: [String: Double] = [:]
        for (p, i) in index { out[p] = pr[i] }
        return out
    }

    /// Dependency-aware emission order:
    /// If A depends on B, emit B before A. When multiple nodes are available,
    /// prefer higher score, then lexicographic path.
    static func orderDependencyAware(_ scored: [ScoredFile]) -> [ScoredFile]  {
        let nodes: [String] = scored.map { $0.analyzed.file.relativePath }
        let idx: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })

        // Build graph with edges B -> A if A depends on B
        var inDegree = Array(repeating: 0, count: nodes.count)
        var adj: [Set<Int>] = Array(repeating: [], count: nodes.count)
        for (aIndex, s) in scored.enumerated() {
            for depPath in s.analyzed.outgoingFileDeps {
                if let bIndex = idx[depPath] {
                    if !adj[bIndex].contains(aIndex) {
                        adj[bIndex].insert(aIndex)
                        inDegree[aIndex] += 1
                    }
                }
            }
        }

        // Priority among zero in-degree: higher score first, then lexicographic path
        func sortedQueue(_ arr: [Int]) -> [Int] {
            return arr.sorted { i, j in
                let si = scored[i], sj = scored[j]
                if si.score != sj.score { return si.score > sj.score }
                return si.analyzed.file.relativePath < sj.analyzed.file.relativePath
            }
        }

        var queue = sortedQueue((0..<nodes.count).filter { inDegree[$0] == 0 })
        var out: [ScoredFile] = []

        while !queue.isEmpty {
            let v = queue.removeFirst()
            out.append(scored[v])
            for u in adj[v] {
                inDegree[u] -= 1
                if inDegree[u] == 0 {
                    // Insert in sorted position
                    let pos = queue.firstIndex(where: { i in
                        let si = scored[u], sj = scored[i]
                        if si.score != sj.score { return si.score > sj.score }
                        return si.analyzed.file.relativePath < sj.analyzed.file.relativePath
                    }) ?? queue.endIndex
                    queue.insert(u, at: pos)
                }
            }
        }

        // Cycles: append remaining deterministically by score then path
        if out.count < scored.count {
            let placed = Set(out.map { $0.analyzed.file.relativePath })
            let remaining = scored.filter { !placed.contains($0.analyzed.file.relativePath) }
            let sortedRem = remaining.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.analyzed.file.relativePath < $1.analyzed.file.relativePath
            }
            out.append(contentsOf: sortedRem)
        }
        return out
    }
}
