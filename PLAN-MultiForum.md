# SNGA 多站点支持实施计划（NGA / V2EX / NodeSeek）

## 摘要

- 目标：把 SNGA 从「NGA 客户端」改成「多论坛客户端」，首批接入 V2EX 和 NodeSeek，NGA 的现有行为不退化。
- 路线：先做一轮不加功能的通用化重构并单独发版，再逐站接入适配器；每一站都是一个独立的、可以单独失败的模块。
- 前置：V2EX 和 NodeSeek 的接口形状必须先用真实账号摸清楚，本计划里所有标 ⚠️ 的能力都属于待验证，不能照抄。

## 现状读数

站点接口已经收在一个协议里：`NGAForumService`（29 个方法，[ForumService.swift](SNGA/Network/ForumService.swift)），UI 只通过 `AppSession.activeService` 取实例，不直接发请求。这一步是接多站最贵的部分，已经付过了。

剩下的是通用层里还留着的六类 NGA 假设：

| # | 漏出点 | 位置 |
| --- | --- | --- |
| 1 | `ForumID` 是 `Int64`，子版面靠 `Int64.min + stid` 偏移编码；`queryName`（`fid`/`stid`）被 UI 直接读走 | [Identifiers.swift:17](SNGA/Models/Identifiers.swift:17)、[ForumViews.swift:670](SNGA/Views/ForumViews.swift:670)、[AppModel.swift:688](SNGA/App/AppModel.swift:688) |
| 2 | 账号没有站点维度，主键身份是 `ngaUID` | [PersistenceModels.swift:6](SNGA/Models/PersistenceModels.swift:6)、[DomainModels.swift:31](SNGA/Models/DomainModels.swift:31) |
| 3 | `NGAServiceError` 的文案写死「NGA」 | [ForumService.swift:3](SNGA/Network/ForumService.swift:3) |
| 4 | `NGAEndpoint.baseURL` 被视图当 WebView 的 baseURL 用；站内链接识别只认 NGA 域名 | [PostWebView.swift:397](SNGA/Views/Components/PostWebView.swift:397)、[NGAEndpoint.swift:17](SNGA/Network/NGAEndpoint.swift:17) |
| 5 | 视图里直接 `NGAParser()` 做回复预览 | [ThreadViews.swift:1288](SNGA/Views/ThreadViews.swift:1288) |
| 6 | 功能假设散在 UI：签到卡片、评分、投票、点赞点踩、子版面、收藏夹分组、UBB 工具条与 NGA 表情 | [ForumViews.swift:104](SNGA/Views/ForumViews.swift:104)、[UBBRichEditor.swift](SNGA/Views/Components/UBBRichEditor.swift) 等 |

一个省事的发现：`FavoriteRecord`、`RecentForumRecord`、`DraftRecord`、`SubforumPreferenceRecord` 的主键都以 `accountIDString`（UUID）打头，而 `AccountID` 本来就是一账号一 UUID。因此只要 `AccountRecord` 加上站点字段，这四张表天然按站点隔离，**不需要**再给每张表加一列站点。真正要迁移的只有 `forumID` 那一列的类型。

## 关键设计决定

### 决定 1：站点是账号的属性，不是全局模式

选：`ForumSite` 挂在账号上，「当前账号决定一切」这个既有模型不变。侧栏账号区按站点分组，「添加账号」变成站点选择菜单。

不选：侧栏顶部加站点切换器（Slack workspace 式），每站各有一套收藏、最近访问和消息。

理由：`ForumStore`、`ThreadStore`、`MessageStore`、`FavoriteStore` 现在都以 `activeService` 为唯一入口，前者不需要动这四个 store 的生命周期，后者要给每个 store 再加一层站点维度的缓存与失效。后者只在「长期同时盯两站」时才有额外价值，而那件事切账号也能做。

### 决定 2：`ForumID` 改成「站点 + 字符串键」，`TopicID` / `PostID` / `MessageID` 不动

V2EX 的节点是名字（`swift`、`qna`），NodeSeek 的分类是 slug，`Int64` 装不下。

```swift
struct ForumID: Hashable, Codable, Sendable {
    let site: ForumSite
    let key: String        // NGA: "123" 或子版面 "s123"；V2EX: "swift"
}
```

顺带把 `Int64.min + stid` 这个只有作者知道的编码换成 `s` 前缀。备选方案（把字符串哈希成 Int64）不可逆，还要额外维护一张映射表，不取。

`TopicID` / `PostID` / `MessageID` 保持 `Int64`：V2EX 的 topic/reply、NodeSeek 的 post/comment 都是整数，跨站串号已经由 `AccountID` 隔离。**不动它们是这次成本控制的关键**，改动面从约 40 个文件降到 19 个。

迁移面：97 处 `ForumID(...)` 构造、19 个文件，其中 [NGAParser.swift](SNGA/Network/NGAParser.swift) 一个文件占大头且都是站内改动。SwiftData 需要一次显式迁移：`FavoriteRecord.forumID`、`RecentForumRecord.forumID`、`SubforumPreferenceRecord.parentForumID` 与 `selectedForumIDsRaw` 从 `Int64` 改成 `String`。

### 决定 3：能力集显式声明，UI 按位门控

不要让新适配器抛一堆 `.unsupported` 给用户看 —— 那是「点了才报错」，应该是「不支持就不画」。

```swift
struct ForumCapabilities: OptionSet, Sendable {
    static let checkIn, postVote, topicRating, poll, subforums,
               forumFavorites, topicFavoriteFolders, privateMessages,
               notifications, globalSearch, userActivities,
               ubbEditor, markdownEditor, anonymousPosts: ForumCapabilities
}

protocol ForumService: Sendable {
    var accountID: AccountID { get }
    var site: ForumSite { get }
    var capabilities: ForumCapabilities { get }
    // 其余方法保持现有全集
}
```

协议方法保留全集，`extension ForumService` 为不支持的方法给一份抛 `.unsupported` 的默认实现，适配器只实现自己有的那部分。

### 决定 4：正文管线分成「站点前处理」和「共用后半段」

现状是站点 HTML → SwiftSoup 清洗 → `PostContent`（原生渲染）或回退 `WKWebView`。后半段（段落、图片、链接、`WKWebView` 回退）与站点无关，可以直接共用；要摘出去的是 NGA 专属的前处理：`ubb-color-*` 类名、NGA 表情 URL、`[lessernuke]` 处罚包裹、`PostQuoteExpander` 的引用展开。

`PostTextColor` 的 16 色固定枚举要放宽 —— V2EX 和 NodeSeek 的正文用任意 CSS 颜色，需要加 `.custom(hex)` 或整体改成 hex 字符串。

### 决定 5：登录统一走 WebView 抓 Cookie，传输层留第二实现

- 三站都用 WebView 登录，`LoginWebView` 参数化（登录页 URL、成功判定、要抓的 Cookie 名）。
- **V2EX**：官方 API v2 是只读的，且限流 120 次/小时/token —— 打开一个节点再翻三页帖子就能吃掉十几次，对浏览型客户端太紧。主路径走 Cookie + 网页解析，API v2 只留作以后可选的通知拉取加速。
- **NodeSeek**：站前有 Cloudflare。`URLSessionTransport` 可能拿不到 `cf_clearance`，也可能因 TLS 指纹被拦。这是本次最大的技术风险，阶段 0 必须先验证；退路是给 `HTTPTransport` 加一个 `WebViewTransport` 实现（在隐藏 `WKWebView` 里发请求，天然带上通过 Cloudflare 后的凭据）。协议本身已经够抽象，加实现不影响上层。

## 能力对照表（待阶段 0 校准）

| 能力 | NGA | V2EX | NodeSeek |
| --- | :---: | :---: | :---: |
| 版面 / 节点目录 | ✅ | ✅ | ✅ |
| 子版面 | ✅ | ❌ | ❌ |
| 话题列表分页 | ✅ | ✅ | ✅ |
| 帖子分页 | ✅ | ✅ | ✅ |
| 回复 | ✅ UBB | ✅ Markdown | ✅ Markdown |
| 引用楼层 | ✅ | ⚠️ 靠 @用户 | ✅ |
| 点赞 / 点踩 | ✅ | ⚠️ 只有单向「感谢」 | ✅ |
| 评分 | ✅ | ❌ | ❌ |
| 投票 | ✅ | ❌ | ⚠️ |
| 收藏版面 | ✅ | ✅ | ⚠️ |
| 收藏话题 | ✅ 带文件夹 | ✅ 无文件夹 | ⚠️ |
| 私信 | ✅ | ❌ | ⚠️ |
| 通知 / 提醒 | ✅ | ✅ | ✅ |
| 每日签到 | ✅ | ✅ 登录奖励 | ⚠️ 鸡腿 |
| 全站搜索 | ✅ | ⚠️ 官方搜索走外部服务 | ⚠️ |
| 匿名楼层 | ✅ | ❌ | ❌ |

标 ⚠️ 的都必须用真实账号验证后才能写进代码。

## 阶段与出口条件

### 阶段 0：摸底（不改产品代码，约 3 天）

- 用真实账号登录 V2EX 和 NodeSeek，抓关键请求：目录、列表、帖子、回复、通知、签到、收藏。
- 验证 NodeSeek 能否用 `URLSession` 直连；不能就先做 `WebViewTransport` 原型。
- 产出脱敏记录 `Design/SiteProbe-V2EX.md`、`Design/SiteProbe-NodeSeek.md`，把上表的 ⚠️ 全部落定。
- 出口：能力对照表定稿，NodeSeek 传输方案有结论。

### 阶段 1：通用化重构（不加功能，约 2 周）

1. `NGAServiceError` → `ForumServiceError`，文案里的站名换成 `site.displayName`。
2. `NGAForumService` → `ForumService`，加 `site` 与 `capabilities`。
3. `ForumSite` 枚举 + `AccountRecord.siteRaw`，`ngaUID` → `siteUserID`；老记录迁移时一律填 `.nga`。
4. `ForumID` 换成站点 + 字符串键，`queryName` / `ngaValue` 从公共 API 撤回 NGA 适配器内部，四张表的列迁移。
5. `NGAEndpoint.baseURL` 与 `NGAInternalLink` 收进 `ForumSiteDescriptor`（baseURL、登录页、Cookie 名、站内链接匹配），视图从 service 拿而不是从类型常量拿。
6. UI 按 `capabilities` 门控：签到卡片、评分、投票、点赞点踩、子版面、收藏夹分组、私信入口、UBB 工具条与表情选择器。
7. `LoginWebView` 参数化。

出口：**应用仍然只支持 NGA**，现有单测与 UI 测试全绿，肉眼回归无差异。单独发 1.9.0。

### 阶段 2：V2EX 适配器（约 2 周）

- `V2EXEndpoint` + `V2EXParser` + `LiveV2EXForumService`：节点目录、节点话题列表、帖子与回复分页、回复提交、通知、收藏节点与话题、每日登录奖励。
- Markdown 回复编辑器：复用现有编辑器骨架，工具条换成 Markdown 版。
- 每个解析入口一份脱敏 HTML 夹具。
- 出口：能登录、浏览、回复、收通知、签到；NGA 与 V2EX 账号并发不串 Cookie。发 2.0.0。

### 阶段 3：NodeSeek 适配器（约 2 周，需要 `WebViewTransport` 则 +1 周）

同阶段 2 的结构；若阶段 0 判定需要，先落地 `WebViewTransport`。

### 阶段 4：多站共存打磨（约 1 周）

- 消息轮询与签到调度按能力跳过不支持的站，系统通知带站点前缀。
- 设置页里按站点分组的选项。
- 侧栏账号分组、站点图标、「添加账号」的站点选择菜单。
- README、版本号，以及「SNGA」这个名字与图标还留不留 —— 单独决定，不阻塞前面任何一步。

## 测试

- 每站一套脱敏夹具，解析器全部走夹具单测，照搬现有 [NGAParserTests.swift](SNGATests/NGAParserTests.swift) 的做法。
- 跨站隔离：NGA 账号与 V2EX 账号并发请求，断言 Cookie 头不互串、`ForumID` 不互认，扩写 [SessionIsolationTests.swift](SNGATests/SessionIsolationTests.swift)。
- SwiftData 迁移：造一份 1.8.2 的库，迁移后收藏、最近访问、草稿、子版面偏好都还在。
- UI 测试：添加两个不同站的账号、切换、各自浏览与回复。

## 风险

| 风险 | 级别 | 应对 |
| --- | --- | --- |
| NodeSeek 的 Cloudflare 拦住 `URLSession` | 高 | 阶段 0 先验证，退路是 `WebViewTransport` |
| `NGAParser.swift` 4844 行，改 `ForumID` 波及面大 | 中 | 只改 ID 类型不动解析逻辑，靠现有 parser 测试兜底，拆小提交 |
| SwiftData 迁移丢用户数据 | 中 | 写迁移测试，迁移前在沙盒里备份旧库 |
| V2EX API v2 限流 120 次/小时 | 中 | 不走 API 主路径 |
| 三站页面结构各自漂移，维护成本 ×3 | 中 | 能力集 + 夹具测试，让「某站坏了」退化成「某站的某个能力暂时不可用」 |
| 应用名与定位 | 低 | 阶段 4 决定，早点想 |

## 边界

- 不做跨站聚合视图（一个列表里混着三站的帖子），站点始终跟着当前账号。
- 不做跨站搜索。
- 三站都仍然不支持发布新话题和上传本地图片，与现状一致。
- 三站的抓取都遵守各自的频率礼节，沿用现有的请求限速。
