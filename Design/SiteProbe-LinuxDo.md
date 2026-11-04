# Linux.do 接口摸底

> 来源：2026-11-04 匿名摸底。`curl` / `URLSession` 各打了一轮公开端点，外加在应用内置浏览器里
> 正常打开了 `/latest.json` 和 `/site.json`。没有任何账号凭据参与，没有发过写请求。
>
> 同日用户在已登录的浏览器里跑了 `probe-linuxdo-logged-in.js`（只打印字段名和状态码），
> 结果并进了下面各节，标作「实测（登录，浏览器）」。
>
> 每一节标了「实测」还是「推断」。写接口仍全是推断（探针只发 GET）；
> **「`URLSession` 带登录 cookie 能不能过」仍没验**，见第九节第一步。

## 〇、它是什么

Linux.do 是一个 **Discourse** 论坛（站点自带插件：`discourse-mini-app`、话题投票 `votes`、
聊天 `chat`、`has_accepted_answer` 说明装了 solved）。这对接入是好消息：

- **浏览面全是 JSON**。几乎每个页面地址加 `.json` 就是它的数据，`cooked` 字段是服务端渲染好的
  正文 HTML。不用像 NGA / V2EX 那样解析网页。
- **写操作有正经接口**（`POST /posts.json` 等），带 `X-CSRF-Token` 即可，不是 V2EX 那种表单加一次性令牌。
- 难点全在**传输层**：站前有 Cloudflare，而且挡得比 NodeSeek 还狠。

## 一、Cloudflare：话题详情匿名拿不到（实测）

| 端点 | curl（Safari UA） | URLSession（Safari UA） | 内置浏览器 |
| --- | --- | --- | --- |
| `/site.json` | ✅ 200 | — | ✅ 200 |
| `/categories.json` | ❌ 403 挑战 | ✅ 200 | — |
| `/latest.json` | ❌ 403 挑战 | ❌ 403 挑战 | ✅ 200（地址栏直接打开） |
| `/t/{id}.json` | ❌ 403 挑战 | ❌ 403 挑战 | ❌ 页内 `fetch` 403；地址栏打开也停在「请稍候…」 |
| `/u/{name}.json` | ❌ 403 挑战 | ✅ 200 | — |
| `/latest.rss` | — | ✅ 200 | — |

挑战形态和 NodeSeek 一样：`cf-mitigated: challenge` + 一张「Just a moment...」HTML，
响应还带 `accept-ch` / `critical-ch` 要全套 `Sec-CH-UA-*` —— 也就是会拿 UA 和 JS 环境交叉核对，
NodeSeek 那条「必须用 WebView 真实 UA」大概率同样成立。

结论：

1. **话题详情这一族连真浏览器匿名都会被挑战**，所以「匿名能浏览」这条路走不通 —— 这个站在应用里
   必须先登录（登录页在 `WKWebView` 里，用户在那里顺手过掉验证框），然后照 NodeSeek 的做法：
   `.webView` UA + 按域名全收 cookie（含 `cf_clearance`）交给 `URLSession`。
   现成的 `NodeSeekNetworkClient.isChallenge` 和那条「挑战要在看状态码之前判」可以直接照搬。
2. **登录之后，浏览器里同源 `fetch` 一路 200、没有一次挑战**（实测，登录，浏览器）：
   `/t/{id}.json`、`/t/{id}/posts.json`、搜索、通知、私信、用户资料全部通过。
   也就是说挑战规则针对的是匿名访问，带着 `_t` + `cf_clearance` 的会话被放行。
3. **`URLSession` 带同一份会话也过了（实测，2026-11-04，`LinuxDoLiveTests`）。** 用例弹窗由人在
   `WKWebView`（`.nonPersistent()`、不设 UA）里登录，再把这个域下的**全部** cookie 和 WebView 自报的
   UA 交给应用自己的 `URLSessionTransport`：

   | 端点 | 结果 |
   | --- | --- |
   | `/latest.json` | ✅ 200，91751 B |
   | `/t/{id}.json` | ✅ 200，93424 B —— 匿名时这一发必被挑战 |
   | `/t/{id}/posts.json?post_ids[]=…` | ✅ 200，48448 B，20 条给满 |
   | `/session/current.json` | ✅ 200 —— **会话被认出来了**，不只是挑战放行 |
   | `/session/csrf` | ✅ 200 |

   登录后 WebView 里有 11 个 cookie：`_t`、`_forum_session`、`_rt`、`cf_clearance`、`__cf_ob`、
   `_cfuvid`，外加 `g_state`、`_ga*`、`__stripe_*` 这些第三方脚本留下的。照规矩按域名全收，不挑。
   WebView 的 UA 长 88 字符（和 NodeSeek 那条一样，没有 `Version/… Safari/…` 后缀）。

   **结论：照 NodeSeek 的路子接，`WebViewTransport` 不用做。** 没验的只剩时效：`cf_clearance`
   多久过期、过期后 `URLSession` 是不是又回到挑战 —— 那时候走「请重新登录」，和 NodeSeek 一样。
3. 自动化探测到此为止：反复去试哪个端点放行、哪个不放行，本身就是在和对方的防护较劲，
   我没有继续，也不建议在实现里做「被挑战就换个端点绕」这种事。

## 二、版面（实测）

`/site.json` 里 `categories` 共 17 个，`parent_category_id` 给出了两层结构：

- 顶层：开发调优(4)、国产替代(98)、资源荟萃(14)、文档共建(42)、非我莫属(27)、读书成诗(32)、
  前沿快讯(34)、网络记忆(92)、福利羊毛(36)、搞七捻三(11)、虫洞广场(110)、运营反馈(2)
- 子分类：网盘资源(94 ⊂ 14)；公告(49)、悬赏(123)、活动(30)、模板(124) ⊂ 运营反馈(2)

`ForumID` 用分类编号即可（`linuxdo` + `"4"`），子分类走 `ForumPage.subforums`，`.subforums` 可以点亮。
列表地址是 `/c/{slug}/{id}/l/latest.json?page=N`（slug 只是装饰，Discourse 按 id 认，推断）。
站点叫它「类别」，descriptor 里的措辞按这个给。

登录后能看到的类别可能更多（`read_restricted`、信任等级门槛），所以版面表**要在登录后拉**，
不能写死 `site.json` 匿名看到的这 17 个。

## 三、列表（实测）

`/latest.json` 结构：

- `topic_list.topics[]`：30 条一页，`more_topics_url` 给下一页（`?page=1`，从 0 起）。
  字段有 `id`、`title`、`fancy_title`、`posts_count`、`reply_count`、`views`、`like_count`、
  `created_at`、`bumped_at`、`last_posted_at`、`pinned`、`closed`、`archived`、`category_id`、
  `tags`、`excerpt`、`posters[]`（只有 `user_id`）。
- `users[]`：本页出现的用户，`id` + `username` + `avatar_template`（`{size}` 占位）+ `trust_level`。
  **楼主、最后回复人要拿 `posters[].user_id` 去这张表里查**，不在话题对象上。

排序档位：`/latest`（按最后回复）、`?order=created`（按发帖）、`/top.json?period=daily|weekly|…`、
`/hot.json`。`TopicListSortOrder` 前两档直接对得上；「只看精华」可以映射成 `/top`，或者干脆不画。

## 四、用户（实测 + 推断）

Discourse 的用户地址是**用户名**（`/u/neo.json`），而应用一律按 `Int64` 认人 —— 和 V2EX 同一个处境。
好在楼层和列表里都同时给 `user_id` 和 `username`，service 里攒一张「编号 → 用户名」的缓存就够，
不需要像 V2EX 那样额外发一次翻译请求（推断：只有从未见过的编号才会落空，比如外部链接直接跳进来）。

用户动态：`/user_actions.json?username=x&filter=4`（发的话题）/ `filter=5`（回复），按 `offset` 翻页（推断）。

## 五、话题与楼层（实测，登录，浏览器）

Discourse 的话题**不分页**，是一条「流」：

- `/t/{id}.json` 返回前 20 楼（`chunk_size` = 20）的完整内容，外加 `post_stream.stream` ——
  **全部**楼层编号（实测：一个 164 楼的话题，`stream` 164 条、`posts` 20 条）。
- 后面的楼按编号批量取：`/t/{id}/posts.json?post_ids[]=…`，**请求 20 条回 20 条**（实测）。
- 只看某人：`/t/{id}.json?username_filters={name}`（推断）。
- `/t/{id}/print` 和 `/t/{id}.rss` 都是 404（实测），别指望拿它们一次取全。

话题对象 75 个字段（实测），值得注意的几个：

- `valid_reactions` + 每一楼都带 `reactions` 字段（20/20）—— **装了 discourse-reactions**，
  楼层除了赞还有一组表情回应，正好落到 `Post.reactions` / `submitPostReaction` 上（实测，第二轮）：
  - 可选回应 10 种：`heart`、`+1`、`laughing`、`open_mouth`、`clap`、`confetti_ball`、`hugs`、
    `distorted_face`，外加两个站点自定义表情 `tieba_087`、`bili_057`。表情图从 `/emojis.json` 取（200）。
  - 楼层上：`reactions[]` 是 `{id, type, count}`；另有 `current_user_reaction`（没回应时 `null`）、
    `reaction_users_count`、`current_user_used_main_reaction`。
  - **回应和赞过一段时间就撤不回来**：站点文案有「您无法再移除您自己的赞了」「您无法再移除您自己的回应了」。
    所以 `vote` 的撤销会失败，界面要能接住这个失败，别假装撤掉了。
- 楼层上还有几样别的站没有的（实测，第二轮）：`user_signature`（楼层签名）、`accepted_answer` /
  `can_accept_answer`（已解决）、`boosts` / `can_boost`、`event` / `calendar_details`。
  `actions_summary` 里的 10 种动作和 `site.json` 的 `post_action_types` 对得上：2 是赞，其余都是举报类。
- 登录后的列表里出现了匿名 `site.json` 里没有的类别（编号 35），印证了第二节「版面表要登录后拉」。
- **`reply_cost`（数字）就是「回复要花积分」**（实测，第二轮）。站点自己的界面文案写着
  「回复本帖将扣减 %{cost} 积分,确认继续？」。抽了开发调优、搞七捻三、悬赏、福利羊毛、资源荟萃、
  网盘资源、非我莫属等类别的 28 个话题，**全是 0** —— 平常不收，是个别话题由楼主或类别设的。
  所以回复照 V2EX「感谢」那个道理处理：`reply_cost > 0` 时先弹确认、把数写出来再发，等于 0 时照常发。
  它**只在话题详情上有**，列表里没有。提交时要不要多带一个「我已确认」的参数没查到
  （确认逻辑在懒加载的插件代码里，主包只有那句文案）—— 等找到一个非零样本再看网页端发的请求。
- `can_vote` / `vote_count` / `user_voted` —— 话题投票插件，是给**整个话题**投票，不是楼层赞踩。
- `last_read_post_number` —— 站点记着读到哪一楼，可以用来定位「上次读到」。
- 这个话题里 `polls` 字段 0 楼有，样本不够，投票能力位先关。

`ThreadStore` 是按页码工作的，所以适配器要**自己切页**：第一次拿到 `stream` 后缓存在 service 里，
第 N 页就是 `stream[(N-1)*20 ..< N*20]` 那一批编号。页大小建议就取 20，和站点的 chunk 一致，
一页正好一次请求。注意 V2EX 那条教训：任何「按楼层数发请求」的功能先算代价，这里一页 20 楼。

楼层正文是 `cooked`（服务端 Markdown 渲染结果）。要写一个 Discourse 版的清洗再交 `PostContentBuilder`，
至少要认：`aside.quote`（引用，带 `data-username` / `data-post` / `data-topic`）、`.lightbox-wrapper`
（图片外面包了一层灯箱）、`aside.onebox`（链接预览卡片）、`img.emoji`、`a.mention`、`details`、
`.spoiler` / `.spoiled`、代码块、`.poll`。认不了的照规矩整层回退 `WKWebView`，`cooked` 本来就是能直接
渲染的 HTML，回退路径成本很低。

## 六、登录与会话（实测 + 推断）

- 登录方式（`site.json` 的 `auth_providers`，实测）：用户名密码、Google、GitHub、Discord、Apple，外加通行密钥。
  **Google 在 `WKWebView` 里会被拒（`disallowed_useragent`）** —— 这是 Google 的策略，不是这个站的；
  登录页上那颗按钮用户点了会失败，至少要在登录说明里写一句。
- 会话 cookie（实测）：`_t`（登录令牌）+ `_forum_session` + `_rt`，外加 Cloudflare 的 `cf_clearance`
  等，全部 11 个见第一节。照 NodeSeek 的规矩按域名全收，`sessionCookieNames` 写 `_t`。
- 用户编号（实测）：cookie 里没有，**页面里的 `#data-preloaded` 也不带 `currentUser`**，
  所以 `renderedDOM` 那条路不通。只能登录之后问一次 `/session/current.json`（200，`{current_user: …}`）——
  和 NodeSeek「只有一个 `session`，登录后问一次」同一个处理。
- 写请求要的 CSRF：`GET /session/csrf` 200，拿得到 `csrf` 字段（实测）；放进 `X-CSRF-Token` 头是推断。

**另一条路：Discourse 的 User API Key。** Discourse 给原生客户端准备了 `/user-api-key/new`
授权流程（官方移动 App 和 DiscourseHub 就用它）：一次授权换一把按权限范围（read / write /
notifications …）发的密钥，请求头带 `User-Api-Key`，不需要 cookie 和 CSRF，也能撤销。
如果 linux.do 开了它、且 Cloudflare 对带这个头的请求放行，它比搬运网页会话干净得多。
探针结果（实测）：`/user-api-key/new` 不带参数答 **400 + JSON**，不是 404 —— 端点在、只是缺参数；
用户资料里也有 `user_api_keys` 字段。**大概率开着**，但 Cloudflare 对它放不放行、哪些信任等级能申请，
都还没验。现阶段仍按网页会话走（和 NodeSeek 同构、现成代码多），User API Key 留作备选。**Linux.do Connect**（`connect.linux.do`）
是另一回事：那是「用 linux.do 账号登录第三方网站」的 OAuth，只给身份，不给论坛读写，帮不上忙。

### 探针

`Design/probe-linuxdo-logged-in.js`：在已登录的浏览器控制台里整段粘贴运行，只打印状态码、字段名、
类型和条数，不打印任何值，只发 GET。第一轮（2026-11-04）答出来的：

| 问题 | 结果 |
| --- | --- |
| 登录后话题 JSON 被不被挑战 | 不被（浏览器）。`URLSession` 未验 |
| 楼层有没有 `reactions` / `polls` | `reactions` 20/20；`polls` 0/20（样本不够） |
| `posts.json?post_ids[]=` 给不给满 | 20/20 |
| 搜索 | 200，`{posts, topics, users, categories, tags, …}` |
| 通知 | 200，`{notifications, total_rows_notifications, seen_notification_id, load_more_notifications}` |
| 私信 | 200，和话题列表同形（`topic_list` + `users`） |
| 书签 / 用户动态 | 200，但这个账号两样都是空列表，**条目形状没看到** |
| `/user-api-key/new` | 400 + JSON：端点在 |

第二轮（同日，Claude 在用户已登录的 Chrome 里跑，同样只发 GET、只取字段名和类型；
`reply_cost` 的数值和回应名单是站点配置，不涉及个人数据，所以记了值）：

| 问题 | 结果 |
| --- | --- |
| `reply_cost` | 数字；28 个话题全是 0；含义见第五节 |
| 回应 | 10 种，楼层上 `{id, type, count}`，见第五节 |
| 用户动态 | `/user_actions.json?filter=4,5` 查别人 200，条目带 `topic_id`、`post_number`、`title`、`excerpt`、`action_type`、`created_at`、`category_id` |
| 用户摘要 | `/u/{name}/summary.json` 200，有发帖数、获赞数、热门话题、热门类别 |
| 别人的资料 | 70 个字段，**没有任何地区 / 属地字段**；有 `gamification_score`（积分） |
| 通知条目 | `{id, notification_type, read, high_priority, created_at, topic_id, post_number, slug, data{…}}`，`data` 随类型变 |
| 私信列表条目 | 话题字段外多了 `unread`、`new_posts`、`unread_posts`、`participants`、`allowed_user_count` |
| 书签条目 | 这个账号没有书签，**仍没看到** |

## 七、映射到 `ForumService` 与能力位

| 方法 / 能力 | Discourse 端点 | 状态 |
| --- | --- | --- |
| `currentUserID` | `/session/current.json`（DOM 预载里没有） | 实测（登录） |
| `forums` / `.subforums` | `/categories.json?include_subcategories=true` | 实测（匿名） |
| `topics` | `/latest.json`、`/c/{slug}/{id}/l/latest.json`、`?order=created` | 实测（匿名列表） |
| `threadPage` | `/t/{id}.json` + `/t/{id}/posts.json?post_ids[]=`，service 自己切页 | 实测（登录，浏览器）；匿名被挑战 |
| `profile` | `/u/{name}.json`（编号→用户名靠缓存） | 实测（匿名） |
| `userActivities` / `.userActivities` | `/user_actions.json` | 推断 |
| `search` / `.globalSearch` | `/search.json?q=`；匿名 `can_search: false`，登录后 200 | 实测（登录） |
| `submitReply` / `.quotePost` | `POST /posts.json`（`raw` + `topic_id` + `reply_to_post_number`）；引用是 `[quote="名字, post:N, topic:T"]`；`reply_cost > 0` 先确认 | 端点推断；`reply_cost` 含义实测 |
| `vote` / `.postVote` | 点赞 `POST /post_actions`（`post_action_type_id=2`），撤销 `DELETE /post_actions/{postID}`；过了时限撤不回 | 推断；只有赞（实测），**没有踩**，`.postDownvote` 关 |
| `submitPostReaction` | 10 种回应（实测）：`PUT /discourse-reactions/posts/{id}/custom-reactions/{emoji}/toggle` | 端点推断 |
| 楼层签名 | 楼层自带 `user_signature`（实测），descriptor 里的签名来源可以指向它 | 实测 |
| `submitTopicPollVote` / `.poll` | `PUT /polls/vote` | 推断，样本里没见到 `polls` |
| `messages` / `.privateMessages` | `/topics/private-messages/{name}.json`，200，话题列表同形（私信是话题，一来一回是楼层） | 实测（登录） |
| `messages` / `.notifications` | `/notifications.json` 200；已读 `PUT /notifications/mark-read` —— 有服务端未读，`markRead` 要实现 | 列表实测，已读推断 |
| 话题收藏 / `.topicFavorites` | 书签：`/u/{name}/bookmarks.json`、`POST /bookmarks`、`DELETE /bookmarks/{id}`；平铺，`.topicFavoriteFolders` 关 | 推断 |
| 版面收藏 | Discourse 的「关注类别」是通知级别，不是收藏，**不接** | — |
| 签到 / `.checkIn` | 站点没有每日签到（LDC 积分在另一个站） | 关 |
| 屏蔽 / `.userBlocking` | 「忽略」要到期时间，对不上；但资料里有 `muted_usernames` / `can_mute_users`（实测），「静音」不限期，可用 `PUT /u/{name}/notification_level.json`（`mute`）接 —— 只挡通知、不挡内容，语义弱于黑名单 | 先关，待定 |
| `.postAuthorLocation` / `.anonymousPosts` / `.topicRating` | Discourse 没有 | 关 |

回复标记：`ReplyMarkup.markdown`。表情是 `:shortcode:`，可以从 `/emojis.json` 取一份做表情包（推断）。

## 八、节奏与限流

Discourse 自己有一层按 IP / 按用户的限流（默认匿名 10 秒 50 发、登录用户每分钟 200 发量级，具体看站点设置），
超了答 **429 + `Retry-After`** —— 正好是 `RequestScheduler` 冷却已经认得的形态。起步节奏照 NodeSeek 的
`requestPacing` 抄，并发 2 以内。没有「按楼层发请求」的功能（属地关着），所以不会出现 V2EX 那种 176 发。

再加一条：Cloudflare 的挑战**不算限流**，不进冷却，报「需要在浏览器里完成一次人机验证，请重新登录」，
和 NodeSeek 一样。

## 九、建议的推进顺序

1. ~~**先验生死线**~~ **已过**（第一节第 3 条）。原计划是写一个 `LinuxDoLiveTests.manualLive*`（手动用例，不以 `test` 开头），
   在应用里用 WebView 登录拿到的 cookie + 真实 UA，`URLSession` 请求一次 `/t/{id}.json`。
   过不去就先停 —— 那意味着要么走 User API Key，要么整个话题页只能 `WKWebView` 承载，工作量完全是另一个量级。
2. **已做（只读骨架）**：类别、列表、话题（自己切页）、资料（`/user-cards.json` 按编号查，
   不必翻译用户名）、「我是谁」。登录走新加的 `SiteUserIDSource.sessionQuery`。
   夹具 `SNGATests/Fixtures/linuxdo-*.json` 是 2026-11-04 登录后抓的，用户名、用户编号和
   话题标题这类自由文本已替换。原计划：`ForumSite.linuxdo` + descriptor（`.webView` UA、`_t`、`/login`）+ 只读三件套
   （`forums` / `topics` / `threadPage` / `profile`），能力位只点亮 `.subforums`。
3. 正文清洗：对着探针拿到形状后抓真实楼层做夹具，逐个认 `cooked` 里的节点。
4. 写操作和消息：回复、点赞、书签、通知、私信，每样配假传输层断言，**不往真站发测试回复**。

另外，接之前值得看一眼站点的社区准则对第三方客户端的态度 —— 我这次没有查。
