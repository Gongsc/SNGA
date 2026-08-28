// 看清 NodeSeek 的 csrf_token / security_token 是什么结构。
//
// 写请求带的 `csrf-token` 头是一个 16 位字母数字串，而 localStorage 里的
// csrf_token 长 54 —— 那 16 位很可能是它的一段。这里只报**结构**：
// 用到了哪些非字母数字字符、按它们切开后每段多长、每段是不是纯字母数字。
//
// **不打印任何值，也不打印任何一段的内容。**
//
// 用法：在已登录的 nodeseek.com 页面粘贴运行，把输出贴回来。
(() => {
  const structure = (raw) => {
    if (raw == null) return '没有';
    const punctuation = [...new Set(raw.replace(/[A-Za-z0-9]/g, ''))];
    const out = {
      长度: raw.length,
      出现的非字母数字字符: punctuation,
      前16位是纯字母数字: /^[A-Za-z0-9]{16}/.test(raw)
    };
    // 按出现的每一种分隔符切开，报各段长度。
    for (const mark of punctuation) {
      const parts = raw.split(mark);
      if (parts.length > 1) {
        out['按 ' + JSON.stringify(mark) + ' 切开'] = parts.map(p => ({
          长度: p.length,
          纯字母数字: /^[A-Za-z0-9]*$/.test(p)
        }));
      }
    }
    return out;
  };

  const read = (key) => { try { return localStorage.getItem(key); } catch (_) { return null; } };

  // cookie 只报名字和长度，看看有没有哪个正好 16 位。
  let cookies = {};
  try {
    for (const pair of document.cookie.split(';')) {
      const index = pair.indexOf('=');
      if (index < 0) continue;
      const name = pair.slice(0, index).trim();
      const value = pair.slice(index + 1);
      cookies[name] = { 长度: value.length, 是16位字母数字: /^[A-Za-z0-9]{16}$/.test(value) };
    }
  } catch (_) {}

  console.log(JSON.stringify({
    csrf_token: structure(read('csrf_token')),
    security_token: structure(read('security_token')),
    cookie: cookies
  }, null, 2));
})();
