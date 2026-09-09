// 摸清 V2EX 登录之后才画出来的那三样：收藏、提醒、每日登录奖励。
//
// 这三样匿名一律 302 到登录页，连标记都看不见，所以适配器一样都没接
// （`.topicFavorites`、`.checkIn` 都关着）。要接就得先有这份结构。
//
// 脚本只报**结构**：链接的路径模板（数字一律换成占位符）、查询参数的**名字**、
// 列表项的类名和条数。**不打印任何参数的值，也不打印任何正文。**
//
// 用法：登录之后依次在这三个地址上粘贴运行，各把结果贴回来：
//   1. 任意主题页（收藏 / 取消收藏那个链接在抬头下面）
//   2. https://www.v2ex.com/my/topics
//   3. https://www.v2ex.com/notifications
//   4. https://www.v2ex.com/mission/daily
(() => {
  const template = (href) => {
    try {
      const url = new URL(href, location.origin);
      return {
        路径模板: url.pathname.replace(/\d+/g, '{数字}'),
        参数名: Array.from(url.searchParams.keys())
      };
    } catch (_) {
      return null;
    }
  };

  const links = (pattern) => Array.from(document.querySelectorAll('a[href]'))
    .map((a) => a.getAttribute('href'))
    .filter((href) => pattern.test(href))
    .map(template)
    .filter(Boolean)
    .slice(0, 4);

  const countOf = (selector) => document.querySelectorAll(selector).length;

  console.log(JSON.stringify({
    地址: location.pathname,
    收藏链接: links(/\/(un)?favorite\//),
    每日奖励链接: links(/\/mission\//),
    // 列表页各用什么模板画每一条。收藏页大概率和 /recent 同一套（div.cell.item），
    // 提醒页是另一套；要接哪一个，先看这里的条数对不对得上。
    列表模板: {
      'div.cell.item': countOf('div.cell.item'),
      'div.cell[id^=n_]': countOf('div[id^="n_"]'),
      'div.dock_area': countOf('div.dock_area'),
      'div.cell': countOf('div.cell')
    },
    // 收藏的节点长什么样。应用现在按 `.fav-node` / `.fav-node-name` 认 ——
    // 那两个类名是从站点自己的 combo.css 里读出来的，但**没有在真页面上验过**。
    // 这几个数就是去验它的：`.fav-node` 的条数应当等于你收藏的节点数。
    节点收藏页: {
        'a.fav-node': countOf('a.fav-node'),
        '.fav-node-name': countOf('.fav-node-name'),
        'a.grid_item': countOf('a.grid_item'),
        '#Main 里指向 /go/ 的链接': Array.from(
            document.querySelectorAll('#Main a[href^="/go/"]')
        ).length,
        一条的类名: (() => {
            const node = document.querySelector('#Main a[href^="/go/"]');
            if (!node) return null;
            return {
                标签: node.tagName.toLowerCase(),
                类名: node.className || null,
                子元素类名: Array.from(node.querySelectorAll('[class]'))
                    .slice(0, 4)
                    .map((child) => child.className)
            };
        })()
    },
    // 提醒每条挂一个删除按钮，`deleteNotification(id, token)` 的第二个参数就是 once。
    提醒项: Array.from(document.querySelectorAll('div[id^="n_"]'))
      .slice(0, 2)
      .map((element) => ({
        id模板: element.id.replace(/\d+/, '{提醒编号}'),
        子元素类名: Array.from(element.querySelectorAll('[class]'))
          .slice(0, 8)
          .map((child) => child.className)
      })),
    // 每日奖励那一页上的按钮：它是个链接还是个表单？
    奖励按钮: Array.from(document.querySelectorAll('#Main input, #Main .super.button'))
      .slice(0, 3)
      .map((element) => ({
        标签: element.tagName.toLowerCase(),
        类型: element.type || null,
        '有 onclick': Boolean(element.getAttribute('onclick'))
      }))
  }, null, 2));
})();
