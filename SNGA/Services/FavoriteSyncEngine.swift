import Foundation

struct FavoriteMergeResult: Sendable, Equatable {
    var visible: [FavoriteSnapshot]
    var pendingAdds: [ForumID]
    var pendingRemovals: [ForumID]
}

enum FavoriteSyncEngine {
    static func merge(server: [Forum], local: [FavoriteSnapshot]) -> FavoriteMergeResult {
        let serverMap = Dictionary(uniqueKeysWithValues: server.map { ($0.id, $0) })
        let localMap = Dictionary(uniqueKeysWithValues: local.map { ($0.forum.id, $0) })
        var visible: [FavoriteSnapshot] = []
        var pendingAdds: [ForumID] = []
        var pendingRemovals: [ForumID] = []

        for item in local.sorted(by: { $0.order < $1.order }) {
            switch item.state {
            case .pendingRemove:
                if serverMap[item.forum.id] != nil { pendingRemovals.append(item.forum.id) }
            case .pendingAdd:
                visible.append(item)
                if serverMap[item.forum.id] == nil { pendingAdds.append(item.forum.id) }
            case .synced, .conflict, .localOnly:
                if let serverForum = serverMap[item.forum.id] {
                    visible.append(FavoriteSnapshot(forum: serverForum, order: item.order, state: .synced))
                } else if item.state == .localOnly {
                    visible.append(item)
                }
            }
        }

        let nextOrder = (visible.map(\.order).max() ?? -1) + 1
        let localIDs = Set(localMap.keys)
        let additions = server.filter { !localIDs.contains($0.id) }.enumerated().map { offset, forum in
            FavoriteSnapshot(forum: forum, order: nextOrder + offset, state: .synced)
        }
        visible.append(contentsOf: additions)
        visible.sort { $0.order < $1.order }
        return FavoriteMergeResult(visible: visible, pendingAdds: pendingAdds, pendingRemovals: pendingRemovals)
    }
}

