// 摸清 V2EX 发回复那张表单到底长什么样。
//
// 这是接 V2EX 时**唯一一处没有匿名夹具可对**的东西：回复表单只画给登录用户，
// 匿名抓多少次都看不见。适配器现在按「POST 到 /t/{主题}，字段 content + once」发，
// 那是照着站点的表单推断的，还没有人验过。
//
// 脚本只报**结构**：表单的地址、方法、字段名、字段类型、以及 once 是不是一个隐藏输入。
// **绝不打印任何字段的值** —— 令牌和正文都不进对话。
//
// 用法：
//   1. 登录之后打开任意一个主题页（比如 https://www.v2ex.com/t/1240288 ）；
//   2. 粘贴运行；
//   3. 把打印出来的那段 JSON 贴回来。
(() => {
  const shape = (value) => {
    if (value === null || value === undefined) return null;
    const text = String(value);
    return { 长度: text.length, 全是数字: /^\d+$/.test(text) };
  };

  const forms = Array.from(document.querySelectorAll('form')).map((form) => ({
    地址: (() => {
      try { return new URL(form.getAttribute('action') || '', location.href).pathname; }
      catch (_) { return form.getAttribute('action'); }
    })(),
    方法: (form.getAttribute('method') || 'get').toLowerCase(),
    字段: Array.from(form.elements)
      .filter((element) => element.name)
      .map((element) => ({
        名字: element.name,
        标签: element.tagName.toLowerCase(),
        类型: element.type || null,
        // 只有 once 报形状，因为要确认它是不是那串数字令牌；别的字段一律不看值。
        值的形状: element.name === 'once' ? shape(element.value) : undefined
      }))
  }));

  const report = {
    表单: forms,
    '页面上的 once 全局': shape(typeof once !== 'undefined' ? once : null),
    '回复输入框的 id': document.querySelector('#reply_content') ? 'reply_content' : null,
    '回复区的容器': ['#reply-box', '.reply-box', '#reply_box']
      .filter((selector) => document.querySelector(selector)),
    // 感谢按钮的 id 模板，用来确认「我感谢过了」在 DOM 上长什么样。
    感谢区: Array.from(document.querySelectorAll('[id^="thank_area_"]'))
      .slice(0, 3)
      .map((element) => ({
        id模板: element.id.replace(/\d+/, '{回复编号}'),
        类名: element.className || null
      }))
  };

  console.log(JSON.stringify(report, null, 2));
})();
