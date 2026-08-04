import CoreFoundation
import Foundation
import SwiftSoup
import XCTest
@preconcurrency import WebKit
@testable import SNGA

final class NGAParserTests: XCTestCase {
    private let parser = NGAParser()

    @MainActor
    func testPostWebViewCacheReusesOnlyMatchingRenderedContent() {
        let cache = PostWebViewCache(countLimit: 2)
        let webView = WKWebView(frame: .zero)

        cache.store(webView, html: "first", height: 42, for: "post")
        let cached = cache.take(for: "post", matching: "first")

        XCTAssertTrue(cached?.webView === webView)
        XCTAssertEqual(cached?.height, 42)
        XCTAssertNil(cache.take(for: "post", matching: "first"))

        cache.store(webView, html: "stale", height: 42, for: "post")
        XCTAssertNil(cache.take(for: "post", matching: "updated"))
    }

    func testParsesProfileDetailsAndReputation() throws {
        let payload = """
        {
          "data": [{
            "uid": 36379260,
            "username": "啊床前明月光",
            "group": "学徒",
            "title": "测试头衔",
            "honor": "荣誉称号",
            "regdate": 1435199662,
            "posts": 394,
            "ipLoc": "浙江省",
            "sign": "<b>测试签名</b>",
            "rvrc": 15,
            "fame": 15,
            "money": 168,
            "follow_by_num": 6,
            "avatar": "//img.nga.178.com/avatars/2015/36379260.jpg"
          }]
        }
        """

        let profile = try parser.profile(
            from: response(payload),
            expectedUID: 36_379_260
        )

        XCTAssertEqual(profile.displayName, "啊床前明月光")
        XCTAssertEqual(profile.userGroup, "学徒")
        XCTAssertEqual(profile.postCount, 394)
        XCTAssertEqual(profile.location, "浙江省")
        XCTAssertEqual(profile.signature, "测试签名")
        XCTAssertEqual(profile.reputation, 1.5)
        XCTAssertEqual(profile.fame, 15)
        XCTAssertEqual(profile.money, 168)
        XCTAssertEqual(profile.followerCount, 6)
        XCTAssertEqual(
            profile.avatarURL?.absoluteString,
            "https://img.nga.178.com/avatars/2015/36379260.jpg"
        )
        XCTAssertFalse(profile.isMasked)
    }

    func testParsesUserTopicAndReplyRows() throws {
        let html = """
        <html><body>
          <table>
            <tr class="topicrow">
              <td class="c2">
                <span class="titleadd2"><a href="/thread.php?fid=414">[游戏综合讨论]</a></span>
                <a class="topic" href="/read.php?tid=47240001">用户发布的主题</a>
              </td>
              <td class="c3"><span class="postdate" title="2026-07-24 08:30">今天</span></td>
            </tr>
            <tr class="topicrow">
              <td class="c2">
                <span class="titleadd2"><a href="/thread.php?fid=-7">[艾泽拉斯国家地理]</a></span>
                <a class="topic" href="/read.php?tid=47240002&amp;pid=87600001">回复所在主题</a>
                <div class="postcontent">
                  <div class="quote">应被移除的引用</div>
                  <span>这是用户自己的回复内容</span>
                </div>
              </td>
              <td class="c3"><span class="postdate" title="2026-07-24 09:15">今天</span></td>
            </tr>
          </table>
          <a href="/thread.php?searchpost=1&amp;authorid=36379260&amp;page=2" title="下一页">下一页</a>
        </body></html>
        """

        let topics = try parser.userActivities(
            from: response(html, contentType: "text/html; charset=utf-8"),
            uid: 36_379_260,
            kind: .topics,
            page: 1
        )
        XCTAssertEqual(topics.activities.first?.subject, "用户发布的主题")
        XCTAssertEqual(topics.activities.first?.forumID, ForumID(rawValue: 414))
        XCTAssertEqual(topics.totalPages, 2)
        XCTAssertTrue(topics.hasMore)

        let replies = try parser.userActivities(
            from: response(html, contentType: "text/html; charset=utf-8"),
            uid: 36_379_260,
            kind: .replies,
            page: 1
        )
        XCTAssertEqual(replies.activities.last?.postID, PostID(rawValue: 87_600_001))
        XCTAssertEqual(replies.activities.last?.excerpt, "这是用户自己的回复内容")
        XCTAssertFalse(replies.activities.last?.excerpt?.contains("引用") == true)
    }

    func testParsesStructuredForumsTopicsAndPosts() throws {
        let forumResponse = response(#"{"__F":[{"fid":-7,"name":"艾泽拉斯国家地理","info":"综合讨论"}]}"#)
        let forums = try parser.forums(from: forumResponse)
        XCTAssertEqual(forums, [Forum(id: ForumID(rawValue: -7), name: "艾泽拉斯国家地理", subtitle: "综合讨论")])

        let topicResponse = response(#"{"__T":[{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":12,"postdate":1700000000}]}"#)
        let page = try parser.forumPage(from: topicResponse, forumID: ForumID(rawValue: -7), page: 1)
        XCTAssertEqual(page.topics.first?.id, TopicID(rawValue: 101))
        XCTAssertEqual(page.topics.first?.replyCount, 12)

        let threadResponse = response(#"{"data":{"__T":{"tid":101,"fid":-7,"subject":"测试主题","author":"Alice","replies":40},"__U":{"1":{"uid":1,"username":"<span>Alice</span>","avatar":"//img.nga.178.com/avatars/2009/1.jpg"}},"__R":[{"pid":201,"tid":101,"lou":0,"authorid":1,"content":"<p>正文</p>","postdatetimestamp":1700000000,"score":8,"vote_down":2}]}}"#)
        let thread = try parser.threadPage(from: threadResponse, topicID: TopicID(rawValue: 101), page: 1)
        XCTAssertEqual(thread.posts.first?.id, PostID(rawValue: 201))
        XCTAssertEqual(thread.posts.first?.floor, 0)
        XCTAssertEqual(thread.posts.first?.author, "Alice")
        XCTAssertEqual(thread.posts.first?.avatarURL?.absoluteString, "https://img.nga.178.com/avatars/2009/1.jpg")
        XCTAssertEqual(thread.posts.first?.html, "<p>正文</p>")
        XCTAssertEqual(thread.posts.first?.upvoteCount, 8)
        XCTAssertEqual(thread.posts.first?.downvoteCount, 2)
        XCTAssertTrue(thread.hotReplies.isEmpty)
        XCTAssertEqual(thread.totalPages, 3)
        XCTAssertTrue(thread.hasMore)
    }

    func testParsesPostAuthorLevelReputationRegistrationPrestigeAndMedals() throws {
        let payload = #"""
        {
          "data": {
            "__F": {
              "fid": -7,
              "custom_level": "[{r:-21000,n:\"草飘浮灵\"},{r:0,n:\"忍里之貉\"},{r:30,n:\"渡来介者\"},{r:60,n:\"戎犬锵锵\"},{r:110,n:\"烦恼刈除\"},{r:200,n:\"花坂豪快\"},{r:400,n:\"红叶逐荒波\"},{r:600,n:\"琉焰华舞\"},{r:900,n:\"真珠之智\"},{r:1200,n:\"白鹭霜华\"},{r:1500,n:\"磐祭叶守\"},{r:1800,n:\"浮世笑百姿\"},{r:2000,n:\"一心净土\"}]"
            },
            "__T": {
              "tid": 33684916,
              "fid": -7,
              "subject": "版头",
              "authorid": 40615142,
              "author": "Nekiri",
              "replies": 0
            },
            "__U": {
              "40615142": {
                "uid": 40615142,
                "username": "UID:40615142",
                "groupid": 5,
                "memberid": 5,
                "medal": "386,45",
                "site": "星辰驰骋终幕蔷薇",
                "honor": " 1763083820 $notitle$ 于明日落下，静寂与月光",
                "regdate": 1487143790,
                "rvrc": 297
              },
              "__GROUPS": {
                "5": ["Warden", 1411060, 5]
              },
              "__MEDALS": {
                "386": ["386.gif", "流浪地球", "……", 386],
                "45": ["ngag.gif", "金质国家地理荣誉徽章", "授予为 NGA 作出贡献的会员", 45]
              },
              "__REPUTATIONS": {
                "130": {"40615142": 2030, "0": "原神Project"}
              }
            },
            "__R": [{
              "pid": 0,
              "tid": 33684916,
              "lou": 0,
              "authorid": 40615142,
              "content": "版头正文"
            }]
          }
        }
        """#

        let page = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 33_684_916),
            page: 1
        )
        let post = try XCTUnwrap(page.posts.first)
        let authorInfo = try XCTUnwrap(post.authorInfo)

        XCTAssertEqual(post.author, "Nekiri")
        XCTAssertEqual(authorInfo.levelTitle, "一心净土")
        XCTAssertEqual(authorInfo.reputation, 2030)
        XCTAssertEqual(authorInfo.reputationLevel, 11)
        XCTAssertEqual(authorInfo.userGroup, "Warden")
        XCTAssertEqual(authorInfo.registeredAt, Date(timeIntervalSince1970: 1_487_143_790))
        XCTAssertEqual(authorInfo.prestige, 29.7)
        XCTAssertEqual(authorInfo.honor, "于明日落下，静寂与月光")
        XCTAssertEqual(authorInfo.site, "星辰驰骋终幕蔷薇")
        XCTAssertEqual(authorInfo.medals.map(\.id), [386, 45])
        XCTAssertEqual(authorInfo.medals.map(\.name), ["流浪地球", "金质国家地理荣誉徽章"])
        XCTAssertEqual(
            authorInfo.medals.map { $0.imageURL?.absoluteString },
            [
                "https://img4.nga.cn/ngabbs/medal/386.gif",
                "https://img4.nga.cn/ngabbs/medal/ngag.gif"
            ]
        )
    }

    func testParsesStructuredTopicPollAndBuildsSubmissionEndpoint() throws {
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 47273517,
              "fid": 853,
              "subject": "投票主题",
              "author": "Alice",
              "replies": 0
            },
            "__R": [{
              "pid": 0,
              "tid": 47273517,
              "lou": 0,
              "author": "Alice",
              "content": "主题正文",
              "vote": "207428~原皮白~207429~剧情黑~207430~泳装白~207431~只想看结果~max_select~1~end~1793076441~opt~1~_207428~0,0,0~_207429~0,0,0~_207430~0,0,0~_207431~0,0,0"
            }]
          }
        }
        """

        let page = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47_273_517),
            page: 1
        )
        let poll = try XCTUnwrap(page.posts.first?.poll)

        XCTAssertEqual(poll.id, TopicID(rawValue: 47_273_517))
        XCTAssertEqual(poll.maximumSelectionsPerGroup, 1)
        XCTAssertEqual(poll.groups.count, 1)
        XCTAssertEqual(
            poll.groups[0].options.map(\.id),
            ["207428", "207429", "207430", "207431"]
        )
        XCTAssertEqual(
            poll.groups[0].options.map(\.title),
            ["原皮白", "剧情黑", "泳装白", "只想看结果"]
        )
        XCTAssertEqual(
            poll.endsAt,
            Date(timeIntervalSince1970: 1_793_076_441)
        )
        XCTAssertTrue(poll.hidesResultsUntilVoting)
        XCTAssertFalse(poll.hidesResultsUntilEnd)
        XCTAssertFalse(poll.showsResults(at: Date(timeIntervalSince1970: 1_790_000_000)))

        let endpoint = NGAEndpoint.topicPollVote(
            topicID: poll.id,
            optionIDs: ["207429"]
        )
        XCTAssertEqual(endpoint.path, "/nuke.php")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertTrue(endpoint.isWrite)
        XCTAssertEqual(endpoint.form["__lib"], "vote")
        XCTAssertEqual(endpoint.form["__act"], "vote")
        XCTAssertEqual(endpoint.form["tid"], "47273517")
        XCTAssertEqual(endpoint.form["voteid"], "207429")
        XCTAssertEqual(endpoint.form["raw"], "3")
        XCTAssertEqual(
            endpoint.referer,
            NGAEndpoint.topicWebURL(topicID: poll.id)
        )
    }

    func testParsesGroupedMultiSelectPollResults() throws {
        let payload = """
        {
          "data": {
            "__T": {"tid": 47273518, "fid": 853, "subject": "分组投票", "replies": 0},
            "__R": [{
              "pid": 0,
              "tid": 47273518,
              "lou": 0,
              "author": "Alice",
              "content": "主题正文",
              "vote": "100~第一组甲~101~第一组乙~102~=== 第二组~103~第二组甲~104~第二组乙~max_select~2~opt~0~_100~3,0,8~_101~5,0,8~_102~0,0,0~_103~4,0,7~_104~3,0,7"
            }]
          }
        }
        """

        let page = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47_273_518),
            page: 1
        )
        let poll = try XCTUnwrap(page.posts.first?.poll)

        XCTAssertEqual(poll.groups.count, 2)
        XCTAssertNil(poll.groups[0].title)
        XCTAssertEqual(poll.groups[0].options.map(\.id), ["100", "101"])
        XCTAssertEqual(poll.groups[1].title, "第二组")
        XCTAssertEqual(poll.groups[1].options.map(\.id), ["103", "104"])
        XCTAssertEqual(poll.maximumSelectionsPerGroup, 2)
        XCTAssertEqual(poll.participantCount, 8)
        XCTAssertEqual(poll.totalVoteCount, 15)
        XCTAssertTrue(poll.showsResults(at: .now))
        XCTAssertTrue(poll.containsValidSelection(["100", "101", "103"]))
        XCTAssertFalse(poll.containsValidSelection(["100", "101", "103", "missing"]))
        XCTAssertEqual(
            poll.orderedOptionIDs(in: ["104", "100", "103"]),
            ["100", "103", "104"]
        )
    }

    func testParsesTopicPollFromHTMLFallback() throws {
        let html = """
        <html>
          <head><title>网页投票 - NGA玩家社区</title></head>
          <body>
            <table>
              <tr class="postrow">
                <td>
                  <a name="l0"></a>
                  <div id="postcontent0"><p>网页正文</p></div>
                </td>
              </tr>
            </table>
            <script>
              commonui.vote($('votec0'),105,'1~选项一~2~选项二~max_select~1~opt~2~_1~6,0,10~_2~4,0,10')
            </script>
          </body>
        </html>
        """

        let page = try parser.threadPage(
            from: response(html, contentType: "text/html; charset=utf-8"),
            topicID: TopicID(rawValue: 105),
            page: 1
        )
        let poll = try XCTUnwrap(page.posts.first?.poll)

        XCTAssertEqual(poll.groups[0].options.map(\.title), ["选项一", "选项二"])
        XCTAssertEqual(poll.groups[0].options.map(\.voteCount), [6, 4])
        XCTAssertEqual(poll.participantCount, 10)
        XCTAssertTrue(poll.hidesResultsUntilEnd)
    }

    func testParsesStructuredTopicRatingAndReplyScore() throws {
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 23347410,
              "fid": 571,
              "subject": "[评分] 《原神》",
              "author": "Alice",
              "replies": 5537,
              "post_misc_var": {
                "vote": "52689~《原神》游戏评分：~max_select~1~type~2~min~1~max~10~52689s5~773~52689s1~2957~52689s4~351~52689s3~282~52689s2~417~_52689~4787,16561,4784"
              }
            },
            "__R": [{
              "pid": 876262889,
              "tid": 23347410,
              "lou": 5,
              "author": "Bob",
              "content": "打个10分。",
              "from_client": "8 Android",
              "vote": "52689~10~type~3"
            }]
          }
        }
        """

        let page = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 23_347_410),
            page: 1
        )
        let rating = try XCTUnwrap(page.topic.rating)
        let dimension = try XCTUnwrap(rating.dimensions.first)

        XCTAssertEqual(rating.id, TopicID(rawValue: 23_347_410))
        XCTAssertEqual(rating.minimumScore, 1)
        XCTAssertEqual(rating.maximumScore, 10)
        XCTAssertEqual(rating.participantCount, 4_784)
        XCTAssertEqual(dimension.id, "52689")
        XCTAssertEqual(dimension.title, "《原神》游戏评分：")
        XCTAssertEqual(dimension.ratingCount, 4_787)
        XCTAssertEqual(dimension.totalScore, 16_561)
        XCTAssertEqual(dimension.averageScore, 3.45, accuracy: 0.001)
        XCTAssertTrue(rating.containsValidScores([:]))
        XCTAssertTrue(rating.containsValidScores(["52689": 8]))
        XCTAssertFalse(rating.containsValidScores(["52689": 11]))
        XCTAssertFalse(rating.containsValidScores(["missing": 8]))
        XCTAssertEqual(page.posts.first?.device, .android)
        XCTAssertEqual(page.posts.first?.ratingScores, ["52689": 10])
    }

    func testParsesTopicRatingAndMultipleReplyScoresFromHTMLFallback() throws {
        let html = """
        <html>
          <head><title>网页评分 - NGA玩家社区</title></head>
          <body>
            <table>
              <tr class="postrow">
                <td>
                  <a name="l0"></a>
                  <div id="postcontent0"><p>评分主题正文</p></div>
                </td>
              </tr>
              <tr class="postrow">
                <td>
                  <a name="l1"></a>
                  <div id="postcontent1"><p>评分回复</p></div>
                </td>
              </tr>
            </table>
            <script>
              commonui.vote(
                $('votec0'),
                105,
                '11~剧情~12~画面~type~2~min~1~max~5~_11~2,7,2~_12~2,9,2'
              )
              commonui.vote($('votec1'),105,'11~3~12~5~type~3')
            </script>
          </body>
        </html>
        """

        let page = try parser.threadPage(
            from: response(html, contentType: "text/html; charset=utf-8"),
            topicID: TopicID(rawValue: 105),
            page: 1
        )
        let rating = try XCTUnwrap(page.topic.rating)
        let reply = try XCTUnwrap(page.posts.first { $0.floor == 1 })

        XCTAssertEqual(rating.dimensions.map(\.id), ["11", "12"])
        XCTAssertEqual(rating.dimensions.map(\.title), ["剧情", "画面"])
        XCTAssertEqual(rating.dimensions.map(\.averageScore), [3.5, 4.5])
        XCTAssertEqual(rating.participantCount, 2)
        XCTAssertEqual(reply.ratingScores, ["11": 3, "12": 5])
    }

    func testParsesTopicSubjectColorsFromTopicMiscAndTitlefont() throws {
        func encodedFontBits(_ bits: UInt32) -> String {
            Data([
                1,
                UInt8((bits >> 24) & 0xFF),
                UInt8((bits >> 16) & 0xFF),
                UInt8((bits >> 8) & 0xFF),
                UInt8(bits & 0xFF)
            ])
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        }

        let payload = """
        {
          "__T": [
            {
              "tid": 201,
              "fid": 650,
              "subject": "实际响应中的红色主题",
              "topic_misc": "AQQAACE"
            },
            {
              "tid": 202,
              "fid": 650,
              "subject": "蓝色主题",
              "topic_misc": "\(encodedFontBits(0x2))"
            },
            {
              "tid": 203,
              "fid": 650,
              "subject": "绿色主题",
              "topic_misc": "\(encodedFontBits(0x4))"
            },
            {
              "tid": 204,
              "fid": 650,
              "subject": "橙色主题",
              "titlefont": "\(encodedFontBits(0x8))"
            },
            {
              "tid": 205,
              "fid": 650,
              "subject": "银色主题",
              "topic_misc": "\(encodedFontBits(0x10))"
            },
            {
              "tid": 206,
              "fid": 650,
              "subject": "普通主题",
              "topic_misc": "AgI6eII"
            }
          ]
        }
        """

        let page = try parser.forumPage(
            from: response(payload),
            forumID: ForumID(rawValue: 650),
            page: 1
        )

        XCTAssertEqual(
            page.topics.map(\.subjectColor),
            [.red, .blue, .green, .orange, .silver, nil]
        )
    }

    func testRepairsUTF8TopicListTextMisdecodedAsGB18030() throws {
        let payload = #"""
        {
          "__T": [
            {
              "tid": 47265330,
              "fid": 853,
              "subject": "[\u942E\u7FE0\u7C28\u59D8\u792D\u9353\u0447\u5FDA\uE11F\u935B\u5A4F\u7D1D\u9358\u71B8\u6F75\u6D93\uE15F\u5C33\u93C4\u95F4\u7BC3\u93C4\uE219\u91DC\u704F\u621D\u30B3\u6FE1\u581D\uE6ED",
              "author": "Qq189622",
              "replies": 5,
              "parent": {
                "0": 853,
                "1": 40755136,
                "2": "\u9353\u0444\u510F\u7481\u3128\uE191"
              }
            },
            {
              "tid": 47265331,
              "fid": 853,
              "subject": "正常显示的主题",
              "author": "Alice",
              "replies": 0
            }
          ]
        }
        """#

        let page = try parser.forumPage(
            from: response(payload),
            forumID: ForumID(rawValue: 853),
            page: 1
        )

        XCTAssertEqual(page.topics.first?.subject, "[破事氵]剧透警告，原来中挽昼也是个少女妈妈")
        XCTAssertEqual(page.topics.first?.sourceForumName, "剧情讨论")
        XCTAssertEqual(page.topics.last?.subject, "正常显示的主题")
    }

    func testThreadPageCountDoesNotAddAnEmptyPageAtTwentyPostBoundary() throws {
        let payload = #"{"data":{"__T":{"tid":102,"fid":-7,"subject":"整页主题","author":"Alice","replies":19},"__R":[{"pid":202,"tid":102,"lou":0,"author":"Alice","content":"正文"}]}}"#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 102),
            page: 1
        )

        XCTAssertEqual(thread.totalPages, 1)
        XCTAssertFalse(thread.hasMore)
    }

    func testLockedTopicJSONErrorUsesLockedTopicError() throws {
        let payload = #"{"error":["11:\u6b64\u5e16\u5b50\u88ab\u9501\u5b9a"],"data":{"__MESSAGE":[11,"\u6b64\u5e16\u5b50\u88ab\u9501\u5b9a",null,403]}}"#

        XCTAssertThrowsError(try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47_305_779),
            page: 1
        )) { error in
            XCTAssertEqual(error as? NGAServiceError, .topicLocked)
        }
    }

    func testComputesForumPageCountFromStructuredRowMetadata() throws {
        let payload = """
        {
          "data": {
            "__ROWS": 343716,
            "__T__ROWS_PAGE": 35,
            "__F": {"fid": 414, "name": "游戏综合讨论"},
            "__T": [
              {"tid": 1001, "fid": 414, "subject": "分页主题", "author": "Alice", "replies": 1}
            ]
          }
        }
        """

        let page = try parser.forumPage(
            from: response(payload),
            forumID: ForumID(rawValue: 414),
            page: 2
        )

        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.totalPages, 9_821)
        XCTAssertTrue(page.hasMore)
    }

    func testParsesAlternateStructuredPostFields() throws {
        let payload = #"{"data":{"__T":{"tid":103,"fid":-7,"subject":"特殊主题","author":"Alice","replies":0},"__R":[{"postid":203,"tid":103,"floor":0,"author":"Alice","post_content":"特殊正文"}]}}"#

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 103),
            page: 1
        )

        XCTAssertEqual(thread.posts.first?.id, PostID(rawValue: 203))
        XCTAssertEqual(thread.posts.first?.html, "特殊正文")
    }

    func testParsesCurrentHTMLPostMetadataAndEmbeddedUsers() throws {
        // 当前 NGA 网页把楼层作者 UID 放在 postArg.proc 中，把真实用户名
        // 放在 userInfo.setAll 的内嵌 JSON 中，作者并不是正文节点的父元素。
        let html = """
        <html>
          <head><title>回退标题 - NGA玩家社区</title></head>
          <body>
            <h1 id="currentTopicName">真实主题标题</h1>
            <table>
              <tr class="postrow">
                <td>
                  <a name="l0"></a>
                  <span id="postdate0">2026-07-23 10:48</span>
                  <h3 id="postsubject0">真实主题标题</h3>
                  <div id="postcontent0"><p>主楼正文</p></div>
                </td>
              </tr>
              <tr class="postrow">
                <td>
                  <a name="l1"></a>
                  <span id="postdate1">2026-07-23 10:52</span>
                  <div id="postcontent1"><p>一楼正文</p></div>
                </td>
              </tr>
            </table>
            <script>
              commonui.userInfo.setAll({
                "62810712": {
                  "uid": 62810712,
                  "username": "主楼用户",
                  "avatar": "//img.nga.178.com/avatars/2020/12/62810712.jpg"
                },
                "67182815": {
                  "uid": 67182815,
                  "username": "一楼用户",
                  "avatar": null
                }
              });
              commonui.postArg.proc('0',0,0,0,0,0,0,0,0,0,'0','0',0,'62810712','1784774880','0,4,0','12',0,0,'7 iOS',0,0,0);
              commonui.postArg.proc('1',0,0,0,0,0,0,0,0,0,'876113671','0',0,'67182815','1784775120','0,2,0','8',0,0,'0 /',0,0,0);
            </script>
          </body>
        </html>
        """

        let thread = try parser.threadPage(
            from: response(html, contentType: "text/html; charset=utf-8"),
            topicID: TopicID(rawValue: 47239186),
            page: 1
        )

        XCTAssertEqual(thread.topic.subject, "真实主题标题")
        XCTAssertEqual(thread.topic.author, "主楼用户")
        XCTAssertEqual(thread.posts.map(\.id), [PostID(rawValue: 0), PostID(rawValue: 876113671)])
        XCTAssertEqual(thread.posts.map(\.floor), [0, 1])
        XCTAssertEqual(thread.posts.map(\.authorUID), [62810712, 67182815])
        XCTAssertEqual(thread.posts.map(\.author), ["主楼用户", "一楼用户"])
        XCTAssertEqual(
            thread.posts.first?.avatarURL?.absoluteString,
            "https://img.nga.178.com/avatars/2020/12/62810712.jpg"
        )
        XCTAssertEqual(thread.posts.map(\.device), [.apple, .desktop])
        XCTAssertEqual(thread.posts.map(\.upvoteCount), [4, 2])
    }

    func testParsesWrappedThreadPayloadWithHotRepliesKeptSeparateFromFloors() throws {
        // 脱敏自 NGA tid=47240175 的响应形态：data 同级包含 __T、__U、__R，
        // 而首帖内还会嵌套 hotreply。热点回复需要展示，但不能混入分页楼层。
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 47240175,
              "fid": 510559,
              "subject": "响应结构测试",
              "authorid": 100,
              "author": "楼主用户",
              "replies": 21
            },
            "__U": {
              "100": {"uid": 100, "username": "UID:100"},
              "200": {"uid": 200, "username": "一楼用户"},
              "300": {"uid": 300, "username": "热门回复用户"}
            },
            "__R": [
              {
                "pid": 0,
                "tid": 47240175,
                "lou": 1,
                "authorid": 100,
                "content": "主题首帖",
                "hotreply": [{
                  "pid": 302,
                  "tid": 47240175,
                  "lou": 2,
                  "authorid": 300,
                  "content": "嵌套热门回复"
                }]
              },
              {
                "pid": 301,
                "tid": 47240175,
                "lou": 1,
                "author_id": 200,
                "content": "正常一楼"
              }
            ]
          }
        }
        """

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47240175),
            page: 1
        )

        XCTAssertEqual(thread.topic.author, "楼主用户")
        XCTAssertEqual(thread.topic.authorUID, 100)
        XCTAssertEqual(thread.topic.replyCount, 21)
        XCTAssertEqual(thread.posts.map(\.id), [PostID(rawValue: 0), PostID(rawValue: 301)])
        XCTAssertEqual(thread.posts.map(\.floor), [0, 1])
        XCTAssertEqual(thread.posts.map(\.author), ["楼主用户", "一楼用户"])
        XCTAssertEqual(thread.hotReplies.map(\.id), [PostID(rawValue: 302)])
        XCTAssertEqual(thread.hotReplies.map(\.floor), [2])
        XCTAssertEqual(thread.hotReplies.map(\.author), ["热门回复用户"])
        XCTAssertEqual(thread.hotReplies.map(\.html), ["嵌套热门回复"])
        XCTAssertEqual(thread.totalPages, 2)
    }

    func testThreadPaginationUsesFilteredResponseRowCount() throws {
        let payload = """
        {
          "data": {
            "__ROWS": 8,
            "__R__ROWS_PAGE": 20,
            "__T": {
              "tid": 47300693,
              "fid": 510381,
              "subject": "只看作者分页",
              "authorid": 64994774,
              "author": "主题作者",
              "replies": 51
            },
            "__R": [{
              "pid": 0,
              "tid": 47300693,
              "lou": 0,
              "authorid": 64994774,
              "content": "主题首帖"
            }]
          }
        }
        """

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47300693),
            page: 1
        )

        XCTAssertEqual(thread.topic.authorUID, 64_994_774)
        XCTAssertEqual(thread.totalPages, 1)
        XCTAssertFalse(thread.hasMore)
    }

    func testKeepsObjectShapedReplyMapInFloorOrderAndResolvesUsers() throws {
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 104,
              "fid": -7,
              "subject": "对象楼层表",
              "authorid": 10,
              "author": "主题作者",
              "replies": 2
            },
            "__U": {
              "10": {"uid": 10, "username": "主题作者"},
              "11": {"uid": 11, "username": "一楼作者"},
              "12": {"uid": 12, "username": "二楼作者"}
            },
            "__R": {
              "2": {"pid": 502, "tid": 104, "lou": 2, "authorId": 12, "content": "二楼"},
              "0": {"pid": 0, "tid": 104, "lou": 0, "authorid": 10, "content": "主楼"},
              "1": {"pid": 501, "tid": 104, "lou": 1, "uid": 11, "content": "一楼"}
            }
          }
        }
        """

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 104),
            page: 1
        )

        XCTAssertEqual(thread.posts.map(\.floor), [0, 1, 2])
        XCTAssertEqual(thread.posts.map(\.author), ["主题作者", "一楼作者", "二楼作者"])
    }

    func testResolvesOrderedAnonymousUsersWhosePayloadUIDsAreZero() throws {
        // NGA 匿名版面中的楼层使用 -1、-2 等 authorid，但 __U 记录的
        // uid 可能全部为 0；用户与负 ID 的关系由 __U 的顺序决定。
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 47239391,
              "fid": 843,
              "subject": "匿名用户映射",
              "authorid": -1,
              "author": "#anony_00000000000000000000000000000000",
              "replies": 2
            },
            "__U": {
              "0": {
                "uid": 0,
                "username": "#anony_00000000000000000000000000000000"
              },
              "1": {
                "uid": 0,
                "username": "#anony_11111111111000000000000000000000"
              },
              "2": {
                "uid": 0,
                "username": "#anony_22222222222000000000000000000000"
              }
            },
            "__R": [
              {
                "pid": 0,
                "tid": 47239391,
                "lou": 0,
                "authorid": -1,
                "content": "主楼"
              },
              {
                "pid": 7001,
                "tid": 47239391,
                "lou": 1,
                "authorid": -2,
                "content": "一楼"
              },
              {
                "pid": 7002,
                "tid": 47239391,
                "lou": 2,
                "authorid": -3,
                "content": "二楼"
              }
            ]
          }
        }
        """

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47239391),
            page: 1
        )

        XCTAssertEqual(thread.topic.author, "甲王王甲王王")
        XCTAssertEqual(thread.posts.map(\.authorUID), [-1, -2, -3])
        XCTAssertEqual(
            thread.posts.map(\.author),
            ["甲王王甲王王", "乙何何乙何何", "丙潘潘丙潘潘"]
        )
        XCTAssertFalse(thread.posts.contains { $0.author.hasPrefix("用户 ") })
    }

    func testResolvesAnonymousUsersFromNegativeUserMapKeys() throws {
        let payload = """
        {
          "data": {
            "__T": {
              "tid": 47238737,
              "fid": 843,
              "subject": "负键匿名用户映射",
              "replies": 1
            },
            "__U": {
              "-2": {
                "uid": 0,
                "username": "#anony_11111111111000000000000000000000"
              },
              "-1": {
                "uid": 0,
                "username": "#anony_00000000000000000000000000000000"
              }
            },
            "__R": [
              {
                "pid": 0,
                "tid": 47238737,
                "lou": 0,
                "authorid": -1,
                "content": "主楼"
              },
              {
                "pid": 7101,
                "tid": 47238737,
                "lou": 1,
                "authorid": -2,
                "content": "一楼"
              }
            ]
          }
        }
        """

        let thread = try parser.threadPage(
            from: response(payload),
            topicID: TopicID(rawValue: 47238737),
            page: 1
        )

        XCTAssertEqual(thread.posts.map(\.author), ["甲王王甲王王", "乙何何乙何何"])
    }

    func testParsesSubforumsAndMarksTopicsWithTheirSource() throws {
        let payload = """
        {
          "data": {
            "__F": {
              "fid": 414,
              "name": "游戏综合讨论",
              "topped_topic": 8984969,
              "sub_forums": {
                "614": [614, "PS游戏综合讨论", null, 15743992, 2606],
                "489": [489, "怪物猎人(Capcom)", "Monster Hunter", 18431266, 40],
                "t35925536": [35925536, "独立游戏", null, 35925536, 2590]
              }
            },
            "__T": [
              {
                "tid": 1001,
                "fid": 414,
                "subject": "主板块主题",
                "author": "Alice",
                "replies": 1
              },
              {
                "tid": 1002,
                "fid": 614,
                "subject": "PS 子板块主题",
                "author": "Bob",
                "replies": 2,
                "parent": {"0": 614, "2": "PS游戏综合讨论"}
              },
              {
                "tid": 1003,
                "fid": 541,
                "subject": "独立游戏合集主题",
                "author": "Carol",
                "replies": 3,
                "parent": {"0": 541, "1": 35925536, "2": "独立游戏"}
              },
              {
                "tid": 1004,
                "fid": 489,
                "subject": "怪猎下属合集主题",
                "author": "David",
                "replies": 4,
                "parent": {"0": 489, "1": 26217002, "2": "新手问答"}
              }
            ]
          }
        }
        """

        let page = try parser.forumPage(
            from: response(payload),
            forumID: ForumID(rawValue: 414),
            page: 1
        )

        XCTAssertEqual(page.forum?.id, ForumID(rawValue: 414))
        XCTAssertEqual(page.forum?.name, "游戏综合讨论")
        XCTAssertEqual(page.forum?.pinnedTopicID, TopicID(rawValue: 8984969))
        XCTAssertEqual(
            Set(page.subforums.map(\.id)),
            Set([
                ForumID(rawValue: 614),
                ForumID(rawValue: 489),
                ForumID(stid: 35925536)
            ])
        )
        XCTAssertEqual(
            page.subforums.first(where: { $0.id == ForumID(rawValue: 489) })?.subtitle,
            "Monster Hunter"
        )
        XCTAssertEqual(
            page.subforums.first(where: { $0.id == ForumID(rawValue: 614) })?.pinnedTopicID,
            TopicID(rawValue: 15743992)
        )
        XCTAssertEqual(
            page.subforums.first(where: { $0.id == ForumID(stid: 35925536) })?.pinnedTopicID,
            TopicID(rawValue: 35925536)
        )
        XCTAssertEqual(
            Set(
                page.subforums
                    .filter { $0.isSelectedInParent == true }
                    .map(\.id)
            ),
            Set([ForumID(rawValue: 614), ForumID(stid: 35925536)])
        )
        XCTAssertEqual(
            page.subforums.first(where: { $0.id == ForumID(rawValue: 489) })?
                .isSelectedInParent,
            false
        )
        XCTAssertNil(page.topics.first(where: { $0.id == TopicID(rawValue: 1001) })?.sourceForumID)
        XCTAssertEqual(
            page.topics.first(where: { $0.id == TopicID(rawValue: 1002) })?.sourceForumID,
            ForumID(rawValue: 614)
        )
        XCTAssertEqual(
            page.topics.first(where: { $0.id == TopicID(rawValue: 1003) })?.sourceForumID,
            ForumID(stid: 35925536)
        )
        XCTAssertEqual(
            page.topics.first(where: { $0.id == TopicID(rawValue: 1004) })?.sourceParentForumID,
            ForumID(rawValue: 489)
        )
    }

    func testUsesSelectedCollectionNameWhenOpeningSTIDSubforum() throws {
        let payload = """
        {
          "data": {
            "__F": {
              "fid": 541,
              "name": "游戏专版/合集",
              "set_topic_tid": 35925536,
              "set_topic_subject": "独立游戏",
              "sub_forums": {
                "t35925536": [35925536, "独立游戏", null, null, 8208]
              }
            },
            "__T": [{
              "tid": 1005,
              "fid": 541,
              "subject": "合集主题",
              "author": "Alice",
              "replies": 1,
              "parent": {"0": 541, "1": 35925536, "2": "独立游戏"}
            }]
          }
        }
        """
        let selectedID = ForumID(stid: 35925536)

        let page = try parser.forumPage(
            from: response(payload),
            forumID: selectedID,
            page: 1
        )

        XCTAssertEqual(
            page.forum,
            Forum(id: selectedID, name: "独立游戏", isSelectedInParent: false)
        )
        XCTAssertTrue(page.subforums.isEmpty)
        XCTAssertNil(page.topics.first?.sourceForumID)
        XCTAssertNil(page.topics.first?.sourceForumName)
    }

    func testParsesForumMirrorAsBoardDestination() throws {
        let payload = """
        {
          "data": {
            "__F": {
              "fid": 414,
              "name": "游戏综合讨论",
              "sub_forums": {
                "510434": [510434, "幻兽帕鲁", null, 39070003, 2606]
              }
            },
            "__T": [{
              "tid": 39070003,
              "fid": 635,
              "subject": "幻兽帕鲁",
              "author": "admin",
              "replies": 0,
              "type": 2097152,
              "topic_misc_var": {"3": 510434, "1": 32},
              "parent": {"0": 635, "2": "版面镜像"}
            }]
          }
        }
        """

        let page = try parser.forumPage(
            from: response(payload),
            forumID: ForumID(rawValue: 414),
            page: 1
        )

        XCTAssertEqual(page.topics.first?.mirroredForumID, ForumID(rawValue: 510434))
        XCTAssertEqual(page.subforums.first?.name, "幻兽帕鲁")
        XCTAssertFalse(page.topics.first?.isPinned ?? true)
    }

    func testParsesCurrentAppForumDirectoryAndKeepsStidDistinct() throws {
        let payload = """
        {
          "code": 0,
          "forum_icon_pre": "http://img4.nga.178.com/ngabbs/nga_classic/f/app/",
          "result": [{
            "_id": "game",
            "name": "综合游戏讨论区",
            "groups": [{
              "name": "热门游戏",
              "forums": [
                {"fid": 510381, "name": "晴风村", "info": "社区讨论", "id": 510381, "icon": ""},
                {"fid": 414, "stid": "18855745", "name": "血污：夜之仪式", "id": "18855745", "icon": ""}
              ]
            }]
          }]
        }
        """

        let forums = try parser.forums(from: response(payload))

        XCTAssertEqual(forums.count, 2)
        XCTAssertEqual(forums[0].id, ForumID(rawValue: 510381))
        XCTAssertEqual(forums[0].category, "综合游戏讨论区")
        XCTAssertEqual(forums[0].iconURL?.scheme, "https")
        XCTAssertEqual(forums[1].id.queryName, "stid")
        XCTAssertEqual(forums[1].id.description, "18855745")
        XCTAssertNotEqual(forums[1].id, ForumID(rawValue: 414))
    }

    func testForumDirectoryEndpointUsesCurrentAppRoute() {
        let endpoint = NGAEndpoint.forums

        XCTAssertEqual(endpoint.path, "/app_api.php")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertFalse(endpoint.isWrite)
        XCTAssertEqual(endpoint.form["__output"], "11")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "__lib" })?.value, "home")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "__act" })?.value, "category")
    }

    func testTopicWebURLUsesCanonicalReadLink() {
        let url = NGAEndpoint.topicWebURL(topicID: TopicID(rawValue: 47239680))

        XCTAssertEqual(url.absoluteString, "https://bbs.nga.cn/read.php?tid=47239680")
        XCTAssertFalse(url.absoluteString.contains("__output"))
    }

    func testRecognizesNGAInternalTopicAndPostLinks() throws {
        let topicURL = try XCTUnwrap(URL(
            string: "https://nga.178.com/read.php?pid=876078281&tid=47237166&page=3"
        ))
        let postURL = try XCTUnwrap(URL(
            string: "https://bbs.ngacn.cc/read.php?pid=876078282&page=4"
        ))

        XCTAssertEqual(
            NGAInternalLink.destination(for: topicURL),
            .topic(
                topicID: TopicID(rawValue: 47_237_166),
                page: 3,
                postID: PostID(rawValue: 876_078_281)
            )
        )
        XCTAssertEqual(
            NGAInternalLink.destination(for: postURL),
            .post(postID: PostID(rawValue: 876_078_282), page: 4)
        )
    }

    func testRecognizesNGAInternalForumAndUserLinks() throws {
        let subforumURL = try XCTUnwrap(URL(
            string: "https://bbs.nga.cn/thread.php?stid=18855745"
        ))
        let userURL = try XCTUnwrap(URL(
            string: "https://ngabbs.com/nuke.php?func=ucp&uid=36379260"
        ))

        XCTAssertEqual(
            NGAInternalLink.destination(for: subforumURL),
            .forum(ForumID(stid: 18_855_745))
        )
        XCTAssertEqual(
            NGAInternalLink.destination(for: userURL),
            .user(uid: 36_379_260)
        )
    }

    func testDoesNotTreatExternalLookalikeAsNGAInternalLink() throws {
        let externalURL = try XCTUnwrap(URL(
            string: "https://bbs.nga.cn.example.com/read.php?tid=47237166"
        ))

        XCTAssertNil(NGAInternalLink.destination(for: externalURL))
    }

    func testThreadHTMLEndpointDoesNotRequestStructuredOutput() {
        let endpoint = NGAEndpoint.threadHTML(
            topicID: TopicID(rawValue: 47239680),
            page: 3,
            authorUID: nil
        )

        XCTAssertEqual(endpoint.path, "/read.php")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "tid" })?.value, "47239680")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "page" })?.value, "3")
        XCTAssertNil(endpoint.queryItems.first(where: { $0.name == "__output" }))
    }

    func testParsesCurrentAccountFavorites() throws {
        let payload = """
        {
          "code": 0,
          "result": [{
            "groups": [{
              "forums": [
                {"fid": -7, "name": "艾泽拉斯国家地理", "info": "网事杂谈"},
                {"fid": 510381, "name": "晴风村"}
              ]
            }]
          }]
        }
        """

        let favorites = try parser.favoriteForums(from: response(payload))
        XCTAssertEqual(favorites.map(\.id), [ForumID(rawValue: -7), ForumID(rawValue: 510381)])
        XCTAssertEqual(NGAEndpoint.favorites.path, "/app_api.php")
        XCTAssertEqual(
            NGAEndpoint.favorites.queryItems.first(where: { $0.name == "__lib" })?.value,
            "favorforum"
        )
        XCTAssertEqual(
            try parser.favoriteForums(from: response(#"{"code":0,"result":[]}"#)),
            []
        )
    }

    func testParsesFavoriteTopicsAndBuildsTopicFavoriteEndpoints() throws {
        let payload = """
        {
          "data": {
            "__ROWS": 21,
            "__T__ROWS_PAGE": 20,
            "__T": {
              "0": {
                "tid": 47239680,
                "fid": -7,
                "subject": "收藏主题",
                "author": "Alice",
                "replies": 12
              }
            }
          }
        }
        """

        let page = try parser.favoriteTopicPage(from: response(payload), page: 1)
        XCTAssertEqual(page.topics.map(\.id), [TopicID(rawValue: 47239680)])
        XCTAssertEqual(page.topics.first?.forumID, ForumID(rawValue: -7))
        XCTAssertTrue(page.topics.first?.isFavorite == true)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.totalPages, 2)

        let listEndpoint = NGAEndpoint.favoriteTopics(folderID: "541", page: 3)
        XCTAssertEqual(listEndpoint.path, "/thread.php")
        XCTAssertEqual(
            listEndpoint.queryItems.first(where: { $0.name == "favor" })?.value,
            "541"
        )
        XCTAssertEqual(
            listEndpoint.queryItems.first(where: { $0.name == "page" })?.value,
            "3"
        )

        let addEndpoint = NGAEndpoint.updateTopicFavorite(
            topicID: TopicID(rawValue: 47239680),
            folderID: "541",
            isFavorite: true
        )
        XCTAssertEqual(addEndpoint.method, .post)
        XCTAssertTrue(addEndpoint.isWrite)
        XCTAssertEqual(
            addEndpoint.queryItems.first(where: { $0.name == "__lib" })?.value,
            "topic_favor_v2"
        )
        XCTAssertEqual(
            addEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "add"
        )
        XCTAssertEqual(addEndpoint.form["tid"], "47239680")
        XCTAssertNil(addEndpoint.form["tidarray"])
        XCTAssertEqual(addEndpoint.form["folder"], "541")

        let removeEndpoint = NGAEndpoint.updateTopicFavorite(
            topicID: TopicID(rawValue: 47239680),
            folderID: "541",
            isFavorite: false
        )
        XCTAssertEqual(
            removeEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "del"
        )
        XCTAssertEqual(removeEndpoint.form["tidarray"], "47239680")
        XCTAssertNil(removeEndpoint.form["tid"])
    }

    func testParsesAndBuildsFavoriteTopicFolderRequests() throws {
        let payload = """
        {
          "data": {
            "0": {
              "1": {
                "id": 1,
                "name": "公主连结",
                "length": 31,
                "default": ""
              },
              "541": {
                "id": "541",
                "name": "未命名的收藏夹#541",
                "length": 27,
                "public": 1
              }
            }
          }
        }
        """

        let folders = try parser.favoriteTopicFolders(from: response(payload))
        XCTAssertEqual(folders.map(\.id), ["1", "541"])
        XCTAssertEqual(folders.map(\.name), ["公主连结", "未命名的收藏夹#541"])
        XCTAssertEqual(folders.map(\.topicCount), [31, 27])
        XCTAssertTrue(folders[0].isDefault)
        XCTAssertFalse(folders[0].isPublic)
        XCTAssertFalse(folders[1].isDefault)
        XCTAssertTrue(folders[1].isPublic)

        let listEndpoint = NGAEndpoint.favoriteTopicFolders
        XCTAssertEqual(
            listEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "list_folder"
        )

        let createEndpoint = NGAEndpoint.createTopicFavoriteFolder(
            name: "攻略",
            isPublic: true,
            isDefault: true
        )
        XCTAssertEqual(
            createEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "new_folder"
        )
        XCTAssertEqual(createEndpoint.form["name"], "攻略")
        XCTAssertEqual(createEndpoint.form["opt"], "3")

        let folder = TopicFavoriteFolder(
            id: "541",
            name: "攻略合集",
            topicCount: 27,
            isPublic: true,
            isDefault: false
        )
        let modifyEndpoint = NGAEndpoint.updateTopicFavoriteFolder(folder)
        XCTAssertEqual(
            modifyEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "modify_folder"
        )
        XCTAssertEqual(modifyEndpoint.form["folder"], "541")
        XCTAssertEqual(modifyEndpoint.form["name"], "攻略合集")
        XCTAssertEqual(modifyEndpoint.form["opt"], "1")

        let deleteEndpoint = NGAEndpoint.deleteTopicFavoriteFolder(folderID: "541")
        XCTAssertEqual(
            deleteEndpoint.queryItems.first(where: { $0.name == "__act" })?.value,
            "del_folder"
        )
        XCTAssertEqual(deleteEndpoint.form["folder"], "541")

        XCTAssertEqual(
            try parser.createdTopicFavoriteFolderID(
                from: response(#"{"data":{"1":"542"}}"#)
            ),
            "542"
        )
    }

    func testFallsBackToHTML() throws {
        let html = """
        <html><body>
        <a href="/thread.php?fid=-7">艾泽拉斯国家地理</a>
        <a href="/thread.php?fid=510381">晴风村</a>
        </body></html>
        """
        let forums = try parser.forums(from: response(html, contentType: "text/html; charset=utf-8"))
        XCTAssertEqual(forums.map(\.id), [ForumID(rawValue: -7), ForumID(rawValue: 510381)])
    }

    func testDecodesGB18030Response() throws {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let encoding = String.Encoding(rawValue: raw)
        let data = try XCTUnwrap("签到成功".data(using: encoding))
        let response = NGAHTTPResponse(
            data: data,
            statusCode: 200,
            headers: ["Content-Type": "text/plain; charset=gb18030"],
            url: NGAEndpoint.baseURL
        )
        XCTAssertEqual(try response.decodedString(), "签到成功")
    }

    func testDecodesHTMLEntitiesInStructuredTextAndPostContent() throws {
        let topicResponse = response(
            #"{"__T":[{"tid":102,"fid":-7,"subject":"Tom&#39;s &quot;Game&quot; &amp;amp; More","author":"A&amp;B","replies":0}]}"#
        )
        let page = try parser.forumPage(
            from: topicResponse,
            forumID: ForumID(rawValue: -7),
            page: 1
        )
        XCTAssertEqual(page.topics.first?.subject, #"Tom's "Game" & More"#)
        XCTAssertEqual(page.topics.first?.author, "A&B")

        let html = parser.sanitizedPostHTML(
            "<p>Tom&amp;#39;s &amp;quot;reply&amp;quot; &amp;amp; more</p>"
        )
        let document = try SwiftSoup.parse(html)
        XCTAssertEqual(try document.body()?.text(), #"Tom's "reply" & more"#)
    }

    func testSanitizerRemovesExecutableContent() {
        let html = parser.sanitizedPostHTML("<p onclick='steal()'>安全</p><script>steal()</script><form><input></form><img src='https://img.nga.cn/a.png'>")
        XCTAssertFalse(html.contains("onclick"))
        XCTAssertFalse(html.contains("<script>steal()"))
        XCTAssertFalse(html.contains("<form>"))
        XCTAssertTrue(html.contains("https://img.nga.cn/a.png"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains(#"<main id="snga-post-content">"#))
    }

    func testRendersAttachmentAndOfficialSmileBBCode() {
        let html = parser.sanitizedPostHTML(
            "[img]./mon_202607/23/example.jpg[/img]\n[s:ac:blink]"
        )

        XCTAssertTrue(html.contains("https://img.nga.178.com/attachments/mon_202607/23/example.jpg"))
        XCTAssertTrue(html.contains("https://img4.nga.178.com/ngabbs/post/smile/ac0.png"))
        XCTAssertTrue(html.contains("background:var(--snga-smile-backdrop)"))
        XCTAssertFalse(html.contains("[s:ac:blink]"))
    }

    func testImageFreeModeDefersPostImagesButKeepsEmoticons() throws {
        let html = parser.sanitizedPostHTML(
            "[img]./mon_202607/23/example.jpg[/img]\n[s:ac:blink]"
        )
        let deferred = PostImagePolicy.applying(to: html, hidesRemoteImages: true)
        let document = try SwiftSoup.parse(deferred)

        XCTAssertEqual(try document.select(".snga-image-placeholder").count, 1)
        XCTAssertEqual(
            try document.select(".snga-image-placeholder").first()?.attr("data-snga-src"),
            "https://img.nga.178.com/attachments/mon_202607/23/example.jpg"
        )
        XCTAssertEqual(try document.select("img.nga-smile[src]").count, 1)
        XCTAssertEqual(
            PostImagePolicy.applying(to: html, hidesRemoteImages: false),
            html
        )
    }

    func testRendersSafeRichTextFormattingForReplyPreview() throws {
        let html = parser.sanitizedPostHTML(
            """
            [color=red]红色[/color] [size=130%]大字[/size]
            [align=center][b]居中[/b][/align]
            适合[color=chocolate][异常][/color]特性的代理人挑战
            """
        )
        let document = try SwiftSoup.parse(html)

        XCTAssertTrue(html.contains(#"class="ubb-color-red""#))
        XCTAssertEqual(try document.select("span.ubb-color-chocolate").first?.text(), "[异常]")
        XCTAssertTrue(html.contains(".ubb-color-chocolate{color:chocolate}"))
        XCTAssertTrue(html.contains(#"class="ubb-size-130""#))
        XCTAssertTrue(html.contains(#"class="ubb-align-center""#))
        XCTAssertTrue(html.contains("<strong>居中</strong>"))
        XCTAssertFalse(html.contains("[color="))
        XCTAssertFalse(html.contains("[size="))
        XCTAssertFalse(html.contains("[align="))
    }

    func testCompactsRedundantSpacingAroundQuotedReplies() {
        let html = parser.sanitizedPostHTML(
            "\n\n[quote]引用内容[/quote]\n\n回复内容\n\n"
        )

        XCTAssertFalse(html.contains(#"<main id="snga-post-content"><br"#))
        XCTAssertFalse(html.contains("</blockquote><br>"))
        XCTAssertTrue(html.contains("</blockquote>回复内容"))
        XCTAssertTrue(html.contains("p{margin:6px 0}"))
    }

    func testRendersAdvancedNGAStyleCardWithoutLeakingLayoutUBB() {
        let html = parser.sanitizedPostHTML(
            """
            [randomblock][fixsize height 32.4 width 76.8 183]
            [style width 52][style font 3][comment game_title_cn]鸣潮3.5版本剧情评分[/comment game_title_cn][/style]
            [comment game_title_image][style width 50 src ./mon_202607/09/cover.webp][/style][/comment game_title_image][/style]
            [style width 12][style innerHTML &#36;votedata_voteavgvalue][/style]/10[/style]
            [color=teal]欢迎参与评分[/color]
            [/randomblock]
            """
        )

        XCTAssertTrue(html.contains("nga-game-card"))
        XCTAssertTrue(html.contains("鸣潮3.5版本剧情评分"))
        XCTAssertTrue(html.contains("https://img.nga.178.com/attachments/mon_202607/09/cover.webp"))
        XCTAssertTrue(html.contains(#"class="ubb-color-teal""#))
        XCTAssertFalse(html.contains("—"))
        XCTAssertFalse(html.contains("[randomblock]"))
        XCTAssertFalse(html.contains("[fixsize"))
        XCTAssertFalse(html.contains("[style"))
        XCTAssertFalse(html.contains("votedata_voteavgvalue"))
    }

    func testRendersFixedNGAHeaderCanvasWithSafeGeneratedStyles() throws {
        let source = """
            [randomblock][fixsize width 90 216 height 18 background #000000 #DDDDDD]
            [style width 90 height 18 left 63 top 0]
            [style width 13.5 height 13.5 left 2.25 top 2.25 dybg 100%;50%;50%;0%;0%;./mon_202603/03/header.webp filter-drop-shadow #00000044;0;0;0.225]
            [style width 8.55 height 1 left 4.5 top 3.15 line-height 1]
            [align=right][style font 1 color #999999][b]版规[/b][/style][/align]
            [/style]
            [style width 8.55 height 3.6 left 4.5 top 0.45 line-height 0.9]
            [align=left][style font 0.85 color #AAAAAA]严禁发布敏感内容[/style][/align]
            [/style]
            [/style][/style]
            [/randomblock]
            """
        let html = parser.sanitizedPostHTML(source)
        let document = try SwiftSoup.parse(html)

        XCTAssertEqual(html, parser.sanitizedPostHTML(source))
        XCTAssertEqual(try document.select(".nga-fixed-block").count, 1)
        XCTAssertEqual(try document.select(".nga-fixed-block-canvas").count, 1)
        XCTAssertEqual(try document.select("[style]").count, 0)
        XCTAssertEqual(try document.select("main").text(), "版规 严禁发布敏感内容")
        XCTAssertTrue(html.contains("height:18em"))
        XCTAssertTrue(html.contains("min-width:90em"))
        XCTAssertTrue(html.contains("max-width:216em"))
        XCTAssertTrue(html.contains("position:absolute"))
        XCTAssertTrue(html.contains("font-size:0.85em"))
        XCTAssertTrue(html.contains("color:#aaaaaa"))
        XCTAssertTrue(html.contains("filter:drop-shadow(0em 0em 0.225em #00000044)"))
        XCTAssertTrue(
            html.contains(
                #"background-image:url(&quot;https://img.nga.178.com/attachments/mon_202603/03/header.webp&quot;)"#
            ) || html.contains(
                #"background-image:url("https://img.nga.178.com/attachments/mon_202603/03/header.webp")"#
            )
        )
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[randomblock]"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[fixsize"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[style"))
    }

    func testKeepsFixedHeaderInlineImagesInsideCanvas() throws {
        let html = parser.sanitizedPostHTML(
            """
            [randomblock][fixsize height 19.3 width 90 153 background #212121 #212121]
            [style width 50% height 100% left 0 top 0]
            [style width 192.2929 height 100% right -98 top 0 dybg 100%;0%;0%;0%;0%;./mon_202607/28/background.webp][/style]
            [/style][/style]
            [style parentfitwidth right 32 top 1]
            [style padding 0 1][url=https://example.com/one]
            [style width 10.1915 height 17.2102 src ./mon_202607/28/character-one.png][/style]
            [/url][/style]
            [style padding 0 0][url=https://example.com/two]
            [style width 10.1915 height 17.2102 src ./mon_202607/28/character-two.png][/style]
            [/url][/style]
            [/style]
            [/randomblock]
            """
        )
        let document = try SwiftSoup.parse(html)
        let images = try document.select(".nga-fixed-block-canvas img")
        let firstImage = try XCTUnwrap(images.first())
        let generatedClass = try XCTUnwrap(
            try firstImage.attr("class").split(separator: " ")
                .map(String.init)
                .first { $0.hasPrefix("snga-fixed-") }
        )

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(
            try firstImage.attr("src"),
            "https://img.nga.178.com/attachments/mon_202607/28/character-one.png"
        )
        XCTAssertTrue(html.contains("padding:0em 1em"))
        XCTAssertTrue(html.contains("right:32em;top:1em;position:absolute"))
        XCTAssertTrue(
            html.contains(
                ".\(generatedClass){display:inline-block;width:10.1915em;height:17.2102em;}"
            )
        )
        XCTAssertEqual(try document.select(".nga-fixed-block-canvas br").count, 0)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[style"))
    }

    func testSuppressesStripBreakMarkersInFixedHeaders() throws {
        let html = parser.sanitizedPostHTML(
            """
            [randomblock][fixsize height 19.3 width 60 153 background transparent transparent]
            [style width 100% align center extendtop 1 src ./mon_202606/29/background.webp][stripbr][comment // 背景图][stripbr]<br/>
            [/style][stripbr]<br/><br/>
            [style right 7 top 1][stripbr]<br/>
            [style width 33 padding 0 0][stripbr]<br/>
            [style padding 0.5 0.4][url=/read.php?tid=47069214][img]./mon_202606/29/banner.png[/img][/url][stripbr][comment // 活动banner]<br/>
            [/style][stripbr]<br/>
            [/style][stripbr]<br/>
            [/style][stripbr]<br/>
            [/randomblock]
            """
        )
        let document = try SwiftSoup.parse(html)
        let canvas = try XCTUnwrap(document.select(".nga-fixed-block-canvas").first())
        let images = try canvas.select("img")

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(
            try images.first?.attr("src"),
            "https://img.nga.178.com/attachments/mon_202606/29/background.webp"
        )
        XCTAssertEqual(
            try images.last?.attr("src"),
            "https://img.nga.178.com/attachments/mon_202606/29/banner.png"
        )
        XCTAssertEqual(try canvas.select("br").count, 0)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[stripbr]"))
    }

    func testRendersControlsForConsecutiveRandomFixedHeaderAlternatives() throws {
        let source = """
            [randomblock][fixsize height 19.3 width 90 153]
            [style width 100% src ./mon_202607/15/header-one.webp][/style]
            [/randomblock][randomblock][fixsize height 19.3 width 90 153]
            [style width 100% src ./mon_202607/15/header-two.webp][/style]
            [/randomblock][randomblock][fixsize height 19.3 width 90 153]
            [style width 100% src ./mon_202607/15/header-three.webp][/style]
            [/randomblock]
            [b]版头下方正文[/b]
            """
        let html = parser.sanitizedPostHTML(source)
        let document = try SwiftSoup.parse(html)
        let images = try document.select(".nga-fixed-block-canvas img")
        let panels = try document.select(".nga-random-block-panel")
        let buttons = try document.select(".nga-random-block-button")

        XCTAssertEqual(html, parser.sanitizedPostHTML(source))
        XCTAssertEqual(try document.select(".nga-random-block-carousel").count, 1)
        XCTAssertEqual(panels.count, 3)
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(try document.select(".nga-fixed-block").count, 3)
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(
            try document.select(".nga-random-block-panel.snga-is-active").count,
            1
        )
        XCTAssertEqual(
            try document.select(".nga-random-block-button.snga-is-active").count,
            1
        )
        XCTAssertEqual(try buttons.select(#"[aria-pressed="true"]"#).count, 1)
        XCTAssertEqual(try buttons.select(#"[aria-pressed="false"]"#).count, 2)
        XCTAssertEqual(try buttons.first?.attr("aria-label"), "显示版头 1，共 3 个")
        XCTAssertTrue(try document.select("main").text().contains("版头下方正文"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[randomblock]"))
    }

    @MainActor
    func testRandomFixedHeaderControlsSwitchVisiblePanel() throws {
        let html = parser.sanitizedPostHTML(
            """
            [randomblock][fixsize height 10 width 40 80]第一个版头[/randomblock]
            [randomblock][fixsize height 10 width 40 80]第二个版头[/randomblock]
            [randomblock][fixsize height 10 width 40 80]第三个版头[/randomblock]
            """
        )
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: PostWebView.randomBlockCarouselScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loaded = expectation(description: "版头页面完成加载")
        let navigationDelegate = TestWebViewNavigationDelegate {
            loaded.fulfill()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(html, baseURL: NGAEndpoint.baseURL)
        wait(for: [loaded], timeout: 3)

        let switched = expectation(description: "版头切换完成")
        var state: [Int]?
        var evaluationError: Error?
        webView.evaluateJavaScript(
            """
            (() => {
                const buttons = Array.from(document.querySelectorAll('.nga-random-block-button'));
                const previous = buttons.findIndex((button) => button.getAttribute('aria-pressed') === 'true');
                const target = (previous + 1) % buttons.length;
                buttons[target].click();
                const panels = Array.from(document.querySelectorAll('.nga-random-block-panel'));
                return [
                    previous,
                    buttons.findIndex((button) => button.getAttribute('aria-pressed') === 'true'),
                    panels.filter((panel) => panel.classList.contains('snga-is-active')).length,
                    buttons.filter((button) => button.getAttribute('aria-pressed') === 'true').length
                ];
            })()
            """
        ) { result, error in
            state = (result as? [NSNumber])?.map(\.intValue)
            evaluationError = error
            switched.fulfill()
        }
        wait(for: [switched], timeout: 3)

        XCTAssertNil(evaluationError)
        let values = try XCTUnwrap(state)
        XCTAssertNotEqual(values[0], values[1])
        XCTAssertEqual(values[2], 1)
        XCTAssertEqual(values[3], 1)
        withExtendedLifetime(navigationDelegate) {}
    }

    func testRendersResponsiveGameRatingCardWithStructuredMetadata() throws {
        let rating = TopicRating(
            id: TopicID(rawValue: 23_347_410),
            dimensions: [
                TopicRatingDimension(
                    id: "52689",
                    title: "《原神》游戏评分：",
                    ratingCount: 4_787,
                    totalScore: 16_561
                )
            ],
            minimumScore: 1,
            maximumScore: 10,
            endsAt: nil,
            participantCount: 4_784
        )
        let html = parser.sanitizedPostHTML(
            """
            [randomblock][fixsize height 52 width 50 90]
            [style innerHTML &#36;votedata_voteavgvalue][/style]
            [style innerHTML &#36;votedata_usernum][/style]
            [comment game_title_cn]《原神》[/comment game_title_cn]
            [comment game_title]Genshin Impact[/comment game_title]
            [comment game_release][stripbr]
            [style color #fff background #0c7da8]客户端游戏[/style] 2020-09-15
            [stripbr][style color #fff background #0c7da8]Android[/style] 2020-09-28
            [/comment game_release]
            [comment game_title_image][style width 50 src ./mon_202009/15/cover.jpg][/style][/comment game_title_image]
            [comment game_type]动作 角色扮演 养成[/comment game_type]
            [comment game_devloper]米哈游[/comment game_devloper]
            [comment game_publisher]米哈游[/comment game_publisher]
            [comment game_website][url=https://ys.mihoyo.com/main/][/comment game_website]
            [style color #b22222]ys.mihoyo.com/main [symbol link][/style][/url]
            [/randomblock]
            """,
            topicRating: rating
        )
        let document = try SwiftSoup.parse(html)

        XCTAssertEqual(try document.select(".nga-game-card").count, 1)
        XCTAssertEqual(try document.select(".nga-game-score-value").text(), "3.4")
        XCTAssertEqual(try document.select(".nga-game-score-count").text(), "4784 人评分")
        XCTAssertEqual(try document.select(".nga-game-title").text(), "《原神》")
        XCTAssertEqual(try document.select(".nga-game-subtitle").text(), "Genshin Impact")
        XCTAssertEqual(try document.select(".nga-game-release-item").count, 2)
        XCTAssertEqual(try document.select(".nga-game-platform").first?.text(), "客户端游戏")
        XCTAssertEqual(try document.select(".nga-game-field").count, 4)
        XCTAssertEqual(
            try document.select(".nga-game-cover img").attr("src"),
            "https://img.nga.178.com/attachments/mon_202009/15/cover.jpg"
        )
        XCTAssertEqual(
            try document.select(".nga-game-website a").attr("href"),
            "https://ys.mihoyo.com/main/"
        )
        XCTAssertFalse(html.contains("[style"))
        XCTAssertFalse(html.contains("votedata_"))
    }

    func testRendersNGAListItemsAndStandaloneEqualsSeparator() throws {
        let html = parser.sanitizedPostHTML(
            """
            [quote]注意事项<br/>
            ======<br/>
            [list][*]第一项<br/>补充说明<br/>
            [*][b]第二项[/b][/list][/quote]
            正文中的 a======b 不应变成分割线
            """
        )
        let document = try SwiftSoup.parse(html)

        XCTAssertEqual(try document.select("ul").count, 1)
        XCTAssertEqual(try document.select("li").count, 2)
        XCTAssertEqual(try document.select("li").first?.text(), "第一项 补充说明")
        XCTAssertEqual(try document.select("li").last?.text(), "第二项")
        XCTAssertEqual(try document.select("hr").count, 1)
        XCTAssertTrue(try document.body()?.text().contains("a======b") == true)
        XCTAssertFalse(html.contains("[*]"))
    }

    func testRendersNGASectionHeadingAndWeightedTableColumns() throws {
        let html = parser.sanitizedPostHTML(
            """
            ===· 危局详情===<br/>
            (38)[sup]1[/sup]<br/>
            [size=120%][b]增益[/b][/size]<br/>
            [table][tr][td width=4][align=center][b]增益名称[/b][/align]<br/>[/td]<br/>
            [td width=6][align=center][b]增益效果[/b][/align]<br/>[/td]<br/>[/tr]<br/>
            [tr][td]溃亡<br/>[/td]<br/><td>[list][*]失衡值提升[/list]<br/>[/td]<br/>[/tr]<br/>[/table]<br/>
            [size=120%][b]强敌[/b][/size]<br/>
            [table][tr][td width=15]当期强敌<br/>[/td]<br/>
            [td width=8]弱点/抗性<br/>[/td]<br/>
            [td width=17]数值<br/>[/td]<br/>
            [td width=60]敌情详解<br/>[/td]<br/>[/tr]<br/>[/table]
            """
        )
        let document = try SwiftSoup.parse(html)
        let tables = try document.select("table")
        let firstRowCells = try tables.first?.select("tr").first?.select("td")
        let enemyCells = try tables.last?.select("tr").first?.select("td")

        XCTAssertEqual(try document.select("h3.nga-section-title").first?.text(), "· 危局详情")
        XCTAssertFalse(try document.body()?.text().contains("===") == true)
        XCTAssertEqual(try document.select("sup").first?.text(), "1")
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[sup]"))
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(firstRowCells?.count, 2)
        XCTAssertEqual(try firstRowCells?.get(0).attr("width"), "40%")
        XCTAssertEqual(try firstRowCells?.get(1).attr("width"), "60%")
        XCTAssertEqual(enemyCells?.count, 4)
        XCTAssertEqual(try enemyCells?.get(0).attr("width"), "15%")
        XCTAssertEqual(try enemyCells?.get(1).attr("width"), "8%")
        XCTAssertEqual(try enemyCells?.get(2).attr("width"), "17%")
        XCTAssertEqual(try enemyCells?.get(3).attr("width"), "60%")
        XCTAssertEqual(try tables.first?.select("ul li").first?.text(), "失衡值提升")
    }

    func testRendersLegacyPinnedTopicTableResponsively() throws {
        let html = parser.sanitizedPostHTML(
            """
            [table][tr]
            [td colspan=2 rowspan=2 width32]
            [l][b][list][*]版规说明[*]加分申请[/list][/b][/l]
            [/td]
            [td][align=center]
            [img]http://img.ngacn.cc/attachments/mon_201804/26/biQ5-ku98K5ToS5k-23.png[/img]
            [color=silver]早上好，锄宗除外[/color]
            [size=0%]用于消除间距的隐藏文字[/size]
            [url=/thread.php?fid=609][b][size=120%][color=red]&gt; 堡垒之夜 &lt;[/color][/size][/b][/url]
            [l][url=/read.php?tid=13896461][b][color=blue]新手入门教程[/color][/b][/url][/l]
            [r][url=/read.php?tid=13923858][b][color=blue]枪械数据一览[/color][/b][/url][/r]
            [/align][/td]
            [/tr][/table]
            [table][tr][td20]一[/td][td20]二[/td][td20]三[/td][td20]四[/td][td20]五[/td][/tr][/table]
            """
        )
        let document = try SwiftSoup.parse(html)
        let tables = try document.select("main table")
        let pinnedCells = try tables.first?.select("td")
        let weightedCells = try tables.last?.select("td")

        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(pinnedCells?.count, 2)
        XCTAssertEqual(try pinnedCells?.first?.attr("colspan"), "2")
        XCTAssertEqual(try pinnedCells?.first?.attr("rowspan"), "2")
        XCTAssertEqual(try pinnedCells?.first?.attr("width"), "")
        XCTAssertEqual(weightedCells?.count, 5)
        XCTAssertEqual(
            try weightedCells?.map { try $0.attr("width") },
            Array(repeating: "20%", count: 5)
        )
        XCTAssertEqual(try document.select(".ubb-split-row").count, 1)
        XCTAssertEqual(try document.select(".ubb-split-left").text(), "新手入门教程")
        XCTAssertEqual(try document.select(".ubb-split-right").text(), "枪械数据一览")
        XCTAssertEqual(try document.select(".ubb-color-silver").text(), "早上好，锄宗除外")
        XCTAssertEqual(
            try document.select("main img").attr("src"),
            "https://img.nga.178.com/attachments/mon_201804/26/biQ5-ku98K5ToS5k-23.png"
        )
        XCTAssertFalse(try document.body()?.text().contains("用于消除间距的隐藏文字") == true)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[td20]"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[l]"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("[/r]"))
        XCTAssertTrue(html.contains("@media(max-width:700px)"))
    }

    func testLocalizesPostImageContextMenuTitles() {
        XCTAssertEqual(
            PostContextMenuLocalization.localizedTitle("Open Image in New Window"),
            "在新窗口中打开图片"
        )
        XCTAssertEqual(
            PostContextMenuLocalization.localizedTitle("Save Image As…"),
            "图片另存为…"
        )
        XCTAssertEqual(
            PostContextMenuLocalization.localizedTitle("Copy Image"),
            "复制图片"
        )
        XCTAssertEqual(
            PostContextMenuLocalization.localizedTitle("Copy Image Address"),
            "复制图片地址"
        )
        XCTAssertEqual(
            PostContextMenuLocalization.localizedTitle("Search with Google"),
            "使用Google搜索"
        )
    }

    func testReplyEditorEmoticonsUseOfficialUBBCodeAndImagePath() {
        let blink = NGAEmoticon.common.first
        let last = NGAEmoticon.common.last

        XCTAssertEqual(NGAEmoticon.common.count, 45)
        XCTAssertEqual(blink?.code, "[s:ac:blink]")
        XCTAssertEqual(blink?.imageURL?.absoluteString, "https://img4.nga.178.com/ngabbs/post/smile/ac0.png")
        XCTAssertEqual(last?.code, "[s:ac:黑枪]")
        XCTAssertEqual(last?.imageURL?.absoluteString, "https://img4.nga.178.com/ngabbs/post/smile/ac44.png")
    }

    func testRendersReplyHeaderAsClickableFloorReference() {
        let html = parser.sanitizedPostHTML(
            "[pid=876078281,47237166,1]Reply[/pid] **Post by [uid=10268839]hang1052[/uid] (2026-07-22 23:08):**"
        )

        XCTAssertTrue(html.contains("Post by hang1052 (2026-07-22 23:08):"))
        XCTAssertTrue(html.contains("pid=876078281"))
        XCTAssertTrue(html.contains("page=1"))
        XCTAssertTrue(html.contains("nga-post-reference"))
        XCTAssertFalse(html.contains("[pid="))
        XCTAssertFalse(html.contains("[uid="))
        XCTAssertFalse(html.contains("**Post by"))
    }

    func testRendersTopicReplyHeaderAsClickableTopicReference() {
        let html = parser.sanitizedPostHTML(
            "[tid=47239680]Topic[/tid] **Post by 豆豆乐乐 (2026-07-23 11:57)**"
        )

        XCTAssertTrue(html.contains("Post by 豆豆乐乐 (2026-07-23 11:57)"))
        XCTAssertTrue(html.contains("tid=47239680"))
        XCTAssertTrue(html.contains("nga-post-reference"))
        XCTAssertFalse(html.contains("[tid="))
        XCTAssertFalse(html.contains("**Post by"))
    }

    func testParsesVoteResponseAndBuildsSingleWriteEndpoint() throws {
        let xml = """
        <root><data><item>12</item><item>3</item><item>1</item></data></root>
        """
        let state = try parser.voteState(from: response(xml, contentType: "text/xml; charset=utf-8"))
        XCTAssertEqual(state, PostVoteState(upvoteCount: 12, downvoteCount: 3, userVote: .up))

        let endpoint = NGAEndpoint.vote(
            topicID: TopicID(rawValue: 47237166),
            postID: PostID(rawValue: 876078281),
            direction: .down
        )
        XCTAssertEqual(endpoint.path, "/nuke.php")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertTrue(endpoint.isWrite)
        XCTAssertEqual(endpoint.userAgentOverride, "NGA_WP_JW/(;WINDOWS)")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "__lib" })?.value, "topic_recommend")
        XCTAssertEqual(endpoint.queryItems.first(where: { $0.name == "lite" })?.value, "xml")
        XCTAssertEqual(endpoint.form["tid"], "47237166")
        XCTAssertEqual(endpoint.form["pid"], "876078281")
        XCTAssertEqual(endpoint.form["value"], "0")
    }

    func testParsesCurrentPrivateMessagesAndNotifications() throws {
        let privateMessages = response("""
        {
          "data": {
            "0": {
              "0": {
                "mid": "42",
                "subject": "测试私信",
                "from": "100",
                "from_username": "Alice",
                "time": "1700000000",
                "last_modify": "1700000100",
                "posts": "3",
                "bit": "1",
                "all_user": "100\\tAlice\\t200\\tBob"
              }
            },
            "nextPage": ""
          }
        }
        """)
        let inbox = try parser.messages(from: privateMessages, folder: .privateMessages, page: 1)
        XCTAssertEqual(inbox.messages.first?.id, MessageID(rawValue: 42))
        XCTAssertEqual(inbox.messages.first?.sender, "Alice")
        XCTAssertEqual(inbox.messages.first?.preview, "共 3 条消息")
        XCTAssertEqual(inbox.messages.first?.isUnread, true)

        let notifications = response("""
        {
          "data": {
            "0": {
              "0": [
                {"0":"1","1":"90","2":"Carol","5":"有人回复了你","6":"100","7":"190","8":"191","9":"1700000100","10":"1"},
                {"0":"4","1":"95","2":"Dave","5":"你的回复收到了评价","6":"102","7":"195","8":"196","9":"1700000150","10":"1"},
                {"0":"7","1":"100","2":"Bob","5":"有人提到了你","6":"101","7":"200","8":"201","9":"1700000200","10":"1"}
              ],
              "1": [
                {"0":"10","1":"100","2":"Alice","5":"新短消息","9":"1700000300","10":"1"}
              ],
              "unread": "2"
            }
          }
        }
        """)
        let reminders = try parser.messages(from: notifications, folder: .notifications, page: 1)
        XCTAssertEqual(reminders.messages.count, 4)
        XCTAssertEqual(reminders.messages.map(\.kind), [.privateMessage, .mention, .comment, .reply])
        XCTAssertEqual(reminders.messages.first?.subject, "短消息")
        XCTAssertEqual(reminders.messages.first?.preview, "Alice 发来一条短消息")
        XCTAssertEqual(reminders.messages.first?.isUnread, true)
        XCTAssertEqual(reminders.messages[1].sender, "Bob")
        XCTAssertEqual(reminders.messages[1].topicID, TopicID(rawValue: 101))
        XCTAssertEqual(reminders.messages[1].isUnread, true)
        XCTAssertEqual(reminders.messages[2].preview, "Dave 评价了你的回复")
        XCTAssertEqual(reminders.messages.last?.isUnread, false)
        XCTAssertFalse(reminders.hasMore)
    }

    func testParsesShortMessageNotificationWithoutTimestamp() throws {
        let notifications = response("""
        {
          "data": {
            "0": {
              "1": [
                {"0":"10","1":"100","2":"Alice","5":"新短消息"}
              ],
              "unread": "1"
            }
          }
        }
        """)

        let page = try parser.messages(from: notifications, folder: .notifications, page: 1)
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.messages.first?.kind, .privateMessage)
        XCTAssertEqual(page.messages.first?.subject, "短消息")
        XCTAssertEqual(page.messages.first?.preview, "Alice 发来一条短消息")
        XCTAssertEqual(page.messages.first?.isUnread, true)
        XCTAssertNil(page.messages.first?.sentAt)
    }

    func testParsesNotificationsEmbeddedInCurrentScriptPayload() throws {
        let notifications = response(
            #"{"data":["__NOTI__{0:[{0:1,1:90,2:\"Carol\",5:\"有人回复了你\",6:100,7:190,8:191,9:1700000100,10:1}],\"unread\":1,\"lasttime\":1700000200}"]}"#
        )

        let page = try parser.messages(
            from: notifications,
            folder: .notifications,
            page: 1
        )

        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.messages.first?.kind, .reply)
        XCTAssertEqual(page.messages.first?.sender, "Carol")
        XCTAssertEqual(page.messages.first?.subject, "有人回复了你")
        XCTAssertEqual(page.messages.first?.topicID, TopicID(rawValue: 100))
        XCTAssertEqual(page.messages.first?.isUnread, true)
    }

    func testParsesShortMessageDetailsWithAuthorAndTimePerPost() throws {
        let details = response("""
        {
          "data": {
            "0": {
              "allmsgs": {
                "0": {
                  "id": "501",
                  "from": "100",
                  "subject": "测试会话",
                  "content": "第一条消息",
                  "time": "1700000000"
                },
                "1": {
                  "id": "502",
                  "from": "200",
                  "subject": "测试会话",
                  "content": "第二条消息",
                  "time": "1700000300"
                }
              },
              "userInfo": {
                "100": {
                  "uid": "100",
                  "username": "Alice",
                  "avatar": "https://img.example/alice.png"
                },
                "200": {
                  "uid": "200",
                  "username": "Bob"
                }
              }
            }
          }
        }
        """)

        let message = try parser.message(
            from: details,
            id: MessageID(rawValue: 42)
        )

        XCTAssertEqual(message.subject, "测试会话")
        XCTAssertEqual(message.posts.map(\.id), [
            MessageID(rawValue: 501),
            MessageID(rawValue: 502)
        ])
        XCTAssertEqual(message.posts.map(\.author), ["Alice", "Bob"])
        XCTAssertEqual(message.posts.map(\.authorUID), [100, 200])
        XCTAssertEqual(
            message.posts.map(\.sentAt),
            [
                Date(timeIntervalSince1970: 1_700_000_000),
                Date(timeIntervalSince1970: 1_700_000_300)
            ]
        )
        XCTAssertEqual(message.sentAt, Date(timeIntervalSince1970: 1_700_000_300))
    }

    func testVisitorPermissionErrorDoesNotMeanWholeSessionExpired() {
        let payload = #"{"error":["访客没有权限使用当前功能"],"time":1784864152}"#

        XCTAssertThrowsError(
            try parser.messages(
                from: response(payload),
                folder: .privateMessages,
                page: 1
            )
        ) { error in
            guard case let NGAServiceError.restricted(message) = error else {
                return XCTFail("访客权限错误不应被识别为登录失效：\(error)")
            }
            XCTAssertTrue(message.contains("访客"))
        }
    }

    func testMessageEndpointsUseCurrentRoutes() {
        let inbox = NGAEndpoint.messages(folder: .privateMessages, page: 1)
        XCTAssertEqual(inbox.method, .post)
        XCTAssertEqual(inbox.queryItems.first(where: { $0.name == "__lib" })?.value, "message")
        XCTAssertEqual(inbox.queryItems.first(where: { $0.name == "act" })?.value, "list")

        let reminders = NGAEndpoint.messages(folder: .notifications, page: 1)
        XCTAssertEqual(reminders.queryItems.first(where: { $0.name == "__act" })?.value, "get_all")

        let detail = NGAEndpoint.message(id: MessageID(rawValue: 42))
        XCTAssertEqual(detail.queryItems.first(where: { $0.name == "act" })?.value, "read")
        XCTAssertEqual(detail.queryItems.first(where: { $0.name == "mid" })?.value, "42")
        XCTAssertEqual(detail.queryItems.first(where: { $0.name == "page" })?.value, "1")
    }

    func testParsesSubmissionFormAndCheckInResult() throws {
        let html = """
        <form action="/post.php?action=reply&amp;tid=1">
          <input type="hidden" name="auth" value="token">
          <input type="hidden" name="step" value="2">
          <textarea name="post_content"></textarea>
        </form>
        """
        let form = try parser.form(from: response(html, contentType: "text/html"), requiredField: "post_content")
        XCTAssertEqual(form.action.path, "/post.php")
        XCTAssertEqual(form.fields["auth"], "token")

        let structuredReply = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
          <content></content>
          <auth>reply-token</auth>
          <attach_url>/nuke.php?__lib=upload</attach_url>
        </root>
        """
        let replyResponse = NGAHTTPResponse(
            data: Data(structuredReply.utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            url: URL(string: "https://bbs.nga.cn/post.php?action=reply&tid=1&lite=xml")!
        )
        let structuredForm = try parser.form(from: replyResponse, requiredField: "post_content")
        XCTAssertEqual(structuredForm.action, replyResponse.url)
        XCTAssertEqual(structuredForm.fields["auth"], "reply-token")

        let submissionResult = try parser.submissionSucceeded(from: response(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <root><__MESSAGE><item>0</item><item>发帖完毕</item><item>200</item></__MESSAGE></root>
            """,
            contentType: "application/xml; charset=utf-8"
        ))
        XCTAssertNil(submissionResult)

        let success = try parser.checkIn(from: response(#"{"data":"签到成功，获得声望"}"#))
        guard case let .success(message) = success else {
            return XCTFail("应识别为签到成功")
        }
        XCTAssertTrue(message.contains("签到成功"))

        let emptySuccess = try parser.checkIn(from: response(#"{"data":null,"time":1700000000}"#))
        guard case .success = emptySuccess else {
            return XCTFail("无文案但没有错误的结构化响应应识别为签到成功")
        }

        let alreadyCheckedIn = try parser.checkIn(from: response(#"{"error":{"0":"今天已经签到"},"data":null}"#))
        guard case .alreadyCheckedIn = alreadyCheckedIn else {
            return XCTFail("应识别 NGA 的重复签到提示")
        }

        let serverMessage = #"{"error":{"0":"你今天已经签到了（以当前服务器时间 2026-07-24 09:23:50计算）"},"time":1784856230}"#
        let rawEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let encodedMessage = try XCTUnwrap(
            serverMessage.data(using: String.Encoding(rawValue: rawEncoding))
        )
        let encodedResult = try parser.checkIn(from: NGAHTTPResponse(
            data: encodedMessage,
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=gb18030"],
            url: NGAEndpoint.baseURL
        ))
        guard case let .alreadyCheckedIn(message) = encodedResult else {
            return XCTFail("应识别非 UTF-8 编码的重复签到响应")
        }
        XCTAssertEqual(message, "今日已签到（服务器时间 2026-07-24 09:23:50）")

        XCTAssertThrowsError(try parser.checkIn(from: response(
            #"{"error":{"0":"CLIENT ERROR"},"data":null}"#
        ))) { error in
            XCTAssertEqual(error.localizedDescription, "签到请求被 NGA 拒绝，请稍后重试")
        }

        XCTAssertEqual(
            NGAEndpoint.checkIn.queryItems.first(where: { $0.name == "__output" })?.value,
            "8"
        )
        XCTAssertEqual(
            NGAEndpoint.checkIn.queryItems.first(where: { $0.name == "__inchst" })?.value,
            "UTF8"
        )
        XCTAssertEqual(NGAEndpoint.checkIn.referer, NGAEndpoint.baseURL)
    }

    private func response(_ text: String, contentType: String = "application/json; charset=utf-8") -> NGAHTTPResponse {
        NGAHTTPResponse(
            data: Data(text.utf8),
            statusCode: 200,
            headers: ["Content-Type": contentType],
            url: URL(string: "https://bbs.nga.cn/")!
        )
    }
}

private final class TestWebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish()
    }
}
