import SwiftUI
import UIKit
import WebKit

/// 全屏原生壳：WKWebView 加载本地 HTTP server 提供的原版前端（UI 与桌面版 1.8.5 一致）。
struct FoliaWebShell: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FoliaWebHostController {
        FoliaWebHostController()
    }

    func updateUIViewController(_ uiViewController: FoliaWebHostController, context: Context) {}
}

/// 承载 WKWebView 的宿主控制器：注入 mediaSession 锁屏桥 JS、转发前端上报的播放
/// 元数据到系统锁屏，并把锁屏命令回传前端。
final class FoliaWebHostController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private let bridge = FoliaMediaBridge.shared
    private var webView: WKWebView!
    /// 安全区脚本的 user script；只保留一份，数值变化时替换内容，避免重复注入叠加。
    private var safeInsetsScripts: [WKUserScript] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        FoliaLocalServer.shared.start()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.userContentController.add(self, name: "foliaMedia")
        config.userContentController.add(FoliaLogRelay.shared, name: "foliaLog")
        config.userContentController.addUserScript(FoliaLogRelay.script())
        config.userContentController.addUserScript(injectedScript())

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        let background = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.scrollView.bounces = false
        // 安全区由页面自己按 --folia-safe-* 留白（index.html）：WebKit 若再自动缩一次，
        // 就成了两份，界面显得被整个顶下去一截。具体数值由下面 injectSafeInsets 交过去。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        view.addSubview(webView)

        injectSafeInsets()

        bridge.ensureRegistered()
        bridge.commandHandler = { [weak self] action in
            self?.evaluateJS("window.__foliaRemote && window.__foliaRemote.command(\(String(reflecting: action)))")
        }
        bridge.seekHandler = { [weak self] t in
            self?.evaluateJS("window.__foliaRemote && window.__foliaRemote.seek(\(t))")
        }

        if let url = URL(string: "http://127.0.0.1:48231/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    private func evaluateJS(_ script: String) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// 把 WKWebView 实测的安全区交给页面（index.html 里的 `--folia-safe-*`）。
    ///
    /// 页面自己那份靠 env() 与机型表猜，在壳里两头都不可靠：WebKit 的自动 inset 已被关掉，
    /// 原生壳全屏铺满后页面的视口也不再随安全区收缩。原生这边 `safeAreaInsets` 是唯一准的，
    /// 由它算好再推过去；页面监听 `folia-safe-insets` 重排一次。注入分两处：
    /// 文档开始时给初值，尺寸/方向变化时（home 条、通话状态栏）再补一次。
    private func injectSafeInsets() {
        let post = """
        (function() {
          try {
            var top = window.__foliaSafeTop || 0;
            var bottom = window.__foliaSafeBottom || 0;
            window.__foliaSafeInsets = {
              top: top,
              bottom: bottom,
              left: window.__foliaSafeLeft || 0,
              right: window.__foliaSafeRight || 0
            };
            window.dispatchEvent(new Event('folia-safe-insets'));
          } catch (e) {}
        })();
        """
        let sync = """
        (function() {
          var v = window.__foliaSafeValues__ || { top: 0, bottom: 0, left: 0, right: 0 };
          window.__foliaSafeTop = v.top;
          window.__foliaSafeBottom = v.bottom;
          window.__foliaSafeLeft = v.left;
          window.__foliaSafeRight = v.right;
        })();
        """
        let insets = view.safeAreaInsets
        let values = "window.__foliaSafeValues__ = { top: \(Int(insets.top.rounded())), bottom: \(Int(insets.bottom.rounded())), left: \(Int(insets.left.rounded())), right: \(Int(insets.right.rounded())) };"
        let controller = webView.configuration.userContentController
        // 先移除上一次的，否则每次尺寸变化都会再叠三份，越叠越多
        for item in safeInsetsScripts {
            controller.removeUserScript(item)
        }
        safeInsetsScripts = [values, sync, post].map {
            WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        }
        for item in safeInsetsScripts {
            controller.addUserScript(item)
        }
        evaluateJS(values + sync + post)
    }

    // MARK: - JS 桥消息

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "foliaMedia",
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else { return }

        switch type {
        case "metadata":
            bridge.updateMetadata(
                title: payload["title"] as? String ?? "",
                artist: payload["artist"] as? String ?? "",
                album: payload["album"] as? String ?? "",
                artworkURL: payload["artwork"] as? String
            )
        case "playbackState":
            bridge.updatePlaybackState(isPlaying: (payload["state"] as? String) == "playing")
        case "audioState":
            bridge.updateAudioState(
                paused: payload["paused"] as? Bool ?? true,
                duration: payload["duration"] as? TimeInterval ?? 0,
                currentTime: payload["currentTime"] as? TimeInterval ?? 0
            )
        default:
            break
        }
    }

    // MARK: - 注入脚本

    private func injectedScript() -> WKUserScript {
        let source = """
        (function() {
          if (window.__foliaInstalled) return;
          window.__foliaInstalled = true;

          function post(payload) {
            try {
              window.webkit.messageHandlers.foliaMedia.postMessage(payload);
            } catch (e) {}
          }

          window.__foliaRemote = {
            command: function(action) {
              var ms = navigator.mediaSession;
              if (ms && ms.__handlers && ms.__handlers[action]) {
                ms.__handlers[action]();
                return;
              }
              var evt = new CustomEvent('folia-remote-command', { detail: action });
              window.dispatchEvent(evt);
            },
            seek: function(t) {
              var audio = document.querySelector('audio');
              if (audio && isFinite(t)) { audio.currentTime = t; }
            }
          };

          var ms = navigator.mediaSession;
          if (ms) {
            ms.__handlers = ms.__handlers || {};
            var origSet = ms.setActionHandler.bind(ms);
            ms.setActionHandler = function(action, handler) {
              ms.__handlers[action] = handler;
              return origSet(action, handler);
            };

            var meta = null;
            Object.defineProperty(ms, 'metadata', {
              get: function() { return meta; },
              set: function(v) {
                meta = v;
                if (v) {
                  var art = (v.artwork && v.artwork.length) ? v.artwork[0].src : '';
                  post({ type: 'metadata', title: v.title || '', artist: v.artist || '', album: v.album || '', artwork: art });
                }
              },
              configurable: true
            });

            var state = ms.playbackState;
            Object.defineProperty(ms, 'playbackState', {
              get: function() { return state; },
              set: function(s) {
                state = s;
                post({ type: 'playbackState', state: s });
              },
              configurable: true
            });
          }

          setInterval(function() {
            var audio = document.querySelector('audio');
            if (!audio) return;
            post({
              type: 'audioState',
              paused: audio.paused,
              duration: isFinite(audio.duration) ? audio.duration : 0,
              currentTime: audio.currentTime
            });
          }, 1000);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - 导航

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[FoliaWebShell] load failed: %@", String(describing: error))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[FoliaWebShell] loaded %@", webView.url?.absoluteString ?? "?")
        // 首帧时 safeAreaInsets 可能还没算出来，加载完成后补一次。
        injectSafeInsets()
        probeLoginApi()
        logApiBase()
        installLoginDiagnostics()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        injectSafeInsets()
    }

    /// 只读系统日志也能看出前端实际用的 API 地址：CI 注入的是 `http://127.0.0.1:48231/api/*`。
    private func logApiBase() {
        let script = """
        (function() {
          try {
            var cfg = window.__FOLIA_RUNTIME_CONFIG__ || {};
            console.log('[FoliaBase] ' + JSON.stringify({ origin: location.origin, href: location.href, runtime: cfg }));
          } catch (e) { console.log('[FoliaBase] unreadable ' + e); }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 登录失败时把前面的请求日志直接铺在页面上：没有 Mac 抓日志，只能让手机自己说。
    private func installLoginDiagnostics() {
        let source = """
        (function() {
          if (window.__foliaLoginDiag) return;
          window.__foliaLoginDiag = true;
          var log = [];
          function now() {
            var d = new Date();
            return ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2);
          }
          var origFetch = window.fetch;
          window.fetch = function(input, init) {
            var url = typeof input === 'string' ? input : (input && input.url) || '';
            var started = Date.now();
            var entry = { url: url, t: now() };
            log.push(entry);
            if (log.length > 40) log.shift();
            return origFetch.apply(this, arguments).then(function(res) {
              entry.status = res.status;
              entry.ms = Date.now() - started;
              entry.ct = res.headers.get('content-type') || '';
              try {
                res.clone().text().then(function(text) {
                  entry.body = text.slice(0, 240);
                  paint();
                }).catch(function() {});
              } catch (e) {}
              paint();
              return res;
            }).catch(function(err) {
              entry.status = 'ERR';
              entry.ms = Date.now() - started;
              entry.body = String(err && err.message ? err.message : err);
              paint();
              throw err;
            });
          };
          // 平时不打扰界面：只有真的出现网络层失败（ERR）时，左下角才冒一个不显眼的小圆点，点开才是面板。
          var wrap = null, panel = null, btn = null, expanded = false;
          var server = [];
          function failed() {
            for (var i = 0; i < log.length; i += 1) { if (log[i].status === 'ERR') return true; }
            return false;
          }
          function ensure() {
            if (wrap && wrap.isConnected) { btn.style.display = failed() ? 'block' : 'none'; return; }
            wrap = document.createElement('div');
            wrap.setAttribute('data-folia-diag', '1');
            wrap.style.cssText = 'position:fixed;left:8px;bottom:calc(6px + env(safe-area-inset-bottom,0px));'
              + 'z-index:2147483647;display:flex;flex-direction:column;align-items:flex-start;gap:6px;';
            panel = document.createElement('pre');
            panel.style.cssText = 'display:none;max-height:40vh;max-width:calc(100vw - 28px);overflow:auto;margin:0;'
              + 'padding:8px 10px;border-radius:8px;font:10px/1.35 -apple-system,Menlo,monospace;'
              + 'background:rgba(0,0,0,.9);color:#9ae6b4;white-space:pre-wrap;word-break:break-all;';
            panel.addEventListener('dblclick', function() { wrap.remove(); wrap = null; panel = null; });
            btn = document.createElement('div');
            btn.textContent = '!';
            btn.style.cssText = 'display:none;width:24px;height:24px;border-radius:12px;background:rgba(0,0,0,.55);'
              + 'color:#9ae6b4;font:12px/24px -apple-system,sans-serif;text-align:center;opacity:.75;';
            btn.addEventListener('click', function() {
              expanded = !expanded;
              panel.style.display = expanded ? 'block' : 'none';
              if (expanded) { pollServer(); paint(); }
            });
            wrap.appendChild(panel);
            wrap.appendChild(btn);
            document.body.appendChild(wrap);
            btn.style.display = failed() ? 'block' : 'none';
          }
          function paint() {
            ensure();
            if (!expanded) return;
            panel.textContent = log.map(function(e) {
              return e.t + ' ' + (e.status === undefined ? '…' : e.status) + ' ' + (e.ms || 0) + 'ms '
                + e.url.replace('http://127.0.0.1:48231', '') + (e.body ? '\\n    ' + e.body : '');
            }).join('\\n')
              + '\\n\\n--- 本机代理（原生侧日志）---\\n'
              + (server.length ? server.join('\\n') : '(空：请求没有到达本机服务器)')
              + '\\n\\n(双击关闭)';
          }
          // 本机代理自己的记录：能看到请求到没到、上游回了什么、失败在哪个错误码。
          function pollServer() {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/__folia/diag?t=' + Date.now(), true);
            xhr.onload = function() {
              try {
                var json = JSON.parse(xhr.responseText);
                if (json && json.events) {
                  server = json.events.slice(-40);
                  if (expanded) paint();
                }
              } catch (e) {}
            };
            xhr.send();
          }
        })();
        """
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    /// 启动时打一次登录接口：从页面自己的源发一条真实的请求，日志里能看到它到底通没通，
    /// 不用等用户点开登录窗口才知道。直连代理本机地址，不经过前端的 base 拼接。
    private func probeLoginApi() {
        let script = """
        (function() {
          fetch('http://127.0.0.1:48231/api/netease/login/qr/key?timestamp=' + Date.now())
            .then(function(r) {
              console.log('[FoliaProbe] netease qr key HTTP ' + r.status);
              return r.text();
            })
            .then(function(t) { console.log('[FoliaProbe] body ' + t.slice(0, 160)); })
            .catch(function(e) { console.log('[FoliaProbe] failed ' + (e && e.message ? e.message : e)); });
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// 把页面里的 console 消息、以及没接住的 JS 异常转到系统日志，排查时看 Console.app 或 idevicesyslog 即可。
final class FoliaLogRelay: NSObject, WKScriptMessageHandler {

    static let shared = FoliaLogRelay()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "foliaLog" else { return }
        NSLog("[FoliaWeb] %@", String(describing: message.body))
    }

    static func script() -> WKUserScript {
        let source = """
        (function() {
          if (window.__foliaLogInstalled) return;
          window.__foliaLogInstalled = true;
          function post(level, args) {
            try {
              var text = Array.prototype.map.call(args, function(a) {
                if (typeof a === 'string') return a;
                try { return JSON.stringify(a); } catch (e) { return String(a); }
              }).join(' ');
              window.webkit.messageHandlers.foliaLog.postMessage(level + ': ' + text);
            } catch (e) {}
          }
          ['log', 'warn', 'error'].forEach(function(level) {
            var original = console[level];
            console[level] = function() {
              post(level, arguments);
              return original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function(event) {
            post('uncaught', [event.message + ' @ ' + (event.filename || '') + ':' + (event.lineno || 0)]);
          });
          window.addEventListener('unhandledrejection', function(event) {
            var reason = event.reason && event.reason.message ? event.reason.message : String(event.reason);
            post('rejection', [reason]);
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
