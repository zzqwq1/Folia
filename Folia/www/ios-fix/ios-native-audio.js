/* iOS 原生播放桥（给 0.7.x 版的 Folia 用）。
   为什么需要：0.7.x 的 Folia 把 <audio> 接进 Web Audio（淡入淡出、均衡器、动感分析），在 iOS 的 WKWebView 里
   这条路既容易卡顿断音，App 一进后台 AudioContext 就被挂起，声音停掉。iOS 壳（2.2.6 移植版的原生部分）自带
   一个 AVPlayer 播放器（webkit.messageHandlers.foliaPlayer），2.2.6 的网页代码就是把声音交给它播的；0.7.x 的
   网页代码里没有这一层，所以这里补上。
   做法：Folia 调 audio.play() 时，把地址交给原生 AVPlayer 播放，网页里的 <audio> 静音暂停不出声；同时把这个
   <audio> 的 paused / currentTime / duration / ended 换成原生播放器的状态，并按时派发 play / playing / pause /
   timeupdate / durationchange / ended 事件 —— Folia 自己的播放逻辑（进度条、歌词、自动下一首）照常工作，不用改它。
   原生没回应（1.8 秒）或报错时退回网页播放。本地音乐（blob: 地址，原生打不开）先交给内置 Node 的
   folia-media.js（127.0.0.1:3215）存成 http 地址再给原生播 —— 否则本地歌一进后台就停。
   原生的 foliaPlayer 通道可能比页面晚注册（2.2.6 也是等它），所以这里一直等到它出现再接管正在放的歌。
   协议（和 2.2.6 一致）：发 {cmd: load|play|pause|seek|volume|muted|status, generation, session, …}；
   原生回调 window.__foliaNativePlayerEvent({type: loaded|state|time|ended|error, position, playing, duration, sentAtMs, generation, session})。
   另外：锁屏 / 耳机的播放控制由原生调 window.folium.playback.*，0.7.x 没有这个对象，这里用 Folia 自己注册的
   mediaSession 动作补上；歌曲信息同步给锁屏（nowplaying_fix 的 foliaNowPlayingFix 通道）。
   localStorage folia_native_player = '0' 可以关掉这一层。 */
(function () {
  if (!window.webkit || !window.webkit.messageHandlers) return; // 不在 iOS App 里
  try { if (localStorage.getItem('folia_native_player') === '0') return; } catch (e) {}
  function nativeHandler() { return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.foliaPlayer; }
  var MEDIA_SERVER = 'http://127.0.0.1:3215';
  var webFetch = window.CapacitorWebFetch || window.fetch.bind(window); // 不走 CapacitorHttp：要传二进制

  var FALLBACK_MS = 1800;
  var proto = HTMLMediaElement.prototype;
  var origPlay = proto.play;
  var origPause = proto.pause;
  var origLoad = proto.load;
  var desc = function (name) { return Object.getOwnPropertyDescriptor(proto, name); };
  var D = { currentTime: desc('currentTime'), paused: desc('paused'), duration: desc('duration'), ended: desc('ended'), volume: desc('volume'), muted: desc('muted'), src: desc('src') };
  var session = 'folia-' + Date.now() + '-' + Math.random().toString(36).slice(2);
  var generation = 0;
  var foreignSessions = {};
  var failures = 0;
  var disabled = false;
  // 原生这次启动后回应过一次，就一直信任它（和 2.2.6 一样）：慢一点加载不算失败，不退回网页 ——
  // 之前 1.8 秒没回应就退回网页、两次后整个关掉，结果歌在网页里放（一进后台就停），
  // 原生那边还留着上一首，灵动岛一点播放就放成了别的歌。
  var nativeEverAlive = false;
  // 诊断用：最近 150 条桥的动作（发给原生的命令、原生的回调、前后台切换、退回网页），「诊断」按钮里能看到
  // 记录存进 localStorage：App 在后台被系统杀掉、重新打开后，上次的记录还在
  var EVENTS_KEY = 'folia_native_audio_events';
  var events = [];
  try { events = JSON.parse(localStorage.getItem(EVENTS_KEY) || '[]') || []; } catch (e) { events = []; }
  events.push('==== 新启动 ' + new Date().toLocaleString() + ' ====');
  var saveTimer = null;
  function note(text) {
    var d = new Date();
    events.push(('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2) + '.' + String(d.getMilliseconds()).padStart(3, '0') + ' ' + text);
    if (events.length > 200) events.splice(0, events.length - 200);
    clearTimeout(saveTimer);
    var save = function () { try { localStorage.setItem(EVENTS_KEY, JSON.stringify(events)); } catch (e) {} };
    if (/进入后台/.test(text)) save(); else saveTimer = setTimeout(save, 300);
  }
  note('桥已加载；foliaPlayer 通道：' + (window.webkit.messageHandlers.foliaPlayer ? '有' : '暂无'));

  // 当前交给原生播放的 <audio> 和它的「原生状态」
  var mirror = null;
  var st = null; // { url, playing, position, at, duration, ended, alive, fallbackTimer, mutedIntent, volumeIntent }
  var tick = null;
  var lastEventAt = 0;
  var silent = false; // 我们自己改 muted / pause 时不当成 Folia 的操作

  // —— 网页里的 Web Audio 引擎 ——
  // Folia 0.7.x 一放歌就开着一个 AudioContext（淡入淡出 / 均衡器 / 动感分析）。声音交给原生后它只是空转，
  // 但 iOS 把它算作网页「正在播放」：App 一进后台，WebKit 打断网页的音频会话、把它挂起，Folia 收到后
  // 调一次暂停 —— 经过这个桥，原生播放器也被停了（系统日志里进后台 0.2 秒后 FigPlayer 被停就是这个）。
  // 所以原生在放的时候把 AudioContext 挂起，并且不让 Folia 再恢复它；退回网页播放时再放开。
  var contexts = [];
  ['AudioContext', 'webkitAudioContext'].forEach(function (name) {
    var C = window[name];
    if (typeof C !== 'function' || C.__foliaWrapped) return;
    var Wrapped = function () {
      var ctx = new (Function.prototype.bind.apply(C, [null].concat(Array.prototype.slice.call(arguments))))();
      contexts.push(ctx);
      if (mirror) suspendContexts('新建时');
      return ctx;
    };
    Wrapped.prototype = C.prototype;
    Object.getOwnPropertyNames(C).forEach(function (k) { if (!(k in Wrapped)) try { Wrapped[k] = C[k]; } catch (e) {} });
    Wrapped.__foliaWrapped = true;
    window[name] = Wrapped;
  });
  var origResume = window.AudioContext && AudioContext.prototype.resume;
  if (origResume) {
    AudioContext.prototype.resume = function () {
      if (mirror && contexts.indexOf(this) >= 0) return Promise.resolve(); // 原生在放：网页引擎保持挂起
      return origResume.apply(this, arguments);
    };
  }
  function suspendContexts(reason) {
    contexts.forEach(function (ctx) {
      if (ctx.state === 'running') { try { ctx.suspend(); note('挂起网页音频引擎（' + reason + '）'); } catch (e) {} }
    });
  }
  function resumeContexts() {
    contexts.forEach(function (ctx) { if (ctx.state !== 'closed' && origResume) { try { origResume.call(ctx); } catch (e) {} } });
  }

  function send(msg) {
    msg.generation = generation;
    msg.session = session;
    var h = nativeHandler();
    if (!h) { note('→ ' + msg.cmd + '（没有原生通道）'); return false; }
    if (msg.cmd !== 'status') note('→ ' + msg.cmd + (msg.url ? ' ' + String(msg.url).slice(-48) : '') + (msg.position != null ? ' @' + Number(msg.position).toFixed(1) : '') + ' g' + msg.generation);
    try { h.postMessage(msg); return true; } catch (e) { note('postMessage 失败：' + e); return false; }
  }
  // **用户亲手按的暂停：单独给壳报一条「这就是用户收手」。**
  //
  // 通用通道 `intent-pause` 同时承载「用户按的」和「WebKit / 恢复链按停的」，
  // 壳只能靠「最近一次触摸过去多久」来猜。实测这个猜测并不可靠：
  // 日志里用户明明按了暂停，`gestureAge` 却是 83 秒（页面按钮那一下没被记成手势），
  // 壳于是判成「不是用户暂停」，保留 `wantsAudible`；紧接着切后台，
  // 后台续播链又把歌放了起来 —— 用户看到的就是「暂停后退出后台还在放」。
  // 这一条只在 `proto.pause` 的直接调用里发（锁屏 / 音频打断走 `remotePause`，不发）。
  function notifyUserPause() {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.foliaAudioIntent;
      if (h) h.postMessage('intent-pause-user');
    } catch (e) {}
  }
  // 用 src 属性（换歌时立刻变）而不是 currentSrc（要等浏览器重新加载才变）
  function srcOf(el) { return D.src.get.call(el) || el.currentSrc || ''; }
  function eligible(el) {
    // 本项目无内置 Node 媒体服务器，blob: 地址原生无法播放，交给网页处理
    return !disabled && !!nativeHandler() && el instanceof HTMLAudioElement && /^https?:/i.test(srcOf(el));
  }
  // 本地文件：blob → 内置 Node 的 http 地址（同一个 blob 只传一次）
  var uploaded = {};
  var EXT = { 'audio/mpeg': 'mp3', 'audio/mp3': 'mp3', 'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/aac': 'aac', 'audio/flac': 'flac', 'audio/x-flac': 'flac', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/wave': 'wav', 'audio/ogg': 'ogg', 'audio/aiff': 'aiff', 'audio/x-aiff': 'aiff' };
  function toNativeUrl(url) {
    if (!/^blob:/i.test(url)) return Promise.resolve(url);
    if (uploaded[url]) return uploaded[url];
    uploaded[url] = webFetch(url).then(function (r) { return r.blob(); }).then(function (blob) {
      var ext = EXT[String(blob.type).toLowerCase()] || 'mp3';
      return webFetch(MEDIA_SERVER + '/media?ext=' + ext, { method: 'PUT', body: blob });
    }).then(function (r) {
      if (!r.ok) throw new Error('media server ' + r.status);
      return r.json();
    }).then(function (j) { return j.url; });
    uploaded[url].catch(function () { delete uploaded[url]; });
    return uploaded[url];
  }
  function fire(el, type) { try { el.dispatchEvent(new Event(type)); } catch (e) {} }
  function position() {
    if (!st) return 0;
    var p = st.position;
    if (st.playing) p += (Date.now() - st.at) / 1000;
    if (st.duration > 0) p = Math.min(p, st.duration);
    return Math.max(0, p);
  }
  function setPosition(p) { st.position = p; st.at = Date.now(); }
  function realMute(el, on) { silent = true; try { D.muted.set.call(el, on); } finally { silent = false; } }
  function startTick() {
    if (tick) return;
    tick = setInterval(function () {
      if (!mirror || !st) return;
      if (st.playing) fire(mirror, 'timeupdate');
      if (st.playing && !document.hidden && Date.now() - lastEventAt > 2200) send({ cmd: 'status' });
      if (st.playing && Date.now() - (st.npAt || 0) > 5000) nowPlaying(); // 锁屏进度
    }, 250);
  }
  // 发出 play / pause 之后的一小段时间里，原生发来的旧状态（命令之前的）不算数
  function expect(playing) { if (st) { st.expectPlaying = playing; st.expectUntil = Date.now() + 900; } }
  function setPlaying(playing) {
    if (!st || st.playing === playing) return;
    setPosition(position());
    st.playing = playing;
    if (playing) { fire(mirror, 'play'); fire(mirror, 'playing'); st.announced = true; } else fire(mirror, 'pause');
    nowPlaying();
  }

  function release(restore) {
    if (!mirror) return;
    var el = mirror, pos = position(), state = st;
    clearTimeout(state.fallbackTimer);
    mirror = null; st = null;
    realMute(el, !!state.mutedIntent);
    if (restore) {
      try { D.currentTime.set.call(el, pos); } catch (e) {}
    }
    return { el: el, pos: pos, playing: state.playing };
  }

  // 原生不回应 / 报错：退回网页播放，从当前位置接着放
  function fallback(reason) {
    if (!mirror) return;
    send({ cmd: 'pause' }); // 原生别再拿着这首（灵动岛 / 锁屏点播放会把它放出来）
    if (!nativeEverAlive) {
      failures += 1;
      if (failures >= 2) disabled = true;
    }
    console.info('[NativeAudio] 退回网页播放：' + reason);
    note('退回网页播放：' + reason);
    if (!st.alive) st.playing = false; // 原生从没出过声：从开始的位置接着放，不用推算出的位置
    var r = release(true);
    resumeContexts();
    try { origPlay.call(r.el).catch(function () {}); } catch (e) {}
  }

  function startNative(el, url) {
    if (mirror && mirror !== el) {
      // 换了一个 <audio>（例如自动混音的下一首）：旧的那个在 Folia 看来就是停了
      var old = release(false);
      if (old && old.playing) fire(old.el, 'pause');
    }
    var startAt = 0;
    try { startAt = D.currentTime.get.call(el) || 0; } catch (e) {}
    try { origPause.call(el); } catch (e) {}
    var mutedIntent = mirror === el && st ? st.mutedIntent : D.muted.get.call(el);
    var volumeIntent = mirror === el && st ? st.volumeIntent : D.volume.get.call(el);
    if (mirror === el && st) clearTimeout(st.fallbackTimer);
    generation += 1;
    mirror = el;
    // 和浏览器一样：play() 之后 paused 立刻是 false；原生确认开始出声时再派发 playing
    st = { url: url, intent: true, playing: true, announced: false, position: startAt, at: Date.now(), duration: NaN, ended: false, alive: false, mutedIntent: mutedIntent, volumeIntent: volumeIntent };
    realMute(el, true);
    suspendContexts('交给原生');
    var gen = generation, state = st;
    toNativeUrl(url).then(function (nativeUrl) {
      if (st !== state || gen !== generation) return; // 已经换歌了
      st.nativeUrl = nativeUrl;
      send({ cmd: 'load', url: nativeUrl, position: startAt, autoplay: st.playing, volume: mutedIntent ? 0 : volumeIntent, muted: mutedIntent });
      if (!nativeEverAlive) st.fallbackTimer = setTimeout(function () { if (st === state && !st.alive && !nativeEverAlive) fallback('原生播放器没有回应'); }, FALLBACK_MS);
    }, function (error) {
      if (st === state) fallback('本地文件交给原生失败：' + (error && error.message || error));
    });
    fire(el, 'play');
    startTick();
    nowPlaying();
  }

  // —— 接管 <audio> ——
  proto.play = function () {
    if (!eligible(this)) {
      if (this instanceof HTMLAudioElement) note('play() 走网页：' + (disabled ? '桥已关闭' : !nativeHandler() ? '没有原生通道' : '地址不支持 ' + srcOf(this).slice(0, 40)));
      return origPlay.apply(this, arguments);
    }
    var url = srcOf(this);
    if (mirror === this && st && st.url === url && !st.ended) {
      send({ cmd: 'play' });
      st.intent = true;
      setPlaying(true);
      expect(true);
      return Promise.resolve();
    }
    startNative(this, url);
    return Promise.resolve();
  };
  var remotePause = false; // 锁屏 / 灵动岛 / 耳机按的暂停（经 folium.playback.pause 进来）
  proto.pause = function () {
    if (mirror !== this || silent) return origPause.apply(this, arguments);
    if ((document.hidden || justHidden()) && !remotePause && st && st.intent) {
      // 进后台那一下网页被系统打断引起的暂停，不是用户按的：原生接着放
      note('忽略进后台时的暂停（不是用户按的）');
      return;
    }
    if (st) st.intent = false;
    send({ cmd: 'pause' });
    setPlaying(false);
    expect(false);
    if (!remotePause) { notifyUserPause(); }
  };
  proto.load = function () {
    if (mirror === this) { send({ cmd: 'pause' }); release(false); }
    return origLoad.apply(this, arguments);
  };
  Object.defineProperty(proto, 'src', {
    configurable: true, enumerable: D.src.enumerable, get: D.src.get,
    set: function (v) {
      D.src.set.call(this, v);
      if (mirror === this && st && D.src.get.call(this) !== st.url) { send({ cmd: 'pause' }); release(false); }
    },
  });
  var setAttribute = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    var result = setAttribute.apply(this, arguments);
    if (this === mirror && String(name).toLowerCase() === 'src' && st && D.src.get.call(this) !== st.url) { send({ cmd: 'pause' }); release(false); }
    return result;
  };
  Object.defineProperty(proto, 'paused', {
    configurable: true, enumerable: D.paused.enumerable,
    get: function () { return mirror === this && st ? !st.playing : D.paused.get.call(this); },
  });
  Object.defineProperty(proto, 'ended', {
    configurable: true, enumerable: D.ended.enumerable,
    get: function () { return mirror === this && st ? st.ended : D.ended.get.call(this); },
  });
  Object.defineProperty(proto, 'duration', {
    configurable: true, enumerable: D.duration.enumerable,
    get: function () { return mirror === this && st && st.duration > 0 ? st.duration : D.duration.get.call(this); },
  });
  Object.defineProperty(proto, 'currentTime', {
    configurable: true, enumerable: D.currentTime.enumerable,
    get: function () { return mirror === this && st ? position() : D.currentTime.get.call(this); },
    set: function (v) {
      if (mirror !== this || !st) { D.currentTime.set.call(this, v); return; }
      var t = Math.max(0, Number(v) || 0);
      setPosition(t);
      st.ended = false;
      send({ cmd: 'seek', position: t });
      fire(this, 'seeking'); fire(this, 'timeupdate'); fire(this, 'seeked');
      nowPlaying();
    },
  });
  Object.defineProperty(proto, 'volume', {
    configurable: true, enumerable: D.volume.enumerable,
    get: function () { return mirror === this && st ? st.volumeIntent : D.volume.get.call(this); },
    set: function (v) {
      if (mirror !== this || !st) { D.volume.set.call(this, v); return; }
      st.volumeIntent = Math.max(0, Math.min(1, Number(v) || 0));
      send({ cmd: 'volume', volume: st.mutedIntent ? 0 : st.volumeIntent });
      fire(this, 'volumechange');
    },
  });
  Object.defineProperty(proto, 'muted', {
    configurable: true, enumerable: D.muted.enumerable,
    get: function () { return mirror === this && st && !silent ? st.mutedIntent : D.muted.get.call(this); },
    set: function (v) {
      if (silent || mirror !== this || !st) { D.muted.set.call(this, v); return; }
      st.mutedIntent = !!v;
      send({ cmd: 'muted', muted: st.mutedIntent });
      fire(this, 'volumechange');
    },
  });

  // —— 原生回调 ——
  window.__foliaNativePlayerEvent = function (e) {
    e = e || {};
    if (e.type !== 'time') note('← ' + e.type + (e.playing != null ? ' playing=' + e.playing : '') + (e.position != null ? ' @' + Number(e.position).toFixed(1) : '') + ' g' + e.generation + (e.message ? ' ' + e.message : '') + (mirror ? '' : '（无接管元素）'));
    if (e.session && String(e.session) !== session) {
      // 页面被系统杀掉重载后，原生还在放上一次页面的歌，而新页面显示的是暂停：两边对不上，灵动岛也一直在。
      // 新页面还没接管任何歌时，把它停掉（发命令会让原生换成本页的 session），之后点播放由页面重新加载。
      var foreign = String(e.session);
      if (foreignSessions[foreign]) return;
      foreignSessions[foreign] = true;
      if (!st && e.playing !== false) { note('  页面重载前留下的原生播放还在放：停掉，等页面重新开始'); send({ cmd: 'pause' }); }
      else note('  忽略：session 不同');
      return;
    }
    var gen = Number(e.generation);
    if (!mirror || !st) return;
    if (Number.isFinite(gen) && gen < generation) return; // 上一首的迟到消息
    lastEventAt = Date.now();
    var type = String(e.type || '');
    if (type !== 'error') { st.alive = true; nativeEverAlive = true; clearTimeout(st.fallbackTimer); failures = 0; }
    var latency = Number.isFinite(Number(e.sentAtMs)) ? Math.min(0.25, Math.max(0, Date.now() - Number(e.sentAtMs)) / 1000) : 0;
    if (Number.isFinite(Number(e.duration)) && Number(e.duration) > 0 && Number(e.duration) !== st.duration) {
      st.duration = Number(e.duration);
      fire(mirror, 'durationchange');
      fire(mirror, 'loadedmetadata');
    }
    if (type === 'error') { fallback(String(e.message || '原生报错')); return; }
    if (type === 'ended') {
      if (e.url && String(e.url) !== (st.nativeUrl || st.url)) return;
      setPosition(st.duration > 0 ? st.duration : position());
      st.playing = false;
      st.ended = true;
      fire(mirror, 'timeupdate');
      fire(mirror, 'ended');
      nowPlaying();
      return;
    }
    if (type === 'state' || type === 'time') {
      var playing = e.playing === true;
      if (st.expectUntil && Date.now() < st.expectUntil && playing !== st.expectPlaying) return;
      // 刚进后台时原生播放器被系统停了（网页的音频会话结束时 iOS 会报一次打断），而不是用户按的暂停：接着放
      if (!playing && st.playing && !autoResumed && justHidden() && !(st.expectUntil && st.expectPlaying === false)) {
        autoResumed = true;
        send({ cmd: 'play' });
        expect(true);
        return;
      }
      var p = Number(e.position);
      if (Number.isFinite(p)) setPosition(p + (playing ? latency : 0));
      if (playing !== st.playing) setPlaying(playing);
      else if (playing && !st.announced) { st.announced = true; fire(mirror, 'playing'); }
      if (type === 'time') fire(mirror, 'timeupdate');
      if (playing) st.ended = false;
    }
  };

  // 回到前台：马上问一次原生状态，把进度对齐。记下进后台的时间（见下面的「打断」处理）
  var hiddenAt = 0, autoResumed = false;
  document.addEventListener('visibilitychange', function () {
    note(document.hidden ? '进入后台' : '回到前台');
    if (document.hidden) { hiddenAt = Date.now(); autoResumed = false; return; }
    if (mirror) send({ cmd: 'status' });
  });
  // 壳在 App 进后台 / 回前台时调这两个函数（2.2.6 用它们把声音交给网页里的「后台播放器」）。0.7.x 没有它们，
  // 壳做完后台交接后原生播放器就停在那里，只有在灵动岛点一下播放才会响。声音本来就在原生播放器里，
  // 所以这里只是让它接着放：进后台时如果在放歌，立刻（再补两次）叫原生继续播放。
  function keepNativePlaying(reason) {
    if (!mirror || !st || !st.intent) return; // 按用户的意图，不按原生刚报的状态（交接时原生可能先报了一次暂停）
    note('保持原生播放（' + reason + '）');
    send({ cmd: 'play' });
    if (!st.playing) setPlaying(true);
    expect(true);
  }
  window.__foliaHandoffToShadow = function () {
    keepNativePlaying('后台交接');
    setTimeout(function () { keepNativePlaying('后台交接 +0.4s'); }, 400);
    setTimeout(function () { keepNativePlaying('后台交接 +1.5s'); }, 1500);
  };
  window.__foliaHandoffFromShadow = function () { if (mirror) send({ cmd: 'status' }); };
  window.__foliaPrimeBackgroundAudio = function () {};
  window.__foliaPauseBackgroundAudio = function () {};
  window.__foliaSeekBackgroundAudio = function (t) { var v = Number(t); if (mirror && Number.isFinite(v)) mirror.currentTime = v; };
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) return;
    suspendContexts('进入后台');
    [300, 700, 1200, 2000].forEach(function (ms) {
      setTimeout(function () { if (document.hidden) keepNativePlaying('进入后台 +' + ms + 'ms'); }, ms);
    });
  });
  window.addEventListener('pagehide', function () { note('pagehide'); });
  document.addEventListener('freeze', function () { note('页面被冻结（freeze）'); });
  function justHidden() { return document.hidden && Date.now() - hiddenAt < 4000; }

  // —— 锁屏 / 耳机控制：原生调 window.folium.playback.*，用 Folia 注册的 mediaSession 动作来实现 ——
  var actions = {};
  if (navigator.mediaSession && navigator.mediaSession.setActionHandler) {
    var setActionHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
    navigator.mediaSession.setActionHandler = function (action, handler) {
      actions[action] = handler;
      try { return setActionHandler(action, handler); } catch (e) {}
    };
  }
  function run(action, details) {
    var h = actions[action];
    if (typeof h === 'function') { try { h(Object.assign({ action: action }, details || {})); return true; } catch (e) {} }
    return false;
  }
  window.folium = window.folium || {};
  if (!window.folium.playback) {
    window.folium.playback = {
      play: function () { note('folium.playback.play（锁屏/灵动岛）'); if (!run('play') && mirror) mirror.play(); },
      pause: function () {
        // 壳的「音频打断」回调会先设 __FOLIA_AUDIO_INTERRUPTED 再调这里。App 进后台时网页的音频会话结束，
        // iOS 也报一次打断 —— 这不是用户暂停，原生播放器在后台照常放，所以不跟着停（锁屏上按暂停不带这个标记）。
        var interrupted = window.__FOLIA_AUDIO_INTERRUPTED === true;
        note('folium.playback.pause（' + (interrupted ? '音频打断' : '锁屏/耳机') + (document.hidden ? '，后台' : '') + '）');
        window.__FOLIA_AUDIO_INTERRUPTED = false;
        if (interrupted && (document.hidden || justHidden()) && mirror) { if (st) setTimeout(function () { send({ cmd: 'play' }); }, 300); return; }
        remotePause = true;
        try { if (!run('pause') && mirror) mirror.pause(); } finally { setTimeout(function () { remotePause = false; }, 0); }
      },
      next: function () { run('nexttrack'); },
      previous: function () { run('previoustrack'); },
      seek: function (t) { var s = Number(t); if (!Number.isFinite(s)) return; if (!run('seekto', { seekTime: s }) && mirror) mirror.currentTime = s; },
    };
  }

  // —— 歌曲信息给锁屏（nowplaying_fix 注入的 foliaNowPlayingFix 通道；没有就算了）——
  function nowPlaying() {
    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.foliaNowPlayingFix;
    if (!h || !st) return;
    st.npAt = Date.now();
    var meta = navigator.mediaSession && navigator.mediaSession.metadata;
    var art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : '';
    try {
      h.postMessage({ title: meta ? meta.title : '', artist: meta ? meta.artist : '', duration: st.duration > 0 ? st.duration : 0, position: position(), playing: st.playing, artworkUrl: art || '' });
    } catch (e) {}
  }
  if (navigator.mediaSession) {
    var metaDesc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(navigator.mediaSession), 'metadata');
    if (metaDesc && metaDesc.set) {
      Object.defineProperty(navigator.mediaSession, 'metadata', {
        configurable: true, get: function () { return metaDesc.get.call(navigator.mediaSession); },
        set: function (v) { metaDesc.set.call(navigator.mediaSession, v); setTimeout(nowPlaying, 0); },
      });
    }
  }

  // 原生通道晚到：出现后把正在网页里放的那首交给原生
  var waits = 0;
  (function waitForNative() {
    if (nativeHandler()) {
      if (mirror) return;
      var playing = Array.prototype.filter.call(document.querySelectorAll('audio'), function (el) { return !D.paused.get.call(el) && eligible(el); });
      if (playing.length === 1) startNative(playing[0], srcOf(playing[0]));
      return;
    }
    if (++waits < 120) setTimeout(waitForNative, 500);
  })();

  window.__foliaNativeAudioStatus = function () {
    return { events: events.slice(), handler: !!nativeHandler(), everAlive: nativeEverAlive, hidden: document.hidden, enabled: !disabled, mirrored: !!mirror, url: st ? st.url.slice(0, 90) : null, playing: st ? st.playing : null, position: st ? position() : null, duration: st ? st.duration : null, alive: st ? st.alive : null, generation: generation, failures: failures };
  };
  console.info('[NativeAudio] 声音交给原生 AVPlayer，<audio> 静音跑时间轴');
})();
