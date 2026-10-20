import { Buffer } from "buffer";
import { handleGenerateTheme } from "./generate-theme.ts";
import { handleGenerateOpenAITheme } from "./generate-theme_openai.ts";
import { handleLyricProxy } from "./lyric-proxy.ts";
import { handleSegmentLyrics } from "./segment-lyrics.ts";
import { QQ_API_PREFIX, type QqServerlessEnv, handleQq } from "./qq.ts";
import { handleBodian } from "./bodian.ts";
import { handleKugou } from "./kugou.ts";

// qq-music-api uses Buffer during requests; Workers do not expose it without nodejs_compat.
// 这一行在模块作用域，所以它先于 fetch handler 与下面导出的 Durable Object 具现化执行 ——
// MQTT codec 也用 Buffer，DO 和入口在同一个 bundle、同一个 isolate 里。
(globalThis as typeof globalThis & { Buffer: typeof Buffer }).Buffer = Buffer;

/**
 * QQ 扫码登录通道的 Durable Object。
 *
 * 导出它本身不产生任何绑定或迁移：没有在 `wrangler.jsonc` 里配 binding 的部署，这就是一个用不到的
 * 导出，`/login/channels` 也只会宣告微信。想要这条通道的人自己加 binding，理由见 `qq.ts`。
 */
export { QqQrChannel } from "./qqQrChannel.ts";

type Env = {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
  AI_PROVIDER?: string;
  GEMINI_API_KEY?: string;
  OPENAI_API_KEY?: string;
  OPENAI_API_URL?: string;
  OPENAI_API_MODEL?: string;
  OPENAI_API_TEMPERATURE?: string;
} & QqServerlessEnv;

const kugouDebugEvents: Array<{ at: number; body: string }> = [];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/generate-theme") {
      return handleGenerateTheme(request, env);
    }

    if (url.pathname === "/api/generate-theme_openai") {
      return handleGenerateOpenAITheme(request, env);
    }

    if (url.pathname === "/api/lyric-proxy") {
      return handleLyricProxy(request);
    }

    if (url.pathname === "/api/segment-lyrics") {
      return handleSegmentLyrics(request, env);
    }

    // QQ 路由必须自己兜住异常：这个 worker 同时负责静态资源与既有三条 API，
    // 让它整个 throw 会把整站一起带下去，所以失败降级成 502 而不是向上冒泡。
    if (url.pathname === QQ_API_PREFIX || url.pathname.startsWith(`${QQ_API_PREFIX}/`)) {
      try {
        return await handleQq(request, env);
      } catch (error) {
        console.error("[worker] qq serverless route failed:", error);
        return new Response(
          JSON.stringify({ code: 502, message: "QQ serverless route failed" }),
          { status: 502, headers: { "content-type": "application/json; charset=utf-8" } },
        );
      }
    }

    // KuGou API 同源反代：转发到 Vercel 上的 KuGouMusicApi。
    // 前端用 VITE_KUGOU_API_BASE=/api/kugou 走同源，避免 vercel.app 在国内被墙。
    // 少了这段，/api/kugou/* 会落到静态资源兜底并返回 index.html（表现为扫码/播放全部"登录错误"）。
    // 酷狗：原生实现在 worker/kugou.ts（原来的 Vercel 后端已停用）。
    if (url.pathname === "/api/kugou" || url.pathname.startsWith("/api/kugou/")) {
      if (url.pathname === "/api/kugou/login/debug") {
        return new Response(JSON.stringify({ events: kugouDebugEvents }), { headers: { "content-type": "application/json; charset=utf-8" } });
      }
      try {
        // 优先走本机 KuGouMusicApi（含扫码登录）；隧道不可用时退回 Worker 原生实现。
        const KUGOU_BASE = "https://missile-calculated-sys-cut.trycloudflare.com";
        // 只把登录/账号相关路径交给本机 KuGouMusicApi；搜索与播放走 Worker 原生实现
        // （原生 tracker 能拿到可播直链，而本机库的 /song/url 会返回 20028「本次请求需要验证」）。
        const kugouPath = url.pathname.slice("/api/kugou".length);
        const needsTunnel = kugouPath.startsWith("/login") || kugouPath.startsWith("/user") || kugouPath.startsWith("/logout") || kugouPath.startsWith("/register");
        if (!needsTunnel) return await handleKugou(request, url);
        const target = KUGOU_BASE + kugouPath + url.search;
        try {
          const upstream = await fetch(new Request(target, request));
          if (kugouPath.indexOf("/login/qr/check") === 0) {
            try {
              const txt = await upstream.clone().text();
              kugouDebugEvents.push({ at: Date.now(), body: txt.slice(0, 600) });
              if (kugouDebugEvents.length > 5) kugouDebugEvents.shift();
            } catch (e) { /* ignore */ }
          }
          if (upstream.ok) return upstream;
        } catch (error) { /* 隧道不可用，退回原生 */ }
        return await handleKugou(request, url);
      } catch (error) {
        console.error("[worker] kugou route failed:", error);
        return new Response(JSON.stringify({ status: 0, error: "kugou route failed: " + String((error as Error)?.message || error) }), { status: 502, headers: { "content-type": "application/json; charset=utf-8" } });
      }
    }

    if (false) {
      const KUGOU_API_BASE = "https://ku-gou-music-api-steel.vercel.app";
      const target = KUGOU_API_BASE + url.pathname.slice("/api/kugou".length) + url.search;
      return fetch(new Request(target, request));
    }


    // 波点音乐：网页/App 没有 Electron 桥，这里按桌面协议复刻（同源 /api/bodian）。
    if (url.pathname === "/api/bodian" || url.pathname.startsWith("/api/bodian/")) {
      try {
        return await handleBodian(request, url);
      } catch (error) {
        console.error("[worker] bodian route failed:", error);
        return new Response(
          JSON.stringify({ error: "bodian route failed" }),
          { status: 502, headers: { "content-type": "application/json; charset=utf-8" } },
        );
      }
    }

    // 网易云：后端在本机（NeteaseCloudMusicApi）+ Cloudflare Tunnel，前端统一走同源 /api/netease。
    if (url.pathname === "/api/netease" || url.pathname.startsWith("/api/netease/")) {
      const NETEASE_BASE = "https://contest-dubai-scientist-survivor.trycloudflare.com";
      try {
        return await fetch(new Request(NETEASE_BASE + url.pathname.slice("/api/netease".length) + url.search, request));
      } catch (error) {
        return new Response(JSON.stringify({ code: 502, message: "netease tunnel unreachable" }), { status: 502, headers: { "content-type": "application/json" } });
      }
    }

    const assetResponse = await env.ASSETS.fetch(request);
    // HTML 永远回源：边缘缓存过的旧 index 会引用已经被新构建替换掉的 chunk，
    // 表现就是模块图补不齐、页面永远白屏（换网络也没用）。
    const contentType = assetResponse.headers.get("content-type") || "";
    // boot-manifest.json 里的文件名每次构建都会变，必须不缓存，否则客户端会预取旧地址。
    if (contentType.includes("text/html") || url.pathname === "/boot-manifest.json") {
      const headers = new Headers(assetResponse.headers);
      headers.set("cache-control", "no-store, no-cache, must-revalidate");
      headers.set("pragma", "no-cache");
      return new Response(assetResponse.body, { status: assetResponse.status, headers });
    }
    return assetResponse;
  },
};
