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

enum ArithmeticEvaluation: Equatable, Sendable {
    case result(String)
    case divisionByZero
}

/// Evaluates the small, deliberately bounded expression language offered by
/// Root Search. Keeping this parser local avoids invoking a scripting engine
/// or allowing arbitrary code when a query happens to look mathematical.
enum ArithmeticExpressionEvaluator {
    nonisolated static func evaluate(_ input: String) -> String? {
        guard case let .result(value) = evaluateDetailed(input) else { return nil }
        return value
    }

    nonisolated static func evaluateDetailed(_ input: String) -> ArithmeticEvaluation? {
        let normalized = normalize(input)
        guard !normalized.isEmpty,
              normalized.count <= 128,
              normalized.contains(where: { "+-*/%".contains($0) }) else {
            return nil
        }

        var parser = Parser(Array(normalized))
        let parsed = parser.parseExpression()
        guard parser.isAtEnd else {
            return nil
        }
        switch parsed {
        case let .success(value):
            guard value.isFinite else { return nil }
            return .result(format(value))
        case .failure(.divisionByZero):
            return .divisionByZero
        case .failure(.invalid):
            return nil
        }
    }

    private nonisolated static func normalize(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only programming-style ASCII operators are accepted. Keeping the
        // accepted alphabet narrow prevents normal language queries from
        // becoming calculator commands accidentally.
        return value.filter { !$0.isWhitespace }
    }

    private nonisolated static func format(_ value: Double) -> String {
        let normalized = abs(value) < 0.000000000001 ? 0 : value
        if normalized.rounded() == normalized,
           abs(normalized) <= 9_007_199_254_740_991 {
            return String(Int64(normalized))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: normalized)) ?? "\(normalized)"
    }

    private struct Parser {
        enum ParseError: Error {
            case invalid
            case divisionByZero
        }

        let characters: [Character]
        var index = 0

        var isAtEnd: Bool {
            index >= characters.count
        }

        init(_ characters: [Character]) {
            self.characters = characters
        }

        mutating func parseExpression() -> Result<Double, ParseError> {
            let first = parseTerm()
            guard case let .success(firstValue) = first else {
                return first
            }
            var value = firstValue
            while let operation = consumeBinaryOperator(plus: true, minus: true) {
                let parsed = parseTerm()
                guard case let .success(rhs) = parsed else {
                    return parsed
                }
                if operation == "+" {
                    value += rhs
                } else {
                    value -= rhs
                }
                guard value.isFinite else { return .failure(.invalid) }
            }
            return .success(value)
        }

        private mutating func parseTerm() -> Result<Double, ParseError> {
            let first = parseUnary()
            guard case let .success(firstValue) = first else { return first }
            var value = firstValue
            while let operation = consumeBinaryOperator(plus: false, minus: false) {
                let parsed = parseUnary()
                guard case let .success(rhs) = parsed else { return parsed }
                switch operation {
                case "*":
                    value *= rhs
                case "/":
                    guard rhs != 0 else { return .failure(.divisionByZero) }
                    value /= rhs
                default:
                    guard rhs != 0 else { return .failure(.divisionByZero) }
                    value.formRemainder(dividingBy: rhs)
                }
                guard value.isFinite else { return .failure(.invalid) }
            }
            return .success(value)
        }

        private mutating func parseUnary() -> Result<Double, ParseError> {
            if consume("+") { return parseUnary() }
            if consume("-") {
                switch parseUnary() {
                case let .success(value): return .success(-value)
                case let .failure(error): return .failure(error)
                }
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Result<Double, ParseError> {
            if consume("(") {
                let parsed = parseExpression()
                guard consume(")") else { return .failure(.invalid) }
                return parsed
            }
            let start = index
            var hasDigits = false
            var hasDecimal = false
            while let character = current {
                if character.isNumber {
                    hasDigits = true
                    index += 1
                } else if character == ".", !hasDecimal {
                    hasDecimal = true
                    index += 1
                } else {
                    break
                }
            }
            guard hasDigits, start < index,
                  let value = Double(String(characters[start..<index])) else {
                return .failure(.invalid)
            }
            return .success(value)
        }

        private mutating func consumeBinaryOperator(
            plus: Bool,
            minus: Bool
        ) -> Character? {
            if plus, consume("+") { return "+" }
            if minus, consume("-") { return "-" }
            if !plus, !minus, consume("*") { return "*" }
            if !plus, !minus, consume("/") { return "/" }
            if !plus, !minus, consume("%") { return "%" }
            return nil
        }

        private mutating func consume(_ expected: Character) -> Bool {
            guard current == expected else { return false }
            index += 1
            return true
        }

        private var current: Character? {
            guard characters.indices.contains(index) else { return nil }
            return characters[index]
        }
    }
}
