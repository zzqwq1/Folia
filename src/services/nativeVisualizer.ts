// src/services/nativeVisualizer.ts
//
// 原生渲染层的 JS 桥。走 WKWebView 的 message handler，而不是 Capacitor 插件：
// 插件注册/调用 API 在不同 Capacitor 大版本之间变过好几次（registerPluginInstance、
// CAPPluginCall 的 getDouble 重载等），而 message handler 不需要注册，能编译通过的
// 表面积小得多。
//
// 设计原则：所有调用都是 fire-and-forget 且静默失败。原生层只是性能优化，
// 任何异常都不能影响播放页面。

type FoliaNativeMessage = {
    cmd: 'mount' | 'unmount' | 'frame';
    x?: number;
    y?: number;
    width?: number;
    height?: number;
    level?: number;
    hue?: number;
};

type MessageHandler = { postMessage: (message: FoliaNativeMessage) => void };

const getHandler = (): MessageHandler | null => {
    if (typeof window === 'undefined') return null;
    const webkit = (window as unknown as {
        webkit?: { messageHandlers?: { foliaNative?: MessageHandler } };
    }).webkit;
    return webkit?.messageHandlers?.foliaNative ?? null;
};

/** 当前环境是否存在原生渲染通道（仅 iOS 原生容器内为 true）。 */
export const isNativeVisualizerAvailable = (): boolean => getHandler() !== null;

const post = (message: FoliaNativeMessage): boolean => {
    const handler = getHandler();
    if (!handler) return false;
    try {
        handler.postMessage(message);
        return true;
    } catch {
        return false;
    }
};

/** 在指定矩形上挂载原生渲染层（坐标单位 CSS 像素）。 */
export const mountNativeVisualizer = (rect: { x: number; y: number; width: number; height: number }): boolean =>
    post({ cmd: 'mount', ...rect });

/** 卸载原生层，交还给 WebView 画布。 */
export const unmountNativeVisualizer = (): boolean => post({ cmd: 'unmount' });

/** 推送一帧状态；调用频率由调用方控制（建议 <= 30Hz）。 */
export const pushNativeVisualizerFrame = (level: number, hue: number): boolean => post({ cmd: 'frame', level, hue });
