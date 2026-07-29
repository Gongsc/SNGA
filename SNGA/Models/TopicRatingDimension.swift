import Foundation

struct TopicRatingDimension: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var ratingCount: Int
    var totalScore: Int

    var averageScore: Double {
        guard ratingCount > 0 else { return 0 }
        let average = Double(totalScore) / Double(ratingCount)
        return (average * 100).rounded(.down) / 100
    }
}
