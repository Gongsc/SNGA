import Foundation
import SwiftData
import XCTest
@testable import SNGA

/// 取消不是错误。
///
/// 切账号、切版面、翻页都会把在飞的请求取消掉。把它当错误报出去，用户看到的是
/// 「The operation couldn't be completed. (Swift.CancellationError error 1.)」——
/// 既看不懂，也没有任何可做的事。
final class CancellationTests: XCTestCase {

    @MainActor
    func testACancelledRequestIsNotShownToTheUser() throws {
        let session = try makeSession()

        session.present(CancellationError())

        XCTAssertNil(session.errorMessage, "取消被当成错误弹出来了")
    }

    /// URLSession 取消任务时抛的是 URLError.cancelled，不是 CancellationError。
    /// 只认一种，另一种照样会弹。
    @MainActor
    func testAURLSessionCancellationIsAlsoSilent() throws {
        let session = try makeSession()

        session.present(URLError(.cancelled))

        XCTAssertNil(session.errorMessage)
    }

    /// 别把真错误一起吞了。
    @MainActor
    func testRealFailuresStillReachTheUser() throws {
        let session = try makeSession()

        session.present(ForumServiceError.server(500))

        XCTAssertNotNil(session.errorMessage)
    }

    /// 网络断了不是取消 —— 它和被取消长得像，但用户对它有事可做。
    @MainActor
    func testALostConnectionIsNotTreatedAsCancellation() throws {
        let session = try makeSession()

        session.present(URLError(.notConnectedToInternet))

        XCTAssertNotNil(session.errorMessage)
    }

    @MainActor
    private func makeSession() throws -> AppSession {
        let schema = Schema([
            AccountRecord.self, FavoriteRecord.self, DraftRecord.self,
            SubforumPreferenceRecord.self, RecentForumRecord.self,
            AIProfileSummaryRecord.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "Cancellation-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true
            )]
        )
        return AppModel(container: container).session
    }
}
