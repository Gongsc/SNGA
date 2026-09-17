// 签到状态检测：摸清 /api/attendance/board 到底怎么说「我今天签过了」。
//
// 在 https://www.nodeseek.com 任意页面（**已登录，并且今天已经签过到**）的
// 浏览器控制台里整段粘贴运行。
//
// 只输出类型、有无、条数和几个与身份无关的数（榜单名次、站点第几天、当页条数），
// **不输出 member_id，也不输出任何时间戳原文** —— 时间只以「是不是今天」的形式
// 出现。输出可以整段贴回来。
(async () => {
  const typeOf = v =>
    v === null ? 'null'
    : Array.isArray(v) ? `array(${v.length})`
    : typeof v;

  // 站点的「今天」按北京时间算（见 CheckInPolicy）。
  const beijingDay = iso => {
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return null;
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit'
    }).format(new Date(t));
  };
  const today = beijingDay(new Date().toISOString());

  const look = async page => {
    const url = `/api/attendance/board?page=${page}`;
    try {
      const r = await fetch(url, {
        cache: 'reload',
        headers: { Accept: 'application/json, text/plain, */*' }
      });
      const text = await r.text();
      let j;
      try { j = JSON.parse(text); }
      catch { return { http: r.status, '不是JSON': true, 开头: text.slice(0, 40) }; }

      const rec = j.record;
      const out = {
        http: r.status,
        顶层字段: Object.keys(j).sort(),
        success字段: 'success' in j ? j.success : '(没有这个字段)',
        message: typeof j.message === 'string' ? j.message : '(没有)',
        list类型: typeOf(j.list),
        order: j.order,
        total: j.total,
        record类型: typeOf(rec)
      };
      if (rec && typeof rec === 'object' && !Array.isArray(rec)) {
        out.record字段 = Object.keys(rec).sort();
        out['record.day_id'] = rec.day_id;
        out['record.gain'] = rec.gain;
        out['record.day_id 等于顶层 total 吗'] = rec.day_id === j.total;
        out['record.created_at 是今天吗（北京时间）'] =
          'created_at' in rec ? beijingDay(rec.created_at) === today : '(没有这个字段)';
      }
      if (Array.isArray(j.list) && j.list.length) {
        out.list每条的字段 = Object.keys(j.list[0]).sort();
      }
      return out;
    } catch (e) {
      return { '请求失败': e.message };
    }
  };

  const report = { '今天（北京）': today };
  for (const page of [1, 2]) {
    report[`page=${page}`] = await look(page);
    await new Promise(r => setTimeout(r, 600));
  }

  console.log(JSON.stringify(report, null, 2));
  return [
    '把上面整段贴回来。里面没有 member_id，也没有任何时间戳原文。',
    '要点：record 在不在、是什么类型、page=2 上还在不在。'
  ].join('\n');
})();
