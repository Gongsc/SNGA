// 签到榜：为什么应用带着 6 个 cookie、拿回 200 和一整张榜，`record` 还是 null。
//
// 在 https://www.nodeseek.com 任意页面（**已登录，并且今天已经签过到**）的浏览器
// 控制台里整段粘贴运行。
//
// 站点自己那张 /board 页面调这个接口用的是一个光秃秃的 fetch()，一个额外的头都不带；
// 应用为了过 Cloudflare 和 CSRF 多带了几个。这一段就是把那几个头一个一个加上去，
// 看是哪个让站点不再认人。
//
// 只输出 record / order 的「有没有、是什么类型」和榜单条数，**不输出任何字段的值**，
// 也不改变任何状态（全是 GET）。输出可以整段贴回来。
(async () => {
  const URL_ = '/api/attendance/board?page=1';

  // 浏览器不允许 JS 设 User-Agent / Referer / Sec-Fetch-*（它们是受保护的头），
  // 所以这里只能试应用额外加的、JS 设得了的那几个。x-dynamic-sign 是头号嫌疑：
  // 站点自己这条路根本不带它，而应用每个 JSON 请求都带。
  const cases = {
    '① 光秃秃（和站点页面一样）': {},
    '② 只加 Accept': { Accept: 'application/json, text/plain, */*' },
    '③ 只加 X-Requested-With': { 'X-Requested-With': 'XMLHttpRequest' },
    '④ 只加 x-dynamic-sign（值是乱填的 40 位）': { 'x-dynamic-sign': 'a'.repeat(40) },
    '⑤ 应用现在这一套': {
      Accept: 'application/json, text/plain, */*',
      'X-Requested-With': 'XMLHttpRequest',
      'x-dynamic-sign': 'a'.repeat(40)
    }
  };

  const report = {};
  for (const [name, headers] of Object.entries(cases)) {
    try {
      const r = await fetch(URL_, { cache: 'reload', headers });
      const j = await r.json();
      report[name] = {
        http: r.status,
        list条数: Array.isArray(j.list) ? j.list.length : `(${typeof j.list})`,
        order: j.order === null ? 'null' : typeof j.order,
        record: j.record === null ? 'null' : typeof j.record,
        '认出我了吗': j.record !== null && j.record !== undefined
      };
    } catch (e) {
      report[name] = { '请求失败': e.message };
    }
    await new Promise(r => setTimeout(r, 600));
  }

  console.log(JSON.stringify(report, null, 2));
  return [
    '把上面整段贴回来。里面没有任何字段的值。',
    '要看的是：哪一行开始「认出我了吗」变成 false —— 那个头就是元凶。',
    '如果每一行都是 true，那问题不在这几个头上，我再换方向。'
  ].join('\n');
})();
