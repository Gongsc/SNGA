# SNGA (Super NGA)

<p align="center">
  <img src="Design/SNGA-AppIcon-Master.png" width="160" alt="SNGA 应用图标">
</p>

SNGA 是一个使用 SwiftUI 构建的原生 macOS NGA 论坛客户端，当前版本为 1.9.0。它支持多账号登录、论坛浏览、话题互动、AI 辅助阅读、消息通知与常用资讯工具。

登录流程由 NGA 官方网页完成。SNGA 不保存密码，并通过独立的网络与解析适配层访问论坛。

> SNGA 是非官方客户端，与 NGA 官方没有从属关系。NGA 未提供稳定的公开 API，页面或接口调整可能导致部分功能暂时不可用。

## 1.9.0 更新

- 小工具不再需要论坛账号，一个账号都没添加时也能打开资讯热榜
- 小工具自己的网络故障不再显示成 NGA 的错误，两边各说各的
- 出错提示前面会标明是哪个站，多账号时不必猜是哪边失败
- 运行日志的脱敏名单改为按站点推导，新增站点的会话 Cookie 不会漏进日志
- 内部改造：网络与解析适配层完成站点无关化，为后续接入其他论坛做准备。本版仍然只支持 NGA，界面与功能没有变化

## 1.8.3 更新

- 新增 OpenAI 兼容接口配置，支持自定义 Base URL、模型、API Key、提示词，以及 Chat Completions 流式和普通响应
- AI 设置增加连接测试、总开关及独立的用户画像和话题总结提示词；API Key 仅保存在 macOS 钥匙串
- 用户中心可生成 AI 用户画像，并在“AI 画像”模块查看、复制、重新生成、删除及管理历史数量
- 话题标题旁新增 AI 总结按钮，结果以 Markdown 流式显示且不会保存
- 话题总结范围支持“前 N 页”到“全部页面”，先串行读取页面再请求 AI，并显示采集进度、覆盖范围和输入裁剪状态
- 优化 AI 与 NGA 请求调度，避免同时访问论坛和 AI 服务；分页采集失败时会标明具体页码，方便排查

## 界面预览

![SNGA 明亮与深色模式界面](Design/SNGA-Light-Dark-Comparison.png)

## 主要功能

- 多账号添加、切换、重新登录与独立会话管理
- 论坛目录、搜索、收藏、最近访问、主板块与子板块浏览
- 话题列表排序、精华筛选、分页、指定页跳转和置顶话题入口
- 话题骨架屏加载、分页、只看楼主、站内链接跳转及回到顶部
- 展示作者头像、级别、声望、注册时间、威望、IP 属地、徽章和发帖设备
- 标注匿名话题与匿名楼层、被管理处罚折叠的楼层，以及楼层发出后的改动时间
- 支持图片、表情、表格、代码、引用、折叠内容、投票、评分、点赞和点踩
- 支持话题回复、楼层引用、UBB 可视化编辑、源码编辑、预览与草稿保存
- 同步板块收藏和话题收藏夹，支持收藏夹管理
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
4. 在应用内使用 NGA 官方页面登录。

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
- AI API Key 仅保存在 macOS 钥匙串；生成前会明确提示公开资料将发送到用户配置的 AI 服务
- 应用启用了 App Sandbox 和 Hardened Runtime

## 当前限制

- 不支持发布新话题或上传本地图片
- 不支持新建陌生人私信、删除私信或批量操作
- 不提供离线全文归档和自动更新
- 应用退出后不会签到、轮询消息或运行独立后台进程
- 尚未包含 Developer ID 签名、公证、安装包或 App Store 发布配置

## 致谢

- [60s API](https://github.com/vikiboss/60s)：为小工具模块提供开放的数据接口与实例支持
