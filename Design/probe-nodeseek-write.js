// 抓 NodeSeek 一次真实写请求（回复/收藏/表态）的请求头。
//
// 值做了脱敏：只有明显是常量的（application/json、simple-token 之类）原样打印，
// 其余一律只报长度和形态。会额外告诉你某个头的值是不是等于 localStorage 里的
// csrf_token / security_token —— 只报「是/否」，不打印值本身。
//
// 网页发完回复会自动刷新，控制台会被冲掉，所以结果先存进 localStorage，
// 刷新后再粘一次就打出来。存进去的是**已经脱敏的那份描述**，不是原始值。
//
// 用法：
//   1. 在已登录的 nodeseek.com 帖子页粘贴运行；
//   2. 在网页上正常发一条回复（会真的发出去）；
//   3. 页面自动刷新之后，把这段**再粘一次** —— 它会先把上一次抓到的打出来；
//   4. 贴回来之后运行 `localStorage.removeItem("snga-write-probe")` 清掉。
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

  const SAVED = 'snga-write-probe';

  // 上一次抓到的先打出来 —— 发完回复页面会自动刷新，控制台留不住东西。
  const previous = store(SAVED);
  if (previous) {
    console.log('【上一次抓到的写请求】\n' + previous);
    console.log('贴回去之后清掉它：localStorage.removeItem("' + SAVED + '")');
  }

  const report = async (label, method, url, headers, body) => {
    const rows = {};
    headers.forEach((value, name) => { rows[name] = describe(name, value); });
    let bodyKeys = null;
    try { bodyKeys = Object.keys(JSON.parse(body || '{}')); } catch (_) {}
    const text = JSON.stringify({
      方法: method,
      地址: url,
      请求体字段: bodyKeys,
      请求头: rows
    }, null, 2);
    console.log(label, text);
    // 页面马上就要刷新，写下来才带得走。
    try { localStorage.setItem(SAVED, text); } catch (_) {}
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
  // 万一那条请求走的是 XMLHttpRequest 而不是 fetch，上面的钩子抓不到。
  const openOriginal = XMLHttpRequest.prototype.open;
  const setHeaderOriginal = XMLHttpRequest.prototype.setRequestHeader;
  const sendOriginal = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__probe = { method: String(method).toUpperCase(), url: String(url), headers: new Map() };
    return openOriginal.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this.__probe) this.__probe.headers.set(String(name), String(value));
    return setHeaderOriginal.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const probe = this.__probe;
    if (probe && probe.method !== 'GET'
        && /\/api\/(content|statistics|notification)\//.test(probe.url)) {
      report('【写请求·XHR】', probe.method, probe.url, probe.headers,
             typeof body === 'string' ? body : '');
    }
    return sendOriginal.apply(this, arguments);
  };

  console.log('钩子已挂上（fetch 和 XHR 都挂了）。现在在网页上正常发一条回复 —— '
            + '发完页面会自动刷新，刷新后把这段再粘一次，就能看到抓到的东西。');
})();
