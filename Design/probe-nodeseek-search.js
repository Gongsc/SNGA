// 摸清 NodeSeek 登录后的搜索：结果页长什么样，用户搜索接口返回什么。
//
// 只输出结构：元素类名、条数、字段名。不输出任何搜索结果的内容。
//
// 用法：
//   1. 在已登录的 nodeseek.com 用顶部搜索框搜一个帖子关键词（会跳到 /search?q=…）；
//   2. 在**结果页**上粘贴运行这一段；
//   3. 把输出贴回来。
(async () => {
  const out = { 当前路径: location.pathname + location.search };

  // 帖子结果是不是和版面列表同一套标记
  const counts = {};
  for (const selector of ['.post-list-item', '.post-title', '.post-info',
                          '[class*="result"]', '[class*="search"]']) {
    counts[selector] = document.querySelectorAll(selector).length;
  }
  out.结果页元素 = counts;

  // 认不出来的话，把主区域里重复出现的类名列出来，好认出「一条结果」长什么样
  if (!document.querySelector('.post-list-item')) {
    const tally = {};
    for (const el of document.querySelectorAll('div,li,article')) {
      const name = (el.className || '').toString().trim();
      if (name && name.length < 60) tally[name] = (tally[name] || 0) + 1;
    }
    out.重复出现的类名 = Object.entries(tally)
      .filter(([, n]) => n >= 3).sort((a, b) => b[1] - a[1]).slice(0, 12);
  }

  // 分页控件
  out.分页 = document.querySelectorAll('.nsk-pager .pager-pos').length;

  // 用户搜索的接口
  try {
    const r = await fetch('/api/account/find/a', { headers: { Accept: 'application/json' } });
    const j = await r.json();
    const names = new Set();
    (function walk(o, p) {
      if (Array.isArray(o)) { if (o.length) walk(o[0], p + '[]'); return; }
      if (o && typeof o === 'object') {
        for (const k in o) { const np = p ? p + '.' + k : k;
          (o[k] && typeof o[k] === 'object') ? walk(o[k], np) : names.add(np); }
      }
    })(j, '');
    out.用户搜索 = { http: r.status, success: j.success, 字段: [...names].sort() };
  } catch (e) { out.用户搜索 = '请求失败：' + e.message; }

  console.log(JSON.stringify(out, null, 2));
})();
