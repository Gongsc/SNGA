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

  const original = window.fetch;
  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : input?.url ?? '';
    const method = (init?.method || (typeof input === 'object' && input?.method) || 'GET').toUpperCase();
    const response = await original.apply(this, arguments);
    if (/\/api\/vote\//.test(url)) {
      try {
        const json = await response.clone().json();
        report(method === 'GET' ? '【投票信息】' : '【投票提交】', url, method, response.status, json);
      } catch (_) {
        console.log('【投票】', url, method, response.status, '（不是 JSON）');
      }
    }
    return response;
  };
  console.log('钩子已挂上。现在站内点进一个带投票的帖子（别刷新）。');
})();
