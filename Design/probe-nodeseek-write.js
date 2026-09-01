// 找出 NodeSeek 写请求里那个 `csrf-token` 头的值是从哪来的。
//
// 发回复的那一刻做两件事：
//   1. 把那个头的值和每一个 localStorage 值、每一个 cookie 值比对 ——
//      **只报是哪个键（以及是整体相等还是包含在里面），绝不打印值本身**；
//   2. 记下这之前发生过的请求（只记方法和路径），万一它是临时去某个接口取的。
//
// 网页发完回复会自动刷新，所以结果存进 localStorage，刷新后再粘一次就打出来。
//
// 用法：
//   1. 在已登录的帖子页粘贴运行；
//   2. 在网页上正常发一条回复；
//   3. 刷新之后把这段**再粘一次**；
//   4. 贴回来后清掉：localStorage.removeItem("snga-write-probe")
(() => {
  const SAVED = 'snga-write-probe';
  const read = (key) => { try { return localStorage.getItem(key); } catch (_) { return null; } };

  const previous = read(SAVED);
  if (previous) {
    console.log('【上一次抓到的】\n' + previous);
    console.log('贴回去之后清掉：localStorage.removeItem("' + SAVED + '")');
  }

  // 最近发生过的请求，只留方法和路径。
  const recent = [];
  const note = (method, url) => {
    try { recent.push(method + ' ' + new URL(url, location.origin).pathname); } catch (_) {}
    if (recent.length > 40) recent.shift();
  };

  /// 这个值在哪儿见过？只回答键名和关系，不回答值。
  const locate = (value) => {
    const hits = [];
    if (!value) return hits;
    try {
      for (const key of Object.keys(localStorage)) {
        if (key === SAVED) continue;
        const stored = localStorage.getItem(key) || '';
        if (stored === value) hits.push(`localStorage.${key}（整体相等）`);
        else if (stored.includes(value)) hits.push(`localStorage.${key}（包含）`);
      }
    } catch (_) {}
    try {
      for (const pair of document.cookie.split(';')) {
        const index = pair.indexOf('=');
        if (index < 0) continue;
        const name = pair.slice(0, index).trim();
        const stored = pair.slice(index + 1);
        if (stored === value) hits.push(`cookie.${name}（整体相等）`);
        else if (stored.includes(value)) hits.push(`cookie.${name}（包含）`);
      }
    } catch (_) {}
    return hits;
  };

  const report = (method, url, headers, body) => {
    const names = [];
    let token = null;
    headers.forEach((value, name) => {
      names.push(name);
      if (name.toLowerCase() === 'csrf-token') token = value;
    });
    let bodyKeys = null;
    try { bodyKeys = Object.keys(JSON.parse(body || '{}')); } catch (_) {}
    const text = JSON.stringify({
      方法: method,
      路径: (() => { try { return new URL(url, location.origin).pathname; } catch (_) { return url; } })(),
      请求头名: names,
      请求体字段: bodyKeys,
      'csrf-token 的长度': token ? token.length : null,
      'csrf-token 出现在哪儿': token ? (locate(token).length ? locate(token) : ['哪儿都没找到']) : null,
      这之前发生的请求: recent.slice(-25)
    }, null, 2);
    console.log('【写请求】', text);
    try { localStorage.setItem(SAVED, text); } catch (_) {}
  };

  const original = window.fetch;
  window.fetch = async function (input, init) {
    const request = new Request(input, init);
    note(request.method, request.url);
    if (request.method !== 'GET' && /\/api\//.test(request.url)) {
      try { report(request.method, request.url, request.headers, await request.clone().text()); }
      catch (e) { console.log('【写请求】读不出来：', e.message); }
    }
    return original.apply(this, arguments);
  };

  const openOriginal = XMLHttpRequest.prototype.open;
  const setHeaderOriginal = XMLHttpRequest.prototype.setRequestHeader;
  const sendOriginal = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__probe = { method: String(method).toUpperCase(), url: String(url), headers: new Map() };
    note(this.__probe.method, this.__probe.url);
    return openOriginal.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this.__probe) this.__probe.headers.set(String(name), String(value));
    return setHeaderOriginal.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const probe = this.__probe;
    if (probe && probe.method !== 'GET' && /\/api\//.test(probe.url)) {
      report(probe.method, probe.url, probe.headers, typeof body === 'string' ? body : '');
    }
    return sendOriginal.apply(this, arguments);
  };

  console.log('钩子已挂上。现在在网页上正常发一条回复，刷新后把这段再粘一次。');
})();
