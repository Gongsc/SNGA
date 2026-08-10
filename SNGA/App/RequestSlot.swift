import Foundation

/// 一类请求的「最新者胜出」闸门。
///
/// 翻页、切板块、切账号都可能在上一个请求还没回来时就发出下一个。旧请求先发后至
/// 时必须被丢弃，否则会用过期数据覆盖掉新结果。原先每种请求各自维护一个
/// `UUID?` 字段并在多处手写比较，同样的判断重复了十余遍；这里把它收成一个组件。
@MainActor
final class RequestSlot {
    private var currentID: UUID?

    init() {}

    /// 开启一次新请求，同一闸门下此前未完成的请求就此作废。
    func begin() -> RequestTicket {
        let id = UUID()
        currentID = id
        return RequestTicket(id: id, slot: self)
    }

    /// 作废当前请求，之后任何在途结果都不再写回。
    func invalidate() {
        currentID = UUID()
    }

    fileprivate func isCurrent(_ id: UUID) -> Bool {
        currentID == id
    }
}

/// 单次请求的凭据。只有它仍然是所属闸门的最新请求时，结果才允许写回状态。
@MainActor
struct RequestTicket {
    fileprivate let id: UUID
    private unowned let slot: RequestSlot

    fileprivate init(id: UUID, slot: RequestSlot) {
        self.id = id
        self.slot = slot
    }

    var isCurrent: Bool { slot.isCurrent(id) }
}
