import Foundation

/// 模糊匹配：支持大小写不敏感、音调符号折叠的子序列匹配，
/// 按连续命中、词首命中、前缀命中加权排序，用于命令面板与资料搜索的即时过滤。
public enum FuzzyMatcher {

    /// 返回 0（不匹配）到 1（完全相等）之间的得分。
    public static func score(query: String, candidate: String) -> Double {
        let foldedQuery = fold(query)
        let foldedCandidate = fold(candidate)
        if foldedQuery.isEmpty { return 1 }
        if foldedQuery == foldedCandidate { return 1 }
        return subsequenceScore(needle: foldedQuery, haystack: foldedCandidate)
    }

    /// 批量打分并按得分降序返回索引（相同得分保持原顺序，保证稳定）。
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [(index: Int, item: T, score: Double)] {
        var results: [(Int, T, Double)] = []
        for (i, item) in items.enumerated() {
            let s = score(query: query, candidate: key(item))
            if s > 0 { results.append((i, item, s)) }
        }
        results.sort { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0 < rhs.0
        }
        return results.map { (index: $0.0, item: $0.1, score: $0.2) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func subsequenceScore(needle: String, haystack: String) -> Double {
        let n = Array(needle.unicodeScalars)
        let h = Array(haystack.unicodeScalars)
        guard !n.isEmpty, n.count <= h.count else { return 0 }

        var hi = 0
        var matched = 0
        var consecutive = 0
        var bestConsecutive = 0
        var wordStartHits = 0
        var prefixHit = 0

        for (offset, scalar) in n.enumerated() {
            var found = false
            var searchFrom = hi
            while searchFrom < h.count {
                if h[searchFrom] == scalar {
                    found = true
                    if searchFrom == hi { consecutive += 1 } else { consecutive = 1 }
                    bestConsecutive = max(bestConsecutive, consecutive)
                    if searchFrom == 0 || isBoundary(h[searchFrom - 1]) {
                        wordStartHits += 1
                    }
                    if offset == 0 && searchFrom == 0 { prefixHit = 1 }
                    hi = searchFrom + 1
                    matched += 1
                    break
                }
                searchFrom += 1
            }
            if !found { return 0 }
        }

        let coverage = Double(matched) / Double(n.count)
        let consecRatio = n.count > 0 ? Double(bestConsecutive) / Double(n.count) : 0
        let wordRatio = n.count > 0 ? Double(wordStartHits) / Double(n.count) : 0
        // 命中位置越靠前越好（首字符位置，与候选总长无关，避免偏好长字符串）。
        let firstMatchStart = max(0, hi - n.count)
        let earliness = 1.0 / (1.0 + Double(firstMatchStart))

        // 权重组合：覆盖率必须为 1（全部命中）才进入候选。
        let base = coverage
        let weighted = 0.30 * base + 0.25 * consecRatio + 0.20 * wordRatio + 0.15 * earliness + 0.10 * Double(prefixHit)
        return weighted
    }

    private static func isBoundary(_ prev: Unicode.Scalar) -> Bool {
        prev == " " || prev == "_" || prev == "-" || prev == "/" || prev == "."
    }
}
