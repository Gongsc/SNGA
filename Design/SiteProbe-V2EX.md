# V2EX 接口摸底

> 来源：**自己跑出来的**。2026-09-08 用一个浏览器 UA 匿名请求公开页面，外加读站点自己的
> JS bundle（`/assets/…-combo.js`，公开静态资源）。没有任何账号凭据参与，也没有向站点
> 发过任何写请求。
>
> 下面每一节都标了「实测」还是「推断」。**只有一处是推断**：发回复那张表单的字段名 ——
> 它只画给登录用户，匿名看不见。见第五节。

## 〇、这个站和 NodeSeek 正好相反

NodeSeek 是「网页要解析、JSON 接口管写操作、Cloudflare 处处设卡」。V2EX 是：

- **浏览面全部公开**。节点列表、主题、回复、会员资料，匿名 `URLSession` 一次请求拿全，
  没有挑战、没有限流提示、不校验 UA。
- **网页是主干**，而且从首页到节点页到「某人发过的主题」，列表用的是**同一套模板**，
  所以 `V2EXParser.topicList` 一个入口吃下四种页面。
- **只剩两个 JSON 接口还活着**，都是只读的：`/api/nodes/all.json` 和
  `/api/members/show.json`。站点自己也在用前者（`combo.js` 的 `fetchNodeList`）。
- **写操作没有接口**，是表单 + 一个叫 `once` 的一次性令牌。

### User-Agent 不校验（实测）

拿 `SNGA/1.0 (macOS; native client)` 请求 `/go/qna`、`/t/{id}`、`/api/nodes/all.json`，
三个都是 200。所以 `userAgent` 用 `.fixed`，不必像 NodeSeek 那样去问 WebView 要真实 UA。

### 语言要自己钉（实测）

对没登录、没设过语言的访客，站点默认发英文页（页面里 `const LANG = 'enus'`），
「最后回复来自」会变成「Lastly replied by」。所以请求一律带 `V2EX_LANG=zhcn`。
解析基本靠结构和 `title` 属性，不靠这些字，但页面里确实有几处只有文字可认。

### 「没有这个节点」也是 200（实测）

`/go/{不存在的节点}` 答的是 **HTTP 200**，一张结构正常、只是没有列表的页面，
面包屑最后一段写着「节点未找到」（这几个字站点没有翻译，英文语言下也一样）。
报成「论坛页面结构已变化」既不对也没用 —— 站点没坏，是节点不在。
`V2EXParser.missingNodeReason` 认它，夹具是 `v2ex-node-missing.html`。

**认它的时候要认准。** 第一版只看「抬头里有句短文字」，结果把
`/member/{名字}/topics` 也网了进去：会员可以把自己的主题列表藏起来（那一页写着
「根据 X 的设置，主题列表被隐藏」），没发过主题的人也一样，两种页面上都没有列表 ——
于是每次切到 V2EX、用户中心一打开就弹一句「V2EX：全部主题」（那是那一页抬头的
最后一段）。两者的区别在面包屑：「节点未找到」是「V2EX › 节点未找到」，只有一个链接；
用户页是「V2EX › 某人 › 全部主题」，有两个。

顺带纠正的是更根本的一件事：**用户的主题一条都没有，是正常状态，不是解析失败。**
那一页因此不再走版面列表那道「什么都认不出来就报错」的关卡，
见 `V2EXParser.userTopics` 和 `v2ex-member-topics-hidden.html`。

这一条被一个更蠢的原因暴露出来过：**切账号时界面上还挂着上一个站的版面**，
按版面编号触发的 `.task(id:)` 拿着 NGA 的 `-7` 去问 V2EX，于是每次从 NGA 或
NodeSeek 切到 V2EX 都弹一句「V2EX：论坛页面结构已变化：未找到主题列表」。
根子不在解析器：那一次请求本来就不该发出去。挡在了 `ForumStore.loadTopics` /
`loadTopicPage` 的入口（`AppSession.belongsToActiveSite`），
`CrossSiteForumGuardTests` 盯着它。

### 会话过期是 302，不是 401（实测）

匿名请求 `/search`、`/mission/daily`、`/notifications`、`/my/topics` 一律 302。
`URLSession` 跟着跳，于是拿回来的是一张 **200 的登录页**。不认这一条，解析器会去登录页上
找主题列表，报出来的是「论坛页面结构已变化」—— 把「去登录」这条唯一有用的路藏起来。
`V2EXNetworkClient.isSignInPage` 负责认它。

## 一、地址（实测）

| 用途 | 地址 | 备注 |
| --- | --- | --- |
| 首页分类 | `/?tab={分类}` | 聚合若干节点，**不分页** |
| 最近主题 | `/recent?p=N` | 首页 `/` **不分页**，能一直翻的是这个 |
| 节点主题 | `/go/{节点}?p=N` | 每页 20 条 |
| 主题 | `/t/{主题}?p=N` | 每页 100 层 |
| 节点目录 | `/planes` | 1366 个节点分进 6 个「位面」 |
| 节点全表 | `/api/nodes/all.json` | 站点搜索框的数据源 |
| 会员资料 | `/api/members/show.json?id=` 或 `?username=` | 两种都通 |
| 某人的主题 | `/member/{用户名}/topics?p=N` | 和节点页同一套列表模板 |
| 某人的回复 | `/member/{用户名}/replies?p=N` | 另一套：dock_area + inner 成对 |
| 一次性令牌 | `/poll_once` | 响应体就是一串数字，**匿名也给** |

总页数一律从分页条那个跳页输入框的 `max` 读（`input.page_input[max]`）。页码链接在页数
多时会省略成「1 2 3 … 12072」，从链接里读会得到 12072 之外的错数。

### 首页分类是聚合版面（实测）

首页顶上那一排（`#Tabs`）不是装饰，是站点自己的一组**聚合版面**：`/?tab=tech`
（技术）同时列出程序员、Python、iDev、Claude、OpenAI、Local LLM、云计算、宽带症候群
这几个节点的主题，页面上还把它们画成第二行（`#SecondaryTabs`）。

三件要注意的：

1. **分类和节点会重名。** 站点有一个叫 `qna` 的分类，也有一个叫 `qna` 的节点，
   `/?tab=qna` 和 `/go/qna` 是两份不同的列表。所以分类的 `ForumID` 加了 `tab:` 前缀 ——
   不加，收藏、最近访问、子版面偏好这些按 `ForumID` 做主键的东西全会串号。
2. **分类页不分页。** 页面上根本没有分页条（实测 `?tab=tech` 40 条、`?tab=all` 54 条、
   `?tab=hot` 37 条，一个 `page_input` 都没有）。服务层因此只取第一页，
   收下大页码只会把同一屏再取一遍，还让界面以为「还有下一页」。
3. **`#SecondaryTabs` 只有分类页有**，节点页和 `/recent` 上没有这个元素。
   它交出去当子版面用：界面已经有一套画子版面的东西，还能按节点筛掉几个不看
   （靠 `Topic.sourceForumID`，所以混合列表里每条都要记住自己来自哪个节点）。

   借这套界面有个坑，踩过一次：那一格的默认状态是**服务端说勾了才勾**
   （`Forum.isSelectedInParent`，NGA 的形状 —— 它的父版面页面里就带着当前勾选）。
   V2EX 什么都没说，于是一个都不勾，界面把这几个节点的主题全筛掉了 ——
   一格「技术」只剩下几条来自别的节点的零星主题，头上还写着「已显示 0」。
   站点在服务端就把这些主题聚合进来了，它们本来就全在列表里，所以解析器给它们
   一律填 `true`。`V2EXTabListingTests` 盯着这一条。

   措辞也不能照搬：V2EX 的节点是平的，那一格不叫「子版面」（叫了等于说它有层级），
   而且两站的默认状态是反的 —— NGA 勾选是**加进来**，V2EX 取消勾选是**筛出去**。
   见 `ForumSiteDescriptor.subforumSectionTitle` / `subforumSelectionHint`。

同一排上还有三个**不是** `?tab=` 的：VXNA（`/xna`，另一个产品）、节点（就是节点目录）、
关注（`/my/following`，要登录）。三个都不是主题列表，没有收进 `V2EXEndpoint.tabs`。
后两个只有登录后才画出来 —— 这一排的长度会随登录状态变，别拿它当固定名单。

分类表写死在 `V2EXEndpoint.tabs` 里。站点改了这一排，
`V2EXLiveTests.manualLiveTabTableMatchesTheSite` 会指出来。

### 会员资料分在两处（实测）

`/api/members/show.json` 给身份和自我介绍；**今日活跃度排名、公司职位、外部链接、
以及 MOD / PRO 徽章只画在网页上**（接口只有一个 `pro` 字段，认不出管理员）。
所以一份完整的资料要两次请求，网页那次是附带的 —— 取不到就少显示几行，
不该把整张资料页拖垮。它也只能在拿到用户名之后才发得出去（网页地址里是用户名）。

网页那半边的几个位置：

| 东西 | 认什么 |
| --- | --- |
| 今日活跃度排名 | `a[href=/top/dau]` 的文字 —— 认链接不认前面那句中文 |
| 公司 / 职位 | 抬头里含 🏢 的那个 `span`，没有类名，站点自己也拿图标当标记 |
| 徽章 | `.badges .badge`（MOD、PRO） |
| 外部链接 | `.widgets a.social_label`，图标的 `alt` 就是种类（Website / GitHub / …） |

两个坑：

- **Geo 那条要挑掉。** 它指向谷歌地图，而属地已经在「所在地」那一行了。
- **时间戳读 `title`，不是 `data-original-title`。** 浏览器里看到的 DOM 是
  tippy.js 改写过的；服务端发的是 `title`。照着浏览器里复制出来的 HTML 写选择器，
  抓下来的页面上一个都匹配不到。

### 一页 100 层，按楼层数发的请求会要命（实测）

V2EX 的主题页每页 **100 层**（NGA 二十几，NodeSeek 十）。任何「按楼层数发一次请求」
的功能，代价在这个站上都要乘十。

踩过一次：界面为了补作者的 IP 属地，会给每一层没有属地的楼去拉一次作者资料。
`/t/1240256?p=1` 那一页 100 层、88 个不同的作者，而 V2EX 的资料要两次请求 ——
**176 次请求排在同一个连接上，按 320ms 的节奏走完要 56 秒**，期间翻页、刷新、
发回复全在后面排队。页面本身只要 0.47 秒，解析 0.26 秒，慢的全是这个。

更糟的是拉回来还用不上：V2EX 的 `location` 是会员自己填的一行字（「cn」），
不是 IP 属地，填进去等于拿自填的地名冒充属地。NodeSeek 的资料里干脆没有这一项，
拉多少次都是空 —— 那边一直也在白拉，只是一页十层没显出来。

所以加了 `.postAuthorLocation` 这一位，门控挡在 `ThreadStore.loadPostAuthorLocation`
的入口。**这个站上凡是「按楼层数」的事，先算一遍一百倍是多少。**

### 正文里会有内嵌播放器（实测）

站点把视频地址渲染成一个播放器：

```html
<div class="embedded_video_wrapper">
  <iframe src="https://www.youtube.com/embed/BpqYEWbkFYw" class="embedded_video"></iframe>
</div>
```

`iframe` 是清洗时一定要去掉的东西（正文是别人写的，要进 `WKWebView`），
也不能改成留着让它播 —— 文档的 CSP 是 `default-src 'none'`，留着也是一块空白。
但**去掉的时候要把地址留下来**：直接清掉的话，那一层楼里的视频连地址都不剩，
读者只看到半句话，还不知道后面本来有东西。

`V2EXParser.replaceEmbeds` 在清洗**之前**把它换成一条能点的链接，播不了至少去得了。
按标签认不按类名认：`embedded_video_wrapper` 是站点现在的写法，
「iframe 里装着一个地址」才是通用的。夹具是 `v2ex-post-video.html`。

## 二、用户名和编号是两套（实测）

页面地址里是**用户名**（`/member/Livid`），应用内部一律拿 `Int64` 认人。翻译只能问
`/api/members/show.json` —— 所以按编号看动态时会多一次请求，结果缓存在服务里。

同一个原因，**正文里的用户链接一概交给浏览器**：`ForumSiteDescriptor.internalDestination`
是同步的，发不了那次请求，猜一个编号比打开浏览器更糟。

登录之后「我是谁」在页面上有三条路，`V2EXParser.signedInUserID` 依次试：

1. `var memberId = …` 这个 JS 全局。站点自己的草稿功能拿它当键
   （`saveTopicDraft(nodeName, memberId)`，见 combo.js）—— 匿名页上没有这一行（实测）。
2. 顶栏头像地址里的编号：`/avatar/205f/180e/600305_normal.png`。
3. 头像元素上的 `data-uid`。

第 3 条不是多余的：**用 gravatar 当头像的会员，地址里是一串哈希、没有编号**（实测，
列表页上就有这种）。三条路都还没在真正的登录态下验过，`Design/probe-v2ex-session.js`
就是去验它的。

## 三、主题搜索是第三方的（实测 + 读站点 JS）

**V2EX 自己没有全文搜索。** 这个结论要说清楚判据，因为同样的判断在 NodeSeek 上错过两次
——那两次都是拿匿名结果当全部事实。匿名访问 `/search?q=X` 会 302 到 `/go/search`
（一个**叫 search 的节点**，不是搜索页），但这不是判据。判据是站点自己的搜索框
（`combo.js` 里 `if (FEATURES.includes('search'))` 那一段），它给的候选一共四档：

```js
searchNode(text)   // 本地过滤 window.V2EX.nodeList，跳 /go/{名字}
searchUser(text)   // 跳 /u/{名字}
searchGoogle(text) // https://www.google.com/search?q=site:v2ex.com/t%20{关键词}
searchSoV2EX(text) // https://www.sov2ex.com/?q={关键词}    ← 第三方
```

匿名页上 `FEATURES` 已经包含 `'search'`，也就是说这就是搜索框的完整行为，
没有「登录后另有一档」。

应用接的是其中两档：**节点**（本地过滤 `/api/nodes/all.json`，不出网）和**主题**
（SoV2EX）。谷歌那档在站外、用户那档只是跳转，都没有对应物。

### SoV2EX：关键词出站，会话不出站

`sov2ex.com` 是第三方建的全文索引，和 V2EX 没有从属关系。接它意味着用户的关键词会
离开 V2EX —— 所以档位名上直接写着 `主题正文（SoV2EX）`，搜索框下面那句说明也点名了
它，用的人有权一眼看见。

**但会话绝不能跟着出去。** 这条路走 `V2EXNetworkClient.getThirdParty`：一个 cookie
都不带，也不带 Referer 和 Origin。单独开一个方法而不是在 `send` 里判域名 ——
判域名是一句可以被后来的人删掉的条件，而「这条路本来就不碰 jar」不是。
`V2EXSearchTests.testTheSessionNeverLeavesV2EX` 盯着它，而且顺带确认同一个会话在
自家请求上确实是带着的，否则那条断言可能只是因为压根没有 cookie。

### 接口（实测 2026-09-08）

`GET https://www.sov2ex.com/api/search?q=&from=&size=&sort=&order=&node=&username=&gte=&lte=`

响应形如 `{"total": 410, "hits": [{"_source": {…}, "highlight": {…}}]}`，
每条命中的 `_source` 里有 `id`、`title`、`content`、`member`、`replies`、`node`、`created`。

五条和它表单上写的不一样，或者一眼看不出来 —— **每一条都要比对结果条数才验得出，
只看状态码全是 200**：

- **`node` 收的是节点名。** 表单写着「支持节点名称与 节点 id」，可传数字编号时过滤
  **根本不生效** —— 结果条数和不带这个参数一模一样（410 对 410），而传 `qna` 是 41 条。
- **`gte` / `lte` 收的是秒。** 表单上写的是 `YYYY-MM-DD`，传日期字符串答 400；
  而**传毫秒不报错、悄悄返回 0 条** —— 那个数落在很远的将来，什么都不在范围里。
  这一条我先写错过一次：只看到毫秒没有 400 就下了结论，没去数结果。
  判据是 `gte=1735689600`（2025-01-01，秒）273 条，同一时刻的毫秒形式 0 条。
- **`order=0` 是降序，`1` 是升序。** 站点表单的默认就是「权重 + 降序」。
- **`_source.node` 是数字编号**，不是名字。要靠 `/api/nodes/all.json` 里的 `id` 翻译，
  所以节点表按编号也索引了一份。翻不出来时结果照常显示 —— 主题是按编号打开的。
- **`created` 没有时区后缀，值是 UTC**（`2026-04-03T05:17:59` 正好等于那条主题
  epoch 的 UTC 表示）。按本地时间读，搜索结果上的日期会整整差八个小时。

分页靠 `from` / `size`，应用一次取 20：取 10 一屏都填不满，取满 50 要等一次更久的往返，
而搜索结果很少有人翻到第三屏。

### 缩进一个节点搜，但缩不进首页分类

主题那一档是 `.topicContent`，`supportsCurrentForum` 为真，所以节点页上会画版面内
搜索那条栏。**首页分类和「最近主题」不行** —— 它们不是节点，`node` 参数带不上。
画出来就是一句谎：范围写着「当前版面」，搜的却是全站。所以又细了一层
`ForumSiteDescriptor.supportsSearch(in:)`，那两种页面上整条栏不画。

### 筛选条件

作者（`username`）、发帖日期区间（`gte` / `lte`）、排序（`sort` / `order`）三样都接了，
搜索栏上那颗「筛选」按钮展开就是。收进 `ForumSearchFilters`，哪几样画得出来由
`ForumSiteDescriptor.searchFilters(for:)` 按**站点加档位**说 —— 同一个 V2EX，
主题搜索三样全收，节点搜索一样都收不下（它是本地过滤一份名单）。
NGA 和 NodeSeek 目前都是空的，那颗按钮在它们上面不画。

两处照着站点的行为做的：日期选的是「哪一天」，所以下界取当天零点、上界取当天最后一秒
（两端都送同一个时刻的话，「从 15 号搜到 15 号」会一条都搜不到）；换到一档收不下筛选的
搜索时把条件清空 —— 留着不画的话，用户看不见它，它却仍然跟着请求发出去。

**没接的两样**：每页条数（接口允许 1~50，应用固定 20，这是偏好不是筛选）和全站搜索里的
节点选择器（缩进某个节点搜，从那个节点页里搜就是了，而全站面板要摆一千三百多个节点
得先有个像样的选择器）。

## 四、感谢要花钱，而且撤不回来（读站点 JS）

抄自 combo.js：

```js
function thankReply(replyId) {
  $.post('/thank/reply/' + replyId + "?once=" + once, function (data) {
    if (data.success) { once = data.once; $('#thank_area_' + replyId).addClass("thanked")…; refreshMoney(); }
    else { alert(data.message); once = data.once; }
  });
}
function thankTopic(topicId, once) { $.post('/thank/topic/' + topicId + "?once=" + once, …); }
```

末尾那句 `refreshMoney()` 就是代价的证据：成功之后余额变了，所以要重新拉一次。
站点的感谢从感谢者账上扣 10 个铜币，**站点不提供撤销**（响应里只有一个新的 `once`，
没有反向动作）。

所以：

- `.postVote` **不点亮**。感谢只有一个方向，而且不该做成一点就发的赞踩按钮。
- 它走 `Post.reactions`，带 `cost`（「花费 10 个铜币」）和 `isIrreversible`，
  由 `PostReactionBar` 先问一次再发 —— 和 NodeSeek 的鸡腿同一个道理。
- 主楼和回复是**两个地址**。主楼没有自己的回复编号，解析器给它填的是主题编号，
  适配器据此分辨走哪条。

同一段 JS 里还有主题级的 `/up/topic/{id}` 和 `/down/topic/{id}`（响应 `{changed, html}`）。
那是**给主题投票**，不是给楼层，应用里没有对应物，没接。

## 五、发回复：唯一一处推断

站点没有回复接口，只有一张表单。表单只画给登录用户 —— 匿名的主题页里连 `<form>` 都没有
（实测），所以字段名是照着站点的表单推断的：

```
POST /t/{主题}
Content-Type: application/x-www-form-urlencoded
content={正文}&once={一次性令牌}
```

有旁证，但不是证明：combo.js 里 `replyOne(username)` 往 `#reply_content` 这个 textarea 里
写 `@用户名 `，说明输入框的 id 是 `reply_content`；站点每一个写动作都带 `once`。

**验它要登录，所以留给 `Design/probe-v2ex-write.js`。** 在验过之前：

- 请求形状由 `SNGATests/V2EXWriteTests` 用假传输层钉住，改起来是一行；
- 不往真实论坛发测试回复 —— 那是替用户发内容；
- 万一字段名不对，后果是一次失败的提交，不是一条发错的回复。

成败怎么判：成功时站点 302 回主题页，没有 JSON 可读。所以判据反过来 ——
**看返回的页面里有没有 `div.problem`**（「请输入回复内容」「你上一条回复的时间过近」这类），
见 `V2EXParser.confirmReply`。

`once` 的取法：站点自己的 `fetchOnce()` 会缓存 10 秒，过期就重新问 `/poll_once`。
我们每次写之前现取一个，不缓存 —— 省下的那一次请求，不值得赌一个过期的令牌。
（主题页的 HTML 里也写着 `var once = "35953";`，匿名页上就有，所以
`V2EXParser.once(inHTML:)` 有夹具可对；但发请求时仍以现取的为准。）

## 六、还没接的（都要登录才看得见）

| 功能 | 地址 | 为什么没接 |
| --- | --- | --- |
| 话题收藏 | `/my/topics`、`/favorite/topic/{id}` | 列表模板和 `/recent` 大概率同一套，但收藏和取消收藏是两个**登录后才画出来的链接**，匿名看不到它们的参数名 |
| 节点收藏 | `/my/nodes`、`/favorite/node/{id}` | 同上 |
| 提醒 | `/notifications`、`/notifications/below/{游标}` | 匿名 302。删除走 `deleteNotification(id, token)`，token 就是 `once` |
| 每日登录奖励 | `/mission/daily` | 匿名 302 |

对应的能力位（`.topicFavorites`、`.forumFavorites`、`.checkIn`）一律关着，
所以侧栏那个「收藏」入口、楼层上的星标、签到那一段**整个不画** —— 不是画出来等用户点了
再报「不支持」。要接就先跑 `Design/probe-v2ex-logged-in.js`。

站点**没有站内私信**（只有提醒），所以 `.privateMessages` 永远不会点亮。

## 七、夹具

`SNGATests/Fixtures/v2ex-*` 都取自 2026-09-08 的匿名响应，文件头写着取自哪个地址、
留了什么。覆盖：首页分类、节点页、最近主题、主题第一页、主题第二页（附言 + 分页 + 感谢数 +
OP 徽章）、带内嵌播放器的楼层、位面目录、节点全表、会员资料页（齐全的和稀疏的两份）、
某人的主题（有的和被隐藏的两份）、某人的回复、找不到的节点，
以及 SoV2EX 的搜索结果 —— 最后这一份取自 sov2ex.com，不是 V2EX。

一条值得记下来的：**主题页每一页都重画一遍抬头和主楼**。跟着照搬的话，翻到第二页会看到
主楼又出现在第 101 层前面 —— `v2ex-topic-paged.html` 这份夹具盯的就是这个。
