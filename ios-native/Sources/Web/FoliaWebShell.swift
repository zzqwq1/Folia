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
        webView.navigationDelegate = self
        view.addSubview(webView)

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
        probeLoginApi()
    }

    /// 启动时打一次登录接口：从页面自己的源发一条真实的跨域请求，日志里能看到它到底通没通，
    /// 不用等用户点开登录窗口才知道。
    private func probeLoginApi() {
        let script = """
        (function() {
          fetch('/netease/login/qr/key?timestamp=' + Date.now(), { credentials: 'include' })
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
