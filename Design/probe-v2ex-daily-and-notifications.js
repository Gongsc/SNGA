// 摸清 V2EX 的「提醒」和「每日登录奖励」两页。
//
// 上一版按树形输出，深度卡在 3 —— 而站点每条提醒外面套着 `table > tbody > tr`，
// 三层全花在包装上，真正有内容的格子一个都没报出来。改成**扁平遍历**：
// 一条提醒底下所有带类名的元素，各报标签、类名、有没有 title、是不是叶子文字。
// 包装套多少层都不影响。
//
// **不打印任何令牌。** onclick 和链接里的数字、长串一律换成 `{值}` 再输出；
// 按钮上的字是界面文案，不是凭据，照原样报 —— 解析器要靠它认「今天领过了」。
// 提醒的正文也不报，只报它在哪个元素里、有多长。
//
// 用法：登录之后分别在这两个地址上粘贴运行，**各贴一次结果**：
//   1. https://www.v2ex.com/notifications
//   2. https://www.v2ex.com/mission/daily
(() => {
  // 数字和长串一律遮掉：`?once=73510` → `?once={值}`。
  const mask = (text) => String(text || '')
    .replace(/\d{2,}/g, '{值}')
    .replace(/[A-Za-z0-9_-]{12,}/g, '{值}');

  /// 一个元素底下所有带类名的后代，摊平成一列。不看层数。
  const flatten = (root) => {
    if (!root) return null;
    return Array.from(root.querySelectorAll('[class], [title], a[href]'))
      .slice(0, 25)
      .map((element) => ({
        标签: element.tagName.toLowerCase(),
        类名: element.className || null,
        // 时间戳在这个站上一律藏在 title 属性里。**两个都要看** ——
        // tippy.js 会在浏览器里把 `title` 挪进 `data-original-title`，
        // 只问 `title` 会得出「这一页没有时间戳」的错结论，而服务端发的是 title。
        title: element.hasAttribute('title')
          ? mask(element.getAttribute('title'))
          : undefined,
        'data-original-title': element.hasAttribute('data-original-title')
          ? mask(element.getAttribute('data-original-title'))
          : undefined,
        href: element.getAttribute('href')
          ? mask(element.getAttribute('href'))
          : undefined,
        // 正文本身不报，只报它有多长 —— 够判断「哪一格装的是正文」。
        文字长度: element.children.length === 0 && element.textContent.trim().length > 0
          ? element.textContent.trim().length
          : undefined
      }));
  };

  const item = document.querySelector('#Main div[id^="n_"]');
  const pager = document.querySelector('input.page_input');

  console.log(JSON.stringify({
    地址: location.pathname,

    分页: {
      本页条数: document.querySelectorAll('#Main div[id^="n_"]').length,
      'page_input 的 max': pager ? pager.getAttribute('max') : null,
      // 提醒页可能是「往下无限加载」而不是翻页，那就会有这么一颗游标。
      有无限加载游标: /notificationBottom/.test(document.documentElement.innerHTML)
    },

    一条提醒: item ? { id模板: mask(item.id), 内部: flatten(item) } : null,

    // 每日奖励那颗按钮点下去做什么，以及领过之后页面怎么说。
    奖励: Array.from(
      document.querySelectorAll('#Main input[type="button"], #Main a.super, #Main .super')
    ).slice(0, 4).map((element) => ({
      标签: element.tagName.toLowerCase(),
      类名: element.className || null,
      按钮文字: (element.value || element.textContent.trim() || null),
      onclick: element.getAttribute('onclick') ? mask(element.getAttribute('onclick')) : undefined,
      href: element.getAttribute('href') ? mask(element.getAttribute('href')) : undefined
    })),

    // 连续签到的天数写在哪儿：整页里带「天」的那几句（数字已遮）。
    含天数的句子: Array.from(document.querySelectorAll('#Main .cell, #Main .inner, #Main .message'))
      .map((cell) => cell.textContent.trim())
      .filter((text) => text.includes('天') && text.length < 80)
      .slice(0, 4)
      .map(mask)
  }, null, 2));
})();
