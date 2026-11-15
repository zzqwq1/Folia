// Folia 汽水「签名器」钩子（必须排在 sdk-glue.js 之前加载）
// 原理：glue 会 hook XMLHttpRequest 给发往 /passport 的请求补 a_bogus；
// 我们在它之前装钩子，于是能拿到「已被重写过的 URL」，但**故意不把请求发出去**（避免 CORS），
// 只把签名后的 URL 交回给宿主（App 内由原生/Node 真正发请求）。
(function () {
  // 1) 种 msToken：glue 会读同源 localStorage 的 xmst / xmsty
  try {
    var qs = new URLSearchParams(location.search);
    var given = qs.get('ms');
    if (given && given.length >= 100) { localStorage.setItem('xmst', given); localStorage.setItem('xmsty', given); }
    if (!localStorage.getItem('xmst')) {
      var buf = new Uint8Array(88);
      (window.crypto || {}).getRandomValues ? crypto.getRandomValues(buf) : buf.forEach(function (_, i) { buf[i] = Math.floor(Math.random() * 256); });
      var s = btoa(String.fromCharCode.apply(null, Array.prototype.slice.call(buf)))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') + '==';
      localStorage.setItem('xmst', s); localStorage.setItem('xmsty', s);
    }
  } catch (e) { /* ignore */ }
  window.__foliaMsToken = function () { try { return localStorage.getItem('xmst') || ''; } catch (e) { return ''; } };

  // 2) 记录 open 传入的 URL（此时 glue 的重写已经发生过，因为它是外层）
  var open0 = XMLHttpRequest.prototype.open;
  var send0 = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__foliaUrl = url; this.__foliaMethod = method;
    return open0.apply(this, arguments);
  };
  // 3) 我们自己的签名请求：只取签名结果，不发送
  XMLHttpRequest.prototype.send = function (body) {
    if (this.__foliaSignRequest) {
      var done = this.__foliaSignResolve;
      this.__foliaSignRequest = false;
      if (done) done({ url: this.__foliaUrl, method: this.__foliaMethod, body: body == null ? null : String(body) });
      return;
    }
    return send0.apply(this, arguments);
  };

  window.__foliaSign = function (method, url, headers, body) {
    return new Promise(function (resolve, reject) {
      var settled = false;
      var timer = setTimeout(function () { if (!settled) { settled = true; reject(new Error('sign timeout')); } }, 8000);
      var x;
      try { x = new XMLHttpRequest(); } catch (e) { return reject(e); }
      x.__foliaSignRequest = true;
      x.__foliaSignResolve = function (r) {
        if (settled) return; settled = true; clearTimeout(timer);
        // 校验 glue 是否真的补上了签名
        var ok = false;
        try { var q = new URL(r.url, location.href).searchParams; ok = (q.get('a_bogus') || '').length === 44; } catch (e) {}
        if (ok) resolve(r); else reject(new Error('a_bogus missing'));
      };
      try {
        x.open(method || 'GET', url, true);
        Object.keys(headers || {}).forEach(function (k) { try { x.setRequestHeader(k, headers[k]); } catch (e) {} });
        x.send(body == null ? null : body);
      } catch (e) { if (!settled) { settled = true; clearTimeout(timer); reject(e); } }
    });
  };
  window.__foliaHookReady = true;
})();
