# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SNGA 是 macOS 26 的原生 SwiftUI 论坛客户端（Swift 6，严格并发），同时支持 NGA、NodeSeek 和 V2EX 三个站点。仓库内文档、代码注释用中文，commit message 用英文。

## 常用命令

构建（Debug）：

```bash
xcodebuild -project SNGA.xcodeproj -scheme SNGA -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

跑全部测试（单元 + UI，`SNGA` scheme 两个 target 都在）：

```bash
xcodebuild -project SNGA.xcodeproj -scheme SNGA -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

只跑单元测试 / 单个类 / 单条用例，加 `-only-testing:`：

```bash
xcodebuild -project SNGA.xcodeproj -scheme SNGA -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:SNGATests/NodeSeekParserTests/testParsesEveryTopicOnTheListPage
```

`.build/` 已被 gitignore，惯例是每类任务用一个自己的 `-derivedDataPath .build/XxxDerivedData`。

**改动文件清单必须重新生成工程。** `project.yml`（XcodeGen）是唯一事实来源，`SNGA.xcodeproj/project.pbxproj` 是产物但也提交进仓库。新增、删除、重命名任何源文件或 `SNGATests/Fixtures/` 下的夹具之后：

```bash
xcodegen generate
```

发版由 `.github/workflows/release.yml` 承担：推一个 `1.9.0` 形式的 tag（不带 `v` 前缀，带后缀的按预发布处理）就归档、临时签名（ad-hoc）、建 Release。tag 必须和 `MARKETING_VERSION` 对得上，发布说明直接取 README 里该版本那一节。不需要任何 secret（`GITHUB_TOKEN` 除外），也不公证——用户首次打开要手动放行。CI 不跑测试。

## 架构

### 站点适配层：四件东西各管一段

UI 从不直接发请求，只经过 `AppSession.activeService`。接一个站点要填的东西分在四处，各有分工：

- **`ForumService`**（[SNGA/Network/ForumService.swift](SNGA/Network/ForumService.swift)）—— 站点能做的**动作**，一个协议、24 个 async 方法。每个账号一个实例（actor），自带 cookie，绝不共享 cookie 容器。协议保留全集，`extension` 给部分方法一份抛 `.unsupported` 的默认实现，适配器只写自己有的。
- **`ForumCapabilities`**（[SNGA/Models/ForumCapabilities.swift](SNGA/Models/ForumCapabilities.swift)）—— OptionSet，站点**支不支持**某个功能。原则是「不支持就不画」，而不是画出来等用户点了再报错。只有「没数据也照样会画」的控件需要门控；数据为空时本来就不画的（评分、子版面、收藏夹）不必再问。**门控要挡在调用层，不只是视图层**——版面收藏在启动和切账号时会主动去拉，光藏界面请求照样发。
- **`ForumSiteDescriptor`**（[SNGA/Network/ForumSiteDescriptor.swift](SNGA/Network/ForumSiteDescriptor.swift)）—— 站点的**静态资料与措辞**：baseURL、登录方式、cookie 域、会话 cookie 名、用户编号从哪读、UA 策略、回复用 UBB / Markdown / 纯文本、搜索有哪几档、楼层签名从哪儿取、资料页显示哪些字段（各站叫法不同，NodeSeek 管货币叫「鸡腿」不叫「N 币」，V2EX 管版面叫「节点」）。视图通过 `@Environment(\.forumSiteDescriptor)` 拿，因为正文渲染链路太深，逐层传参会改一整条签名链。
- **`ForumSite`**（[SNGA/Models/ForumSite.swift](SNGA/Models/ForumSite.swift)）—— 枚举。刻意不给 `default` 分支：加站点时编译器会把每一处要补的 `switch` 指出来。

一个站点的实现是三个文件：`XxxEndpoint`（拼地址）+ `XxxParser`（解析，无状态）+ `XxxForumService`（actor，串起来）。网络往返统一走 `HTTPTransport` 协议（[SNGA/Network/HTTPTransport.swift](SNGA/Network/HTTPTransport.swift)），测试注入假实现。

### 状态层

`AppModel`（[SNGA/App/AppModel.swift](SNGA/App/AppModel.swift)）持有 `AppSession` 和七个领域 store：`ForumStore`（浏览）、`ThreadStore`（话题）、`MessageStore`、`FavoriteStore`、`AIProfileStore`、`SearchHistoryStore`（搜过的关键词）、`ToolboxStore`。

- `AppSession`（[SNGA/App/AppSession.swift](SNGA/App/AppSession.swift)）是各 store 的唯一依赖：给「当前账号的服务」「出错怎么呈现」「加载指示」三件事。store 不反手持有 `AppModel`；跨领域的事（收藏状态变化要更新话题列表）用闭包在 `AppModel.init` 里对接。
- 错误呈现只有 `AppSession.present(_:)` 一道门。取消（`CancellationError` 和 `URLError.cancelled` 两种形态都要认）在这里拦掉，展示时冠上站名。
- `RequestSlot`（[SNGA/App/RequestSlot.swift](SNGA/App/RequestSlot.swift)）是「最新者胜出」闸门：翻页、切版面、切账号时旧请求先发后至不能覆盖新结果。新起一类异步请求就配一个 slot。
- **切账号时，界面上还挂着上一个站的版面。** 按版面编号触发的 `.task(id:)` 会拿它去问新账号的服务 —— V2EX 收到一个 NGA 的 `-7`，答一张「节点未找到」的正常页面，用户看到「论坛页面结构已变化」。`AppSession.belongsToActiveSite(_:)` 挡在 `ForumStore` 发请求**之前**：`ForumID` 本来就带着站点，判断只是没人做过。新加按 `ForumID` 发的请求，记得也过这一道。
- `ToolboxStore` 是唯一不吃 `AppSession` 的 store —— 资讯小工具不认账号也不认论坛，一个账号没有时也能用，它的网络故障不能显示成论坛的错误。

### 正文管线

站点 HTML →（站点自己的清洗：`NGAParser.sanitizedPostHTML` / `MarkdownRenderer`）→ `PostContentBuilder` 尝试转成原生 `PostContent` → 失败就回退 `PostDocument` + `WKWebView`。

`PostContentBuilder`（[SNGA/Network/PostContentBuilder.swift](SNGA/Network/PostContentBuilder.swift)）是**全有或全无**：遇到一个还原不了的节点就返回 nil 整层回退，宁可多回退也不能悄悄丢内容。超过 150 块或引用嵌套超 16 层也回退（实测 2000 块要 6.7 秒布局，主线程追不上）。

`PostDocument.baseStyleSheet` 里 `:root` 那几个 CSS 变量名不能改 —— `ResolvedAppTheme.applying(to:)` 靠字符串替换上主题，改名字主题会静默失效。

### 标识与持久化

`ForumID` 是「站点 + 字符串键」（[SNGA/Models/Identifiers.swift](SNGA/Models/Identifiers.swift)）；`TopicID` / `PostID` / `MessageID` 仍是 `Int64`。NGA 自己的编码约定（子版面加 `s` 前缀、`fid` 还是 `stid`）全在 [SNGA/Network/ForumID+NGA.swift](SNGA/Network/ForumID+NGA.swift) 里，不外泄到通用层。

用户一律按 `Int64` 认。V2EX 的页面地址里是**用户名**（`/member/Livid`），编号只能问 `/api/members/show.json` —— 所以那边看用户动态会多一次翻译请求（结果缓存在 service 里），而正文里的用户链接一概交给浏览器：`internalDestination(for:)` 是同步的，发不了那次请求，猜一个编号比打开浏览器更糟。

SwiftData 的 `FavoriteRecord`、`RecentForumRecord`、`DraftRecord`、`SubforumPreferenceRecord`、`SearchHistoryRecord` 主键都以 `accountIDString` 打头，所以**天然按站点隔离**，不需要给每张表加站点列。存量库靠 `LegacyStoreBackfill` 回填，它必须在任何人按主键查记录**之前**跑（见 `SNGAApp.init`）—— 主键算法换过，没补过的老行查不到会被当新行插进去。`SNGATests/Fixtures/legacy-1.8.2.store` 是用 1.8.2 的模型定义真实生成的库，迁移用例对着它跑。

会话 cookie 按账号存成独立文件（0600，`LocalSessionStore`），不进 SwiftData。AI API Key 同样存成 0600 文件（`LocalAIKeyStore`）。运行日志的脱敏名单从 `ForumSite.allCases` 的 descriptor 推导，加站点自动纳入，别写死。

**不要使用 macOS 钥匙串。** 产品代码和本地命令都不用：它会弹出要求输入登录密码的系统对话框（本地构建每次签名不同，应用访问自己的钥匙串项也会被问），自动化里没人能替它填。密钥一律落成沙盒内的 0600 文件。本地 `xcodebuild` 一律带 `CODE_SIGNING_ALLOWED=NO`；不要跑 `security`，也不要用真实身份 `codesign`。CI 同样不用：`release.yml` 里的证书导入和公证已整个删掉，产物固定是 ad-hoc 签名。（`codesign --verify` / `-d` 只读磁盘上的签名，不查身份，可以用。）

## 加一个新站点

1. 给 `ForumSite` 加 case，编译器会列出所有要补的 `switch`（包括 `ForumSiteDescriptor.descriptor`、内链解析、预览清洗、`topicWebURL`、搜索措辞、资料页字段）。
2. 写 `ForumSiteDescriptor.xxx` 静态实例。
3. 写 `XxxEndpoint` + `XxxParser` + `XxxForumService`，在 `AppSession.makeService` 的 `switch` 里补分支（那里直接写着具体类型，是 factory 的分支，不是漏出）。
4. 点亮 `capabilities` 里真验证过的位，并检查是否有主动拉取的调用点需要门控。
5. 每个解析入口配一份脱敏 HTML/JSON 夹具，放 `SNGATests/Fixtures/`，`xcodegen generate`。

## 测试与对线上站点工作

- 全是 XCTest，没有 swift-testing。解析器测试一律**对着真实抓取的脱敏夹具**跑，先有夹具再写解析器；`RecordingHTTPTransport` 用来断言发出去的请求体。
- **方法名不以 `test` 开头的是手动用例**，XCTest 发现不了（如 `NodeSeekLiveTests.manualLive*`、`SNGAUITests.manualOfficialLogin*`）。它们打线上站点或依赖 XCUITest 查不进的 `NSAlert`，慢且会随对方改版而红。怀疑站点改版时才临时把名字改回 `test` 前缀单独跑。环境变量传不进 UI 测试运行器，这是唯一可行的排除方式。
- UI 测试靠 launch arguments 驱动：`--uitesting`（内存库 + `DebugForumService` 假数据）、`--uitesting-seed`（灌种子数据）、`--uitesting-no-folders` / `--uitesting-one-way-vote`（模拟缺能力的站点）等。`DebugForumService` 的 `capabilities` 可注入，用来验「站点缺某个能力时会怎样」而不必等真适配器写出来。
- **UI 套件 27 条、单次约 7 分半（算上构建 8 分钟），大约每 4 次有 1 次偶发失败**（中文 `typeText` 打出乱码；或断言「此刻还没加载出来」的用例被更快的加载抢先）。跑一次、如实报告、继续干活，不要为偶发失败反复重跑。连续同一处失败才值得查，且只做一步判据：把改动 `checkout HEAD` 原样跑一次，分清「是我改的」还是「环境如此」，然后停下来汇报，而不是一轮轮加诊断。
- **需要登录态才能摸清的接口，写探针脚本交给用户在浏览器控制台跑**（`Design/probe-nodeseek-*.js`），不要拿凭据自己发请求。探针只打印字段名、类型、条数，绝不打印值。会话凭据不进对话。
- **不往真实论坛发测试回复** —— 那是替用户发内容。写请求的验证靠假传输层断言「取校验字段 → 提交一次 → 确认结果」。
- 匿名请求测不出登录才有的功能。这个坑在 NodeSeek 上踩过两次（先误判「没有站内搜索」，后误判 csrf），结论都写在 [Design/SiteProbe-NodeSeek.md](Design/SiteProbe-NodeSeek.md) 里。所以断言「站点没有某功能」时，判据得比「匿名访问被转走」更硬 —— V2EX「自己没有主题全文搜索」这一条是读站点自己的 `combo.js` 得出的（搜索框只有节点、用户、谷歌、SoV2EX 四档），不是靠那次 302。
- **走第三方服务时，关键词可以出站，会话绝不能。** V2EX 的主题搜索接的是 SoV2EX（它搜索框里的第四档，第三方），走 `V2EXNetworkClient.getThirdParty` —— 一个 cookie 都不带，也不带 Referer 和 Origin。单独开一个方法而不是在发送函数里判域名：判域名是一句可以被后来的人删掉的条件。档位名和搜索框下那句说明都点了 SoV2EX 的名，用的人有权知道关键词发去了哪儿。

### V2EX 的六条（实测，2026-09-08）

1. **不校验 UA**，`.fixed("SNGA/1.0 …")` 就够；也没有 Cloudflare 挑战。但**语言要自己钉** —— 不带 `V2EX_LANG=zhcn` 时站点对匿名访客发英文页。
2. **会话过期是 302 到 `/signin`，不是 401。** `URLSession` 跟着跳，拿回来的是一张 200 的登录页；不认这一条，解析器会去登录页上找列表，报出来的是「页面结构已变化」。见 `V2EXNetworkClient.isSignInPage`。
3. **写操作没有接口。** 回复是表单加一个一次性令牌 `once`（`GET /poll_once` 现取，匿名也给）；加减节点收藏干脆就是页面上的一条链接，点了整页跳转。后者**不拼地址**：先取那一页把链接原样读出来再请求它 —— 路径上是名字还是编号、令牌叫什么，全写在链接里。页面上已经有的东西，读它，别重新算一遍。
4. **「感谢」花掉感谢者 10 个铜币且撤不回来**，所以它不是赞踩，而是带 `cost` 和 `isIrreversible` 的 `PostReaction`，界面先确认再发 —— 和 NodeSeek 的鸡腿同一个道理。
5. **主题页一页 100 层**（NGA 二十几、NodeSeek 十）。任何「按楼层数发一次请求」的功能，代价在这个站上乘十 —— 补作者属地那一下就变成了 176 次请求、56 秒，见 `.postAuthorLocation`。这个站上凡是按楼层数的事，先算一遍一百倍是多少。
6. **首页分类（`/?tab=tech`）是聚合版面，不分页，而且会和节点重名**（`?tab=qna` 和 `/go/qna` 是两份列表）。所以它的 `ForumID` 加了 `tab:` 前缀，翻页在服务层被钳成第一页。它底下那第二排节点走 `ForumPage.subforums`，筛选靠 `Topic.sourceForumID`。分类表写死在 `V2EXEndpoint.tabs`。

浏览面全部公开、匿名抓得全，所以夹具是真实响应；收藏 / 提醒 / 每日奖励只在登录后的页面上，一样都没接，能力位也关着。**唯一一处推断是发回复那张表单的字段名**，理由和验法记在 [Design/SiteProbe-V2EX.md](Design/SiteProbe-V2EX.md) 第五节。

### NodeSeek 的三条传输硬约束（实测）

1. 请求必须带 `WKWebView` 自报的**真实 UA**。写死会和页面 JS 环境（`navigator.userAgentData`、`Sec-CH-UA`）对不上，Cloudflare 无限挑战。
2. 必须带站点的**全部** cookie（登录后有 6 个），只带其中两个会被拒。
3. **别用 curl 验证这个站** —— 同样的请求 curl 被挑战、`URLSession` 通过。
4. 几个「带 page、批量吐公开数据」的接口对非浏览器客户端一律回一句假的 `wrong uid`，`NodeSeekParser.rejectBulkGate` 负责识别并抛错，而不是给一页空数据。

## 界面约束

- **颜色一律走主题**（`@Environment(\.sngaTheme)` 拿 `ResolvedAppTheme`）：卡片和面板底色 `surfaceColor`、磁贴和边栏行 `fillColor` / `hoverFillColor`、描边 `separatorColor`、控件描边 `controlBorderColor`、强调 `accentColor` / `accentSoftColor`、文字 `foregroundColor` / `secondaryForegroundColor` / `tertiaryForegroundColor`。**别拿 `.background.secondary` 这类系统材质当卡片底** —— 应用有六套主题，午夜蓝和 NGA 暖金下它和周围对不上。`.tint` 可以用：`RootView` 已经把环境色设成了主题强调色。错误红、成功绿这种语义色不跟主题走（见 `SettingsView` 的连接状态）。
- **`.regularMaterial` 只留给真正浮在内容之上的层**：底部动作栏、悬浮胶囊、登录遮罩、下拉面板。它要的是「透出底下的东西」，铺在内容里的块用主题色。
- **主题色的用法有对比度测试**（`SNGATests/ThemeContrastTests.swift`）：新配色或新用法先过它，别只在自己那套主题下看着顺眼。
- **排版尺寸收进视图自己的 `private enum Metrics`**，别散在 `body` 里。同一个东西在两处各写一个数，就会在两个页面上长得不一样 —— `ForumSearchBar` 的注释记着那次：两条本该一样的搜索栏，间距、边距、选择器宽度四处都差着几点。
- **一小组要对齐的表单用 `Grid`**，别拿一列 `LabeledContent` 凑：后者每一行各管各的，标签宽度对不齐，控件会各起各的头。
- **控件给死宽度，别让它贴着内容**。内容一变宽度就跳 —— 档位选择器的标题长短差一倍，贴着内容会让旁边的输入框跟着变形。
- **`.controlSize` 管控件大小，`.font` 管文字大小。** 拿 `.font(.caption)` 罩住整块面板来「让它小一点」，会把里面的输入框和选择器一起缩掉。
- **每个可交互控件配 `accessibilityIdentifier`**，前缀由调用方给（`ForumSearchBar` 的 `identifierPrefix` 就是这么用的）—— UI 测试只认得它。
- **不支持就不画。** 这一条在能力位那一节，界面这边的落法是：站点收不下的控件根本不出现，而不是画出来等用户点了再报错。名字也按站点自己的说法给（`ForumSiteDescriptor` 里那一串 `xxxTitle`）。
- **结果来自站外时要在界面上说出来。** 写在跟着内容走的那一行，别塞进定宽控件的标题里 —— 「主题正文（SoV2EX）」在档位选择器里会截断成「主题正文（SoV2…」，反而谁也看不见。

## 写代码的调子

- 注释写**为什么**，尤其是「为什么不是另一种更显然的写法」：踩过的坑、排除过的解释、实测的数字。仓库里大量注释是这种形态，新代码照着来。commit message 同理，正文用英文散文说清动机与取舍，不是变更清单。
- 站名不进 `ForumServiceError`（错误值会跨账号传递比较），在展示层冠。
- 各站的措辞按站点自己的说法走，别照搬 NGA 的词。
