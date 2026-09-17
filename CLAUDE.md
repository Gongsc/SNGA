# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SNGA 是 macOS 26 的原生 SwiftUI 论坛客户端（Swift 6，严格并发），同时支持 NGA、NodeSeek 和 V2EX 三个站点。仓库内文档、代码注释用中文，commit message 用英文。

## 常用命令

构建（Debug）：

```bash
xcodebuild -project SNGA.xcodeproj -scheme SNGA -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

跑全部测试（单元 + UI，`SNGA` scheme 两个 target 都在）。**凡是会跑到 UI 测试的命令，签名参数换成 ad-hoc，不能用 `CODE_SIGNING_ALLOWED=NO`**，原因见下面那条：

```bash
xcodebuild -project SNGA.xcodeproj -scheme SNGA -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="--timestamp=none" test
```

**macOS 27 起，UI 测试不能再用 `CODE_SIGNING_ALLOWED=NO`。** 那个开关是把 codesign 这一步整个跳过，`.app` 里只剩链接器生成的 ad-hoc 签名、没有 `_CodeSignature` 封签（`codesign --verify` 报「code has no resources but signature indicates they must be present」）。macOS 26 还容得下，macOS 27 会在握手之前就把测试运行器 SIGKILL 掉，报「Early unexpected exit, operation never finished bootstrapping — Test crashed with signal kill before establishing connection」，一条用例都跑不到。上面那组参数是真的走一遍 ad-hoc 签名（身份就是一个减号），**不碰钥匙串、不弹密码框**，和 `release.yml` 里归档用的是同一组。构建和只跑单元测试仍可以用 `CODE_SIGNING_ALLOWED=NO`。

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
- **能力位一条条写，别写 `.all`**。`.all` 的含义是「以后新加的任何一位我都支持」，而新加一位的时候适配器多半还没写。NGA 栽过一次：`.userBlocking` 一进 `.all`，它的用户中心立刻画出一个屏蔽按钮，点下去才答「NGA 没有站点黑名单」—— 正是「不支持就不画」要拦的那种事。`.all` 现在只给 `DebugForumService` 用。
- **`ForumSiteDescriptor`**（[SNGA/Network/ForumSiteDescriptor.swift](SNGA/Network/ForumSiteDescriptor.swift)）—— 站点的**静态资料与措辞**：baseURL、登录方式、cookie 域、会话 cookie 名、用户编号从哪读、UA 策略、回复用 UBB / Markdown / 纯文本、搜索有哪几档、楼层签名从哪儿取、资料页显示哪些字段（各站叫法不同，NodeSeek 管货币叫「鸡腿」不叫「N 币」，V2EX 管版面叫「节点」）。视图通过 `@Environment(\.forumSiteDescriptor)` 拿，因为正文渲染链路太深，逐层传参会改一整条签名链。
- **`ForumSite`**（[SNGA/Models/ForumSite.swift](SNGA/Models/ForumSite.swift)）—— 枚举。刻意不给 `default` 分支：加站点时编译器会把每一处要补的 `switch` 指出来。

一个站点的实现是三个文件：`XxxEndpoint`（拼地址）+ `XxxParser`（解析，无状态）+ `XxxForumService`（actor，串起来）。网络往返统一走 `HTTPTransport` 协议（[SNGA/Network/HTTPTransport.swift](SNGA/Network/HTTPTransport.swift)），测试注入假实现。

**发送节奏不在各客户端里，在 `RequestScheduler`**（[SNGA/Network/RequestScheduler.swift](SNGA/Network/RequestScheduler.swift)）。三个客户端原先各有一份「相邻两发隔 280–320ms」的节流，节奏是对的，但它只会排队、不会挑人：补作者属地那一下在 V2EX 上排进去 176 发，第 176 发等到 56 秒，而用户此刻点的那一下**排在它们后面**。闸门把三件事一起给了 —— 起飞间隔（各站的数原样搬过来，写在 `ForumSiteDescriptor.requestPacing`）、并发上限（和 `httpMaximumConnectionsPerHost` 对齐，为的是把排序权拿在自己手里而不是留给 `URLSession`）、以及优先级。`ScheduledTransport` 是套在传输外面的装饰器，`AppSession` 每个站点建一个闸门、**账号之间共用**（限流是服务器按 host 算的）。

优先级走 task-local（`RequestPriority.current`），不是逐层传参 —— 从「谁发起的」到「谁在发」中间隔着 store → service → client → transport 四层，沿途绝大多数调用点不关心这件事。**默认是 `.userInitiated`，后台请求自己用 `RequestPriority.inBackground { }` 声明**；反过来省事，但忘了标的地方会悄悄把用户的点击降级。目前标了的有两处：逐楼补作者属地、定时的未读轮询。

站点回 429 / 503 就进冷却（**按主机记**，至少 60 秒，`Retry-After` 更长就听它的 —— 队列和节奏共用，冷却不共用：V2EX 的主题搜索走的是站外的 SoV2EX，它被限流不该让用户连 V2EX 都读不了），冷却期间那一发不出门、就地答一个 429 —— 三个客户端早就认得 429，不必为冷却在三处各写一遍翻译。**403 不算限流**：油猴那边分不出来所以一并算了，我们分得出（NodeSeek 的 `/api/vote/*` 少了签名头就是 403，那是自己的 bug），而闸门按站点共用，把 403 算进去会因为一个账号会话过期把另一个也停掉。

### 状态层

`AppModel`（[SNGA/App/AppModel.swift](SNGA/App/AppModel.swift)）持有 `AppSession` 和九个领域 store：`ForumStore`（浏览）、`ThreadStore`（话题）、`MessageStore`、`FavoriteStore`、`AIProfileStore`、`SearchHistoryStore`（搜过的关键词）、`TopicHistoryStore`（读过的话题）、`ToolboxStore`、`TopicMonitorStore`（新帖监控）。

- `AppSession`（[SNGA/App/AppSession.swift](SNGA/App/AppSession.swift)）是各 store 的唯一依赖：给「当前账号的服务」「出错怎么呈现」「加载指示」三件事。store 不反手持有 `AppModel`；跨领域的事（收藏状态变化要更新话题列表）用闭包在 `AppModel.init` 里对接。
- 错误呈现只有 `AppSession.present(_:)` 一道门。取消（`CancellationError` 和 `URLError.cancelled` 两种形态都要认）在这里拦掉，展示时冠上站名。
- `RequestSlot`（[SNGA/App/RequestSlot.swift](SNGA/App/RequestSlot.swift)）是「最新者胜出」闸门：翻页、切版面、切账号时旧请求先发后至不能覆盖新结果。新起一类异步请求就配一个 slot。
- **切账号时，界面上还挂着上一个站的版面。** 按版面编号触发的 `.task(id:)` 会拿它去问新账号的服务 —— V2EX 收到一个 NGA 的 `-7`，答一张「节点未找到」的正常页面，用户看到「论坛页面结构已变化」。`AppSession.belongsToActiveSite(_:)` 挡在 `ForumStore` 发请求**之前**：`ForumID` 本来就带着站点，判断只是没人做过。新加按 `ForumID` 发的请求，记得也过这一道。
- `TopicHistoryStore`（[SNGA/App/TopicHistoryStore.swift](SNGA/App/TopicHistoryStore.swift)）一张表供着两件事：侧栏的「浏览历史」和列表里「读过的变灰」—— 它们本来就是同一个事实。它也是唯一一个**不重新查库**的 store：默认五百条上限，而写入发生在每次打开话题（用户正等着页面出来），所以内存里留一份列表加一个编号集合，写库只写变动的那一行。
- `TopicMonitorStore`（[SNGA/App/TopicMonitorStore.swift](SNGA/App/TopicMonitorStore.swift)）是**新帖监控**：按正则盯 `rss.nodeseek.com` 那份公开订阅，命中就收录并发一条系统通知。它和小工具一样不吃 `AppSession` —— 订阅是匿名的，**一个 cookie 都不带**（和 SoV2EX 那条同理，单独一个 `TopicMonitorFeed` 而不是在发送函数里判域名）。两条规矩写在 `TopicMonitorPolicy` 里，都不是可选的：**首次检查只记位置不提醒**（订阅一次给二十条，开箱二十条通知的结果是用户把提醒关掉），**水位线只进不退**（请求失败不推进，拿到旧数据也不回拨，否则提醒过的会再提醒一遍）。规则、进度和结果落 `UserDefaults`，所以 UI 测试里要换成 `.uiTestingVolatile` 那一套，别写用户真实的偏好。
- `ToolboxStore` 同样不吃 `AppSession` —— 资讯小工具不认账号也不认论坛，一个账号没有时也能用，它的网络故障不能显示成论坛的错误。

### 正文管线

站点 HTML →（站点自己的清洗：`NGAParser.sanitizedPostHTML` / `MarkdownRenderer`）→ `PostContentBuilder` 尝试转成原生 `PostContent` → 失败就回退 `PostDocument` + `WKWebView`。

`PostContentBuilder`（[SNGA/Network/PostContentBuilder.swift](SNGA/Network/PostContentBuilder.swift)）是**全有或全无**：遇到一个还原不了的节点就返回 nil 整层回退，宁可多回退也不能悄悄丢内容。超过 150 块或引用嵌套超 16 层也回退（实测 2000 块要 6.7 秒布局，主线程追不上）。

`PostDocument.baseStyleSheet` 里 `:root` 那几个 CSS 变量名不能改 —— `ResolvedAppTheme.applying(to:)` 靠字符串替换上主题，改名字主题会静默失效。

### 标识与持久化

`ForumID` 是「站点 + 字符串键」（[SNGA/Models/Identifiers.swift](SNGA/Models/Identifiers.swift)）；`TopicID` / `PostID` / `MessageID` 仍是 `Int64`。NGA 自己的编码约定（子版面加 `s` 前缀、`fid` 还是 `stid`）全在 [SNGA/Network/ForumID+NGA.swift](SNGA/Network/ForumID+NGA.swift) 里，不外泄到通用层。

用户一律按 `Int64` 认。V2EX 的页面地址里是**用户名**（`/member/Livid`），编号只能问 `/api/members/show.json` —— 所以那边看用户动态会多一次翻译请求（结果缓存在 service 里），而正文里的用户链接一概交给浏览器：`internalDestination(for:)` 是同步的，发不了那次请求，猜一个编号比打开浏览器更糟。

SwiftData 的 `FavoriteRecord`、`RecentForumRecord`、`DraftRecord`、`SubforumPreferenceRecord`、`SearchHistoryRecord` 主键都以 `accountIDString` 打头，所以**天然按站点隔离**，不需要给每张表加站点列。存量库靠 `LegacyStoreBackfill` 回填，它必须在任何人按主键查记录**之前**跑（见 `SNGAApp.init`）—— 主键算法换过，没补过的老行查不到会被当新行插进去。`SNGATests/Fixtures/legacy-1.8.2.store` 是用 1.8.2 的模型定义真实生成的库，迁移用例对着它跑。

会话 cookie 按账号存成独立文件（0600，`LocalSessionStore`），不进 SwiftData。AI API Key 同样存成 0600 文件（`LocalAIKeyStore`）。运行日志的脱敏名单从 `ForumSite.allCases` 的 descriptor 推导，加站点自动纳入，别写死。

**不要使用 macOS 钥匙串。** 产品代码和本地命令都不用：它会弹出要求输入登录密码的系统对话框（本地构建每次签名不同，应用访问自己的钥匙串项也会被问），自动化里没人能替它填。密钥一律落成沙盒内的 0600 文件。本地 `xcodebuild` 带 `CODE_SIGNING_ALLOWED=NO`（跑 UI 测试时改成 ad-hoc 签名，见「常用命令」——ad-hoc 同样不碰钥匙串）；不要跑 `security`，也不要用真实身份 `codesign`。CI 同样不用：`release.yml` 里的证书导入和公证已整个删掉，产物固定是 ad-hoc 签名。（`codesign --verify` / `-d` 只读磁盘上的签名，不查身份，可以用。）

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
- **UI 套件 34 条，单次约十分钟（算上构建更久）。跑一次、如实报告、继续干活，不要为一次失败反复重跑。** 确实有偶发失败这一类（中文 `typeText` 打出乱码；或断言「此刻还没加载出来」的用例被更快的加载抢先），但**别拿「偶发」当默认解释** —— 2026-09-15 这一天，套件里当时红着的每一条查到底都是真 bug：标识符被容器盖掉、版本号断言停在 1.9.0、签名那条去 `label` 上找一个只存在于 `value` 的字符串。三条都不是时序，都是写下那天起就没对过，而且在 macOS 27 把测试运行器直接杀掉的那段时间里根本没人看得见。
- **判一条失败是不是偶发，只看一步：同一条单独再跑两三次。** 真偶发会时红时绿；稳定红的就是 bug，接着查，别再重跑。要分「是我改的」还是「本来就这样」，把改动 `checkout HEAD` 原样跑一次 —— 但注意这一招在编译不过的时候用不了（macOS 27 刚升上来那次就是），那种情况下改动范围本身就是判据。查因优先看无障碍树（`XCUIElement.debugDescription` 落到文件里慢慢读），它直接说明元素到底叫什么、值在哪个属性上，比一轮轮加断言快得多。
- **断言一行字用 `value`，不是 `label`。** SwiftUI 的 `Text` 把内容放在 `value` 上，`staticTexts["某某"]` 这种下标匹配的是标识符和 label，永远匹配不上；写成 `.matching(NSPredicate(format: "value CONTAINS %@", …))`，并把范围收在所属元素之内。
- **需要登录态才能摸清的接口，写探针脚本交给用户在浏览器控制台跑**（`Design/probe-nodeseek-*.js`），不要拿凭据自己发请求。探针只打印字段名、类型、条数，绝不打印值。会话凭据不进对话。
- **不往真实论坛发测试回复** —— 那是替用户发内容。写请求的验证靠假传输层断言「取校验字段 → 提交一次 → 确认结果」。
- 匿名请求测不出登录才有的功能。这个坑在 NodeSeek 上踩过两次（先误判「没有站内搜索」，后误判 csrf），结论都写在 [Design/SiteProbe-NodeSeek.md](Design/SiteProbe-NodeSeek.md) 里。所以断言「站点没有某功能」时，判据得比「匿名访问被转走」更硬 —— V2EX「自己没有主题全文搜索」这一条是读站点自己的 `combo.js` 得出的（搜索框只有节点、用户、谷歌、SoV2EX 四档），不是靠那次 302。
- **走第三方服务时，关键词可以出站，会话绝不能。** V2EX 的主题搜索接的是 SoV2EX（它搜索框里的第四档，第三方），走 `V2EXNetworkClient.getThirdParty` —— 一个 cookie 都不带，也不带 Referer 和 Origin。单独开一个方法而不是在发送函数里判域名：判域名是一句可以被后来的人删掉的条件。档位名和搜索框下那句说明都点了 SoV2EX 的名，用的人有权知道关键词发去了哪儿。

### V2EX 的七条（实测，2026-09-08 起）

1. **不校验 UA**，`.fixed("SNGA/1.0 …")` 就够；也没有 Cloudflare 挑战。但**语言要自己钉** —— 不带 `V2EX_LANG=zhcn` 时站点对匿名访客发英文页。
2. **会话过期是 302 到 `/signin`，不是 401。** `URLSession` 跟着跳，拿回来的是一张 200 的登录页；不认这一条，解析器会去登录页上找列表，报出来的是「页面结构已变化」。见 `V2EXNetworkClient.isSignInPage`。
3. **写操作没有接口。** 回复是表单加一个一次性令牌 `once`（`GET /poll_once` 现取，匿名也给）；加减收藏是页面上的一条链接（点了整页跳转），领每日奖励是一颗按钮的 `onclick`。后三样**一律不拼地址**：先取那一页，把链接 / `location.href` 的目标原样读出来再请求它 —— 路径上是名字还是编号、令牌叫什么，全写在里面。**页面上已经有的东西，读它，别重新算一遍。**
4. **「感谢」花掉感谢者 10 个铜币且撤不回来**，所以它不是赞踩，而是带 `cost` 和 `isIrreversible` 的 `PostReaction`，界面先确认再发 —— 和 NodeSeek 的鸡腿同一个道理。
5. **主题页一页 100 层**（NGA 二十几、NodeSeek 十）。任何「按楼层数发一次请求」的功能，代价在这个站上乘十 —— 补作者属地那一下就变成了 176 次请求、56 秒，见 `.postAuthorLocation`。这个站上凡是按楼层数的事，先算一遍一百倍是多少。
6. **只有提醒，没有站内私信。** 能力位因此拆成 `.privateMessages` 和 `.notifications` 两位 —— 侧栏那个「论坛消息」入口两者有其一就画。提醒页只给相对时间，也没有未读状态（打开即已读）。
7. **首页分类（`/?tab=tech`）是聚合版面，不分页，而且会和节点重名**（`?tab=qna` 和 `/go/qna` 是两份列表）。所以它的 `ForumID` 加了 `tab:` 前缀，翻页在服务层被钳成第一页。它底下那第二排节点走 `ForumPage.subforums`，筛选靠 `Topic.sourceForumID`。分类表写死在 `V2EXEndpoint.tabs`。

浏览面全部公开、匿名抓得全，所以夹具是真实响应；收藏 / 提醒 / 每日奖励只在登录后的页面上，一样都没接，能力位也关着。**唯一一处推断是发回复那张表单的字段名**，理由和验法记在 [Design/SiteProbe-V2EX.md](Design/SiteProbe-V2EX.md) 第五节。

**从只读接口推出来的状态会不准，而且不准的时候和一个正常的否定答案长得一模一样。** NodeSeek 的签到榜是标本：会话不被它认时照样答 HTTP 200、照样给整整 50 条榜单和总人数，只是不带 `record` —— 和「你今天还没签到」分不开（2026-09-17 实测）。而那次出问题的会话**不是整个死的**，同一份会话的私信、提醒全是好的，所以「拿另一个会话接口去问一句」也问不出来。这类地方要留一条**自己记下的事实**兜底：签到成功那一刻写下 `AccountRecord.lastCheckInDay`（北京时间日界），亲手发过、亲眼见站点答应的事实比推出来的结论硬，一次读不准的查询翻不动它，隔日自动作废。反过来不成立 —— 记着的日子不是今天，不能据此说「还没签」。

### NodeSeek 的三条传输硬约束（实测）

1. 请求必须带 `WKWebView` 自报的**真实 UA**。写死会和页面 JS 环境（`navigator.userAgentData`、`Sec-CH-UA`）对不上，Cloudflare 无限挑战。
2. 必须带站点的**全部** cookie（登录后有 6 个），只带其中两个会被拒。
3. **别用 curl 验证这个站** —— 同样的请求 curl 被挑战、`URLSession` 通过。
4. 几个「带 page、批量吐公开数据」的接口对非浏览器客户端一律回一句假的 `wrong uid`，`NodeSeekParser.rejectBulkGate` 负责识别并抛错，而不是给一页空数据。

## 界面约束

- **颜色一律走主题**（`@Environment(\.sngaTheme)` 拿 `ResolvedAppTheme`）：卡片和面板底色 `surfaceColor`、磁贴和边栏行 `fillColor` / `hoverFillColor`、描边 `separatorColor`、控件描边 `controlBorderColor`、强调 `accentColor` / `accentSoftColor`、文字 `foregroundColor` / `secondaryForegroundColor` / `tertiaryForegroundColor`。**别拿 `.background.secondary` 这类系统材质当卡片底** —— 应用有六套主题，午夜蓝和 NGA 暖金下它和周围对不上。`.tint` 可以用：`RootView` 已经把环境色设成了主题强调色。错误红、成功绿这种语义色不跟主题走（见 `SettingsView` 的连接状态）。
- **这四处的文字走字体设置**（`@Environment(\.sngaFonts)` 拿 `ResolvedAppFonts`，再按 `.sidebar` / `.topicList` / `.threadContent` / `.postAuthor` 取）：侧栏的行、话题列表的行、楼层正文与楼层号、楼层头上那一栏（作者、级别、声望、发帖时间）。写 `fonts.topicList.caption` 而不是 `.caption` —— 语义档位照旧，只是整段按用户调的字号缩放（`ScopedFontSet` 抄了一张 macOS 的档位点数表，`FontSettingsTests` 对着 AppKit 校它）。**只罩文字，别罩控件**：`.font` 铺在装着输入框和选择器的容器上，会把控件一起缩掉。**套着 `frame(height:)` 的那一栏，框也要跟着算**（`PostAuthorHeaderLayout`）—— 写死的行高会把字裁掉一截，看上去像是根本没生效。网页楼层那一侧走 `PostDocument` 里 `--snga-font-size` / `--snga-font-small` / `--snga-font-family` 三个变量的字符串替换，和主题同一条路 —— 那三条的**整句**都是标记，改一个字符就静默失效。四段之外（设置面板、小工具、消息）不跟着变，是有意的。
- **`.regularMaterial` 只留给真正浮在内容之上的层**：底部动作栏、悬浮胶囊、登录遮罩、下拉面板。它要的是「透出底下的东西」，铺在内容里的块用主题色。
- **主题色的用法有对比度测试**（`SNGATests/ThemeContrastTests.swift`）：新配色或新用法先过它，别只在自己那套主题下看着顺眼。
- **排版尺寸收进视图自己的 `private enum Metrics`**，别散在 `body` 里。同一个东西在两处各写一个数，就会在两个页面上长得不一样 —— `ForumSearchBar` 的注释记着那次：两条本该一样的搜索栏，间距、边距、选择器宽度四处都差着几点。
- **一小组要对齐的表单用 `Grid`**，别拿一列 `LabeledContent` 凑：后者每一行各管各的，标签宽度对不齐，控件会各起各的头。
- **控件给死宽度，别让它贴着内容**。内容一变宽度就跳 —— 档位选择器的标题长短差一倍，贴着内容会让旁边的输入框跟着变形。
- **`.controlSize` 管控件大小，`.font` 管文字大小。** 拿 `.font(.caption)` 罩住整块面板来「让它小一点」，会把里面的输入框和选择器一起缩掉。
- **每个可交互控件配 `accessibilityIdentifier`**，前缀由调用方给（`ForumSearchBar` 的 `identifierPrefix` 就是这么用的）—— UI 测试只认得它。
- **标识符贴在控件本身上，绝不贴在包着若干控件的布局容器上。** `accessibilityIdentifier` 挂在 `VStack` / `HStack` / `Group` 这类布局容器上并不是给容器起名 —— 它会把这个名字发给底下**每一个**元素，而且外层修饰符最后生效，于是孩子们各自的标识符被**全部盖掉**。挂在本身就是一个无障碍元素的东西上（`ScrollView`、`Button`、`TextField`）才是给它自己起名，`settings-detail-<section>` 一直没出事就是因为它贴在 `ScrollView` 上。真要给一整块面板起名，先 `.accessibilityElement(children: .contain)` 声明成容器，再给标识符。这一条踩过三处（浏览历史的面板和行、搜索历史下拉、搜索筛选面板），症状是 UI 测试说「找不到」而界面上明明画着 —— 所以怀疑标识符时先 dump 无障碍树，别改测试。
- **不支持就不画。** 这一条在能力位那一节，界面这边的落法是：站点收不下的控件根本不出现，而不是画出来等用户点了再报错。名字也按站点自己的说法给（`ForumSiteDescriptor` 里那一串 `xxxTitle`）。
- **结果来自站外时要在界面上说出来。** 写在跟着内容走的那一行，别塞进定宽控件的标题里 —— 「主题正文（SoV2EX）」在档位选择器里会截断成「主题正文（SoV2…」，反而谁也看不见。

## 写代码的调子

- 注释写**为什么**，尤其是「为什么不是另一种更显然的写法」：踩过的坑、排除过的解释、实测的数字。仓库里大量注释是这种形态，新代码照着来。commit message 同理，正文用英文散文说清动机与取舍，不是变更清单。
- 站名不进 `ForumServiceError`（错误值会跨账号传递比较），在展示层冠。
- 各站的措辞按站点自己的说法走，别照搬 NGA 的词。
