import { mountNativeVisualizer, pushNativeVisualizerFrame, unmountNativeVisualizer } from './nativeVisualizer';

// src/services/nativeVisualizerProbe.ts
//
// 原生渲染链路的冒烟测试：地址栏带 `?nativeViz=1` 时，在整个屏幕上盖一层原生 Metal 视图，
// 用来验证「JS → Capacitor 插件 → Metal」这条路是否通。
//
// 为什么不直接接到晶格上：原生层还没在真机验证过，先让它独立跑起来，确认不崩、帧率正常，
// 再替换真正的渲染内容。参数去掉即恢复原样，不改变任何现有行为。

const PROBE_QUERY_KEY = 'nativeViz';

let mounted = false;
let frameTimer: ReturnType<typeof setInterval> | null = null;

/** 启动冒烟测试；未带参数时直接返回，不做任何事。 */
export const startNativeVisualizerProbeIfRequested = (): void => {
    if (typeof window === 'undefined') return;
    const params = new URLSearchParams(window.location.search);
    if (params.get(PROBE_QUERY_KEY) !== '1') return;
    if (mounted) return;

    void (async () => {
        const ok = await mountNativeVisualizer({
            x: 0,
            y: 0,
            width: window.innerWidth,
            height: window.innerHeight * 0.5,
        });
        if (!ok) return;
        mounted = true;

        // 用一条正弦曲线驱动电平，肉眼能确认画面确实在动、且由 JS 驱动。
        let phase = 0;
        frameTimer = setInterval(() => {
            phase += 0.08;
            const level = (Math.sin(phase) + 1) / 2;
            void pushNativeVisualizerFrame(level, 0.6);
        }, 33);

        // 方便卸载：再点一次同一参数或调用 window.__foliaStopNativeViz()
        (window as unknown as { __foliaStopNativeViz?: () => void }).__foliaStopNativeViz = () => {
            if (frameTimer) clearInterval(frameTimer);
            frameTimer = null;
            void unmountNativeVisualizer();
            mounted = false;
        };
    })();
};
