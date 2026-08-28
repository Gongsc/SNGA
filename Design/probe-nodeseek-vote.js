// 取 NodeSeek 投票接口的字段形状。
//
// 为什么要挂钩子而不是直接 fetch：/api/vote/info/{id} 对手写的请求一律回 403
// （匿名下试过 4 个 id、加过各种头，全是 403），只有页面自己发的那次是 200。
// 所以这里挂住 fetch，等页面自己去拉。
//
// 只输出字段名、类型和条数，不输出任何字段的值 —— 选项文字、票数、你投了哪个
// 一律不会出现在结果里。
//
// 用法：
//   1. 在 https://www.nodeseek.com 的**任意帖子页**（已登录）粘贴运行；
//   2. 然后在站内点进一个带投票的帖子（例如 post-895695-1）；
//      要点进去，不要刷新 —— 刷新会把钩子清掉。
//   3. 控制台会打出形状。想看投票提交的接口，就在那个帖子里投一票
//      （会真的投出去，自己决定）。
//
// 提交那一半现在最要紧的是**请求体**：响应只有 {success:true}，从它看不出
// 这个接口要什么。上一版只认字符串 body，别的类型被静默跳过，所以第一次跑
// 什么都没打出来。这一版每种 body 都认，走 XMLHttpRequest 的路也管，
// 认不出来的也照实说它是什么类型。
(() => {
  const shape = (o, path = '', out = new Map()) => {
    if (Array.isArray(o)) { if (o.length) shape(o[0], path + '[]', out); return out; }
    if (o && typeof o === 'object') {
      for (const k of Object.keys(o)) {
        const p = path ? `${path}.${k}` : k;
        const v = o[k];
        if (v && typeof v === 'object') shape(v, p, out);
        else out.set(p, v === null ? 'null' : typeof v);
      }
    }
    return out;
  };
  const report = (label, url, method, status, json) => {
    const listKey = json && Object.keys(json).find(k => Array.isArray(json[k]));
    console.log(label, JSON.stringify({
      接口: url.replace(/\/\d+$/, '/{id}'),
      方法: method,
      http: status,
      success: json && json.success,
      条数: listKey ? json[listKey].length : 0,
      列字段: listKey || '(无数组)',
      字段: [...shape(json).entries()].map(([k, t]) => `${k}:${t}`).sort()
    }, null, 2));
  };

  // 读出请求体的形状，不管它是什么类型。
  //
  // 上一版只认字符串 body，别的类型（URLSearchParams、FormData、Request 对象）
  // 直接被跳过，而且一声不吭 —— 所以第一次跑什么都没打出来。现在每一种都认，
  // 认不出来的也照实说它是什么。
  const describeBody = async (input, init) => {
    let body = init?.body;
    // 用 new Request(url, {body}) 发的请求，body 在 input 上，而且是个流。
    if (body == null && input && typeof input === 'object' && typeof input.clone === 'function') {
      try { body = await input.clone().text(); } catch (_) { return ['（Request 的 body 读不出来）']; }
    }
    if (body == null) return ['（没有请求体）'];

    const keysAndTypes = (obj) => Object.entries(obj).map(([k, v]) =>
      `${k} : ${Array.isArray(v) ? '数组，长度 ' + v.length : typeof v}`);

    if (typeof body === 'string') {
      try {
        return ['类型：JSON 字符串', ...keysAndTypes(JSON.parse(body))];
      } catch (_) {
        // 可能是 a=1&b=2 这种
        if (/^[^=&]+=[^&]*(&|$)/.test(body)) {
          return ['类型：表单编码字符串',
            ...[...new URLSearchParams(body).keys()].map(k => `${k} : string`)];
        }
        return ['类型：普通字符串，长度 ' + body.length];
      }
    }
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      return ['类型：URLSearchParams', ...[...body.keys()].map(k => `${k} : string`)];
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      return ['类型：FormData', ...[...body.keys()].map(k => `${k} : ?`)];
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) {
      try {
        const text = await body.text();
        return ['类型：Blob', ...keysAndTypes(JSON.parse(text))];
      } catch (_) { return ['类型：Blob（内容不是 JSON）']; }
    }
    return ['类型：' + Object.prototype.toString.call(body) + '（认不出来）'];
  };

  const original = window.fetch;
  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : input?.url ?? '';
    const method = (init?.method || (typeof input === 'object' && input?.method) || 'GET').toUpperCase();
    const isVote = /\/api\/vote\//.test(url);

    // 请求体要在发出去之前读，读完了流就没了。
    const bodyShape = (isVote && method !== 'GET') ? await describeBody(input, init) : null;

    const response = await original.apply(this, arguments);
    if (isVote) {
      if (bodyShape) {
        console.log('【投票提交·请求体形状】', url, '\n' + bodyShape.join('\n'));
      }
      try {
        const json = await response.clone().json();
        report(method === 'GET' ? '【投票信息】' : '【投票提交·响应】', url, method, response.status, json);
      } catch (_) {
        console.log('【投票】', url, method, response.status, '（不是 JSON）');
      }
    }
    return response;
  };

  // 站点也可能走 XMLHttpRequest。上一版没管这条路 —— 如果 fetch 那边一直没动静，
  // 但你确实投出去了，那就是走的这里。
  const openOriginal = XMLHttpRequest.prototype.open;
  const sendOriginal = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__probe = { method: String(method).toUpperCase(), url: String(url) };
    return openOriginal.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    if (this.__probe && /\/api\/vote\//.test(this.__probe.url)) {
      describeBody(null, { body }).then(shapeLines => {
        console.log('【投票·XHR 请求体形状】', this.__probe.method, this.__probe.url,
          '\n' + shapeLines.join('\n'));
      });
      this.addEventListener('load', () => {
        console.log('【投票·XHR 响应】', this.status, String(this.responseText).slice(0, 300));
      });
    }
    return sendOriginal.apply(this, arguments);
  };

  console.log('钩子已挂上。现在站内点进一个带投票的帖子（别刷新）。');
})();
