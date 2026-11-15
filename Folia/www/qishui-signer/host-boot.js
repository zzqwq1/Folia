// 原生宿主适配层（必须排在 signer-bridge.js **之后**）。
//
// 官方这套签名器（从参考 ipa 1:1 抄来的 11 个文件）是为「页面里开 iframe、
// 父页面 postMessage 进去」设计的：`signer-bridge.js` 只会往 `parent` 发
// `ready` / `signed` / `sign-error`，从不给原生桥发消息。
//
// 但本壳的签名器是**一个隐藏的 WKWebView**，没有父页面，原生侧是靠
// `evaluateJavaScript` 直接调 `window.__foliaSign(...)`、并把结果通过
// `window.webkit.messageHandlers.foliaQishuiSigner` 收回去的。
//
// 所以这里只做一件事：把 `signer-bridge.js` 的 `ready` 转成一条原生
// `booted` 消息，让 `QishuiSigner.dispatch` 的排队请求能真正发出去。
// 不覆盖 `__foliaSign` 本身 —— 那是 `signer-bridge.js` 的职责，重复实现只会
// 和它抢 `XMLHttpRequest` 的钩子。
(function () {
  var sent = false;
  function boot() {
    if (sent) { return true; }
    try {
      if (typeof window.__foliaSign !== 'function') { return false; }
      if (!window.bdms || !window._sdkGlueVersionMap) { return false; }
      var handler = window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.foliaQishuiSigner;
      if (!handler) { return false; }
      sent = true;
      handler.postMessage({ type: 'booted' });
      return true;
    } catch (e) {
      return false;
    }
  }
  // `signer-bridge.js` 在 glue 就绪后会往 parent 发 ready；iframe 里没父页面，
  // 直接轮询同两个判据最稳（只在装载那几秒跑，就绪即停）。
  var started = Date.now();
  (function poll() {
    if (boot()) { return; }
    if (Date.now() - started > 40000) { return; }
    setTimeout(poll, 150);
  })();
})();
