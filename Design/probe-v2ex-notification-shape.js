// 把一条提醒的**结构**原样打出来，文字全部遮掉。
//
// 前两轮的探针报的是「有哪些类名、各多长」，据此只能猜每一格装的是什么 ——
// 比如 `span.snow` 11 个字、`a.node[href="#;"]` 2 个字，看着像「相对时间」和
// 「删除」，但那是猜的。猜错的后果是解析出来的正文里混进一个「删除」。
//
// 这一份直接给 `outerHTML`，但**每一段文字都换成 `文字×N`**，数字和长串换成
// `{值}` —— 结构一目了然，而别人写给你的话一个字都不出去。
//
// 用法：登录之后在 https://www.v2ex.com/notifications 粘贴运行，把结果贴回来。
(() => {
  const maskValue = (text) => String(text || '')
    .replace(/\d{2,}/g, '{值}')
    .replace(/[A-Za-z0-9_-]{12,}/g, '{值}');

  /// 深拷一份，把里面所有文字节点换成「文字×长度」，属性值里的数字也遮掉。
  const masked = (node) => {
    const copy = node.cloneNode(true);
    const walker = document.createTreeWalker(copy, NodeFilter.SHOW_TEXT);
    const texts = [];
    while (walker.nextNode()) texts.push(walker.currentNode);
    for (const text of texts) {
      const length = text.textContent.trim().length;
      text.textContent = length > 0 ? `文字×${length}` : '';
    }
    for (const element of [copy, ...copy.querySelectorAll('*')]) {
      for (const attribute of Array.from(element.attributes || [])) {
        element.setAttribute(attribute.name, maskValue(attribute.value));
      }
    }
    return copy.outerHTML;
  };

  const items = document.querySelectorAll('#Main div[id^="n_"]');
  const main = document.querySelector('#Main');

  console.log(JSON.stringify({
    条数: items.length,
    第一条的结构: items[0] ? masked(items[0]) : null,
    // 第二条只看开头几百字，够比对「两条之间怎么断」。
    第二条的开头: items[1] ? masked(items[1]).slice(0, 400) : null,
    // 翻页 / 加载更多的线索藏在列表后面那一截里。
    列表之后: main ? masked(main).slice(-600) : null
  }, null, 2));
})();
