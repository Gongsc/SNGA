// 在 https://www.nodeseek.com 任意页面（已登录）的浏览器控制台里整段粘贴运行。
//
// 只输出字段名、类型和条数，不输出任何字段的值 —— 私信正文、收件人、
// cookie 一律不会出现在结果里。可以放心把输出整段贴回来。
(async () => {
  const shape = (o, path = '', out = new Map()) => {
    if (Array.isArray(o)) {
      if (o.length) shape(o[0], path + '[]', out);
      return out;
    }
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

  const endpoints = {
    '私信列表':   '/api/notification/message/list?page=1',
    '@我':        '/api/notification/at-me/list?page=1',
    '回复我':     '/api/notification/reply-to-me/list?page=1',
    '未读数':     '/api/notification/unread-count',
    '收藏列表':   '/api/statistics/list-collection?page=1',
    '签到榜':     '/api/attendance/board?page=1',
    '我的主题':   '/api/content/list-discussions?uid=__ME__&page=1'
  };

  // 「我是谁」从页面自己的状态里取，不需要你手动填。
  let me = '';
  try {
    const link = document.querySelector('.user-card a[href^="/space/"]');
    me = (link?.getAttribute('href').match(/\/space\/(\d+)/) || [])[1] || '';
  } catch (_) {}
  console.log(me ? '已认出当前账号（编号不打印）' : '没认出当前账号，我的主题那条会跳过');

  const report = {};
  for (const [name, path] of Object.entries(endpoints)) {
    const url = path.replace('__ME__', me);
    if (url.includes('__ME__') || (path.includes('__ME__') && !me)) { report[name] = '跳过'; continue; }
    try {
      const r = await fetch(url, { cache: 'reload', headers: { Accept: 'application/json, text/plain, */*' } });
      const j = await r.json();
      const listKey = Object.keys(j).find(k => Array.isArray(j[k]));
      report[name] = {
        http: r.status,
        success: j.success,
        条数: listKey ? j[listKey].length : 0,
        列字段: listKey || '(无数组)',
        字段: [...shape(j).entries()].map(([k, t]) => `${k}:${t}`).sort()
      };
    } catch (e) {
      report[name] = '请求失败：' + e.message;
    }
    await new Promise(r => setTimeout(r, 600));
  }
  console.log(JSON.stringify(report, null, 2));
  return '上面这段整个复制回去即可 —— 里面没有任何字段的值。';
})();
