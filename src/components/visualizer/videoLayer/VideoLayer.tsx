import React, { useEffect, useRef } from 'react';
import { useShallow } from 'zustand/react/shallow';
import { PlayerState } from '../../../types';
import { currentTime } from '../../../stores/motionSignals';
import { selectDisplayPlayerState, selectDisplaySong, usePlaybackStore } from '../../../stores/usePlaybackStore';
import { ensureVideoLayerFileRestored, useVideoLayerSettingsStore } from '../../../stores/useVideoLayerSettingsStore';
import { setStatusMessage } from '../../../stores/useStatusMessageStore';

// src/components/visualizer/videoLayer/VideoLayer.tsx
// Built-in muted video behind the lyrics (above the background, under the lyrics). The video follows
// playback without any per-frame React work: play/pause follows the player state, a jump in the
// playback clock (seek, song change) re-aligns it, and slow drift is corrected every few seconds.
// The video position is the song position modulo the video length, so a short loop keeps cycling.

const DRIFT_CHECK_MS = 5000;
// iOS 上频繁 seek 会拖垮解码器并导致整个 WebView 被系统回收（闪退），
// 容差放宽到 1.5 秒、检查间隔拉到 5 秒，减少 seek 次数。
const DRIFT_TOLERANCE_SEC = 1.5;
// A clock step bigger than this between two ticks is a seek or a song change, not playback.
const CLOCK_JUMP_SEC = 1;

interface VideoLayerProps {
    /** The shell's pause signal (window hidden etc.); the video stops even while music plays. */
    paused: boolean;
}

const VideoLayer: React.FC<VideoLayerProps> = ({ paused }) => {
    const videoRef = useRef<HTMLVideoElement | null>(null);
    const pausedRef = useRef(paused);
    pausedRef.current = paused;
    const { enabled, url, opacity, fit, localFileUrl } = useVideoLayerSettingsStore(useShallow(state => ({
        enabled: state.videoLayerEnabled,
        url: state.videoLayerUrl,
        opacity: state.videoLayerOpacity,
        fit: state.videoLayerFit,
        localFileUrl: state.localFileUrl,
    })));
    const source = localFileUrl ?? (url || null);
    const active = enabled && Boolean(source);

    useEffect(() => {
        ensureVideoLayerFileRestored();
    }, []);

    useEffect(() => {
        const video = videoRef.current;
        if (!active || !video) return;

        const align = () => {
            if (!Number.isFinite(video.duration) || video.duration <= 0 || video.seeking) return;
            const target = currentTime.get() % video.duration;
            if (Math.abs(video.currentTime - target) > DRIFT_TOLERANCE_SEC) video.currentTime = target;
        };
        const followState = () => {
            const playing = selectDisplayPlayerState(usePlaybackStore.getState()) === PlayerState.PLAYING;
            if (playing && !pausedRef.current) void video.play().catch(() => {});
            else video.pause();
        };
        const onMetadata = () => {
            align();
            followState();
        };

        // 崩溃守卫：只在视频**真正开始播放**时记 pending，稳定播放 15 秒后记 ok。
        // 之前是在组件挂载时就写 pending，用户 15 秒内退出 App 就会留下 pending，
        // 下次启动会被 store 判定成「上次带视频层崩了」→ 关掉视频层并删掉视频，
        // 用户看到的现象就是「背景视频怎么不显示了」。
        let guardTimer: number | undefined;
        const markVideoPlaying = () => {
            try { window.localStorage.setItem('video_layer_crash_guard', 'pending'); } catch { /* ignore */ }
            if (guardTimer !== undefined) return;
            guardTimer = window.setTimeout(() => {
                try { window.localStorage.setItem('video_layer_crash_guard', 'ok'); } catch { /* ignore */ }
            }, 15000);
        };
        video.addEventListener('playing', markVideoPlaying);

        video.addEventListener('loadedmetadata', onMetadata);
        if (video.readyState >= HTMLMediaElement.HAVE_METADATA) onMetadata();

        const unsubscribeStore = usePlaybackStore.subscribe((state, previous) => {
            if (selectDisplayPlayerState(state) !== selectDisplayPlayerState(previous)) followState();
            if (selectDisplaySong(state) !== selectDisplaySong(previous)) align();
        });
        let lastClock = currentTime.get();
        const unsubscribeClock = currentTime.on('change', (value) => {
            if (Math.abs(value - lastClock) > CLOCK_JUMP_SEC) align();
            lastClock = value;
        });
        const drift = window.setInterval(align, DRIFT_CHECK_MS);

        return () => {
            // 正常卸载 = 没有崩：把守卫标记清成 ok，避免下次启动误判。
            if (guardTimer !== undefined) {
                try { window.localStorage.setItem('video_layer_crash_guard', 'ok'); } catch { /* ignore */ }
            }
            video.removeEventListener('playing', markVideoPlaying);
            window.clearTimeout(guardTimer);
            window.clearInterval(drift);
            unsubscribeClock();
            unsubscribeStore();
            video.removeEventListener('loadedmetadata', onMetadata);
            video.pause();
        };
    }, [active, source]);

    // The shell's pause flag changes without touching the source; only play/pause needs to follow.
    useEffect(() => {
        const video = videoRef.current;
        if (!active || !video) return;
        if (paused) {
            video.pause();
        } else if (selectDisplayPlayerState(usePlaybackStore.getState()) === PlayerState.PLAYING) {
            void video.play().catch(() => {});
        }
    }, [active, paused]);

    if (!active || !source) return null;

    return (
        <video
            ref={videoRef}
            key={source}
            src={source}
            muted
            loop
            playsInline
            preload="auto"
            aria-hidden
            // iOS 对 HEVC/超大文件可能直接解码失败：静默会表现为「选了但没画面」，这里给出提示。
            onError={() => {
                console.warn('[VideoLayer] video decode failed for', source);
                void useVideoLayerSettingsStore.getState().clearLocalFile();
                setStatusMessage({ type: 'error', text: '这个视频无法在当前设备解码（建议 mp4/h264）' });
            }}
            className="absolute inset-0 h-full w-full pointer-events-none bg-transparent"
            style={{ opacity, objectFit: fit }}
        />
    );
};

export default VideoLayer;
