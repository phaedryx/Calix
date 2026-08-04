// FuzzyMatcher.swift
// Calix
//
// Fuzzy string matching for the command palette.

import Foundation

enum FuzzyMatcher {

    /// Score a query against a candidate string.
    /// Returns 0 for no match, higher scores for better matches.
    static func score(query: String, candidate: String) -> Int {
        guard !query.isEmpty else { return 1 }

        let queryLower = query.lowercased()
        let candidateLower = candidate.lowercased()

        var score = 0
        var queryIndex = queryLower.startIndex
        var candidateIndex = candidateLower.startIndex
        var consecutiveBonus = 0
        var matched = false

        while queryIndex < queryLower.endIndex && candidateIndex < candidateLower.endIndex {
            let qChar = queryLower[queryIndex]
            let cChar = candidateLower[candidateIndex]

            if qChar == cChar {
                score += 1

                // Consecutive match bonus
                consecutiveBonus += 1
                score += consecutiveBonus

                // Word-start bonus: first char or preceded by space/separator
                if candidateIndex == candidateLower.startIndex {
                    score += 5
                } else {
                    let prevIndex = candidateLower.index(before: candidateIndex)
                    let prevChar = candidateLower[prevIndex]
                    if prevChar == " " || prevChar == "_" || prevChar == "-" || prevChar == ":" {
                        score += 3
                    }
                }

                queryIndex = queryLower.index(after: queryIndex)
                matched = true
            } else {
                consecutiveBonus = 0
            }

            candidateIndex = candidateLower.index(after: candidateIndex)
        }

        // All query chars must match
        guard queryIndex == queryLower.endIndex else { return 0 }

        // Exact match bonus
        if matched && queryLower == candidateLower {
            score += 10
        }

        // Prefix match bonus
        if matched && candidateLower.hasPrefix(queryLower) {
            score += 7
        }

        return score
    }
}
