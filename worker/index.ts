import { Buffer } from "buffer";
import QRCode from "qrcode/lib/server.js";
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


/** 上游把设备标识放在 Set-Cookie 里，而前端只认 JSON 里的 cookie 字段；
 *  不合并的话每个请求都会被当成新设备，多人登录就互相覆盖（表现为账号串号、地区乱跳）。 */
const mergeSetCookie = async (response: Response): Promise<Response> => {
  if (response.status !== 200 || !(response.headers.get("content-type") || "").includes("application/json")) return response;
  const raw = response.headers.getSetCookie ? response.headers.getSetCookie() : [];
  if (!raw.length) return response;
  const cookies = raw.map(line => line.split(";")[0]).filter(Boolean);
  try {
    const body: any = await response.clone().json();
    const merged = [body?.cookie, ...cookies].filter(Boolean).join("; ");
    const next = { ...body, cookie: merged };
    return new Response(JSON.stringify(next), { status: response.status, headers: { "content-type": "application/json; charset=utf-8" } });
  } catch { return response; }
};

// ---------- 网易云 weapi 加密（让取流完全跑在 Cloudflare，不依赖本机电脑） ----------
const NETEASE_PRESET_KEY = "0CoJUm6Qyw8W8jud";
const NETEASE_IV = "0102030405060708";
const NETEASE_PUBMOD = BigInt(
  "0x00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7",
);
const NETEASE_PUBEXP = 65537n;
const NETEASE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

const modPow = (base: bigint, exp: bigint, mod: bigint): bigint => {
  let result = 1n;
  let b = base % mod;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % mod;
    b = (b * b) % mod;
    e >>= 1n;
  }
  return result;
};

const aesCbcBase64 = async (text: string, key: string): Promise<string> => {
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey("raw", enc.encode(key), { name: "AES-CBC" }, false, ["encrypt"]);
  const encrypted = await crypto.subtle.encrypt({ name: "AES-CBC", iv: enc.encode(NETEASE_IV) }, cryptoKey, enc.encode(text));
  let binary = "";
  const bytes = new Uint8Array(encrypted);
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
};

/** 生成 weapi 需要的 params / encSecKey。 */
const neteaseWeapi = async (payload: Record<string, unknown>): Promise<{ params: string; encSecKey: string }> => {
  const text = JSON.stringify(payload);
  const first = await aesCbcBase64(text, NETEASE_PRESET_KEY);
  let key = "";
  for (let i = 0; i < 16; i += 1) key += NETEASE_CHARS[Math.floor(Math.random() * NETEASE_CHARS.length)];
  const params = await aesCbcBase64(first, key);
  const reversed = key.split("").reverse().join("");
  let hex = "";
  for (let i = 0; i < reversed.length; i += 1) hex += reversed.charCodeAt(i).toString(16).padStart(2, "0");
  const encSecKey = modPow(BigInt("0x" + hex), NETEASE_PUBEXP, NETEASE_PUBMOD)
    .toString(16)
    .padStart(256, "0");
  return { params, encSecKey };
};

/** 调一次网易云 weapi，返回解析后的 JSON。 */
// 匿名 cookie：不注册匿名设备时，取流接口对部分歌会直接返回 404（等价“未登录”）。
let neteaseAnonCookie: string | null = null;
const ensureNeteaseAnonCookie = async (): Promise<string> => {
  if (neteaseAnonCookie) return neteaseAnonCookie;
  try {
    const data: any = await neteaseWeapiRequest("/weapi/register/anonimous", {});
    neteaseAnonCookie = typeof data?.cookie === "string" ? data.cookie : "";
  } catch {
    neteaseAnonCookie = "";
  }
  return neteaseAnonCookie ?? "";
};

const neteaseWeapiRequest = async (path: string, payload: Record<string, unknown>): Promise<any> => {
  const { params, encSecKey } = await neteaseWeapi({ ...payload, csrf_token: "" });
  const body = new URLSearchParams({ params, encSecKey }).toString();
  const response = await fetch("https://music.163.com" + path, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "referer": "https://music.163.com/",
      "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
      "cookie": (neteaseAnonCookie ? neteaseAnonCookie + "; " : "") + "os=pc; appver=2.9.7; channel=netease;",
    },
    body,
  });
  return response.json();
};

/**
 * 把 /api/* 的响应补上 CORS 头。
 *
 * 用途：iOS 包如果把网页资源内置（capacitor://localhost），页面就成了另一个源，
 * 直接请求 https://app.folia-api.top/api/... 属于跨域，必须显式允许，否则登录态、搜索、
 * 歌词全部拿不到。这里回显 Origin 而不是写死 `*`，因为登录要带 cookie。
 */
const withCors = (request: Request, response: Response): Response => {
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/api/")) return response;
  const origin = request.headers.get("origin");
  if (!origin) return response;

  // 重建 Response 时不能带上 content-encoding / content-length：
  // Worker 拿到的 body 已经是解压过的，浏览器看到这两个头会再解一次，
  // 结果是请求直接以 TypeError: Load failed 结束（网易云扫码 check 就是这么挂的）。
  const headers = new Headers(response.headers);
  headers.delete("content-encoding");
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-credentials", "true");
  headers.set("vary", "origin");
  headers.set("access-control-expose-headers", "set-cookie, content-range, accept-ranges");

  // Headers 会把重复的 Set-Cookie 合并掉，这里逐条补回去（登录态就靠它）。
  // 同时补 SameSite=None; Secure：页面来源是 capacitor://localhost 时属于「跨站」，
  // 不带这两个属性的 cookie 会被 WebKit 直接丢弃 —— 表现就是「登录提示成功但下一次请求仍是匿名」。
  const setCookies = (response.headers as unknown as { getSetCookie?: () => string[] }).getSetCookie?.() ?? [];
  if (setCookies.length > 0) {
    headers.delete("set-cookie");
    for (const raw of setCookies) {
      let line = raw;
      if (!/samesite=/i.test(line)) line += "; SameSite=None";
      if (!/;\s*secure/i.test(line)) line += "; Secure";
      headers.append("set-cookie", line);
    }
  }

  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
};

// 备用隧道：两条 quick tunnel 指向同一台服务器的同一个 nginx。
// quick tunnel 偶尔在 Cloudflare 边缘抖 100 秒级别，单条隧道会让扫码登录整段失败，
// 所以这里按"主 → 备"顺序重试，任一成功即返回。
const NETEASE_BACKUP_BASE = "https://enclosure-sailing-senate-taken.trycloudflare.com";

/**
 * 依次尝试主、备基址取数。
 *
 * `buildUrl` 把基址拼成完整 URL；请求体会按次 clone，避免 POST 在第二次尝试时已经被消费。
 * 两次都失败时优先把"最后一次真实响应"返回给调用方，保持与单隧道时的错误语义一致。
 */
const fetchWithBackup = async (
  buildUrl: (base: string) => string,
  request: Request,
  signal?: AbortSignal,
): Promise<Response> => {
  let lastResponse: Response | null = null;
  const bases = ["", NETEASE_BACKUP_BASE];
  for (const base of bases) {
    try {
      const attempt = await fetch(new Request(buildUrl(base), request.clone()), { signal });
      if (attempt.status < 500) return attempt;
      lastResponse = attempt;
    } catch (error) {
      if (lastResponse) continue;
      throw error;
    }
  }
  if (lastResponse) return lastResponse;
  throw new Error("both backend tunnels unreachable");
};

const foliaFetch = async (request: Request, env: Env): Promise<Response> => {
    const url = new URL(request.url);

    if (url.pathname === "/api/generate-theme") {
      return handleGenerateTheme(request, env);
    }

    if (url.pathname === "/api/generate-theme_openai") {
      return handleGenerateOpenAITheme(request, env);
    }

    if (url.pathname === "/api/lyric-proxy") {
      // QQ 音乐对 Cloudflare 出口 IP 风控（code 2001），本机直连正常（code 0）。
      // 目标域名是 QQ 系时改走本机代理（qq-proxy 服务 + 隧道），其余仍由 Worker 直连。
      try {
        const target = new URL(url.searchParams.get("url") || "");
        if (/(^|\.)(qq\.com|gtimg\.cn)$/.test(target.hostname)) {
          // QQ 音乐按来源 IP 风控：机房 IP（云服务器）拿到 code 2001，只有住宅宽带 IP 能过。
          // 先走云服务器；正文出现 2001 就回落到用户自己电脑上的代理（住宅 IP）。
          // 电脑关机时回落也失败，此时返回服务器原始响应，表现只是「QQ 搜不到」，不影响其它平台。
          const QQ_PROXY_SERVER = "https://personals-viewed-bradford-kings.trycloudflare.com/qq";
          const QQ_PROXY_HOME = "https://placed-vintage-precision-donate.trycloudflare.com/qq";
          let fromServer: Response | null = null;
          try {
            fromServer = await fetch(new Request(QQ_PROXY_SERVER + url.pathname + url.search, request.clone()));
            if (fromServer.status < 500) {
              const body = await fromServer.clone().text();
              if (!body.includes('"code":2001') && !body.includes('"code": 2001')) return fromServer;
            }
          } catch { /* 服务器路失败，继续试住宅路 */ }
          try {
            const viaHome = await fetch(new Request(QQ_PROXY_HOME + url.pathname + url.search, request.clone()));
            if (viaHome.status < 500) return viaHome;
          } catch { /* 电脑关机或家用隧道失效 */ }
          if (fromServer) return fromServer;
          return handleLyricProxy(request);
        }
      } catch { /* fallthrough */ }
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
        const KUGOU_BASE = "https://personals-viewed-bradford-kings.trycloudflare.com/kugou";
        // 只把登录/账号相关路径交给本机 KuGouMusicApi；搜索与播放走 Worker 原生实现
        // （原生 tracker 能拿到可播直链，而本机库的 /song/url 会返回 20028「本次请求需要验证」）。
        const kugouPath = url.pathname.slice("/api/kugou".length);
        // 用户登录后，取流必须交给本机 KuGouMusicApi：会员曲目的播放地址由账号鉴权决定，
        // 而 Worker 原生实现只走匿名 tracker，登录了也照样返回 code 2（「会员歌还是听不了」）。
        // 因此带 cookie 的播放请求优先走隧道，失败或无 url 时再退回原生匿名实现。
        const hasAccountCookie = Boolean(url.searchParams.get("cookie"));
        const isPlaybackPath = kugouPath.startsWith("/audio")
          || kugouPath.startsWith("/song/url")
          || kugouPath.startsWith("/krm/audio");
        if (hasAccountCookie && isPlaybackPath) {
          try {
            const upstream = await fetch(new Request(KUGOU_BASE + kugouPath + url.search, request));
            if (upstream.ok) {
              const body = await upstream.text();
              let parsed: any = null;
              try { parsed = JSON.parse(body); } catch { parsed = null; }
              // 本机 KuGouMusicApi 与 Worker 原生实现的响应形状不一致（一个顶层 url、一个 data 里带 url），
              // 前端是按下标/字段去取的，所以这里统一成前端的期望形状，避免"登录后反而播不了"。
              const urlFromBody = parsed?.url
                ?? parsed?.data?.url
                ?? (Array.isArray(parsed?.data) ? parsed.data[0]?.url : undefined)
                ?? undefined;
              const upstreamCode = parsed?.error_code ?? parsed?.errcode;
              const failed = !urlFromBody
                || parsed?.status === 0
                || upstreamCode === 2
                || upstreamCode === 152
                || upstreamCode === 20028;
              if (!failed) {
                return new Response(JSON.stringify({
                  status: 1,
                  errcode: 0,
                  url: String(urlFromBody),
                  data: [{ url: String(urlFromBody) }],
                }), { status: 200, headers: { "content-type": "application/json; charset=utf-8" } });
              }
            }
          } catch (error) { /* 隧道不可用：退回下面的原生实现 */ }
        }
        const needsTunnel = !(kugouPath.startsWith("/search") || kugouPath.startsWith("/song/url") || kugouPath.startsWith("/audio") || kugouPath.startsWith("/krm/audio"));
        if (!needsTunnel) return await handleKugou(request, url);
        const target = KUGOU_BASE + kugouPath + url.search;
        try {
          const upstream = await fetch(new Request(target, request));
          if (url.pathname.indexOf("/login/qr/check") >= 0) {
            try {
              const txt = await upstream.clone().text();
              kugouDebugEvents.push({ at: Date.now(), body: txt.slice(0, 600) });
              if (kugouDebugEvents.length > 5) kugouDebugEvents.shift();
            } catch (e) { /* ignore */ }
          }
          if (upstream.ok) return await mergeSetCookie(upstream);
        } catch (error) { /* 隧道不可用，走下面的兜底 */ }
        // 需要登录态的接口（歌单/用户信息）拿不到时，返回"空"而不是报错，
        // 这样界面显示"暂无内容"，不会出现"加载失败"。
        if (kugouPath.startsWith("/user")) {
          return new Response(JSON.stringify({ status: 1, error_code: 0, data: { lists: [], total: 0 } }), {
            status: 200,
            headers: { "content-type": "application/json; charset=utf-8" },
          });
        }
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

    // 网易云原生兜底：本机隧道不可用时（Cloudflare Worker 无法回连 trycloudflare，会 530），
    // 直接用网易云公开接口兜住搜索 / 歌词 / 取流，让"电脑关机也能播"。
    const nativeNetease = async (pathname: string, searchParams: URLSearchParams): Promise<Response | null> => {
      const pick = (name: string, fallback = "") => searchParams.get(name) ?? fallback;
      const headers = {
        "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "referer": "https://music.163.com/",
        "accept": "application/json",
      };
      const json = (body: unknown) => new Response(JSON.stringify(body), {
        headers: { "content-type": "application/json; charset=utf-8", "set-cookie": "keep-alive" },
      });
      try {
        if (pathname === "/search" || pathname === "/cloudsearch") {
          const keyword = pick("keywords") || pick("s");
          const limit = pick("limit", "30");
          const offset = pick("offset", "0");
          const upstream = await fetch(
            `https://music.163.com/api/search/get?s=${encodeURIComponent(keyword)}&type=1&limit=${limit}&offset=${offset}`,
            { headers },
          );
          const data: any = await upstream.json();
          const songs = (data?.result?.songs || []).map((song: any) => ({
            id: song.id,
            name: song.name,
            artists: (song.artists || []).map((artist: any) => ({ id: artist.id, name: artist.name })),
            album: song.album ? { id: song.album.id, name: song.album.name, picUrl: song.album.picUrl } : undefined,
            duration: song.duration,
          }));
          return json({ code: 200, result: { songs, songCount: songs.length } });
        }
        if (pathname === "/lyric") {
          const id = pick("id");
          const upstream = await fetch(
            `https://music.163.com/api/song/lyric?id=${encodeURIComponent(id)}&lv=1&kv=1&tv=-1`,
            { headers },
          );
          const data: any = await upstream.json();
          return json({ code: 200, lrc: data?.lrc, klyric: data?.klyric, tlyric: data?.tlyric });
        }
        if (pathname === "/login/qr/key") {
          // 扫码第一步：unikey。路径与参数对齐 NeteaseCloudMusicApi（/api/login/qrcode/unikey -> weapi，type:3）。
          const data: any = await neteaseWeapiRequest("/weapi/login/qrcode/unikey", { type: 3 });
          return json({ code: 200, data: data ?? {} });
        }
        if (pathname === "/login/qr/create") {
          // 扫码第二步：二维码。NeteaseCloudMusicApi 这一步不请求上游，而是本地拼 qrurl + 生成 PNG，
          // Worker 里用 qrcode 包做同样的事。响应形状必须与框架一致：{ code:200, data:{ qrurl, qrimg } }。
          const key = pick("key");
          const qrurl = `https://music.163.com/login?codekey=${encodeURIComponent(key)}`;
          let qrimg = "";
          try {
            qrimg = await QRCode.toDataURL(qrurl, { margin: 1, width: 320, color: { dark: "#000000", light: "#ffffff" } });
          } catch (error) {
            console.error("[worker] qrcode render failed:", error);
          }
          return json({ code: 200, data: { qrurl, qrimg } });
        }
        if (pathname === "/login/qr/check") {
          // 扫码第三步：长轮询（网易侧会挂到确认/过期，约 20 秒），绝不能套 12 秒上限。
          // 登录成功的 cookie 在响应头的 Set-Cookie 里，手动拼进 body.cookie（与框架行为一致）。
          const key = pick("key");
          const { params, encSecKey } = await neteaseWeapi({ key, type: 3 });
          const upstream = await fetch("https://music.163.com/weapi/login/qrcode/client/login", {
            method: "POST",
            headers: {
              "content-type": "application/x-www-form-urlencoded",
              "referer": "https://music.163.com/",
              "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
              "cookie": (neteaseAnonCookie ? neteaseAnonCookie + "; " : "") + "os=pc; appver=2.9.7; channel=netease;",
            },
            body: new URLSearchParams({ params, encSecKey }).toString(),
          });
          const data: any = await upstream.json().catch(() => ({}));
          const rawCookies = (upstream.headers as unknown as { getSetCookie?: () => string[] }).getSetCookie?.() ?? [];
          data.cookie = rawCookies.join("; ");
          return json(data ?? { code: 800, message: "expired" });
        }
        if (pathname === "/song/url") {
          const id = pick("id");
          await ensureNeteaseAnonCookie().catch(() => "");
          const data: any = await neteaseWeapiRequest("/weapi/song/enhance/player/url", {
            ids: `[${id}]`,
            br: 320000,
          });
          const fixed = JSON.stringify(data).replace(/http:\/\/([a-z0-9.-]+\.)?(music\.126\.net|126\.net)/g, "https://$1$2");
          return new Response(fixed, { headers: { "content-type": "application/json; charset=utf-8" } });
        }
        if (pathname === "/song/detail" || pathname === "/song/detail/") {
          const ids = pick("ids");
          const upstream = await fetch(`https://music.163.com/api/song/detail?ids=[${encodeURIComponent(ids)}]`, { headers });
          const body = await upstream.text();
          const fixed = body.replace(/http:\/\/([a-z0-9.-]+\.)?(music\.126\.net|126\.net)/g, "https://$1$2");
          return new Response(fixed, { headers: { "content-type": "application/json; charset=utf-8" } });
        }
        return null;
      } catch (error) {
        console.error("[worker] native netease failed:", error);
        return null;
      }
    };

    // 网易云：后端在本机（NeteaseCloudMusicApi）+ Cloudflare Tunnel，前端统一走同源 /api/netease。
    if (url.pathname === "/api/netease" || url.pathname.startsWith("/api/netease/")) {
      const NETEASE_BASE = "https://personals-viewed-bradford-kings.trycloudflare.com/netease";
      try {
        // 本机 NeteaseCloudMusicApi 偶尔会在 /song/url 上挂很久（上游网易云不响应），
        // 前端就会一直停在「正在获取歌曲链接」。这里给 12 秒上限，超时立刻返回 504，
        // 让界面走失败提示而不是无限等待。
        // 扫码登录路径：服务器隧道优先，原生仅兜底。
        // 原生（CF 出口）做 check 会被网易风控（-462 验证码 / 800 过期，共享出口 IP 串号），
        // 北京服务器上的 NeteaseCloudMusicApi 反而是稳定的（匿名 cookie + 固定 IP）。
        if (url.pathname === "/api/netease/login/qr/key"
          || url.pathname === "/api/netease/login/qr/create"
          || url.pathname === "/api/netease/login/qr/check") {
          const qrPath = url.pathname.slice("/api/netease".length);
          try {
            const qrUpstream = await fetchWithBackup(
              (base: string) => `${base || NETEASE_BASE}${qrPath}${url.search}`,
              request,
              AbortSignal.timeout(30000),
            );
            if (qrUpstream.status < 500) return qrUpstream;
          } catch { /* 隧道失败，走原生兜底 */ }
          const qrNative = await nativeNetease(qrPath, url.searchParams);
          if (qrNative) return qrNative;
        }
        // ?native=1 强制走 Cloudflare 原生实现（用于验证/无需本机电脑的场景）
        if (url.searchParams.get("native") === "1") {
          const forced = await nativeNetease(url.pathname.slice("/api/netease".length) || "/", url.searchParams);
          if (forced) return forced;
        }
        // 扫码登录是长轮询（check 可能要挂十几秒），12 秒会把它掐断，浏览器侧就报 Load failed。
        // 登录相关路径给 30 秒，其它接口仍保持 12 秒的快速失败。
        const neteaseTimeoutMs = url.pathname.includes("/login/") ? 30000 : 12000;
        const upstreamSignal = AbortSignal.timeout(neteaseTimeoutMs);
        const startedAt = Date.now();
        const neteasePath = url.pathname.slice("/api/netease".length) + url.search;
        const buildNeteaseUrl = (base: string) => `${base || NETEASE_BASE}${neteasePath}`;
        let upstream = await fetchWithBackup(buildNeteaseUrl, request, upstreamSignal);
        // quick tunnel 偶发 530（边缘没连上源站），等 300ms 重试一次通常就通；
        // 用户看到的「加载失败 … returned HTTP 530 without a JSON body」就是这一次抖动。
        if (upstream.status >= 500) {
          await new Promise((resolve) => setTimeout(resolve, 300));
          try {
            upstream = await fetchWithBackup(buildNeteaseUrl, request, AbortSignal.timeout(neteaseTimeoutMs));
          } catch { /* 保持第一次的结果，交给下面的兜底 */ }
        }
        // 网易云下发的播放直链是 http://…music.126.net，https 页面里会被当作混合内容拦截。
        // 这里把 JSON 响应里的这些地址统一升成 https（126.net 的 https 可用，已实测 206 audio/mpeg）。
        if (upstream.status >= 500) {
          const neteasePath = url.pathname.slice("/api/netease".length) || "/";
          const native = await nativeNetease(neteasePath, url.searchParams);
          if (native) return native;
          // 隧道与原生兜底都不可用：返回结构化错误，避免把 Cloudflare 的 530 HTML 丢给前端，
          // 那样界面会一直转圈而不是给出「音源不可用」的明确提示。
          // 把上游状态码和耗时写进 message：客户端诊断面板会原样显示，
          // 不用 wrangler tail 也能判断是"上游慢"还是"链路断"。
          return new Response(JSON.stringify({
            code: 503,
            message: `netease backend offline (upstream=${upstream.status}, took=${Date.now() - startedAt}ms)`,
          }), { status: 200, headers: { "content-type": "application/json; charset=utf-8" } });
        }
        console.log("[netease]", request.method, neteasePath, "->", upstream.status, Date.now() - startedAt, "ms");
        const upstreamType = upstream.headers.get("content-type") || "";
        if (upstreamType.includes("application/json")) {
          const text = await upstream.text();
          const fixed = text.replace(/http:\/\/([a-z0-9.-]+\.)?(music\.126\.net|126\.net)/g, "https://$1$2");
          // 登录态靠 cookie 传递：NeteaseCloudMusicApi 在登录成功后用 Set-Cookie 下发 MUSIC_U，
          // 之前这里重建 Response 时把 Set-Cookie 丢了，前端拿不到 cookie，于是「登录提示成功但下一次
          // 请求又是匿名」——表现就是登录错误、搜索/歌单用不了。这里把 Set-Cookie 带过去并合并进 JSON。
          const headers = new Headers({ "content-type": "application/json; charset=utf-8" });
          const rawCookies = (upstream.headers as any).getSetCookie ? (upstream.headers as any).getSetCookie() : [];
          for (const line of rawCookies as string[]) headers.append("set-cookie", line);
          const rebuilt = new Response(fixed, { status: upstream.status, headers });
          return await mergeSetCookie(rebuilt);
        }
        return upstream;
      } catch (error) {
        const neteasePath = url.pathname.slice("/api/netease".length) || "/";
        const native = await nativeNetease(neteasePath, url.searchParams);
        if (native) return native;
        const aborted = (error as Error)?.name === "TimeoutError" || (error as Error)?.name === "AbortError";
        return new Response(
          JSON.stringify({
            code: aborted ? 504 : 502,
            message: `${aborted ? "netease upstream timeout" : "netease tunnel unreachable"} (took=${Date.now() - startedAt}ms, ${String((error as Error)?.name ?? error)})`,
          }),
          { status: aborted ? 504 : 502, headers: { "content-type": "application/json" } },
        );
      }
    }

    const assetResponse = await env.ASSETS.fetch(request);
    // HTML 永远回源：边缘缓存过的旧 index 会引用已经被新构建替换掉的 chunk，
    // 表现就是模块图补不齐、页面永远白屏（换网络也没用）。
    // 带内容哈希的 /assets/* 可以永久缓存：这样启动时的「预取 + import」第二次直接从本地拿，
    // 弱网不会把 2MB 主包下载两遍（之前 max-age=0 会强制回源，等于白预取）。
    if (url.pathname.startsWith("/assets/")) {
      const assetHeaders = new Headers(assetResponse.headers);
      assetHeaders.set("cache-control", "public, max-age=31536000, immutable");
      return new Response(assetResponse.body, { status: assetResponse.status, headers: assetHeaders });
    }

    const contentType = assetResponse.headers.get("content-type") || "";
    // boot-manifest.json 里的文件名每次构建都会变，必须不缓存，否则客户端会预取旧地址。
    if (contentType.includes("text/html") || url.pathname === "/boot-manifest.json") {
      const headers = new Headers(assetResponse.headers);
      headers.set("cache-control", "no-store, no-cache, must-revalidate");
      headers.set("pragma", "no-cache");
      return new Response(assetResponse.body, { status: assetResponse.status, headers });
    }
    return assetResponse;
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // 预检请求直接放行，避免跨域的写操作（登录、收藏）被浏览器拦掉。
    if (request.method === "OPTIONS" && url.pathname.startsWith("/api/")) {
      const origin = request.headers.get("origin") || "*";
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-credentials": "true",
          "access-control-allow-methods": "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
          "access-control-allow-headers": request.headers.get("access-control-request-headers") || "content-type",
          "access-control-max-age": "86400",
          vary: "origin",
        },
      });
    }
    return withCors(request, await foliaFetch(request, env));
  },
};
