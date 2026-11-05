// Linux.do 登录态接口摸底探针。
//
// 用法：在已登录 linux.do 的浏览器标签页里打开开发者工具控制台，整段粘贴运行。
// 只打印字段名、类型、条数和状态码，**绝不打印值**：用户名、令牌、正文一样都不出控制台。
// 只发 GET，不发任何写请求（CSRF 端点也只看拿不拿得到，不打印令牌）。
//
// 想回答的问题见 Design/SiteProbe-LinuxDo.md 第六节。
(async () => {
  const shape = (v, depth = 0) => {
    if (v === null) return "null";
    if (Array.isArray(v)) return v.length ? [`Array(${v.length})`, depth < 2 ? shape(v[0], depth + 1) : "…"] : "Array(0)";
    if (typeof v === "object") {
      if (depth >= 2) return `Object{${Object.keys(v).length}}`;
      return Object.fromEntries(Object.keys(v).map((k) => [k, shape(v[k], depth + 1)]));
    }
    return typeof v;
  };
  const get = async (label, path) => {
    try {
      const r = await fetch(path, { headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" } });
      const cf = r.headers.get("cf-mitigated");
      const text = await r.text();
      let json = null;
      try { json = JSON.parse(text); } catch {}
      console.log(`[${label}] ${r.status} cf=${cf ?? "-"} json=${json !== null} bytes=${text.length}`);
      return json;
    } catch (e) {
      console.log(`[${label}] 失败：${e.name}`);
      return null;
    }
  };

  // Cookie：只看非 httpOnly 的名字（_t、_forum_session 是 httpOnly，这里看不见是正常的）。
  console.log("[cookie names]", document.cookie.split(";").map((c) => c.split("=")[0].trim()).filter(Boolean));

  // 当前用户：编号从哪儿拿。
  const current = await get("session/current", "/session/current.json");
  console.log("[session/current shape]", shape(current));
  const preloaded = document.getElementById("data-preloaded");
  console.log("[data-preloaded 有 currentUser]", !!preloaded && "currentUser" in JSON.parse(preloaded.dataset.preloaded || "{}"));
  const me = current?.current_user?.username;

  const csrf = await get("session/csrf", "/session/csrf");
  console.log("[csrf 拿得到]", typeof csrf?.csrf === "string");

  // 话题：匿名时这一族被 Cloudflare 挑战（2026-11-04 实测），登录后呢？
  const latest = await get("latest", "/latest.json");
  const topic = latest?.topic_list?.topics?.find((t) => t.posts_count > 40 && !t.pinned);
  if (topic) {
    const t = await get("topic", `/t/${topic.id}.json`);
    if (t) {
      const posts = t.post_stream?.posts ?? [];
      console.log("[topic keys]", Object.keys(t));
      console.log("[topic stream/loaded/chunk]", t.post_stream?.stream?.length, posts.length, t.chunk_size);
      console.log("[post shape]", shape(posts[1] ?? posts[0]));
      console.log("[有 reactions 字段的楼层数]", posts.filter((p) => "reactions" in p).length);
      console.log("[有 polls 字段的楼层数]", posts.filter((p) => "polls" in p).length);
      const ids = (t.post_stream?.stream ?? []).slice(20, 40);
      if (ids.length) {
        const q = ids.map((id) => `post_ids[]=${id}`).join("&");
        const more = await get("topic posts by ids", `/t/${topic.id}/posts.json?${q}`);
        console.log("[posts.json 返回条数 / 请求条数]", more?.post_stream?.posts?.length, ids.length);
      }
      await get("topic print", `/t/${topic.id}/print`);
      await get("topic rss", `/t/${topic.id}.rss`);
    }
  }

  await get("categories", "/categories.json?include_subcategories=true");
  const search = await get("search", "/search.json?q=linux");
  console.log("[search shape]", shape(search));

  if (me) {
    const n = await get("notifications", "/notifications.json");
    console.log("[notifications shape]", shape(n));
    const pm = await get("private messages", `/topics/private-messages/${encodeURIComponent(me)}.json`);
    console.log("[pm shape]", shape(pm));
    const bm = await get("bookmarks", `/u/${encodeURIComponent(me)}/bookmarks.json`);
    console.log("[bookmarks shape]", shape(bm));
    const acts = await get("user_actions", `/user_actions.json?username=${encodeURIComponent(me)}&filter=4,5&offset=0`);
    console.log("[user_actions shape]", shape(acts));
    const u = await get("user", `/u/${encodeURIComponent(me)}.json`);
    console.log("[user keys]", Object.keys(u?.user ?? {}));
    await get("user-api-key page", "/user-api-key/new");
  }
  console.log("探针结束。把以上输出整段贴回给 Claude 即可，里面没有任何值。");
})();
