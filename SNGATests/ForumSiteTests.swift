import Foundation
import XCTest
@testable import SNGA

/// 站点资料收进 `ForumSiteDescriptor` 之后，域名判断的结果必须和原先逐处写死时一致。
///
/// 尤其是 `nga.178.com`：它原本是 `isForumHost` 里单独写的一个特例，现在并进了
/// `linkDomains`。这里把并进去之后的行为钉住。
final class ForumSiteTests: XCTestCase {

    private let nga = ForumSiteDescriptor.nga

    // MARK: - 站内链接的域名

    func testKnownForumHostsAreRecognized() {
        for host in [
            "nga.cn",
            "bbs.nga.cn",
            "ngacn.cc",
            "bbs.ngacn.cc",
            "ngabbs.com",
            "nga.178.com",
            "bbs.nga.178.com"
        ] {
            XCTAssertTrue(nga.owns(host: host), "应认作站内域名：\(host)")
        }
    }

    func testHostMatchingIsCaseInsensitive() {
        XCTAssertTrue(nga.owns(host: "BBS.NGA.CN"))
    }

    /// 只补足一个点号就能骗过后缀判断的域名，必须挡住。
    func testLookalikeHostsAreRejected() {
        for host in [
            "evilnga.cn",
            "nga.cn.example.com",
            "ngacn.cc.example.com",
            "example.com",
            ""
        ] {
            XCTAssertFalse(nga.owns(host: host), "不该认作站内域名：\(host)")
        }
    }

    // MARK: - Cookie 的域名

    func testCookieDomainsToleratateALeadingDot() {
        XCTAssertTrue(nga.owns(cookieDomain: "nga.cn"))
        XCTAssertTrue(nga.owns(cookieDomain: ".nga.cn"))
        XCTAssertTrue(nga.owns(cookieDomain: "bbs.nga.cn"))
    }

    /// Cookie 的域比站内链接的域窄：镜像域上的 Cookie 不收。
    /// 这一条和登录时那次过滤是同一个判断，别把两份域名列表当成一份。
    func testCookieDomainsAreNarrowerThanLinkDomains() {
        XCTAssertTrue(nga.owns(host: "ngabbs.com"))
        XCTAssertFalse(nga.owns(cookieDomain: "ngabbs.com"))
        XCTAssertFalse(nga.owns(cookieDomain: "nga.178.com"))
    }

    // MARK: - 站内链接的解析

    func testInternalDestinationParsesAForumLinkOnAKnownHost() throws {
        let url = try XCTUnwrap(URL(string: "https://bbs.nga.cn/read.php?tid=42&page=3"))

        XCTAssertEqual(
            nga.internalDestination(for: url),
            .topic(topicID: TopicID(rawValue: 42), page: 3, postID: nil)
        )
    }

    func testInternalDestinationIgnoresForeignHosts() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/read.php?tid=42"))

        XCTAssertNil(nga.internalDestination(for: url))
    }

    // MARK: - 站点表

    func testEverySiteHasAConsistentDescriptor() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            XCTAssertEqual(descriptor.site, site)
            XCTAssertEqual(descriptor.displayName, site.displayName)
            XCTAssertFalse(site.displayName.isEmpty)
            XCTAssertFalse(descriptor.cookieDomains.isEmpty)
            XCTAssertFalse(descriptor.linkDomains.isEmpty)
            XCTAssertFalse(descriptor.uidCookieName.isEmpty)
            XCTAssertFalse(descriptor.credentialCookieName.isEmpty)
            XCTAssertTrue(descriptor.loginURL.absoluteString.hasPrefix("https://"))
            XCTAssertTrue(descriptor.baseURL.absoluteString.hasPrefix("https://"))
        }
    }

    /// 日志脱敏名单从站点资料里推导，新加的站点不该漏出会话 Cookie。
    func testRuntimeLoggerRedactsEverySiteCredentialCookie() {
        for site in ForumSite.allCases {
            let descriptor = site.descriptor
            for name in [descriptor.uidCookieName, descriptor.credentialCookieName] {
                XCTAssertEqual(
                    RuntimeLogger.redacted("Cookie: \(name)=very-secret"),
                    "Cookie: <redacted>",
                    "\(site.rawValue) 的 \(name) 没有被脱敏"
                )
                let url = URL(string: "https://example.com/x?\(name)=very-secret")!
                XCTAssertFalse(
                    RuntimeLogger.sanitizedURL(url).contains("very-secret"),
                    "\(site.rawValue) 的 \(name) 在 URL 里没有被脱敏"
                )
            }
        }
    }
}
