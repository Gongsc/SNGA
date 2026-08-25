# 阶段 1 提交序列（通用化重构）

> **已完成。** 19 个提交全部落地，另加 3 个计划外的（登录用例改手动、真库迁移验证、
> 小工具那一组的收尾）。290 单测 + 22 UI 测试通过。执行中与本文不一致的地方记在末尾
> 「实际执行与计划的出入」。

对应 [PLAN-MultiForum.md](PLAN-MultiForum.md) 的阶段 1。基线为 `e766911`，共 19 个提交。

## 三条规则

1. **每个提交都能编译、测试全绿、可以就地停下发版。** 没有「做到一半不能停」的跨提交状态。
2. **不改行为。** 唯一的例外是错误文案的措辞（C2 拿掉站名，C6 又用活的站名补回来）。整组做完时，NGA 声明全部能力，界面应该一处都没变 —— 这就是阶段 1 的验收标准。
3. **先拆依赖，再动核心类型。** `ForumID` 换表示（C11）排在把 NGA 细节从它公开面上摘掉（C9、C10）之后。

## 基线变化

计划写于 `5259bcc`，仓库已前进到 `e766911`，多出一套 AI 摘要功能（+5100 行）。对阶段 1 的影响：

- 协议从 29 个方法变成 30 个（新增 `checkInStatus()`）。
- 多出一个新的跨站碰撞：`AIProfileSummaryRecord.id` 是 `String(uid)`，两个站的同号用户会共用一条画像记录。已补为 C19。
- AI 提示词里写死了「NGA 用户画像分析助手」等字样（`AIProfileModels.swift:22,33`、`OpenAICompatibleClient.swift:706`），一并在 C19 处理。

另外查明：仓库里**没有任何 `VersionedSchema` 或 `SchemaMigrationPlan`**，一直靠 SwiftData 的隐式轻量迁移。C11–C13 的做法就是为了不引入自定义迁移。

---

## 第 T 组 · 小工具独立（已完成，在 C1 之前）

小工具读的是 60s 开放接口，和任何论坛都没关系，所以先把它从论坛领域里摘出来 ——
这样阶段 1 后面那些改动都不会再牵连到它。

### T1 — Move the toolbox models out of the forum domain file

`ToolboxFeed`、`WorldBriefing`、`ToolboxArticle`、`ToolboxContent` 从 `DomainModels.swift`（107 行）
搬到新的 `SNGA/Models/ToolboxModels.swift`。`SettingsSection.toolbox` 与 `SidebarSelection.toolbox`
是导航枚举，留在原处。

### T2 — Extract HTTPTransport into its own file

`HTTPTransport` 与 `URLSessionTransport` 从 `ForumService.swift` 搬到 `SNGA/Network/HTTPTransport.swift`，
小工具不再依赖一个论坛命名的文件。

顺带修掉一个真实的小 bug：`URLSessionTransport` 原本抛 `NGAServiceError.invalidResponse`，
于是小工具自己的网络失败会显示「NGA 返回了无法识别的响应」。现在改抛
`HTTPTransportError.invalidResponse`，由 `NGANetworkClient` 和 `ToolboxAPIService`
各自翻译成自己领域的错误 —— NGA 那边的写入重试判断（`!(lastError is NGAServiceError)`）
因此保持原样。

### T3 — Give the toolbox its own store, independent of the forum session

新增 `SNGA/App/ToolboxStore.swift`。`AppModel` 交出 `selectedToolboxFeed`、
`toolboxRefreshRevision` 和 `refreshToolbox()`，改为持有 `let toolbox = ToolboxStore()` ——
**它是唯一一个不吃 `AppSession` 的 store**，这就是「独立」的落点。

`ToolboxMenuView` 与 `ToolboxFeedView` 从 `@Environment(AppModel.self)` 换成
`@Environment(ToolboxStore.self)`，两个文件里对 `AppModel` 的引用清零。

### T4 — Show the toolbox without a forum account

小工具原本在 `activeAccountID != nil` 的门槛里面，一个账号都没添加时根本点不到 ——
而它压根不需要账号。现在移到边栏一个始终可见的「工具」分组。

新增 UI 用例 `testToolboxIsReachableWithoutAnyAccount`：不带 `--uitesting-seed` 启动，
断言「全部版面」不存在而小工具可用。

### T5 — Move the toolbox tests into their own file

`ToolboxAPIParserTests` 和两个私有 transport 从 `FavoriteAndCheckInTests.swift`
（1088 → 699 行）搬到 `SNGATests/ToolboxTests.swift`。

**验证**：全量 246 个单测 + 23 个 UI 测试通过。

---

## 第 0 组 · 安全网

### C1 — Pin current ForumID and persistence behaviour with characterization tests

新增 `SNGATests/ForumIdentityTests.swift`，钉住 C11–C13 要动的全部不变量：

- `ForumID(rawValue: 414).description == "414"`
- `ForumID(stid: 35_925_536)` 的 `description`、`queryName`、`isSubforum`
- `FavoriteRecord`、`RecentForumRecord`、`SubforumPreferenceRecord` 的存取往返
- `RecentForumRecord.recordID(accountID:forumID:)` 与 `SubforumPreferenceRecord.recordID(...)` 的字符串格式

**为什么先做**：后面每一步走样都会立刻在这里红掉，而不是等到 UI 测试。

---

## 第 1 组 · 改名（纯机械）

### C2 — Rename NGAServiceError to ForumServiceError

83 处、10 个文件。同时把文案里的「NGA」去掉：`"NGA 地址无效"` → `"论坛地址无效"`，依此类推。

**站名不进错误类型。** 错误值要跨账号传递和比较（`SessionIsolationTests` 里有 `==` 断言），带上站点会让每处构造都多一个参数，收益只在文案上。站名由 `AppSession.present` 在展示时补（C6）。

已确认没有任何测试断言错误字符串，风险低。

### C3 — Rename the NGAForumService protocol to ForumService

只改协议名和 8 处 `any NGAForumService`；`LiveNGAForumService`、`DebugForumService` 的 conformance 跟着改。

### C4 — Rename LiveNGAForumService to NGAForumService

实现类改名，与未来的 `V2EXForumService`、`NodeSeekForumService` 对齐。

**单独一个提交**，否则 C3 的 diff 里 `NGAForumService` 前后指两个不同的东西，没法读。触及 `AppSession.makeService` 和 `SessionIsolationTests` 的 4 处构造。

---

## 第 2 组 · 引入站点身份（全部是加法）

### C5 — Add ForumSite and ForumSiteDescriptor with only NGA populated

- 新文件 `SNGA/Models/ForumSite.swift`：`enum ForumSite: String, Codable, CaseIterable { case nga }` + `displayName`
- 新文件 `SNGA/Network/ForumSiteDescriptor.swift`：`baseURL`、`loginURL`、`cookieDomains`、`uidCookieName`、`credentialCookieName`、`internalLink(for:)`

`.nga` 的值从 `NGAEndpoint` 和 `LoginWebView` **搬**过来，不是复制 —— 原处改成引用描述。

只有一个 case 时 `switch` 是穷尽的；加第二个 case 时编译器会替你找出所有要补的分支。这是刻意的。

### C6 — Give ForumService a site and prefix presented errors with it

`protocol ForumService { var site: ForumSite { get } }`，NGA 与 Debug 返回 `.nga`。`AppSession.present`（`AppSession.swift:180`）取 `activeService?.site.displayName` 拼到消息前面。

C2 拿掉的站名到这里还回去，但这次是活的。

### C7 — Add a site column to AccountRecord

`AccountRecord.siteRaw: String = "nga"`（带默认值 → 轻量迁移直接吃下），`AccountSummary.site`。`AppSession.makeService`（`AppSession.swift:69`）改成按 `record.site` 分发的 factory，现在只有一个分支。

**验证**：拿一份 1.8.2 的库启动，账号还在。

### C8 — Rename AccountRecord.ngaUID to siteUserID

用 `@Attribute(originalName: "ngaUID") var siteUserID: Int64` —— SwiftData 认这个，不需要自定义迁移。

34 处、8 个文件，含 `SidebarSelection.userCenter` 和 `AIProfileViews`。`FavoriteAndCheckInTests`、`AIProfileTests` 跟着改。

---

## 第 3 组 · 把 NGA 从 ForumID 的公开面上摘掉

### C9 — Move the subforum flag from ForumID onto Forum

`Forum.isSubforum: Bool = false`，由 `NGAParser` 构造时填。`SidebarView.swift:251`、`ForumViews.swift:1651` 改读 `forum.isSubforum`。

`ForumID.isSubforum` 保留，但从此只有 NGA 适配器内部在用。图标选择是展示逻辑，不该去问 ID 的编码方式。

### C10 — Stop reading queryName outside the NGA adapter

`AppModel.swift:780` 和 `ForumViews.swift:721` 这两处拼的是展示字符串，改成 `forumID.description`，或给 `Forum` 加一个 `sourceLabel`。

之后 `queryName` 与 `ngaValue` 降为 `NGAEndpoint` 的私有细节。

---

## 第 4 组 · ForumID 换表示（最危险的一段）

### C11 — Reshape ForumID into site plus string key, keeping the Int64 on disk

```swift
struct ForumID: Hashable, Codable, Sendable {
    let site: ForumSite
    let key: String          // NGA 普通版面 "414"，子版面 "s35925536"
}
```

- `description == key`
- 桥接：`init(nga rawValue: Int64)` 与 `var ngaRawValue: Int64?`，持久化层继续存 Int64
- 97 处构造、19 个文件，`NGAParser.swift` 占大头

**UI 测试标识符必须逐字不变。** `SNGAUITests` 里有 `favorite-forum--7`、`directory-forum-510381`、`recent-forum-510381`，它们来自 `forum.id.description`。普通版面的 `key` 与旧的 `ngaValue` 完全相同，所以这些标识符不变；UI 测试里没有用到子版面。

### C12 — Store the forum key alongside the legacy Int64 column

`FavoriteRecord`、`RecentForumRecord`、`SubforumPreferenceRecord` 各加 `forumSiteRaw: String = "nga"` 与 `forumKey: String = ""`，都带默认值 → 轻量迁移。写入两边；读取优先 `forumKey`，为空时回落到 Int64。

**不改列的类型。** SwiftData 没有干净的「同名属性改类型」路径 —— 加新列、回填、下个版本删旧列，是标准解法，全程不需要 `MigrationStage`。

### C13 — Backfill forumKey once at launch

启动时把 `forumKey` 为空的行补上，`@AppStorage` 标记跑过就不再跑。幂等、可重入。

旧的 Int64 列从此只剩兼容用途，**下一个版本再删，不属于阶段 1**。

---

## 第 5 组 · 站点描述进视图

### C14 — Thread the site descriptor into PostWebView through the environment

新增 `\.forumSiteDescriptor` 环境值，`RootView` 从 `activeService.site` 注入。替换 `PostWebView.swift` 的 4 处 `NGAEndpoint.baseURL`（96、397、433、659）与 2 处 `NGAInternalLink.destination(for:)`（706、861）。

用 Environment 而不是参数：`PostWebView` 嵌在正文渲染深处，逐层传参会波及 `ThreadPageContentView`、`PostContentView` 一整串签名。

### C15 — Route the reply preview sanitizer through the service

`ThreadViews.swift:1444` 的 `NGAParser().sanitizedPostHTML(content)` 改成 `ForumService.sanitizedPreviewHTML(_:)`，NGA 实现转发给 `NGAParser`。

---

## 第 6 组 · 能力集

### C16 — Add ForumCapabilities with NGA declaring everything

`OptionSet`：`checkIn`、`postVote`、`topicRating`、`poll`、`subforums`、`topicFavoriteFolders`、`privateMessages`、`globalSearch`、`userActivities`、`ubbEditor`、`anonymousPosts`。NGA 与 Debug 都返回全集。无 UI 变化。

### C17 — Gate the always-visible controls on capabilities

**需要显式门控的只有这几处** —— 投票、评分、子版面、收藏夹在数据为空时本来就不画，这次盘查下来能力门控比原计划里说的小得多：

| 位置 | 能力 |
| --- | --- |
| `ForumViews.swift:109` 签到卡片 | `checkIn` |
| `ThreadViews.swift:1158` 楼层点赞点踩 | `postVote` |
| `SidebarView.swift:53` 论坛消息入口 | `privateMessages` |
| UBB 工具条与 `NGAEmoticonPicker` | `ubbEditor` |
| `ForumSearchKind.allCases` 过滤 | `globalSearch` |

**验收**：NGA 声明全集 → 界面一处不变。

---

## 第 7 组 · 登录参数化与 AI 记录补站点

### C18 — Parameterize LoginWebView with the site descriptor

登录页 URL（`LoginWebView.swift:29`）、Cookie 域过滤与 `ngaPassportUid` / `ngaPassportCid` 的名字（`LoginWebView.swift:203–213`）搬进描述。`LoginCapture` 带上 `site`，`AppModel.addAccount` 按 capture 的站点建账号。

「添加账号」按钮仍直接进 NGA 登录；站点选择菜单属于阶段 4。

### C19 — Scope AI profile records by site

- `AIProfileSummaryRecord.id` 从 `String(uid)` 改成 `"\(site.rawValue):\(uid)"`，加 `siteRaw` 列
- 提示词里的「NGA」换成站名（`AIProfileModels.swift:22,33`、`OpenAICompatibleClient.swift:706`、`AIProfileStore.swift:213`、`AIProfileViews.swift:662`）
- 旧记录：画像是可再生的缓存，**直接清空**比回填简单，推荐清空

---

## 依赖与并行

关键路径只有一条：**C1 → C5 → C9、C10 → C11 → C12 → C13**。其余都挂在它旁边。

| 提交 | 阻塞于 |
| --- | --- |
| C2、C3、C4 | 无（随时可做） |
| C5 | C1 |
| C6、C7 | C5 |
| C8 | C7 |
| C9、C10 | C1 |
| C11 | C5、C9、C10 |
| C12 | C11 |
| C13 | C12 |
| C14 | C5 |
| C15 | C3 |
| C16 | C6 |
| C17 | C16 |
| C18 | C5、C7 |
| C19 | C5 |

## 每个提交的验证动作

```sh
xcodebuild -project SNGA.xcodeproj -scheme SNGA -configuration Debug \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

另外在 C7、C8、C12、C13 之后，各用一份 1.8.2 时期的库跑一次真机启动，确认账号、收藏、最近访问、草稿、子版面偏好都还在。

---

## 实际执行与计划的出入

按提交顺序记，只记与本文写法不同的部分。

**C8 —— `@Attribute(originalName:)` 是对的，但差点被误判。**
中途一次批量替换把注解本身也改了（`originalName: "siteUserID"` 指向自己），迁移失败，
我一度以为这个机制对隐式轻量迁移无效。改回正确的列名后一次通过。老库夹具里那条
1.8.2 写的 `ngaUID` 能读成 `siteUserID`，就是它生效的证据。

**C10 —— 差点静默删掉一个有测试保护的功能。**
计划写「改成 `forumID.description`」。实际发现目录搜索把 `queryName` 放进了待匹配文本，
输入「fid 510381」能搜到版面，而且有用例盯着。改成给 `Forum` 加 `searchAliases`，由适配器
盖章，行为一字不差。

**C12 —— 没有按计划改 `recordID`。**
改主键算法会让老行查不到，接着被当成新行插进去，变成重复。挪到 C13，和回填同一趟做。

**C13 —— 因此比计划多做一件事：重写存量行的主键。**
顺带填掉一个阶段 2 的坑：`recordID` 原本回落到 `ngaRawValue ?? 0`，所有 V2EX 版面会撞在 0 上。

**C15 —— 放在描述上而不是服务上。**
计划写 `ForumService.sanitizedPreviewHTML(_:)`。做不到：`ForumService` 是 actor，而调用点在
视图 `body` 里，等不了。改放 `ForumSiteDescriptor`，各站的清洗器本来就是无状态值。
顺带把 `NGAEndpoint.topicWebURL` 一起搬了。

**C17 —— 能力门控比计划里说的小。**
只有五处「没数据也照样画」的控件需要显式门控，其余在数据为空时本来就不画。

**C19 —— 老画像迁移而不是清空。**
计划说画像是可再生缓存，清掉即可。但它是花过 token 生成的，而一次性回填那一趟已经在为
另外三张表做同样的事，加第四张几乎不要钱。`ForumKeyBackfill` 因此更名 `LegacyStoreBackfill`。

**计划外的三个提交：**

- 官方登录页那条 UI 用例改成手动。它弹的对话框是 `NSAlert.beginSheetModal` 挂在
  SwiftUI sheet 上，XCUITest 查不进内部，每次尝试要 76–96 秒超时，整套跑起来像卡死在
  弹窗上，而且没人点掉它。排除方式是把方法名从 `test` 前缀改掉 —— 环境变量传不进
  UI 测试运行器（`SNGA_MANUAL_UI_TESTS=1` 和 `TEST_RUNNER_` 前缀都试过）。
- 真库迁移验证。在 1.8.2 的工作树里用那个版本自己的模型定义生成了一份真实的 `.store`，
  作为夹具提交。此前所有迁移用例都是拿新 schema 建内存库再手动装成老行，验的是回落
  逻辑而不是迁移本身。
- 小工具独立（T1–T5）排在 C1 之前。

## 遗留

- `AppSession.makeService` 里仍然直接写着 `NGAForumService` —— 那正是 factory 的分支，
  加站点时编译器会要求补上，不是漏出。
- 持久化层仍在写 `forumID: Int64` 那一列。**下一个版本可以删掉它**，以及
  `ForumID.ngaRawValue` / `init(ngaStoredValue:)` 和 `LegacyStoreBackfill` 里的回落分支。
- 版本号还是 1.8.2，README 未更新。
