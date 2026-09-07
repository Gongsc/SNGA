// 摸清 NodeSeek 楼层签名（`div.signature`）在 DOM 里的位置和用到哪些标签。
//
// 站点对未登录用户不下发签名 —— 匿名抓过 11 个帖子、82 层，一个 `div.signature`
// 都没有，所以这一份只能由登录着的人在浏览器里跑。
//
// 解析器现在按 `.content-item` 找签名、找到就摘走，对「签名是 article 的兄弟」和
// 「签名在 article 里面」两种排法都成立。这个探针是去确认到底是哪一种，以及签名里
// 有没有出现清洗白名单挡掉、或者 `PostContentBuilder` 还原不了的标签 —— 后者会让
// 签名从原生渲染掉回 `WKWebView`，一页二十层就是二十个网页视图。
//
// **只打印结构：标签名、类名、数量。不打印任何链接地址、文字或用户信息。**
//
// 用法：在已登录的 nodeseek.com 上打开一个楼层里有签名的帖子，粘贴运行，
// 把输出贴回来。
(() => {
  const signatures = [...document.querySelectorAll('.signature')];
  if (!signatures.length) {
    console.log('这一页没有签名 —— 换一个能看到签名的帖子再试');
    return;
  }

  // `PostContentBuilder` 能原生还原的标签，和 Swift 那边保持一致。
  const nativeBlocks = new Set(['P', 'DIV', 'BLOCKQUOTE', 'BODY']);
  const nativeInline = new Set([
    'A', 'B', 'STRONG', 'I', 'EM', 'U', 'STRIKE', 'S', 'DEL', 'SPAN', 'BR', 'CODE', 'FONT'
  ]);

  const report = signatures.slice(0, 5).map((element) => {
    const item = element.closest('.content-item');
    const article = element.closest('article.post-content');
    const descendants = [...element.querySelectorAll('*')];
    const tagCounts = {};
    for (const node of descendants) {
      tagCounts[node.tagName] = (tagCounts[node.tagName] || 0) + 1;
    }
    const unsupported = [...new Set(
      descendants
        .map((node) => node.tagName)
        .filter((tag) => !nativeBlocks.has(tag) && !nativeInline.has(tag) && tag !== 'IMG')
    )];
    return {
      在楼层里: !!item,
      在正文article里: !!article,
      父节点: element.parentElement.tagName + '.' + (element.parentElement.className || ''),
      前一个兄弟: element.previousElementSibling
        && element.previousElementSibling.tagName + '.' + (element.previousElementSibling.className || ''),
      后一个兄弟: element.nextElementSibling
        && element.nextElementSibling.tagName + '.' + (element.nextElementSibling.className || ''),
      节点数: descendants.length,
      标签分布: tagCounts,
      原生还原不了的标签: unsupported,
      有图: descendants.some((node) => node.tagName === 'IMG')
    };
  });

  console.log('这一页的签名数：', signatures.length,
              '楼层数：', document.querySelectorAll('.content-item').length);
  console.log('各签名的结构：', report);

  // 楼层里除了 .signature 还有没有别的地方也叫这个名字，避免误摘。
  console.log(
    '类名里带 sign 的其它元素：',
    [...new Set(
      [...document.querySelectorAll('[class*="sign"]')]
        .map((node) => node.tagName + '.' + node.className)
    )]
  );
})();
