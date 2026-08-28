// 抓 NodeSeek 一次真实写请求（回复/收藏/表态）的请求头。
//
// 值做了脱敏：只有明显是常量的（application/json、simple-token 之类）原样打印，
// 其余一律只报长度和形态。会额外告诉你某个头的值是不是等于 localStorage 里的
// csrf_token / security_token —— 只报「是/否」，不打印值本身。
//
// 用法：
//   1. 在已登录的 nodeseek.com 帖子页粘贴运行；
//   2. 在网页上正常发一条回复（会真的发出去）；
//   3. 把控制台打出来的那段贴回来。
(() => {
  const store = (key) => { try { return localStorage.getItem(key); } catch (_) { return null; } };
  const known = {
    csrf_token: store('csrf_token'),
    security_token: store('security_token')
  };
  console.log('localStorage 里有没有：', Object.fromEntries(
    Object.entries(known).map(([k, v]) => [k, v ? '有' : '无'])
  ));

  const safe = new Set(['content-type', 'accept', 'accept-language', 'x-requested-with',
                        'sec-fetch-dest', 'sec-fetch-mode', 'sec-fetch-site', 'priority']);
  const describe = (name, value) => {
    const lower = name.toLowerCase();
    if (safe.has(lower)) return value;
    for (const [key, stored] of Object.entries(known)) {
      if (stored && value === stored) return `＝localStorage.${key}（长度 ${value.length}）`;
    }
    if (/^[0-9a-f]{32,}$/i.test(value)) return `十六进制串，长度 ${value.length}`;
    if (value.length <= 24) return value;          // 短的多半是常量，看得见才有用
    return `长度 ${value.length}`;
  };

  const report = async (label, method, url, headers, body) => {
    const rows = {};
    headers.forEach((value, name) => { rows[name] = describe(name, value); });
    let bodyKeys = null;
    try { bodyKeys = Object.keys(JSON.parse(body || '{}')); } catch (_) {}
    console.log(label, JSON.stringify({
      方法: method,
      地址: url,
      请求体字段: bodyKeys,
      请求头: rows
    }, null, 2));
  };

  const original = window.fetch;
  window.fetch = async function (input, init) {
    const request = new Request(input, init);
    const url = request.url;
    if (/\/api\/(content|statistics|notification)\//.test(url) && request.method !== 'GET') {
      try {
        await report('【写请求】', request.method, url, request.headers,
                     await request.clone().text());
      } catch (e) { console.log('【写请求】读不出来：', e.message); }
    }
    return original.apply(this, arguments);
  };
  console.log('钩子已挂上。现在在网页上正常发一条回复（别刷新）。');
})();
