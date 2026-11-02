// 汽水音乐签名器。
//
// 背景：`api.qishui.com/passport/*` 要求请求带 44 位 `a_bogus`，它由抖音风控 SDK
// （`bdms`）结合浏览器环境算出。原生侧没有这套环境，所以在 WKWebView 里开一个
// 隐藏页面专门算签名，原生只负责真正发包。
//
// 原理：`sdk-glue.js` 自己是外层钩子，会在 `open()` 阶段把 `a_bogus` 补进发给
// `/passport` 的 URL。我们在它**之前**装钩子，于是对同一个 xhr 实例，`open()`
// 返回时 URL 已被改写；再在 `send()` 里截住，只把改写后的 URL 交回原生，
// 请求本身一步都不发出去（避免 CORS，也不产生真实流量）。
//
// 本文件为本项目自写，只是沿用了这套公开的 SDK 调用协议。
(function () {
    'use strict';

    // 1) SDK 会从同源 localStorage 读 `xmst` / `xmsty` 作为 msToken。
    //    这里必须是「本页自己的」localStorage，因为隐藏页与主站不同源。
    try {
        if (!localStorage.getItem('xmst')) {
            var buf = new Uint8Array(88);
            if (window.crypto && crypto.getRandomValues) {
                crypto.getRandomValues(buf);
            } else {
                for (var i = 0; i < buf.length; i++) { buf[i] = Math.floor(Math.random() * 256); }
            }
            var chars = '';
            for (var j = 0; j < buf.length; j++) { chars += String.fromCharCode(buf[j]); }
            var ms = btoa(chars).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') + '==';
            localStorage.setItem('xmst', ms);
            localStorage.setItem('xmsty', ms);
        }
    } catch (e) { /* 隐私模式下写不进去，签名仍可能成功，不阻断 */ }

    var openBase = XMLHttpRequest.prototype.open;
    var sendBase = XMLHttpRequest.prototype.send;

    // 2) 记录 open 传入的 URL。我们装在内层，SDK 改完 URL 后才会调到这里，
    //    所以这里拿到的已经是补好签名的地址。
    XMLHttpRequest.prototype.open = function (method, url) {
        this.__foliaUrl = url;
        this.__foliaMethod = method;
        return openBase.apply(this, arguments);
    };

    // 3) 签名请求走到 send 时直接结束，不真正发起网络请求。
    XMLHttpRequest.prototype.send = function (body) {
        if (this.__foliaSignRequest) {
            var settle = this.__foliaSignResolve;
            this.__foliaSignRequest = false;
            if (settle) {
                settle({ url: this.__foliaUrl, method: this.__foliaMethod });
            }
            return;
        }
        return sendBase.apply(this, arguments);
    };

    // 4) 对外的签名接口：给定完整 URL，返回补齐 `a_bogus` 的 URL。
    window.__foliaSign = function (method, url) {
        return new Promise(function (resolve, reject) {
            var settled = false;
            var timer = setTimeout(function () {
                if (settled) { return; }
                settled = true;
                reject(new Error('signer timeout'));
            }, 8000);

            var xhr;
            try { xhr = new XMLHttpRequest(); } catch (e) { clearTimeout(timer); reject(e); return; }

            xhr.__foliaSignRequest = true;
            xhr.__foliaSignResolve = function (result) {
                if (settled) { return; }
                settled = true;
                clearTimeout(timer);
                // 校验签名确实补上了：没有 44 位的 a_bogus，说明 SDK 没接管这条路径。
                var signed = '';
                try {
                    signed = new URL(result.url, location.href).searchParams.get('a_bogus') || '';
                } catch (e) { /* 留给下面统一判失败 */ }
                if (signed.length === 44) {
                    resolve({ url: result.url, aBogus: signed });
                } else {
                    reject(new Error('a_bogus missing'));
                }
            };

            try {
                xhr.open(method || 'GET', url, true);
                xhr.send(null);
            } catch (e) {
                if (!settled) {
                    settled = true;
                    clearTimeout(timer);
                    reject(e);
                }
            }
        });
    };

    window.__foliaSignerLoaded = true;
})();
