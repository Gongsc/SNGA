// 找出 NodeSeek 写请求用的 csrf-token 存在哪儿。
//
// **只报形状，不打印任何值** —— 长度、是不是 JSON、有哪些字段、哪些字段的长度是 16。
// cookie 只报名字。
//
// 用法：在已登录的 nodeseek.com 页面粘贴运行，把输出贴回来即可。
(() => {
  const shapeOf = (raw) => {
    if (raw == null) return '没有';
    const out = { 长度: raw.length };
    try {
      const parsed = JSON.parse(raw);
      out.是JSON = true;
      if (parsed && typeof parsed === 'object') {
        out.字段 = Object.fromEntries(Object.entries(parsed).map(([k, v]) => [
          k, typeof v === 'string' ? `字符串，长度 ${v.length}` : typeof v
        ]));
      }
    } catch (_) {
      out.是JSON = false;
      // 写请求带的那个令牌是 16 位字母数字。这里只回答「像不像」。
      out.像16位令牌 = /^[A-Za-z0-9]{16}$/.test(raw);
    }
    return out;
  };

  const store = {};
  try {
    for (const key of Object.keys(localStorage)) store[key] = shapeOf(localStorage.getItem(key));
  } catch (e) { store.读取失败 = e.message; }

  let cookieNames = [];
  try {
    cookieNames = document.cookie.split(';').map(s => s.trim().split('=')[0]).filter(Boolean);
  } catch (_) {}

  console.log(JSON.stringify({
    localStorage: store,
    // HttpOnly 的 cookie 这里看不见，看得见的才有可能被 JS 读去当请求头。
    可被脚本读到的cookie名: cookieNames,
    页面里有没有内嵌的令牌: /csrf/i.test(document.documentElement.innerHTML)
  }, null, 2));
})();
