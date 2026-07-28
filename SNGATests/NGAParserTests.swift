import CoreFoundation
import Foundation
import SwiftSoup
import XCTest
@testable import SNGA

final class NGAParserTests: XCTestCase {
    private let parser = NGAParser()

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

    func testThreadHTMLEndpointDoesNotRequestStructuredOutput() {
        let endpoint = NGAEndpoint.threadHTML(topicID: TopicID(rawValue: 47239680), page: 3)

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

        XCTAssertTrue(html.contains("nga-rich-card"))
        XCTAssertTrue(html.contains("鸣潮3.5版本剧情评分"))
        XCTAssertTrue(html.contains("https://img.nga.178.com/attachments/mon_202607/09/cover.webp"))
        XCTAssertTrue(html.contains(#"class="ubb-color-teal""#))
        XCTAssertFalse(html.contains("[randomblock]"))
        XCTAssertFalse(html.contains("[fixsize"))
        XCTAssertFalse(html.contains("[style"))
        XCTAssertFalse(html.contains("votedata_voteavgvalue"))
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
