import { Buffer } from 'buffer';
import { installGlobalVisualizerFrameRateLimiter } from './utils/frameRateLimiter';
import { installWebglContextGuard } from './utils/webglContextGuard';
import { installConsoleLogCapture } from './utils/consoleLogBuffer';
import { installDebugModule } from './services/debug/debugModule';
import { installMemorySampleFeed } from './services/debug/memorySamples';
// import { installCoverSizeAudit } from './services/debug/coverSizeSamples';
// @ts-ignore
globalThis.Buffer = Buffer;
// First, so the debug overlay's console tab has the startup lines too - they are where a failure
// to reach a library or restore a session shows up.
installConsoleLogCapture();
// Right after it, so the startup lines reach the runtime log file too and not only the in-memory
// buffer. Both no-op off Electron. See services/debug/debugModule.ts.
installDebugModule();
installMemorySampleFeed();
// Cover size audit, left wired but switched off: it answered whether the provider CDNs honour the
// size in a cover URL - they do - and that is not a question worth re-asking every session. The
// collector and its panel are still in the tree, and `?probe=coverSizeAudit` still reaches them.
// To bring the tab back, uncomment this line and the four sites in DevDebugOverlay.tsx. It was dev
// only even then: a packaged build has nothing to do with the answer, so it should not pay the
// observer or the rows it retains.
// if (import.meta.env.DEV) installCoverSizeAudit();
installGlobalVisualizerFrameRateLimiter();
// 上下文被回收时把黑画布藏起来（歌词动画期间画布最多，黑屏多半来自这里）。
installWebglContextGuard();
// iOS 17.4+ 的音频会话：声明成 playback 才能切后台/锁屏继续放，且不会被其它 App 的提示音打断。
try {
    const audioSession = (navigator as Navigator & { audioSession?: { type?: string } }).audioSession;
    if (audioSession) audioSession.type = 'playback';
} catch { /* 老浏览器没有这个 API，忽略 */ }

// 启动阶段标记：卡住时兜底面板会把它显示出来，用来定位是哪一步没走完。
const stage = (value: string) => { (window as unknown as { __foliaStage?: string }).__foliaStage = value; };
stage('entry');

/** 主包约 2 MB，个别 iOS WebView 上这个请求会挂住：先用 fetch 预取（可超时可换连接），再 import。 */
const PREFETCH_TIMEOUT_MS = 8000;
const bootChunkUrl = (): string | null => {
    const link = Array.from(document.querySelectorAll('link[rel="modulepreload"]'))
        .map(node => node.getAttribute('href') || '')
        .find(href => href.includes('/bootstrap-'));
    return link || null;
};

/** preload 链接常常不在（bootstrap 是动态 import），这时退回到构建期写下的清单。 */
const fetchManifestBootstrap = async (): Promise<string | null> => {
    try {
        const response = await fetch('/boot-manifest.json', { cache: 'no-store' });
        if (!response.ok) return null;
        const body = await response.json() as { bootstrap?: string };
        return typeof body.bootstrap === 'string' ? body.bootstrap : null;
    } catch {
        return null;
    }
};

const prefetch = (url: string, timeoutMs: number): Promise<void> => new Promise((resolve, reject) => {
    const controller = new AbortController();
    const timer = setTimeout(() => { controller.abort(); reject(new Error('prefetch timeout')); }, timeoutMs);
    fetch(url, { signal: controller.signal, cache: 'force-cache' })
        .then(response => (response.ok ? resolve() : reject(new Error('HTTP ' + response.status))))
        .catch(reject)
        .finally(() => clearTimeout(timer));
});

const boot = async () => {
    const chunk = bootChunkUrl() || await fetchManifestBootstrap();
    if (chunk) {
        try {
            stage('prefetch');
            await prefetch(chunk, PREFETCH_TIMEOUT_MS);
            stage('prefetched');
        } catch {
            try {
                stage('prefetch-retry');
                await prefetch(chunk + '?r=' + Date.now(), PREFETCH_TIMEOUT_MS);
                stage('prefetched-retry');
            } catch {
                stage('prefetch-failed');
            }
        }
    }
    // 没有预取到 URL（HTML 里没有 preload 链接）时，import 本身仍可能挂住。
    // 现在的策略：等够 20 秒 → 首次整页重载（HTML 已是 no-store，会换新连接与新 chunk 名）；
    // 第二次仍卡住就主动唤起兜底面板，绝不让用户停在开屏上无路可走。
    stage('import-pending');
    let settled = false;
    const timer = setTimeout(() => {
        if (settled) return;
        stage('import-timeout');
        let retried = false;
        try { retried = sessionStorage.getItem('folia.boot.retried') === '1'; } catch { /* ignore */ }
        if (!retried) {
            try { sessionStorage.setItem('folia.boot.retried', '1'); } catch { /* ignore */ }
            // 单纯 reload 会继续用旧的 Service Worker 缓存，坏状态永远修不回来。
            // 这里先注销 SW + 清 CacheStorage，再带 fresh 参数重载（新连接、新 chunk 名），
            // 让「页面没能加载完成」这种状态自己恢复，用户不必手动清缓存。
            const goFresh = () => location.replace(location.pathname + '?fresh=' + Date.now());
            void (async () => {
                const cap = (task: Promise<unknown>, ms: number) => Promise.race([
                    task.catch(() => undefined),
                    new Promise<void>((resolve) => { setTimeout(resolve, ms); }),
                ]);
                try {
                    if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
                        await cap(
                            navigator.serviceWorker.getRegistrations()
                                .then((registrations) => Promise.all(registrations.map((r) => r.unregister()))),
                            1500,
                        );
                    }
                } catch { /* ignore */ }
                try {
                    if (window.caches && caches.keys) {
                        await cap(
                            caches.keys().then((keys) => Promise.all(keys.map((key) => caches.delete(key)))),
                            1200,
                        );
                    }
                } catch { /* ignore */ }
                goFresh();
            })();
            // 浏览器把上面那几步卡住时也保证跳一次，不至于停在开屏。
            setTimeout(goFresh, 2600);
            return;
        }
        try {
            (window as unknown as { __foliaRevealFail?: (msg: string) => void }).__foliaRevealFail?.(
                '主程序下载超时（已重试一次），请点下面按钮重试',
            );
        } catch { /* ignore */ }
    }, 20000);
    try {
        await import('./bootstrap');
        settled = true;
        clearTimeout(timer);
        stage('bootstrap-loaded');
    } catch (error) {
        settled = true;
        clearTimeout(timer);
        stage('bootstrap-failed');
        console.error('[boot] bootstrap failed', error);
        try {
            (window as unknown as { __foliaRevealFail?: (msg: string) => void }).__foliaRevealFail?.(
                '主程序加载失败：' + String((error as Error)?.message || error),
            );
        } catch { /* ignore */ }
    }
};

void boot();
