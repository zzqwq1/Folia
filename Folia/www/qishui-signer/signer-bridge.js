// 与宿主（App 页面 / 取证台页面）用 postMessage 通信：ready / signed / error
(function () {
  var post = function (msg) { msg.source = 'folia-signer'; try { parent.postMessage(msg, '*'); } catch (e) {} };
  var started = Date.now();
  (function waitGlue() {
    if (window.bdms && window._sdkGlueVersionMap) {
      post({ type: 'ready', glue: window._sdkGlueVersionMap, msToken: window.__foliaMsToken() });
      return;
    }
    if (Date.now() - started > 40000) { post({ type: 'error', message: 'glue 未就绪' }); return; }
    setTimeout(waitGlue, 120);
  })();
  window.addEventListener('message', function (ev) {
    var d = ev.data || {};
    if (d.type !== 'sign') return;
    window.__foliaSign(d.method, d.url, d.headers, d.body).then(function (r) {
      post({ type: 'signed', id: d.id, url: r.url, method: r.method });
    }).catch(function (e) {
      post({ type: 'sign-error', id: d.id, message: String((e && e.message) || e) });
    });
  });
})();
