// 摸清 V2EX 的「提醒」和「每日登录奖励」两页。
//
// 上一轮的探针已经报回骨架：提醒是 `div#n_{编号}.cell`，子元素里有 avatar、fade、
// topic-link、node、payload；每日奖励是一颗带 onclick 的 `input[type=button]`。
// 骨架够画个轮廓，不够写解析器 —— 还差三件事，这个脚本只问这三件。
//
// **不打印任何令牌。** onclick 和链接里的数字、长串一律换成 `{值}` 再输出；
// 按钮上的字是界面文案，不是凭据，照原样报（解析器要靠它认「今天领过了」）。
//
// 用法：登录之后分别在这两个地址上粘贴运行，各把结果贴回来：
//   1. https://www.v2ex.com/notifications
//   2. https://www.v2ex.com/mission/daily
(() => {
  // 数字和长串一律遮掉：`?once=73510` → `?once={值}`。
  const mask = (text) => String(text || '')
    .replace(/\d{2,}/g, '{值}')
    .replace(/[A-Za-z0-9_-]{12,}/g, '{值}');

  const outline = (element, depth) => {
    if (!element || depth > 3) return null;
    return {
      标签: element.tagName.toLowerCase(),
      类名: element.className || null,
      // 时间戳在这个站上一律藏在 title 属性里，得知道是哪个元素带着它。
      'title 属性': element.hasAttribute('title')
        ? mask(element.getAttribute('title'))
        : undefined,
      有文字: element.children.length === 0 && element.textContent.trim().length > 0
        ? true
        : undefined,
      子元素: Array.from(element.children).slice(0, 6)
        .map((child) => outline(child, depth + 1))
        .filter(Boolean)
    };
  };

  const pager = document.querySelector('input.page_input');

  console.log(JSON.stringify({
    地址: location.pathname,

    // 一、这一页有多少条、翻不翻页。
    分页: {
      条数: document.querySelectorAll('#Main div[id^="n_"]').length,
      'page_input 的 max': pager ? pager.getAttribute('max') : null
    },

    // 二、一条提醒的完整轮廓：时间在哪个元素的 title 上、正文在哪一格。
    一条提醒: outline(document.querySelector('#Main div[id^="n_"]'), 0),

    // 三、每日奖励那颗按钮点下去做什么，以及领过之后页面怎么说。
    奖励: Array.from(document.querySelectorAll('#Main input[type="button"], #Main a.super'))
      .slice(0, 3)
      .map((element) => ({
        标签: element.tagName.toLowerCase(),
        // 按钮上的字是界面文案，解析器要靠它认「今天领过了」，照原样报。
        按钮文字: element.value || element.textContent.trim() || null,
        onclick: mask(element.getAttribute('onclick')),
        href: element.getAttribute('href') ? mask(element.getAttribute('href')) : undefined
      })),
    // 连续签到的天数写在哪儿：整页里带「天」的那几句（数字已遮）。
    含天数的句子: Array.from(document.querySelectorAll('#Main .cell, #Main .inner'))
      .map((cell) => cell.textContent.trim())
      .filter((text) => text.includes('天') && text.length < 60)
      .slice(0, 3)
      .map(mask)
  }, null, 2));
})();
