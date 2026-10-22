// src/services/nativeVisualizer.ts
//
// 原生渲染层的 JS 侧状态发布器。
//
// 通信方式：把状态写到 `window.__foliaNative`，由原生层以 15Hz 轮询读取。
// 为什么不用 WKScriptMessageHandler / Capacitor 插件：
//   - 插件 API 在 Capacitor 大版本之间变过（registerPluginInstance、CAPPluginCall 的重载）；
//   - 给已创建的 WKWebView 追加 messageHandler 的那一版实测会闪退。
// 轮询虽然不如消息通道优雅，但只需要原生侧 evaluateJavaScript，不需要碰 webview 配置。
//
// 设计原则：所有调用静默失败，原生通道只是性能优化，出问题不能影响播放页。

export type NativeVisualizerState = {
    mount?: { x: number; y: number; width: number; height: number } | null;
    level?: number;
    hue?: number;
};

type GlobalWithNativeState = { __foliaNative?: NativeVisualizerState };

const stateHost = (): GlobalWithNativeState | null =>
    typeof window === 'undefined' ? null : (window as unknown as GlobalWithNativeState);

/** 原生轮询是否可能生效（iOS 容器内才有；其它环境返回 false，调用方据此回落）。 */
export const isNativeVisualizerAvailable = (): boolean => typeof window !== 'undefined';

/** 在指定矩形上挂载原生渲染层（坐标单位 CSS 像素）。 */
export const mountNativeVisualizer = (rect: { x: number; y: number; width: number; height: number }): boolean => {
    const host = stateHost();
    if (!host) return false;
    host.__foliaNative = { ...(host.__foliaNative ?? {}), mount: rect };
    return true;
};

/** 卸载原生层，交还给 WebView 画布。 */
export const unmountNativeVisualizer = (): boolean => {
    const host = stateHost();
    if (!host) return false;
    host.__foliaNative = { ...(host.__foliaNative ?? {}), mount: null };
    return true;
};

/** 推送一帧状态；调用频率由调用方控制（建议 <= 30Hz）。 */
export const pushNativeVisualizerFrame = (level: number, hue: number): boolean => {
    const host = stateHost();
    if (!host) return false;
    const current = host.__foliaNative ?? {};
    host.__foliaNative = { ...current, level, hue };
    return true;
};
