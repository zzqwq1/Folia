// worker/kugou.ts
// 酷狗音乐的原生实现（不再依赖已停用的 Vercel 后端）。
// 目前覆盖搜索；播放直链、扫码登录、歌单后续按同样方式补齐。
// 上游是酷狗的公开接口，无需签名：
//   GET https://songsearch.kugou.com/song_search_v2?keyword=&page=&pagesize=&format=json

import { md5Hex } from './bodian.ts';

const SEARCH_URL = 'https://songsearch.kugou.com/song_search_v2';
const TRACKER_URL = 'https://trackercdn.kugou.com/i/v2/';

const json = (body: unknown, status = 200): Response => new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' },
});

type KugouSong = {
    FileHash?: string;
    SongName?: string;
    SingerName?: string;
    AlbumName?: string;
    AlbumID?: string | number;
    Duration?: number;
    FileSize?: number;
    HQFileHash?: string;
    SQFileHash?: string;
    ResFileHash?: string;
    Image?: string;
};

/** 把酷狗搜索的原始行映射成前端 provider 认识的字段（与 KuGouMusicApi 的 /search 同形）。 */
const toListItem = (row: KugouSong) => ({
    FileHash: String(row.FileHash || ''),
    SongName: String(row.SongName || ''),
    SingerName: String(row.SingerName || ''),
    Singername: String(row.SingerName || ''),
    AlbumName: String(row.AlbumName || ''),
    AlbumID: String(row.AlbumID ?? ''),
    Duration: Number(row.Duration) || 0,
    FileSize: Number(row.FileSize) || 0,
    HQFileHash: String(row.HQFileHash || ''),
    SQFileHash: String(row.SQFileHash || ''),
    ResFileHash: String(row.ResFileHash || ''),
    Image: String(row.Image || ''),
});

export const handleKugou = async (request: Request, url: URL): Promise<Response> => {
    const path = url.pathname.replace(/^\/api\/kugou/, '') || '/';
    if (path === '/search') {
        const keyword = (url.searchParams.get('keyword') || '').trim();
        if (!keyword) return json({ status: 1, data: { lists: [], total: 0 } });
        const page = Math.max(1, Number(url.searchParams.get('page')) || 1);
        const pagesize = Math.min(50, Math.max(1, Number(url.searchParams.get('pagesize')) || 20));
        const target = `${SEARCH_URL}?keyword=${encodeURIComponent(keyword)}&page=${page}&pagesize=${pagesize}&format=json`;
        let response: Response;
        try {
            response = await fetch(target, {
                headers: {
                    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36',
                    accept: 'application/json',
                },
            });
        } catch (error) {
            return json({ status: 0, error: `kugou search unreachable: ${String(error)}` }, 502);
        }
        if (!response.ok) return json({ status: 0, error: `kugou search failed: ${response.status}` }, response.status);
        const payload: any = await response.json().catch(() => null);
        const data = payload?.data || {};
        const rows: KugouSong[] = Array.isArray(data.info) ? data.info : Array.isArray(data.lists) ? data.lists : [];
        return json({
            status: 1,
            error_code: 0,
            data: {
                lists: rows.map(toListItem),
                total: Number(data.total) || rows.length,
            },
        });
    }
    if (path === '/song/url') {
        const hash = (url.searchParams.get('hash') || '').trim();
        if (!/^[a-f0-9]{32}$/i.test(hash)) return json({ status: 0, error: 'hash is required' }, 400);
        const quality = (url.searchParams.get('quality') || 'high').toLowerCase();
        // hq / sq / 128 对应不同 br 参数；取不到时退回 hq。
        const br = quality === 'lossless' ? 'sq' : quality === 'standard' ? '128' : 'hq';
        const key = md5Hex(hash + 'kgcloudv2');
        const target = `${TRACKER_URL}?key=${key}&hash=${hash}&br=${br}&appid=1005&pid=2&cmd=25&behavior=play`;
        let response: Response;
        try {
            response = await fetch(target, {
                headers: { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36' },
            });
        } catch (error) {
            return json({ status: 0, error: `kugou tracker unreachable: ${String(error)}` }, 502);
        }
        const payload: any = await response.json().catch(() => null);
        const urls: string[] = Array.isArray(payload?.url) ? payload.url : payload?.url ? [payload.url] : [];
        const playUrl = urls.find((item: string) => /^https?:\/\//.test(item)) || '';
        if (!playUrl) {
            return json({ status: 0, error: `kugou tracker returned no url (code ${payload?.error ?? payload?.status ?? '?'})` }, 502);
        }
        return json({
            status: 1,
            errcode: 0,
            url: playUrl,
            data: { url: playUrl, quality: br === 'sq' ? 'lossless' : br === '128' ? 'standard' : 'high', size: Number(payload?.fileSize) || 0 },
        });
    }

    return json({ status: 0, error: `kugou route not implemented yet: ${path}` }, 501);
};
