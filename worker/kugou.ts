// worker/kugou.ts
// 酷狗音乐的原生实现（不再依赖已停用的 Vercel 后端）。
// 目前覆盖搜索；播放直链、扫码登录、歌单后续按同样方式补齐。
// 上游是酷狗的公开接口，无需签名：
//   GET https://songsearch.kugou.com/song_search_v2?keyword=&page=&pagesize=&format=json

import { md5Hex } from './bodian.ts';

const SEARCH_URL = 'https://songsearch.kugou.com/song_search_v2';
const TRACKER_URL = 'https://trackercdn.kugou.com/i/v2/';

/** 记录播放代理被调用的情况，用来判断前端到底有没有走同源代理。 */
const streamHits: Array<{ at: number; range: string; ok: boolean }> = [];

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
    if (path === '/search/lyric') {
        // 前端先按 hash/关键词搜歌词候选，返回 candidates（含 id/accesskey）。
        const hash = (url.searchParams.get('hash') || url.searchParams.get('fileHash') || '').trim();
        // 注意：`man` 是「是否要多个候选」的开关，绝不能当关键词用。
        // 之前的写法把 man=no 传成了 keyword=no，会让 krcs 匹配到别的版本（比如现场版），
        // 时间轴对不上，表现就是「歌词和声音不同步」。
        const keyword = (url.searchParams.get('keyword') || '').trim();
        const man = url.searchParams.get('man') || 'no';
        const duration = url.searchParams.get('duration') || '';
        const albumAudioId = url.searchParams.get('album_audio_id') || '';
        const requestedMs = Number(duration) || 0;
        const searchUrl = 'https://krcs.kugou.com/search?ver=1&man=' + encodeURIComponent(man)
            + '&client=mobi'
            + (keyword ? '&keyword=' + encodeURIComponent(keyword) : '')
            + (duration ? '&duration=' + encodeURIComponent(duration) : '')
            + (albumAudioId ? '&album_audio_id=' + encodeURIComponent(albumAudioId) : '')
            + (hash ? '&hash=' + hash : '');
        try {
            const response = await fetch(searchUrl, { headers: { 'user-agent': 'Mozilla/5.0' } });
            const payload: any = await response.json().catch(() => null);
            const candidates = (payload?.candidates || []).map((item: any) => ({
                id: String(item.id ?? ''), accesskey: String(item.accesskey ?? ''),
                song: item.song ?? '', singer: item.singer ?? '', duration: item.duration ?? '',
            }));
            // 按时长接近度排序：时长差得越少，越可能是同一个录音版本，时间轴才对得上。
            if (requestedMs > 0) {
                candidates.sort((a: any, b: any) => {
                    const da = Math.abs(Number(a.duration) - requestedMs) || Number.MAX_SAFE_INTEGER;
                    const db = Math.abs(Number(b.duration) - requestedMs) || Number.MAX_SAFE_INTEGER;
                    return da - db;
                });
            }
            return json({ status: 200, candidates, data: candidates });
        } catch (error) {
            return json({ status: 200, candidates: [], data: [], error: String(error) });
        }
    }
    if (path === '/lyric') {
        // 前端拿 id + accesskey 取歌词文本，读的是 decodeContent。
        const id = url.searchParams.get('id') || '';
        const accesskey = url.searchParams.get('accesskey') || '';
        // krc 是二进制歌词，atob 后无法当文本用；统一取 lrc 文本，保证能显示。
        const fmt = 'lrc';
        if (!id || !accesskey) return json({ status: 200, decodeContent: '', lyric: '' });
        const dlUrl = 'https://lyrics.kugou.com/download?ver=1&client=pc&id=' + encodeURIComponent(id)
            + '&accesskey=' + encodeURIComponent(accesskey) + '&fmt=' + encodeURIComponent(fmt) + '&charset=utf8';
        try {
            const response = await fetch(dlUrl, { headers: { 'user-agent': 'Mozilla/5.0', referer: 'https://www.kugou.com/' } });
            const payload: any = await response.json().catch(() => null);
            let text = '';
            if (payload?.content) {
                try { text = atob(payload.content); } catch { text = String(payload.content); }
            }
            return json({ status: 200, decodeContent: text, lyric: text, data: { lyric: text } });
        } catch (error) {
            return json({ status: 200, decodeContent: '', lyric: '', error: String(error) });
        }
    }

    if (path === '/audio' || path === '/krm/audio' || path === '/song/url') {
        // 前端播放走的是 /audio（不是 /song/url），这里统一处理。
        const hash = (url.searchParams.get('hash') || url.searchParams.get('fileHash')
            || url.searchParams.get('id') || '').trim();
        if (!/^[a-f0-9]{32}$/i.test(hash)) return json({ status: 0, error: 'hash is required' }, 400);
        const quality = (url.searchParams.get('quality') || url.searchParams.get('level') || 'high').toLowerCase();
        const attempts: string[] = quality === 'lossless' ? ['sq', 'hq', '128']
            : quality === 'standard' ? ['128', 'hq']
            : ['hq', '128', 'sq'];
        let playUrl = '';
        let usedBr = '';
        let lastCode: unknown = '';
        for (const br of attempts) {
            const key = md5Hex(hash + 'kgcloudv2');
            const tracker = TRACKER_URL + '?key=' + key + '&hash=' + hash + '&br=' + br
                + '&appid=1005&pid=2&cmd=25&behavior=play';
            try {
                const response = await fetch(tracker, { headers: { 'user-agent': 'Mozilla/5.0' } });
                const payload: any = await response.json().catch(() => null);
                lastCode = payload?.error ?? payload?.status ?? '';
                const urls: string[] = Array.isArray(payload?.url) ? payload.url : payload?.url ? [payload.url] : [];
                const found = urls.find((item: string) => /^https?:\/\//.test(item));
                if (found) { playUrl = found.replace(/^http:\/\//, 'https://'); usedBr = br; break; }
            } catch { /* next */ }
        }
        if (!playUrl) return json({ status: 0, error: 'kugou tracker returned no url (code ' + String(lastCode) + ')' }, 502);
        return json({
            status: 1,
            errcode: 0,
            url: playUrl,
            data: { url: playUrl, quality: usedBr === 'sq' ? 'lossless' : usedBr === '128' ? 'standard' : 'high' },
        });
    }

    return json({ status: 0, error: `kugou route not implemented yet: ${path}` }, 501);
};
