// worker/bodian.ts
// 波点音乐（酷我 bd-api）在同源 Worker 里的实现。
// 桌面版走 Electron 主进程的 bodian-music-api；网页/App 没有那个桥，所以这里按同一套协议复刻：
//   GET/POST https://bd-api.kuwo.cn{path} + desktop 头 + md5 签名（盐 kuwotest）
// 会话（uid/token）由前端保存并在每次请求里带过来，Worker 不存任何凭据。

import QRCode from 'qrcode';

const API_ORIGIN = 'https://bd-api.kuwo.cn';
const LYRIC_ORIGIN = 'https://mlyric.kuwo.cn';
const SALT = 'kuwotest';
// 稳定的设备标识（32 位小写 hex）。同一实例共用一个，够用；要隔离可以改成按客户端生成。
const DEVICE_ID = '3f7c1a9d52b84e0fa6c3d81b4e2f7a95';
// 上游请求超时：酷我有时挂起不回，无限等会让前端一直转圈。8s 内没回就明确报错。
const UPSTREAM_TIMEOUT_MS = 8000;

// ── 歌词解码（复刻 bodian-music-api 的 lyrics.cjs） ──────────────────────
const decodeBodianWordTiming = (content: string): string | null => {
    const tag = content.match(/\[kuwo:([0-7]+)(?:\]\[.*)?\]/);
    const factors = tag ? parseInt(tag[1], 8) : 11;
    const startFactor = Math.trunc(factors / 10);
    const durationFactor = factors % 10;
    if (!startFactor || !durationFactor) return null;
    return content.replace(/\[kuwo:[^\]]*\]/g, '').replace(/<(-?\d+),(-?\d+)>/g, (_match, left, right) => {
        const a = Number(left), b = Number(right);
        const start = Math.trunc(Math.abs((a + b) / (2 * startFactor)));
        const duration = Math.trunc(Math.abs((a - b) / (2 * durationFactor)));
        return `<${start},${duration}>`;
    });
};

const decodeLyrics = (content: string): { mainText: string; wordByWordText: string | null } => ({
    mainText: content.replace(/<-?\d+,-?\d+>/g, '').replace(/\[kuwo:[^\]]*\]/g, ''),
    wordByWordText: /<-?\d+,-?\d+>/.test(content) ? decodeBodianWordTiming(content) : null,
});

// ── md5（Workers 的 WebCrypto 不保证支持 MD5，这里自带一份实现） ─────────────
const MD5 = (() => {
    const s = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    const K = new Int32Array(64);
    for (let i = 0; i < 64; i += 1) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;

    const rotl = (x: number, c: number) => (x << c) | (x >>> (32 - c));

    const toUtf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

    const md5 = (input: string): string => {
        const bytes = toUtf8(input);
        const bitLen = bytes.length * 8;
        const padded = new Uint8Array((((bytes.length + 8) >>> 6) + 1) << 6);
        padded.set(bytes);
        padded[bytes.length] = 0x80;
        const view = new DataView(padded.buffer);
        view.setUint32(padded.length - 8, bitLen >>> 0, true);
        view.setUint32(padded.length - 4, Math.floor(bitLen / 4294967296), true);

        let a0 = 0x67452301;
        let b0 = 0xefcdab89;
        let c0 = 0x98badcfe;
        let d0 = 0x10325476;

        for (let offset = 0; offset < padded.length; offset += 64) {
            const M = new Int32Array(16);
            for (let i = 0; i < 16; i += 1) M[i] = view.getInt32(offset + i * 4, true);
            let A = a0;
            let B = b0;
            let C = c0;
            let D = d0;
            for (let i = 0; i < 64; i += 1) {
                let F: number;
                let g: number;
                if (i < 16) { F = (B & C) | (~B & D); g = i; }
                else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
                else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
                else { F = C ^ (B | ~D); g = (7 * i) % 16; }
                const tmp = D;
                D = C;
                C = B;
                const sum = (A + F + K[i] + M[g]) | 0;
                B = (B + rotl(sum, s[(i >>> 4) * 4 + (i % 4)])) | 0;
                A = tmp;
            }
            a0 = (a0 + A) | 0;
            b0 = (b0 + B) | 0;
            c0 = (c0 + C) | 0;
            d0 = (d0 + D) | 0;
        }

        const out = new Uint8Array(16);
        const outView = new DataView(out.buffer);
        outView.setInt32(0, a0, true);
        outView.setInt32(4, b0, true);
        outView.setInt32(8, c0, true);
        outView.setInt32(12, d0, true);
        return Array.from(out).map(byte => byte.toString(16).padStart(2, '0')).join('');
    };

    return md5;
})();

/** 桌面协议：把编码后的 query 和 UTF-8 body 一起签名。 */
/** 供其它 provider 复用（酷狗 tracker 的 key 也用它）。 */
export const md5Hex = MD5;

const signQuery = (path: string, query: Record<string, string>, body = ''): string => {
    const encoded = new URLSearchParams(query).toString();
    let seed = `${SALT}${Array.from(encoded).filter(char => /[a-z0-9]/i.test(char)).sort().join('')}`;
    if (body) seed += MD5(`${body}${SALT}`);
    return MD5(`${seed}${path}`);
};

const desktopHeaders = (deviceId: string, uid: string, token: string): Record<string, string> => ({
    'User-Agent': 'Dart/3.3 (dart:io)',
    plat: 'win',
    channel: 'W1',
    ver: '1.1.7',
    svrver: '13',
    'api-ver': 'application/json',
    brand: 'Windows',
    net: 'wifi',
    devid: deviceId,
    qimei36: deviceId,
    'Content-Type': 'application/json',
    ...(uid && uid !== '-1' ? { uid, token } : {}),
});


/**
 * 把文本渲染成二维码 SVG（data URI）。只用 qrcode 的矩阵，不依赖 canvas/pngjs，
 * 所以在 Worker 里也能跑；返回的 data URI 直接塞给 <img src>。
 */
const qrSvgDataUri = (text: string): string => {
    const qr = QRCode.create(text, { errorCorrectionLevel: 'M' });
    const size = qr.modules.size;
    const data = qr.modules.data;
    const margin = 3;
    const dim = size + margin * 2;
    let path = '';
    for (let y = 0; y < size; y += 1) {
        for (let x = 0; x < size; x += 1) {
            if (data[y * size + x]) path += `M${x + margin},${y + margin}h1v1h-1z`;
        }
    }
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320" viewBox="0 0 ${dim} ${dim}" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="${path}" fill="#000"/></svg>`;
    return `data:image/svg+xml;base64,${btoa(svg)}`;
};

const json = (body: unknown, status = 200): Response => new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' },
});

const errorJson = (message: string, status = 502): Response => json({ error: message }, status);

/** 把酷我上游的错误码翻译成前端看得懂的原因（不再是无脑「连接失败」）。 */
const bodianUpstreamFailure = (code: number | undefined, msg?: string): Error => {
    const message = typeof msg === 'string' && msg.trim() ? msg.trim() : '';
    switch (code) {
        case 407: return new Error(`region-restricted: ${message || '该内容仅限中国大陆地区使用'}`);
        case 11012: return new Error(`auth-required: ${message || '需要登录'}`);
        case 20018: return new Error(`not-playable: ${message || '该歌曲不可播放'}`);
        default: return new Error(message ? `bodian upstream code ${code ?? 'missing'} ${message}` : `bodian upstream code ${code ?? 'missing'}`);
    }
};

const callBd = async (
    path: string,
    options: { params?: Record<string, string | number>; body?: unknown; method?: string; signed?: boolean; uid?: string; token?: string; deviceId?: string } = {},
): Promise<any> => {
    const { params = {}, body, method = 'GET', signed = false, uid = '-1', token = '', deviceId = DEVICE_ID } = options;
    const query: Record<string, string> = { ...Object.fromEntries(Object.entries(params).map(([k, v]) => [k, String(v)])), uid, token };
    const bodyText = body === undefined ? '' : JSON.stringify(body);
    if (signed) {
        query.timestamp = String(Date.now());
        query.sign = signQuery(path, query, bodyText);
    }
    const url = new URL(path, API_ORIGIN);
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
    let response: Response;
    try {
        response = await fetch(url.toString(), {
            method,
            headers: desktopHeaders(deviceId, uid, token),
            body: bodyText || undefined,
            signal: controller.signal,
        });
    } catch (error) {
        clearTimeout(timer);
        if ((error as Error)?.name === 'AbortError') throw new Error('bodian upstream timed out');
        throw error;
    }
    clearTimeout(timer);
    const payload = await response.json().catch(() => null) as any;
    if (Number(payload?.code) !== 200) {
        throw bodianUpstreamFailure(Number(payload?.code), payload?.msg ?? payload?.message);
    }
    return payload;
};

const pageParams = (limit: number, offset: number, firstPage = 1) => {
    const rn = Math.min(Math.max(limit || 50, 1), 100);
    return { pn: Math.floor(offset / rn) + firstPage, rn };
};

const searchBody = (keyword: string, limit: number, offset: number) => {
    const { pn, rn } = pageParams(limit, offset, 0);
    return { keyword, correct: 1, pn, rn };
};

/** 对齐官方 SDK 的 pageData：给分页结果补上 bodianPagination（前端据此翻页/判定 hasMore）。 */
const pageResult = (data: any, field: string, limit: number, offset: number) => {
    const safe = data && typeof data === 'object' ? data : {};
    const raw = Array.isArray(safe[field]) ? safe[field] : [];
    const rn = Math.min(Math.max(limit || 50, 1), 100);
    const items = raw.slice(offset % rn);
    const pageEnd = (Math.floor(offset / rn) + 1) * rn;
    const total = Number(safe.total);
    const knownTotal = safe.total != null && Number.isSafeInteger(total) && total >= 0;
    const hasMore = raw.length > 0 && (knownTotal ? pageEnd < total : raw.length === rn);
    return {
        ...safe,
        [field]: items,
        bodianPagination: {
            nextOffset: hasMore ? pageEnd : Math.max(offset + items.length, knownTotal ? Math.min(pageEnd, total) : offset + items.length),
            hasMore,
        },
    };
};

const audioOf = async (musicId: string, quality: string, freeSign: string, uid: string, token: string, deviceId: string) => {
    const format = quality === 'lossless' || quality === 'hires'
        ? { format: 'flac', br: '2000kflac' }
        : quality === 'high'
            ? { format: 'mp3', br: '320kmp3' }
            : { format: 'mp3', br: '128kmp3' };
    const rightBody = { musicId: Number(musicId), freeSign };
    const right = (await callBd('/api/play/music/v2/checkRight', {
        params: { musicId, freeSign }, body: rightBody, signed: true, uid, token,
    })).data;
    if (Number(right?.status) === 3 && right.audition) {
        return {
            url: String(right.audition.https || right.audition.url || ''),
            quality: 'standard',
            fetchedAt: Date.now(),
            preview: { startTime: Number(right.audition.start), endTime: Number(right.audition.end) },
        };
    }
    const body = { devId: deviceId, musicId: Number(musicId), ...format, freeSign };
    const audio = (await callBd('/api/play/music/v2/audioUrl', {
        params: { ...body, musicId }, body, signed: true, uid, token,
    })).data;
    const url = String(audio?.audioHttpsUrl || audio?.audioUrl || '');
    if (!url) throw new Error('bodian returned no audio url');
    return { url, quality, fetchedAt: Date.now() };
};

/** /api/bodian?op=...&uid=...&token=... 的入口。 */
export const handleBodian = async (request: Request, url: URL): Promise<Response> => {
    if (request.method === 'OPTIONS') {
        return new Response(null, {
            status: 204,
            headers: { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET,POST,OPTIONS', 'access-control-allow-headers': '*' },
        });
    }
    const op = url.searchParams.get('op') || '';
    const dev = url.searchParams.get('dev') || '';
    const deviceId = /^[a-f0-9]{32}$/.test(dev) ? dev : DEVICE_ID;
    const uid = url.searchParams.get('uid') || '-1';
    const token = url.searchParams.get('token') || '';
    const limit = Number(url.searchParams.get('limit') || 50);
    const offset = Number(url.searchParams.get('offset') || 0);
    const id = url.searchParams.get('id') || '';
    try {
        switch (op) {
            case 'search': {
                const keyword = (url.searchParams.get('query') || '').trim();
                if (!keyword) return json({ resultList: [], total: 0, bodianPagination: { nextOffset: 0, hasMore: false } });
                const data = (await callBd('/api/search/music/list', { params: searchBody(keyword, limit, offset) })).data;
                return json(pageResult(data ?? {}, 'resultList', limit, offset));
            }
            case 'song_detail':
                return json((await callBd('/api/service/music/info', { params: { musicId: id } })).data);
            case 'audio': {
                const quality = url.searchParams.get('quality') || 'high';
                const freeSign = url.searchParams.get('freeSign') || '';
                return json(await audioOf(id, quality, freeSign, uid, token, deviceId));
            }
            case 'qr_key': {
                const data = (await callBd('/api/ucenter/login/qrCode', { signed: true, uid: '-1', token: '', deviceId })).data;
                return json({ key: String(data?.qrCode || '') });
            }
            case 'qr_create': {
                const key = url.searchParams.get('key') || '';
                if (!key) return errorJson('key is required', 400);
                const target = new URL('https://bodian-oia.kuwo.cn/bodian/download.html');
                target.search = new URLSearchParams({ pageName: 'login_pc', pt: '3', id: key }).toString();
                return json({ imageUrl: qrSvgDataUri(target.toString()) });
            }
            case 'qr_check': {
                const data = (await callBd('/api/ucenter/login/qrCodeStatus', { params: { qrCode: id }, signed: true, deviceId })).data;
                const status = Number(data?.status);
                if (status === 1) return json({ state: 'waiting' });
                if (status === 2) return json({ state: 'expired' });
                if (status !== 3) return json({ state: 'waiting' });
                const login = (await callBd('/api/ucenter/users/login', {
                    method: 'POST', body: { authType: 10, qrCode: id }, signed: true, deviceId,
                })).data;
                const raw = login?.userInfo || login?.user || login?.data?.userInfo || login?.data?.user || {};
                const uid = String(login?.uid ?? raw?.id ?? raw?.uid ?? login?.data?.uid ?? '');
                const token = String(login?.token || login?.data?.token || '');
                // 上游有时只给 uid/token，不给昵称头像；这时用一个占位昵称，别让账号刷新因为空身份失败。
                const nickname = String(raw?.nickname || raw?.name || raw?.userName || '') || '波点账号';
                const avatarUrl = String(raw?.headImg || raw?.avatarUrl || raw?.headImgUrl || '');
                if (!uid || !token) {
                    return json({ state: 'error', message: 'bodian login returned no session' });
                }
                return json({
                    state: 'confirmed',
                    session: { uid, token },
                    user: { id: uid, nickname, avatarUrl },
                });
            }
            case 'playlists': {
                // 桌面 SDK 的 user_playlists 返回 { owned, liked, collected }，其中每项都带 playLists 数组；
                // provider 侧按这个结构解析（缺字段会直接抛 invalid-response，登录后的账号刷新就会失败）。
                const params = { userId: uid, fromUid: uid };
                const [owned, liked, collected] = await Promise.all([
                    callBd('/api/service/playlist/userCreate', { params, uid, token, deviceId }).then(r => r.data).catch(() => null),
                    callBd('/api/service/playlist/fond', { params, uid, token, deviceId }).then(r => r.data).catch(() => null),
                    callBd('/api/service/collect/4/list', { params: { ...params, ...pageParams(limit, offset) }, uid, token }).then(r => r.data).catch(() => null),
                ]);
                const listsOf = (data: any): any[] => (
                    Array.isArray(data?.playLists) ? data.playLists : Array.isArray(data) ? data : []
                );
                return json({
                    owned: { playLists: listsOf(owned) },
                    liked: { playLists: listsOf(liked) },
                    collected: {
                        playLists: listsOf(collected),
                        bodianPagination: { nextOffset: offset, hasMore: false },
                    },
                });
            }
            case 'liked_songs': {
                const params = { userId: uid, fromUid: uid };
                const liked = await callBd('/api/service/playlist/fond', { params, uid, token, deviceId }).then(r => r.data).catch(() => null);
                const listId = liked?.id;
                if (!listId) return json({ list: [], total: 0 });
                const data = await callBd(`/api/service/playlist/${listId}/musicList`, {
                    params: { source: 5, ...pageParams(limit, offset) }, uid, token,
                }).then(r => r.data).catch(() => null);
                return json({ list: Array.isArray(data?.list) ? data.list : [], total: Number(data?.total) || 0 });
            }
            case 'user_albums':
                return json({ albumList: [], bodianPagination: { nextOffset: offset, hasMore: false } });
            case 'lyrics': {
                // 歌词走 mlyric.kuwo.cn，query 是 base64 编码的固定模板。
                const lyricQuery = `type=lyric&req=2&lrcx=1&rid=${id}&songname=&artist=&corp=kuwo&fromchannel=bodian`;
                const lyricUrl = new URL('/mobi.s', LYRIC_ORIGIN);
                lyricUrl.searchParams.set('f', 'bodian');
                lyricUrl.searchParams.set('q', btoa(lyricQuery));
                const lyricResp = await fetch(lyricUrl.toString(), { headers: desktopHeaders(deviceId, uid, token) });
                const lyricPayload = await lyricResp.json().catch(() => null) as any;
                const content = String(lyricPayload?.data?.content || '');
                if (!content) return json({ mainText: '', wordByWordText: null });
                const decoded = decodeLyrics(atob(content));
                return json(decoded);
            }
            case 'home_module': {
                const moduleId = Number(url.searchParams.get('moduleId') || 0);
                return json((await callBd('/api/service/home/module', { params: { moduleId }, uid, token, deviceId })).data);
            }
            case 'ai_playlist_detail': {
                const index = Number(url.searchParams.get('index') || 0);
                return json((await callBd('/api/service/home/aiPlaylistDetail', { params: { index }, uid, token, deviceId })).data);
            }
            case 'recommendations':
                return json((await callBd('/api/service/finds/playlist', { uid, token, deviceId })).data);
            case 'personal_fm':
                return json((await callBd('/api/service/music/recommendList', { uid, token, deviceId })).data);
            case 'playlist_detail': {
                const source = Number(url.searchParams.get('source') || 4);
                return json((await callBd(`/api/service/playlist/info/${id}`, { params: { source }, uid, token, deviceId })).data);
            }
            case 'playlist_tracks': {
                const source = Number(url.searchParams.get('source') || 4);
                const { pn, rn } = pageParams(limit, offset, 1);
                const data = (await callBd(`/api/service/playlist/${id}/musicList`, { params: { pn, rn, source }, uid, token, deviceId })).data;
                return json(pageResult(data ?? {}, 'list', limit, offset));
            }
            case 'album_detail':
                return json((await callBd(`/api/service/album/${id}`, { uid, token, deviceId })).data);
            case 'album_tracks': {
                const { pn, rn } = pageParams(limit, offset, 0);
                const data = (await callBd(`/api/service/album/music/${id}`, { params: { pn, rn }, uid, token, deviceId })).data;
                return json(pageResult(data ?? {}, 'resultList', limit, offset));
            }
            case 'artist_detail':
                return json((await callBd(`/api/service/artist/${id}`, { uid, token, deviceId })).data);
            case 'artist_songs': {
                const { pn, rn } = pageParams(limit, offset, 0);
                const data = (await callBd(`/api/service/artist/music/${id}`, { params: { pn, rn }, uid, token, deviceId })).data;
                return json(pageResult(data ?? {}, 'resultList', limit, offset));
            }
            case 'artist_albums': {
                const { pn, rn } = pageParams(limit, offset, 0);
                const data = (await callBd(`/api/service/artist/album/${id}`, { params: { pn, rn }, uid, token, deviceId })).data;
                return json(pageResult(data ?? {}, 'resultList', limit, offset));
            }
            case 'like_song': {
                // 找到"我喜欢"歌单，再往里面加/删歌曲。
                const liked = await callBd('/api/service/playlist/fond', { params: { userId: uid, fromUid: uid }, uid, token, deviceId }).then(r => r.data).catch(() => null);
                const listId = Number(liked?.id);
                if (!listId) return errorJson('bodian liked playlist not found', 502);
                const likedParam = url.searchParams.get('liked') === 'true';
                const musicId = Number(id);
                await callBd(`/api/service/playlist/music${likedParam ? '' : '/delete'}`, {
                    method: 'POST', body: { playListId: listId, musicIdList: [musicId] }, signed: true, uid, token, deviceId,
                });
                return json(null);
            }
            case 'login_qr_cancel':
                // 波点没有显式取消接口，前端清掉本地 key 即可。
                return json(null);
            default:
                // 账号刷新会连带很多可选能力：不认识的先回空结构，别用它把登录判失败。
                return json({});
        }
    } catch (error) {
        return errorJson(String((error as Error)?.message || error));
    }
};
