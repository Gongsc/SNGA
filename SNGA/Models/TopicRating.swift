import Foundation

struct TopicRating: Identifiable, Hashable, Codable, Sendable {
    let id: TopicID
    var dimensions: [TopicRatingDimension]
    var minimumScore: Int
    var maximumScore: Int
    var endsAt: Date?
    var participantCount: Int

    var scoreValues: [Int] {
        let (span, overflow) = maximumScore.subtractingReportingOverflow(minimumScore)
        guard !overflow, span >= 0, span <= 100 else { return [] }
        return Array(minimumScore...maximumScore)
    }

    func isAcceptingResponses(at date: Date) -> Bool {
        endsAt.map { date <= $0 } ?? true
    }

    func dimension(id: String) -> TopicRatingDimension? {
        dimensions.first { $0.id == id }
    }

    func containsValidScores(_ scores: [String: Int]) -> Bool {
        let dimensionIDs = Set(dimensions.map(\.id))
        guard Set(scores.keys).isSubset(of: dimensionIDs) else {
            return false
        }
        return scores.values.allSatisfy {
            $0 >= minimumScore && $0 <= maximumScore
        }
    }
}
