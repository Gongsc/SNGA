// 确认登录之后「我是谁」该从哪儿读。
//
// V2EX 不把会员编号写进 Cookie（`A2` 是签名过的会话串，`PB3_SESSION` 里编的是来访
// IP），也没有 who-am-I 接口 —— `/api/members/show.json` 只按编号或用户名查别人。
// 所以只能从登录后的页面上读，适配器排了三条路：
//
//   1. `memberId` 这个 JS 全局（站点自己的草稿功能拿它当键）
//   2. 顶栏头像地址里的编号（`/avatar/205f/180e/600305_normal.png`）
//   3. 头像元素上的 `data-uid`
//
// 用 gravatar 当头像的会员走不通第 2 条，所以第 3 条不是多余的。这个脚本报的是
// **哪几条路走得通**，不报编号本身。
//
// 用法：登录之后在首页（https://www.v2ex.com/ ）粘贴运行，把结果贴回来。
(() => {
  const numeric = (value) => value !== null && value !== undefined && /^\d+$/.test(String(value));

  const fromAvatar = (value) => {
    const match = (value || '').match(/\/avatar\/[^"'\s]*?(\d+)_[a-z]+\./i);
    return match ? match[1] : null;
  };

  const selectors = ['#menu-entry img', '#Top img.avatar', '.tools img', '#Rightbar img.avatar'];
  const routes = selectors.map((selector) => {
    const images = Array.from(document.querySelectorAll(selector));
    return {
      选择器: selector,
      命中元素数: images.length,
      '有 data-uid': images.some((image) => numeric(image.getAttribute('data-uid'))),
      '头像地址里有编号': images.some((image) => numeric(fromAvatar(image.getAttribute('src'))))
    };
  });

  console.log(JSON.stringify({
    'memberId 全局存在': typeof memberId !== 'undefined' && numeric(memberId),
    各选择器: routes,
    // 适配器实际跑的就是这一段，这里只问它成不成，不问它算出了几号。
    '当前脚本能不能读出编号': (() => {
      if (typeof memberId !== 'undefined' && memberId) return true;
      for (const image of document.querySelectorAll(selectors.join(', '))) {
        if (numeric(image.getAttribute('data-uid'))) return true;
        if (numeric(fromAvatar(image.getAttribute('src')))) return true;
      }
      return false;
    })()
  }, null, 2));
})();
