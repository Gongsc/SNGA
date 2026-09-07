// 弄清 NGA 的签名档在结构化响应里叫什么字段。
//
// 楼层签名在网页版是 `.postsignC > #postsigncontent{楼层}`，但客户端走的是
// `read.php?...&__output=11` 那份 JSON，签名藏在 `__U` 的用户记录里 —— 名字未知。
// 已知两个候选：话题页可能叫 `signature`，资料接口（`__lib=ucp&__act=get`）叫 `sign`。
//
// 未登录看不到签名，匿名抓取也被站点整个挡住（访客不能直接访问），所以这一步只能
// 由登录着的人在浏览器里跑。
//
// **只打印字段名、类型、长度和一个「像不像 UBB」的判断，不打印任何签名内容。**
//
// 用法：在已登录的 bbs.nga.cn 上打开任意一个话题页，粘贴运行，把输出贴回来。
(() => {
  const shape = (value) => {
    if (value == null) return null;
    const type = typeof value;
    if (type !== 'string') return { 类型: type };
    return {
      类型: 'string',
      长度: value.length,
      // UBB 原文里会有 [b] [img] 这类方括号标签；已渲染的 HTML 里是尖括号。
      含方括号标签: /\[[a-z]+[\]=]/i.test(value),
      含尖括号标签: /<[a-z]+[\s>/]/i.test(value)
    };
  };

  const users = (window.commonui && commonui.userInfo && commonui.userInfo.users) || null;
  if (!users) {
    console.log('这个页面上没有 commonui.userInfo.users —— 换一个话题页再试');
    return;
  }

  // 所有用户记录上出现过的键名，以及每个键出现在多少条记录里。
  const keyCounts = {};
  const records = [];
  for (const uid of Object.keys(users)) {
    const user = users[uid];
    if (!user || typeof user !== 'object') continue;
    records.push(user);
    for (const key of Object.keys(user)) {
      keyCounts[key] = (keyCounts[key] || 0) + 1;
    }
  }

  console.log('用户记录条数：', records.length);
  console.log('所有键名及出现次数：', keyCounts);

  // 逐个看候选字段是什么形状。多找几个拼法，免得漏。
  const candidates = Object.keys(keyCounts).filter(
    (key) => /sign|sig$|bio|intro/i.test(key)
  );
  console.log('名字里带 sign / bio / intro 的键：', candidates);

  const report = {};
  for (const key of candidates.length ? candidates : ['signature', 'sign']) {
    report[key] = records
      .map((user) => shape(user[key]))
      .filter((entry) => entry !== null);
  }
  console.log('这些键各自的形状（只有类型和长度）：', report);

  // 交叉验证：页面上确实画出签名的那些楼层，作者是谁。
  // 如果有楼层画了签名、而上面那些键在它作者的记录里全是空的，
  // 说明签名不在 __U 里，得另找地方。
  const rendered = [...document.querySelectorAll("[id^='postsigncontent']")]
    .map((element) => ({
      楼层: element.id.replace('postsigncontent', ''),
      有内容: element.textContent.trim().length > 0
    }));
  console.log('页面上画出签名的楼层：', rendered);
})();
