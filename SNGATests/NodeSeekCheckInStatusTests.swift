import XCTest
@testable import SNGA

/// 今天签没签，从签到榜读。
///
/// **夹具不是一次原样抓取**，这一点得写明白，免得后来的人当它是。签到榜要登录才
/// 给，而探针（`Design/probe-nodeseek-attendance.js`）是按「不打印值」的规矩写的。
/// 所以这份夹具是：字段名和层级来自 2026-09-17 那次实测输出，几个与身份无关的数
/// （`order` 482、`total` 10502、`day_id` 1441、`gain` 8、每页 50 条）照抄，
/// 而 `member_id` / `member_name` 是编的。
///
/// 那次实测同时定死了两件先前只能猜的事：
/// - `record` **不随 page 变**，`page=1` 和 `page=2` 给的是同一份，所以只问第一页是对的；
/// - `total` **不是**站点的第几天（那是 `day_id`），它是今天签到的总人数，
///   `order` 是我今天的名次。谁也不能拿它们充「连续天数 / 累计天数」。
final class NodeSeekCheckInStatusTests: XCTestCase {
    private static let unreadOK =
        #"{"success":true,"unreadCount":{"all":0,"atMe":0,"message":0,"reply":0}}"#
    private static let unreadPath = "/api/notification/unread-count"

    private func boardJSON() throws -> String {
        try String(
            contentsOf: try XCTUnwrap(
                Bundle(for: Self.self)
                    .url(forResource: "nodeseek-attendance-board", withExtension: "json")
            ),
            encoding: .utf8
        )
    }

    /// 把 `record` 摘掉，其余原样 —— 手写一份「没签到的榜」等于又猜一遍。
    private func boardWithoutRecord() throws -> String {
        var board = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try boardJSON().utf8)) as? [String: Any]
        )
        board.removeValue(forKey: "record")
        return String(
            decoding: try JSONSerialization.data(withJSONObject: board), as: UTF8.self
        )
    }

    private func makeService(
        _ transport: RecordingHTTPTransport
    ) -> NodeSeekForumService {
        NodeSeekForumService(
            accountID: AccountID(),
            cookies: [],
            transport: transport,
            userAgent: "probe"
        )
    }

    func testTheBoardSaysCheckedInWhenItCarriesMyRecord() async throws {
        let transport = RecordingHTTPTransport(responding: try boardJSON())

        let statistics = try await makeService(transport).checkInStatus()

        XCTAssertTrue(statistics.isCheckedInToday)
        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "https://www.nodeseek.com/api/attendance/board?page=1"
        )
        // 站点不报这两个数。顶层的 order / total 说的是名次和今天的总人数，
        // 拿它们充数会在界面上显示一个错的数字。
        XCTAssertNil(statistics.consecutiveDays)
        XCTAssertNil(statistics.totalDays)
    }

    /// 已经签到的那条路**不该多发一次请求**。确认会话是给 `record` 为空时兜底的，
    /// 签过了就没什么可兜的。
    func testTheCheckedInPathCostsExactlyOneRequest() async throws {
        let transport = RecordingHTTPTransport(responding: try boardJSON())

        _ = try await makeService(transport).checkInStatus()

        XCTAssertEqual(transport.requests.count, 1)
    }

    /// `record` 为空时再问一句「你还认得我吗」。
    ///
    /// 站点自己也是分两步：`t.me ? (record === null ? 还没签 : 签过了) : 登录后签到`，
    /// 而那个 `me` 读的是页面的 `__config__.user`，不是这个接口。
    func testAnEmptyRecordIsConfirmedAgainstTheSession() async throws {
        let transport = RecordingHTTPTransport(
            responding: try boardWithoutRecord(),
            byPath: [Self.unreadPath: Self.unreadOK]
        )

        let statistics = try await makeService(transport).checkInStatus()

        XCTAssertFalse(statistics.isCheckedInToday, "会话还在，那就真的是今天还没签")
        XCTAssertEqual(
            transport.requests.map { $0.url?.path ?? "" },
            ["/api/attendance/board", Self.unreadPath]
        )
    }

    /// **站点认不出我的时候，不许说「你还没签到」。**
    ///
    /// 这个接口匿名访问一样答 200、一样给整张 50 条的榜，只是 `order` 和 `record`
    /// 都是 null —— 「没认出你」和「你还没签」在响应里长得一模一样。报上来的 bug
    /// 就是这个：明明签过了，界面一直催他去签。
    func testAnUnrecognisedSessionIsAFailureNotAnUncheckedDay() async throws {
        let transport = RecordingHTTPTransport(
            responding: try boardWithoutRecord(),
            byPath: [Self.unreadPath: #"{"success":false,"message":"USER NOT FOUND"}"#]
        )

        do {
            _ = try await makeService(transport).checkInStatus()
            XCTFail("站点认不出我，却答了一句「还没签到」")
        } catch {
            XCTAssertEqual(error as? ForumServiceError, .requiresLogin)
        }
    }

    /// **「查不到」不许伪装成「还没签到」。**
    ///
    /// `/api/attendance/board?page=` 正是「带 page、批量吐公开数据」那一族，站点对
    /// 非浏览器客户端回的是假的 `wrong uid`，还是 HTTP 200，客户端那层拦不住。
    func testAnAnswerThatIsNotABoardFailsInsteadOfSayingNotYet() async throws {
        for payload in [
            #"{"success":false,"message":"wrong uid"}"#,
            #"{"success":false,"message":"USER NOT FOUND"}"#,
            #"{"order":0,"total":10502}"#
        ] {
            let transport = RecordingHTTPTransport(responding: payload)
            do {
                _ = try await makeService(transport).checkInStatus()
                XCTFail("『查不到』被读成了『还没签到』：\(payload)")
            } catch {
                XCTAssertTrue(error is ForumServiceError)
            }
        }
    }
}
