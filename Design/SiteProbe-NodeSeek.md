# NodeSeek 接口摸底

> 来源：阅读 [nodyssey](https://github.com/5151561/nodyssey)（一个 Kotlin Multiplatform 的
> NodeSeek 客户端，GPL-3.0）的源码得出。SNGA 同为 GPL-3.0，许可证兼容；但本文只记录**接口事实**
> ——地址、参数名、响应形状、以及对方项目注释中标注为实测的行为，不复制其实现。
>
> 该项目的注释多处写明"某年某月某日从线上抓取/从站点自身的 JS bundle 读出"。这类条目我在下面标了
> 「实测」。没有标注的按推断对待，接入时仍需自行验证。
>
> **本文没有经过真实账号验证。** 阶段 0 的验收标准是拿真账号跑一遍，这一步仍然欠着。

## 〇、实测结论（2026-08-26，本机验证）

下面这一节是**我自己跑出来的**，不是从 nodyssey 读来的。其余各节仍是转述。

### 站内搜索：没有（2026-08-27 实测）

`/search?q=X` 回 302，去向 `https://www.google.com/search?q=site:www.nodeseek.com&q=X`。
站点自己就是把搜索转交出去的，没有任何接口能把结果取回来。

所以 `.globalSearch` 这一位**不能点亮** —— 最初的能力表按「用户看得见搜索框」记成了「有」，
那是从浏览器角度看的事实，表达不了「我们取不回结果」。

### 有几个接口挡批量抓取，而且它撒谎（2026-08-27 实测）

匿名 `URLSession` 请求这几个接口时，回的是一句像参数写错了的话：

```
{"success":false,"message":"wrong uid"}
```

**这句话是假的。** 判据：把 `page` 故意写成 `abc`，浏览器会如实答 `wrong page`；
被挡的客户端无论传什么都只回 `wrong uid` —— 连 `uid` 整个不传也一样。请求根本没被解析。

| 接口 | 匿名 `URLSession` | 匿名浏览器 |
| --- | --- | --- |
| `/api/content/list-discussions?uid=&page=` | 🚫 万能 `wrong uid` | ✅ 真数据 |
| `/api/content/list-comments?uid=&page=` | 🚫 万能 `wrong uid` | ✅ 真数据 |
| `/api/attendance/board?page=` | 🚫 万能 `wrong page` | ✅ 真数据 |
| `/api/account/getInfo/{uid}` | ✅ 真解析 | ✅ |
| 通知 / 收藏 / 未读数 | ✅ 真解析（未登录答 `USER NOT FOUND`） | 同样 |

被挡的三个都是「带 `page`、批量吐公开数据」的接口，单条记录和会话内的接口不受影响。

排除过的解释：不是跳转丢参数（无跳转）、不是缺 cookie（页面不下发 cookie，带 jar 也一样）、
不是 Referer / `Sec-Fetch-*` / `Accept-Language`（逐项加过）、不是连接指纹
（同一个 `URLSession` 里 `getInfo` 是通的）。

**带完整登录 cookie（含 `cf_clearance`）能不能过，没验过** —— 验它要拿真账号的凭据发请求。
适配器里对这句假答复做了识别（`NodeSeekParser.rejectBulkGate`），被挡时抛错而不是给一页空数据。

### `URLSession` 直连可行，`WebViewTransport` 不用做

用一个 `WKWebView` 登录并过掉验证框，把它的 cookie 和 UA 交给 `URLSession`，四个端点全部 200：

| 端点 | 结果 |
| --- | --- |
| `/api/content/list-categories` | ✅ 200，2725 B |
| `/api/notification/unread-count` | ✅ 200，71 B —— **会话被认出来了**，不是 500 |
| `/api/statistics/list-collection?page=1` | ✅ 200，121 B |
| `/categories/daily`（HTML 列表页） | ✅ 200，85923 B |

**计划里那个「+1 周做 `WebViewTransport`」的退路可以划掉。**

`URLSession` 的配置照抄了 SNGA 的 `URLSessionTransport`：ephemeral、不用共享 Cookie 容器、
Cookie 走显式请求头。WebView 用的也是 `.nonPersistent()`，和 `LoginWebView` 一致。

### 必须把站点的**全部** cookie 都带上

登录后 WebView 里有 6 个：`cf_clearance`、`colorscheme`、`fog`、`pjwt`、`session`、`smac`。

**只带 `session` + `cf_clearance` 会被挑战（403）。** 我先前几轮从外部浏览器只抄这两个，
结果全红，还据此推断成「外部浏览器的 clearance 绑定不上」——**那个推断是错的**，
真实原因就是抄漏了。

SNGA 的登录抓取按**域名**过滤而不是按名字，本来就会把 6 个全收走，所以这条天然满足。
但它同时说明：**不能"挑几个认识的 cookie 存下来"**，那样会坏。

### UA 约束成立，而且形态出乎意料

不设 `applicationNameForUserAgent` 时，`WKWebView` 自报的 UA 长 88 字符，**结尾没有
`Version/x Safari/y`** —— 那截后缀正是 `applicationNameForUserAgent` 拼上去的。

也就是说：**一旦设了它，UA 就和 WebView 的 JS 环境对不上了**。现在的实现（`.fixed` 才设、
`.webView` 一行不设）方向是对的。

### curl 过不去，`URLSession` 过得去

同样的匿名裸请求：curl 被挑战（403 + `cf-mitigated: challenge`），`URLSession` 直接 200。
TLS 指纹确实是因素，而 macOS 的网络栈被接受。**验证这类站点不能用 curl。**

### 未登录时会话端点返回 500

`/api/notification/unread-count` 不带 cookie 时是 HTTP 500，不是 401 —— 印证了 nodyssey
文档里的说法。

## 一、传输层：最大的风险有答案了

计划里把"NodeSeek 能不能用 `URLSession` 直连"列为整个项目的最大技术风险。答案是**能，但有三个硬约束**，
任何一个没满足都会掉进无限挑战。

### 1. User-Agent 必须是 WebView 的真实值

Cloudflare 的 managed challenge 会拿请求头里的 `User-Agent` 去和 JS 环境
（`navigator.userAgentData`、`Sec-CH-UA`）交叉核对。后者由 WebView 按它真实的引擎版本上报，
改不动。**头和 JS 自相矛盾 → 再发一次挑战 → 无限循环。** 对方项目记录这个 bug 真实发生过，
并为此写了回归测试。

更细的一条：调用「设置 UA」这个 API 本身会把 UA 标记为已覆盖并改变客户端提示的上报方式，
**所以把它设成它本来就有的值也不是 no-op**。正确做法是一行都不设，然后从 WebView 里读出来
（`navigator.userAgent`），把这个值用在所有原生 HTTP 请求上。

### 2. Cookie 就是会话，WebView 和 HTTP 客户端必须共用同一份

没有 token 端点，也没有第二份拷贝。`cf_clearance` 也在这份里，原生请求必须带上。

### 3. 挑战中间态 cookie 不能当作会话变化

`cf_chl_*` 是用户正在勾选验证框时的中间态（`cf_clearance` 例外）。把它们当作"会话变了"去触发重新拉取，
等于朝一个进行中的挑战打一串非浏览器流量，**能把一个本来能过的挑战变成过不去的**。

### 挑战的三种形态

判定要在读状态码之前做，因为"请去验证"和"请去登录"是两条不同的恢复路径：

- 响应体是挑战 HTML（JSON 端点返回以 `<` 开头的内容即可判定）
- 响应头 `cf-mitigated: challenge`
- 403 包着上面两者之一

## 二、会话与登录

| 项 | 值 |
| --- | --- |
| BASE_URL | `https://www.nodeseek.com` |
| 会话 Cookie | `session`；部分部署另有 JWT 形态的 `token` |
| **uid Cookie** | **没有** |
| 登录页 | `/signIn.html` |
| 登录接口 | `/api/account/signIn`（凭据与第二因素两段都走它） |
| Turnstile sitekey | `0x4AAAAAAAaNy7leGjewpVyR`（实测 2026-08-24） |
| Turnstile token 请求头 | `x-captcha-token` |

## 三、浏览走 HTML，不走 JSON

**JSON 接口不覆盖浏览。** 列表页和帖子页都是服务端渲染的 HTML，只能解析。JSON 只在统计、通知、
写操作那一圈存在。

| 用途 | 路径 |
| --- | --- |
| 综合（首页） | `/`，翻页 `/page-N` |
| 分类 | `/categories/{slug}`，翻页 `/categories/{slug}/page-N` |
| 按发帖时间排序 | 上述路径加 `?sortBy=postTime`（默认按最后回复，不带参数） |
| 帖子 | `/post-{postId}-{page}`，**每页 10 层** |
| 搜索 | `/search?q=&page=&category=&sortBy=` |
| 用户空间 | `/space/{uid}` |

分类 slug 是固定的 15 个：综合（无 slug）、`daily` 日常、`tech` 技术、`info` 情报、`review` 测评、
`trade` 交易、`carpool` 拼车、`promotion` 推广、`life` 生活、`dev` Dev、`photo-share` 贴图、
`expose` 曝光、`inside` 内版、`meaningless` 无意义、`sandbox` 沙盒。

搜索有两个坑（对方项目标为实测）：**限流 1 次 / 2 秒**，超出返回 429；**翻过尾页返回 0 行但分页条
仍然渲染"下一页"**，所以不能靠分页条判断还有没有下一页。

## 四、JSON 接口清单

### 内容

- `/api/content/list-categories` — 分类目录
- `/api/content/list-discussions?uid=&page=` — 某用户的话题
- `/api/content/list-comments?uid=&page=` — 某用户的回复
- `/api/content/new-comment` — **回复**。`{content, mode:"new-comment", postId}`，
  答 `{success:true, redirect:"/post-841108-1", redirectHash:"#3"}`。
  **楼层号只存在于 `redirectHash` 里**（实测 2026-07-28）
- `/api/content/new-discussion` — 发新话题
- `/api/content/edit-discussion` — `{title, postId, rank, mode:"edit-discussion"}`
- `/api/content/edit-comment` — `{commentId, mode:"edit-comment"}`

### 反应与收藏

- `/api/statistics/{upvote|like|dislike}` — `{commentId, action:"add"}` → `{success, current, coin, message}`
- `/api/statistics/collection` — 收藏话题，`{postId, action:"add"|"remove"}`，可逆
- `/api/statistics/list-collection?page=` — 收藏列表（属于会话，看不了别人的）

### 通知与私信

- `/api/notification/unread-count`
- `/api/notification/{type}/list?page=` — type 为 `at-me`（@我）、`reply-to-me`（回复我）、`message`（私信）
- `/api/notification/{type}/markViewed?all=true` — 全部已读；不带 query 时用 JSON body 逐条标记
- `/api/notification/message/with/{uid}` — 一段完整会话
- `/api/notification/message/send` — **收件人字段是 camelCase 的 `receiverUid`**，
  而这套接口其余字段都是 snake_case（实测 2026-07-26，从站点自身的 `notification.js` 读出）

### 账号与签到

- `/api/account/getInfo/{uid}?readme=1` — 不加 `readme=1` 时响应里没有个人简介
- `/api/account/find/{query}` — 用户搜索
- `/api/attendance?random=true|false` — **签到**。`random=true` 是抽奖式，`false` 是固定 5 个鸡腿
- `/api/attendance/board?page=` — 签到榜，今日是否已签到从这里的 `record` 读
- `/api/progress/today` — 今日各项额度

### 投票

`/api/vote/*` 整族都需要 `x-dynamic-sign` 请求头，**缺了一律 403，连未登录的读取也是**。
值是 `method + "\n\n" + 绝对URL + "\n\n" + UserAgent + "\n\n" + body` 的 SHA-1 十六进制。
对方项目记录：服务端当前只校验该头**存在**，四十个字符的假值也能过；但他们仍然算真的摘要。

- `/api/vote/info/{voteId}` — GET 读、POST（不带 id）创建、DELETE（带 id 且带 body）删除
- `/api/vote/voteforitem` — `{"ids":[13201]}`，单选也是数组
- `/api/vote/lock/{voteId}`、`/api/vote/voter-of-item?id=&page=`

## 五、两个会咬人的地方

### 反应的命名和它的含义对不上

**这是最危险的一条。**

| 接口动作 | 站点上的实际含义 | 代价 |
| --- | --- | --- |
| `upvote` | 投喂（给作者星辰） | **免费** |
| `like` | **加鸡腿** | 花掉读者 1 个鸡腿 |
| `dislike` | **反对** | 花掉读者 2 个鸡腿 |

把点赞图标接到 `like` 上，会在用户以为自己只是点了个赞的时候**悄悄花掉他的货币**。

而且**三种都不可撤销** —— 站点没有提供任何一个的 remove。

### 未登录时返回 500 而不是 401

这几族端点在没有会话时答 500：`/api/notification`、`/api/statistics`、`/api/admin`、
`/api/account/find`。照常识把 500 显示成"服务器错误，请重试"，会把唯一有用的动作（去登录）藏起来。

另外，写端点在非 2xx 上也带有意义的 JSON body —— 重复签到答的是 HTTP 500，而 body 里正是要展示给
用户的那句话。所以写请求不能按状态码直接抛错。

## 六、对 SNGA 现有抽象的冲击

阶段 1 建的那套抽象大体够用，但有 **6 处是照着 NGA 的形状做的**，接 NodeSeek 前得改：

| # | 现状 | 为什么不行 |
| --- | --- | --- |
| 1 | `ForumSiteDescriptor.uidCookieName` / `credentialCookieName` | NodeSeek 只有一个 `session`，**没有 uid cookie**。uid 得另外取 |
| 2 | `AppSession.reloadAccountsAndServices` 按"uid cookie + 凭据 cookie 都在"判断会话完整 | 同上，对 NodeSeek 不成立 |
| 3 | `URLSessionTransport` 写死 `User-Agent: SNGA/1.0 (macOS; native client)` | **对 NodeSeek 是致命的** —— 会触发无限挑战 |
| 4 | `LoginWebView` 设 `applicationNameForUserAgent = "SNGA/1.0"` | 同样致命。而且"设成原值也不是 no-op" |
| 5 | `LoginWebView` 用 `.nonPersistent()` 数据存储 | ~~需要共用 cookie~~ —— **复查后作废，见下** |
| 6 | `PostVoteState.optimisticallyApplying` 假设点赞可撤销、且只有上下两个方向 | NodeSeek 是**三种、都不可撤销、其中两种要花钱** |

第 3、4 条尤其要注意：它们现在对 NGA 是正确的，不能直接删，得改成按站点取值。

### 第 5 条：复查后作废

初读时我把它记成了「WebView 和 HTTP 必须共用一份 cookie 存储」。回头对照 SNGA 的实际做法后，
这条不成立：

- 登录时的抓取按**域名**过滤而不是按名字，`cf_clearance` 本来就会被一起收走
- `NGANetworkClient` 有 `mergeResponseCookies`，响应里换发的 cookie 会被合并并持久化，
  所以 Cloudflare 轮换 `cf_clearance` 也跟得上
- `.nonPersistent()` 指的是不与 Safari 共享，这是想要的行为，不是问题

**真正缺的是另一件事**：会话中途再次出现挑战时，SNGA 没有把用户送回 WebView 去解一次的路径。
那是 NodeSeek 适配器要做的事，不是抽象层的缺陷。

### 第 6 条：留到写适配器时再定

NGA 是「上/下两个方向、可切换」，NodeSeek 是「三个动作、都不可撤销、其中两个花钱」。
这不是加一个能力位能抹平的差别，是领域模型不同。现在照着 NodeSeek 改会做出一个 NGA 用不上的
抽象，等真写适配器时手上有完整信息再定更合算。`postDownvote` 那一位已经在了，能表达
「没有反方向」这一半。

## 七、仍然欠着的

- ~~没有真实账号验证过~~ —— 传输层已验（见第〇节）。**写接口的响应字段仍未验证**
- 读接口的响应字段已验（2026-08-27，登录态下用 `Design/probe-nodeseek-session.js` 跑的）：
  - 用户动态 `{post_id, rank, title}`，评论多 `floor_id`、`text`，每页 15 条
  - 私信 `msgArray[]`：`max_id, sender_id/name, receiver_id/name, content, viewed, created_at`
    —— 给的是**会话**不是单条消息，一个对话方一行
  - 通知 `at-me` / `reply-to-me` 同形状 `data[]`：`id, post_id, title, comment_id,
    first_comment_id, floor_id, commenter_id/name, viewed, created_at`，**没有正文**
  - 未读数 `unreadCount.{all, atMe, message, reply}`
  - 收藏 `collections[]`：`post_id, rank, title`。每页多少条没测出来（当时只有一条收藏）
  - 签到榜 `list[] + record + order + total`，**没有 success 字段**；
    `record` 里没有连续/累计天数，顶层的 `order`/`total` 说的是榜单不是我的天数
- 投票（2026-08-27 摸到一半）：
  - **投票不在内嵌状态里**，而是写在正文的 Markdown 里：`nsapp://vote?id=3027`。
    服务端把它渲染成 `<a href="javascript://void(0)" data-href="nsapp://vote?id=3027">`，
    网页版的 JS 认出它、去 `/api/vote/info/{id}` 取数据、再画面板。
  - 面板渲染出来长这样：`.vote-panel > .embed-vote`，`h2` 是标题，每个选项一个
    `input[type=radio][name=vote-item][value=<选项id>]`，`label .vote-item-text` 是选项文字。
    单选是 radio，多选想必是 checkbox（没见到样本）。页脚写着「(公开投票)」。
  - **匿名看不到票数**，按钮是禁用的「登陆后再投票」。
  - `/api/vote/info/{id}` **对手写请求一律 403**（试过 4 个 id、加过 XHR 头，
    都是 `{"success":false}`），只有页面自己那次是 200 —— 少了什么头还不知道。
    登录态下页面自己那次的响应字段（2026-08-27 实测）：
    `vote.{id, uid, title, isPublic, locked, multiple}` +
    `vote.items[].{vote_item_id, vote_id, text, count, voted}`。
    **注意 `multiple` 是布尔值不是上限**，`locked` 是布尔值、没有截止时间。
  - 提交是 `POST /api/vote/voteforitem`，响应只有 `{success: boolean}`。
    **请求体的形状还不知道** —— 响应看不出它要什么。拿到之前不实现提交。
  - 匿名下 `URLSession` 能不能取到投票没验过（403 的原因还没查清）。取不到时
    按「这帖没有投票」处理，不让一个附加内容把整页帖子拖垮。
  - 因此 `.poll` 仍然不点亮：结果能看，票投不出去。界面按这个状态显示
    「本站的投票暂时只能查看」，而不是假装投票已结束。
- HTML 解析所需的选择器没有整理（对方项目有一份 `Selectors.kt` 可参考）
- 帖子页里楼层的具体结构、@提及、表情、图片的形态
- 私信列表与会话的响应字段
- `/api/content/new-comment` 是否需要 CSRF token（对方项目提到过 `Csrf-Token`，与 `x-dynamic-sign`
  一样只校验存在性，但我没确认这条是否适用于回复）
