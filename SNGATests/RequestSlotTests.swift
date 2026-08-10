import XCTest
@testable import SNGA

/// 这些判断原先以手写 UUID 比较的形式散落在 AppModel 的十余处请求里，
/// 一旦写漏就会出现「旧响应覆盖新结果」这类很难复现的问题。
@MainActor
final class RequestSlotTests: XCTestCase {
    func testNewestTicketWins() {
        let slot = RequestSlot()

        let first = slot.begin()
        XCTAssertTrue(first.isCurrent)

        let second = slot.begin()
        XCTAssertFalse(first.isCurrent, "发出新请求后，旧请求必须失效")
        XCTAssertTrue(second.isCurrent)
    }

    func testInvalidateDropsInFlightRequest() {
        let slot = RequestSlot()
        let ticket = slot.begin()

        slot.invalidate()

        XCTAssertFalse(ticket.isCurrent, "作废后在途结果不应再写回")
    }

    func testSlotsAreIndependent() {
        let threads = RequestSlot()
        let messages = RequestSlot()

        let threadTicket = threads.begin()
        _ = messages.begin()

        XCTAssertTrue(
            threadTicket.isCurrent,
            "另一类请求的更新不应影响本闸门"
        )
    }

    func testTicketStaysCurrentUntilSuperseded() {
        let slot = RequestSlot()
        let ticket = slot.begin()

        XCTAssertTrue(ticket.isCurrent)
        XCTAssertTrue(ticket.isCurrent, "重复读取不应改变状态")
    }
}
