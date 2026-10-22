import { Capacitor, registerPlugin } from '@capacitor/core';

// src/services/nativeVisualizer.ts
//
// 原生渲染层的 JS 桥。iOS 上如果原生 Metal 渲染可用，就把高频重绘交给它；
// 不可用（安卓 / 浏览器 / 插件缺失）时返回 false，由调用方回落到原有的 canvas 实现。
//
// 设计原则：所有方法都必须**静默失败**。原生层只是性能优化，任何异常都不能把播放页带崩。

type FoliaVisualizerPlugin = {
    isSupported(): Promise<{ supported: boolean; backend: string }>;
    mount(options: { x: number; y: number; width: number; height: number }): Promise<{ mounted: boolean }>;
    unmount(): Promise<{ mounted: boolean }>;
    pushFrame(options: { level: number; hue: number }): Promise<void>;
};

const NativeVisualizer = registerPlugin<FoliaVisualizerPlugin>('FoliaVisualizer');

let supportedCache: boolean | null = null;

/** 当前环境能否使用原生渲染（只在 iOS 原生容器内为 true）。 */
export const isNativeVisualizerAvailable = async (): Promise<boolean> => {
    if (supportedCache !== null) return supportedCache;
    if (!Capacitor.isNativePlatform()) {
        supportedCache = false;
        return false;
    }
    try {
        const result = await NativeVisualizer.isSupported();
        supportedCache = Boolean(result?.supported);
    } catch {
        supportedCache = false;
    }
    return supportedCache;
};

/** 在指定矩形上挂载原生渲染层（坐标单位 CSS 像素）。 */
export const mountNativeVisualizer = async (rect: { x: number; y: number; width: number; height: number }): Promise<boolean> => {
    if (!(await isNativeVisualizerAvailable())) return false;
    try {
        const result = await NativeVisualizer.mount(rect);
        return Boolean(result?.mounted);
    } catch {
        return false;
    }
};

/** 卸载原生层，交还给 WebView 画布。 */
export const unmountNativeVisualizer = async (): Promise<void> => {
    if (!(await isNativeVisualizerAvailable())) return;
    try {
        await NativeVisualizer.unmount();
    } catch {
        /* 卸载失败不影响界面 */
    }
};

/** 每帧推一次状态；调用频率由调用方控制（建议 <= 30Hz）。 */
export const pushNativeVisualizerFrame = async (level: number, hue: number): Promise<void> => {
    if (!(await isNativeVisualizerAvailable())) return;
    try {
        await NativeVisualizer.pushFrame({ level, hue });
    } catch {
        /* 单帧丢失无所谓 */
    }
};
