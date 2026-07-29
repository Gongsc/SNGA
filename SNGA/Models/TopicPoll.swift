import Foundation

struct TopicPoll: Identifiable, Hashable, Codable, Sendable {
    struct Option: Identifiable, Hashable, Codable, Sendable {
        let id: String
        var title: String
        var voteCount: Int
    }

    struct Group: Identifiable, Hashable, Codable, Sendable {
        let id: Int
        var title: String?
        var options: [Option]

        var voteCount: Int {
            options.reduce(0) { $0 + $1.voteCount }
        }
    }

    let id: TopicID
    var groups: [Group]
    var maximumSelectionsPerGroup: Int
    var endsAt: Date?
    var hidesResultsUntilVoting: Bool
    var hidesResultsUntilEnd: Bool
    var participantCount: Int

    var totalVoteCount: Int {
        groups.reduce(0) { $0 + $1.voteCount }
    }

    func isAcceptingResponses(at date: Date) -> Bool {
        endsAt.map { date <= $0 } ?? true
    }

    func showsResults(at date: Date) -> Bool {
        if hidesResultsUntilEnd, isAcceptingResponses(at: date) {
            return false
        }
        if hidesResultsUntilVoting, participantCount == 0 {
            return false
        }
        return true
    }

    func orderedOptionIDs(in selection: Set<String>) -> [String] {
        groups.flatMap(\.options).compactMap { option in
            selection.contains(option.id) ? option.id : nil
        }
    }

    func containsValidSelection(_ selection: Set<String>) -> Bool {
        guard !selection.isEmpty else { return false }
        let selectedIDs = Set(orderedOptionIDs(in: selection))
        guard selectedIDs == selection else { return false }
        return groups.allSatisfy { group in
            selectedIDs.intersection(group.options.map(\.id)).count <= maximumSelectionsPerGroup
        }
    }
}
