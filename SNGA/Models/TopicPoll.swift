import Foundation

struct TopicPoll: Identifiable, Hashable, Codable, Sendable {
    struct Option: Identifiable, Hashable, Codable, Sendable {
        let id: String
        var title: String
        var voteCount: Int
        /// 我投过这一项。站点报得出来就填，报不出来就一直是 false。
        var isChosen: Bool = false
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
    /// 投票被关掉了。
    ///
    /// 和 `endsAt` 不是一回事：有的站点给的是截止时间，有的只给一个「已锁定」的布尔值，
    /// 没有日期可填。把锁定硬塞成一个假的过去时间能骗过 `isAcceptingResponses`，
    /// 但界面上「截止于 1970 年」就出来了。
    var isLocked: Bool = false

    var totalVoteCount: Int {
        groups.reduce(0) { $0 + $1.voteCount }
    }

    func isAcceptingResponses(at date: Date) -> Bool {
        guard !isLocked else { return false }
        return endsAt.map { date <= $0 } ?? true
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
