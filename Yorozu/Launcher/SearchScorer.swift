import Foundation

enum SearchScorer {
    private struct QueryPlan {
        let value: String
        let tokens: [String]
        let characters: [Character]
        let compactValue: String

        init(_ rawValue: String) {
            value = rawValue.launcherNormalized
            tokens = value.split(separator: " ").map(String.init)
            characters = Array(value.filter { !$0.isWhitespace })
            compactValue = String(characters)
        }
    }

    nonisolated static func rank(
        applications: [LaunchableApplication],
        query: String,
        now: Date = Date(),
        limit: Int = 20
    ) -> [LaunchableApplication] {
        let queryPlan = QueryPlan(query)
        if queryPlan.value.isEmpty {
            return Array(applications.sorted(by: emptyQueryComparator).prefix(limit))
        }

        let scored = applications.compactMap { application -> (LaunchableApplication, Int, Int)? in
            guard let textScore = bestTextScore(for: application, query: queryPlan) else {
                return nil
            }
            let behaviorScore = behaviorBonus(for: application.preference, now: now)
            return (application, textScore, behaviorScore)
        }

        return scored.sorted { lhs, rhs in
            let lhsTotal = lhs.1 + lhs.2
            let rhsTotal = rhs.1 + rhs.2
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.preference.isPinned != rhs.0.preference.isPinned {
                return lhs.0.preference.isPinned
            }
            if lhs.0.preference.lastLaunchedAt != rhs.0.preference.lastLaunchedAt {
                return (lhs.0.preference.lastLaunchedAt ?? .distantPast)
                    > (rhs.0.preference.lastLaunchedAt ?? .distantPast)
            }
            if lhs.0.preference.launchCount != rhs.0.preference.launchCount {
                return lhs.0.preference.launchCount > rhs.0.preference.launchCount
            }
            let nameComparison = lhs.0.primaryName.localizedStandardCompare(rhs.0.primaryName)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.0.canonicalURL.path < rhs.0.canonicalURL.path
        }
        .prefix(limit)
        .map(\.0)
    }

    nonisolated static func totalScore(
        for application: LaunchableApplication,
        query: String,
        now: Date = Date()
    ) -> Int? {
        let queryPlan = QueryPlan(query)
        guard !queryPlan.value.isEmpty,
              let textScore = bestTextScore(for: application, query: queryPlan) else {
            return nil
        }
        return textScore + behaviorBonus(for: application.preference, now: now)
    }

    nonisolated static func totalScore(
        title: String,
        subtitle: String,
        preference: LauncherPreference,
        query: String,
        now: Date = Date()
    ) -> Int? {
        let queryPlan = QueryPlan(query)
        guard !queryPlan.value.isEmpty else { return nil }

        let titleField = ApplicationSearchField(rawValue: title)
        let subtitleField = ApplicationSearchField(rawValue: subtitle)
        let titleScore = score(candidate: titleField, query: queryPlan)
        let subtitleScore = score(candidate: subtitleField, query: queryPlan)
        guard let textScore = [titleScore, subtitleScore].compactMap({ $0 }).max() else {
            return nil
        }
        return textScore + behaviorBonus(for: preference, now: now)
    }

    private nonisolated static func emptyQueryComparator(
        _ lhs: LaunchableApplication,
        _ rhs: LaunchableApplication
    ) -> Bool {
        if lhs.preference.isPinned != rhs.preference.isPinned {
            return lhs.preference.isPinned
        }
        if lhs.preference.isPinned,
           lhs.preference.pinnedAt != rhs.preference.pinnedAt {
            return (lhs.preference.pinnedAt ?? .distantFuture)
                < (rhs.preference.pinnedAt ?? .distantFuture)
        }
        if lhs.preference.lastLaunchedAt != rhs.preference.lastLaunchedAt {
            return (lhs.preference.lastLaunchedAt ?? .distantPast)
                > (rhs.preference.lastLaunchedAt ?? .distantPast)
        }
        if lhs.preference.launchCount != rhs.preference.launchCount {
            return lhs.preference.launchCount > rhs.preference.launchCount
        }
        return lhs.primaryName.localizedStandardCompare(rhs.primaryName) == .orderedAscending
    }

    private nonisolated static func bestTextScore(
        for application: LaunchableApplication,
        query: QueryPlan
    ) -> Int? {
        var bestScore = score(candidate: application.primarySearchField, query: query)
        if application.displaySearchField.value != application.primarySearchField.value,
           let displayScore = score(candidate: application.displaySearchField, query: query) {
            bestScore = max(bestScore ?? Int.min, displayScore)
        }
        if let alias = application.preference.alias {
            let aliasField = ApplicationSearchField(rawValue: alias)
            if let aliasScore = score(candidate: aliasField, query: query) {
                bestScore = max(bestScore ?? Int.min, aliasScore + 25)
            }
        }
        if let bundleField = application.bundleSearchField,
           let bundleScore = score(candidate: bundleField, query: query) {
            bestScore = max(bestScore ?? Int.min, bundleScore - 100)
        }
        return bestScore
    }

    private nonisolated static func score(
        candidate: ApplicationSearchField,
        query: QueryPlan
    ) -> Int? {
        guard !candidate.value.isEmpty, !query.value.isEmpty else { return nil }
        if candidate.value == query.value { return 1_000 }
        if candidate.value.hasPrefix(query.value) { return 900 }

        if query.tokens.count > 1,
           query.tokens.allSatisfy({ token in
               candidate.words.contains(where: { $0.hasPrefix(token) })
           }) {
            return 850
        }

        if candidate.acronym.hasPrefix(query.compactValue) {
            return 820
        }

        if candidate.value.contains(query.value) { return 750 }
        return fuzzySubsequenceScore(candidate: candidate, query: query)
    }

    private nonisolated static func fuzzySubsequenceScore(
        candidate: ApplicationSearchField,
        query: QueryPlan
    ) -> Int? {
        let candidateCharacters = candidate.characters
        let queryCharacters = query.characters
        guard !queryCharacters.isEmpty else { return nil }

        var matchedIndices: [Int] = []
        var searchStart = 0
        for character in queryCharacters {
            guard searchStart < candidateCharacters.count,
                  let relativeIndex = candidateCharacters[searchStart...].firstIndex(of: character) else {
                return nil
            }
            matchedIndices.append(relativeIndex)
            searchStart = relativeIndex + 1
        }

        var adjacentMatches = 0
        var totalGapLength = 0
        var wordBoundaryMatches = 0

        for (offset, index) in matchedIndices.enumerated() {
            if index == 0 || !candidateCharacters[index - 1].isLetter && !candidateCharacters[index - 1].isNumber {
                wordBoundaryMatches += 1
            }
            guard offset > 0 else { continue }
            let gap = index - matchedIndices[offset - 1] - 1
            if gap == 0 {
                adjacentMatches += 1
            } else {
                totalGapLength += gap
            }
        }

        return min(
            699,
            max(
                300,
                300
                    + 8 * queryCharacters.count
                    + 12 * adjacentMatches
                    + 15 * wordBoundaryMatches
                    - 2 * totalGapLength
            )
        )
    }

    private nonisolated static func behaviorBonus(
        for preference: LauncherPreference,
        now: Date
    ) -> Int {
        let pinBonus = preference.isPinned ? 30 : 0
        let recencyBonus: Int
        if let lastLaunchedAt = preference.lastLaunchedAt {
            let days = max(0, now.timeIntervalSince(lastLaunchedAt) / 86_400)
            switch days {
            case ...1: recencyBonus = 20
            case ...7: recencyBonus = 15
            case ...30: recencyBonus = 10
            case ...90: recencyBonus = 5
            default: recencyBonus = 0
            }
        } else {
            recencyBonus = 0
        }

        let frequencyBonus = min(
            10,
            Int(floor(log2(Double(preference.launchCount) + 1) * 2))
        )
        return pinBonus + recencyBonus + frequencyBonus
    }
}
