#!/usr/bin/env bash
# Folia 后端一键安装（Ubuntu 22.04 / 24.04，国内轻量云或任意 VPS）
#
# 两种模式：
#   1) 直连模式（国内服务器推荐，不需要域名、不需要备案）
#        sudo bash install.sh direct
#      三个服务监听 0.0.0.0:3210/3211/3212，Worker 直接访问 http://服务器IP:端口
#
#   2) 隧道模式（有 Cloudflare 域名时）
#        sudo bash install.sh api.folia-api.top
#      服务只监听 127.0.0.1，对外由 cloudflared 命名隧道提供 HTTPS
set -euo pipefail

MODE="${1:-direct}"
DIRECT="yes"
DOMAIN=""
if [[ "$MODE" != "direct" ]]; then
  DIRECT="no"
  DOMAIN="$MODE"
fi

echo "==> 1/6 安装 Node 20"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
node -v

echo "==> 2/6 系统依赖"
apt-get update -y
apt-get install -y git curl ca-certificates

echo "==> 3/6 网易云 NeteaseCloudMusicApi (3210)"
mkdir -p /opt/folia/netease
cd /opt/folia/netease
if [[ ! -d node_modules/NeteaseCloudMusicApi ]]; then
  npm init -y >/dev/null
  npm install NeteaseCloudMusicApi@4 --omit=dev
fi

echo "==> 4/6 酷狗 KuGouMusicApi (3211)"
mkdir -p /opt/folia/kugou
cd /opt/folia/kugou
if [[ ! -f package.json ]]; then
  git clone --depth 1 https://github.com/makcRe/KuGouMusicApi.git .
  npm install --omit=dev
fi

echo "==> 5/6 folia-proxy (3212)"
mkdir -p /opt/folia/proxy
cat > /opt/folia/proxy/server.mjs <<'PROXY'
// folia 本机转发：QQ 音乐（?url=）与网易云透传（/netease/*）
import http from 'node:http';
import https from 'node:https';

const PORT = Number(process.env.PORT) || 3212;
const HOST = process.env.HOST || '127.0.0.1';
const ALLOWED = /(^|\.)(qq\.com|gtimg\.cn)$/;
const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,OPTIONS,PATCH,DELETE,POST,PUT',
    'Access-Control-Allow-Headers': 'Content-Type, User-Agent, Referer, Accept, X-Requested-With, Range',
    'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges',
};
const HOP = new Set(['host','connection','content-length','accept-encoding','transfer-encoding','keep-alive']);

const forward = (target, method, incoming, body, res) => {
    const headers = {};
    for (const [k, v] of Object.entries(incoming)) {
        if (v === undefined || HOP.has(k.toLowerCase())) continue;
        headers[k] = v;
    }
    const client = target.protocol === 'https:' ? https : http;
    const req = client.request({
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port || (target.protocol === 'https:' ? 443 : 80),
        path: target.pathname + (target.search || ''),
        method,
        headers,
    }, (upstream) => {
        const out = { ...CORS };
        for (const [k, v] of Object.entries(upstream.headers)) {
            const lower = k.toLowerCase();
            if (v === undefined || lower === 'content-length' || lower === 'connection' || lower === 'transfer-encoding') continue;
            out[k] = v;
        }
        res.writeHead(upstream.statusCode || 502, out);
        upstream.pipe(res);
    });
    req.on('error', () => { if (!res.headersSent) res.writeHead(502, CORS); res.end('upstream error'); });
    if (body && body.length) req.write(body);
    req.end();
};

http.createServer((req, res) => {
    for (const [k, v] of Object.entries(CORS)) res.setHeader(k, v);
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
    const parsed = new URL(req.url, 'http://127.0.0.1');
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
        const body = Buffer.concat(chunks);
        if (parsed.pathname === '/netease' || parsed.pathname.startsWith('/netease/')) {
            const rest = parsed.pathname.slice('/netease'.length) || '/';
            forward(new URL(`http://127.0.0.1:3210${rest}${parsed.search || ''}`), req.method, req.headers, body, res);
            return;
        }
        const neteaseHost = parsed.pathname === '/netease-direct';
        if (neteaseHost) { res.writeHead(404, CORS); res.end(); return; }
        const targetStr = parsed.searchParams.get('url') || '';
        let target;
        try { target = new URL(targetStr); } catch { res.writeHead(400, CORS); res.end('bad url'); return; }
        if (!ALLOWED.test(target.hostname)) { res.writeHead(403, CORS); res.end('forbidden host'); return; }
        forward(target, req.method, req.headers, body, res);
    });
}).listen(PORT, HOST);
PROXY

echo "==> 6/6 systemd 服务"
BIND_HOST="127.0.0.1"
if [[ "$DIRECT" == "yes" ]]; then BIND_HOST="0.0.0.0"; fi

cat > /etc/systemd/system/folia-netease.service <<UNIT
[Unit]
Description=Folia NeteaseCloudMusicApi
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/folia/netease
Environment=PORT=3210
Environment=HOST=$BIND_HOST
ExecStart=/usr/bin/node ./node_modules/NeteaseCloudMusicApi/app.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/folia-kugou.service <<UNIT
[Unit]
Description=Folia KuGouMusicApi
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/folia/kugou
Environment=PORT=3211
Environment=HOST=$BIND_HOST
ExecStart=/usr/bin/node app.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/folia-proxy.service <<UNIT
[Unit]
Description=Folia local proxy (QQ + netease passthrough)
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/folia/proxy
Environment=PORT=3212
Environment=HOST=$BIND_HOST
ExecStart=/usr/bin/node server.mjs
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now folia-netease folia-kugou folia-proxy
sleep 4
ss -lntp | grep -E '3210|3211|3212' || true

if [[ "$DIRECT" == "no" ]]; then
  echo "==> cloudflared 命名隧道（$DOMAIN）"
  if ! command -v cloudflared >/dev/null 2>&1; then
    ARCH=$(uname -m)
    FILE="cloudflared-linux-amd64"
    if [[ "$ARCH" == "aarch64" ]]; then FILE="cloudflared-linux-arm64"; fi
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$FILE" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/config.yml <<YAML
tunnel: folia
credentials-file: /root/.cloudflared/folia.json
ingress:
  - hostname: $DOMAIN
    path: /kugou/*
    service: http://127.0.0.1:3211
  - hostname: $DOMAIN
    path: /qq/*
    service: http://127.0.0.1:3212
  - hostname: $DOMAIN
    service: http://127.0.0.1:3210
  - service: http_status:404
YAML
  cloudflared service install || true
fi

cat <<DONE

安装完成（模式：$([[ "$DIRECT" == "yes" ]] && echo 直连 || echo 隧道)）。

自检：
  curl -s localhost:3210/search?keywords=test&limit=1 | head -c 160; echo
  curl -s localhost:3211/search?keyword=test | head -c 160; echo

直连模式还需要：
  1) 在云厂商控制台「防火墙/安全组」放行入站 TCP 3210、3211、3212
  2) 把公网 IP 告我 -> 我把 Worker 指到 http://IP:3210 / :3211 / :3212 并部署

隧道模式还需要：
  cloudflared tunnel login && cloudflared tunnel create folia
  cloudflared tunnel route dns folia $DOMAIN && systemctl restart cloudflared
DONE
