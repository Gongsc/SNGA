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
    private func boardJSON() throws -> String {
        try String(
            contentsOf: try XCTUnwrap(
                Bundle(for: Self.self)
                    .url(forResource: "nodeseek-attendance-board", withExtension: "json")
            ),
            encoding: .utf8
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

    /// 同一张榜去掉 `record` 就是「今天还没签」—— 这一条得留着，否则下面那几条
    /// 「认不出就抛」可能只是把所有答复都抛掉了。
    func testTheSameBoardWithoutMyRecordMeansNotYet() async throws {
        // 把 `record` 摘掉，其余原样 —— 手写一份「没签到的榜」等于又猜一遍。
        var board = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try boardJSON().utf8)) as? [String: Any]
        )
        board.removeValue(forKey: "record")
        let body = String(
            decoding: try JSONSerialization.data(withJSONObject: board), as: UTF8.self
        )

        let statistics = try await makeService(
            RecordingHTTPTransport(responding: body)
        ).checkInStatus()

        XCTAssertFalse(statistics.isCheckedInToday)
    }

    /// **「查不到」不许伪装成「还没签到」。**
    ///
    /// 签没签是靠 `record` 在不在判断的，所以任何不是签到榜的答复都会变成一个
    /// 很肯定的「还没签」—— 用户明明签过了，界面一直催他去签。而
    /// `/api/attendance/board?page=` 正是「带 page、批量吐公开数据」那一族，
    /// 站点对非浏览器客户端回的是假的 `wrong uid`，还是 HTTP 200，客户端那层拦不住。
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
