// qrcode 包未自带类型声明，Worker 端（bodian.ts / index.ts）用它生成二维码。
// 这里补齐环境声明，交给 wrangler 在打包时真正解析模块；类型按 any 走，够用。
declare module 'qrcode' {
    const QRCode: any;
    export default QRCode;
}

declare module 'qrcode/lib/server.js' {
    const QRCode: any;
    export default QRCode;
}