# SNGA (Super NGA)

<p align="center">
  <img src="Design/SNGA-AppIcon-Master.png" width="160" alt="SNGA 应用图标">
</p>

<p align="center">
  <a href="https://github.com/Gongsc/SNGA/releases/latest"><img src="https://img.shields.io/github/v/release/Gongsc/SNGA?label=%E6%9C%80%E6%96%B0%E5%8F%91%E5%B8%83&color=blue" alt="最新发布版本"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Gongsc/SNGA?label=%E8%AE%B8%E5%8F%AF%E8%AF%81&color=blue" alt="许可证"></a>
</p>

SNGA 是一个使用 SwiftUI 构建的原生 macOS 论坛客户端，开发中的版本为 1.9.3（[已发布的版本见 Releases](https://github.com/Gongsc/SNGA/releases)）。它支持多账号登录、论坛浏览、话题互动、AI 辅助阅读、消息通知与常用资讯工具。

网络与解析层是站点无关的适配层，**NGA** 和 **NodeSeek** 接在它上面 —— 同一套界面能同时用于两个论坛。

> 这里只写开发中那一版的更新。已发布版本的说明在各自的 [Release](https://github.com/Gongsc/SNGA/releases) 页面上。

登录流程由各论坛的官方网页完成。SNGA 不保存密码，凭据按账号隔离保存。

> SNGA 是非官方客户端，与 NGA、NodeSeek 官方均无从属关系。两个站点都没有提供稳定的公开 API，页面或接口调整可能导致部分功能暂时不可用。

## 1.9.3 更新（开发中）

- 楼层末尾会显示作者的签名，和正文之间隔一条分割线。两个站的签名都跟着话题页一起下发，不额外增加请求；签名里的链接照常可点，指向站内的直接在应用里打开。可以在「设置 → 浏览 → 在话题中显示签名」里关掉（两个站都只对已登录用户下发签名）
- 用户中心里的自我介绍按站点自己的说法称呼：NGA 是「签名」，NodeSeek 是「个人简介」—— 在 NodeSeek 上它和楼层签名是两份东西
- 搜索面板和版面内搜索改用同一条搜索栏，两处的输入框和结果行和话题列表对齐；此前面板那条在某些窗口宽度下会整体往右偏二十来点

## 界面预览

![SNGA 明亮与深色模式界面](Design/SNGA-Light-Dark-Comparison.png)

## 支持的论坛

| 论坛 | 登录方式 |
| --- | --- |
| [NGA](https://bbs.nga.cn) | 官方网页登录 |
| [NodeSeek](https://www.nodeseek.com) | 邮箱验证码或账号密码，都走站点官方页面 |

两个站点共用同一套界面，账号各自独立，可以同时添加并随时切换。每个站点能做什么由它自己的适配层声明，界面据此决定画不画对应控件。

### 各站差异

| 功能 | NGA | NodeSeek |
| --- | --- | --- |
| 回复格式 | UBB | Markdown |
| 回复表情 | AC 娘一套 45 个 | 四套共 252 个，短代码写法 |
| 全站搜索 | 话题、版面、版主、用户 | 帖子标题（需登录，不搜正文） |
| 楼层表态 | 点赞、点踩 | 点赞免费；加鸡腿和反对要花掉读者自己的鸡腿，收在「更多表态」里并先确认 |
| 话题收藏 | 分收藏夹，支持管理 | 平铺一个列表 |
| 楼层签名 | 跟着话题页下发，UBB 排版照原样显示 | 跟着话题页下发，签名里的链接照常可点，站内的直接在应用里打开 |
| 版面收藏、子版面、话题评分、匿名楼层、只看楼主、精华筛选 | 支持 | 站点没有 |
| 私信、通知、签到、话题内投票、用户发帖记录 | 支持 | 支持 |

NodeSeek 这边另外处理了站点特有的正文：表情图、`:::: tabs` 标签页、带 ANSI 颜色的测评报告（含中英文混排的等宽对齐）、置顶 / 推荐阅读 / 等级限制标记，以及热点回复楼层。

## 主要功能

- 多账号添加、切换、重新登录与独立会话管理
- 论坛目录、搜索、收藏、最近访问、主板块与子板块浏览
- 话题列表排序、分页、指定页跳转和置顶话题入口
- 话题骨架屏加载、分页、站内链接跳转及回到顶部
- 展示作者头像、等级、注册时间、IP 属地、徽章等资料，字段和叫法按各站自己的说法显示
- 标注被管理处罚折叠的楼层，以及楼层发出后的改动时间
- 楼层末尾用一条分割线隔出作者签名，可在设置里关掉
- 支持图片、表情、表格、代码、引用、折叠内容、投票和楼层表态（NGA 另有话题评分）
- 支持话题回复、楼层引用、可视化编辑、源码编辑、预览与草稿保存，编辑器按站点给 UBB 或 Markdown 工具条
- 同步话题收藏；NGA 还同步板块收藏与收藏夹管理
- 用户中心、短消息、通知、手动签到与签到统计，以及 macOS 系统通知
- OpenAI 兼容的 AI 用户画像与临时话题总结，支持 OpenAI、Ollama 等兼容服务
- 跟随系统、明亮、深色、NGA 暖金、午夜蓝及自定义共六套主题，无图模式、运行日志，以及无需登录即可使用的资讯热榜小工具

## 系统要求

- macOS 26.0 或更高版本
- Xcode 26.6 或更高版本
- Swift 6

项目主要使用 SwiftUI、SwiftData、WebKit、UserNotifications，以及固定版本的 [SwiftSoup 2.13.6](https://github.com/scinfu/SwiftSoup/releases/tag/2.13.6)。

## 构建与运行

1. 使用 Xcode 打开 `SNGA.xcodeproj`。
2. 选择 `SNGA` scheme 和 `My Mac`。
3. 等待 Swift Package Manager 下载依赖后运行应用。
4. 在应用内使用对应论坛的官方页面登录。

命令行 Debug 构建：

```sh
xcodebuild -project SNGA.xcodeproj \
  -scheme SNGA \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 数据与安全

- 账号资料、收藏、草稿、偏好和签到记录保存在应用沙盒中
- 会话 Cookie 按账号隔离保存，普通请求不使用共享 Cookie 容器
- 帖子 HTML 会移除脚本、表单、iframe、事件属性和不安全链接
- 运行日志默认关闭，启用后不会记录 Cookie、登录令牌或请求正文
- AI API Key 保存在应用沙盒内权限 0600 的私有文件中，与会话 Cookie 同级；生成前会明确提示公开资料将发送到用户配置的 AI 服务
- 应用启用了 App Sandbox 和 Hardened Runtime

## 当前限制

- 不支持发布新话题或上传本地图片
- 不支持新建陌生人私信、删除私信或批量操作
- NodeSeek 尚不支持用户搜索、收藏夹分组，点赞发出后也撤不回（站点如此）
- 不提供离线全文归档和自动更新
- 应用退出后不会签到、轮询消息或运行独立后台进程
- 尚未包含 Developer ID 签名、公证、安装包或 App Store 发布配置

## 致谢

- [60s API](https://github.com/vikiboss/60s)：为小工具模块提供开放的数据接口与实例支持
