import Foundation

/// Returns the nodes that can reach themselves by following `edges`.
/// Used for schema-layout cycles (boxing) and reference-expansion cycles
/// (hoisting external schemas).
func selfReachableNodes(in edges: [String: Set<String>]) -> Set<String> {
    var result: Set<String> = []
    for start in edges.keys {
        var visited: Set<String> = []
        var frontier = Array(edges[start] ?? [])
        while let node = frontier.popLast() {
            guard !visited.contains(node) else { continue }
            visited.insert(node)
            frontier.append(contentsOf: edges[node] ?? [])
        }
        if visited.contains(start) {
            result.insert(start)
        }
    }
    return result
}
