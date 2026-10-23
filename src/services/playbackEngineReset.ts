// src/services/playbackEngineReset.ts

/**
 * 「重置播放引擎」：iOS 上音频会话被系统置成 interrupted（或被别的 App 抢走）之后，
 * AudioContext / <audio> 元素可能进入一种"活着但永远不出声"的状态，重新 play() 也救不回来。
 * 唯一可靠的恢复手段是让整个页面重建一遍：注销 Service Worker、清空 CacheStorage，
 * 再带新的时间戳重载。用户点一下按钮即可，不需要杀 App。
 */
export const resetPlaybackEngine = async (): Promise<void> => {
    const goFresh = () => {
        // 带上时间戳，确保拿到新的 HTML 与新的 chunk（旧缓存引用的文件可能已被替换）。
        location.replace(`${location.pathname}?fresh=${Date.now()}`);
    };

    const cap = (task: Promise<unknown>, ms: number) => Promise.race([
        task.catch(() => undefined),
        new Promise<void>((resolve) => { window.setTimeout(resolve, ms); }),
    ]);

    try {
        if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
            await cap(
                navigator.serviceWorker.getRegistrations()
                    .then((registrations) => Promise.all(registrations.map((registration) => registration.unregister()))),
                1500,
            );
        }
    } catch { /* ignore */ }

    try {
        if (window.caches && window.caches.keys) {
            await cap(
                window.caches.keys().then((keys) => Promise.all(keys.map((key) => window.caches.delete(key)))),
                1200,
            );
        }
    } catch { /* ignore */ }

    goFresh();
};
