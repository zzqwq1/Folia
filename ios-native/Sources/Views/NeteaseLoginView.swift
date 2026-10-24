import SwiftUI
import WebKit

/// 在原生 App 里跑一个 WKWebView，让用户用网易云账号扫码登录。
/// 登录成功后从 Set-Cookie / document.cookie 里把 MUSIC_U 抓出来，交给原生层用。
struct NeteaseLoginView: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var statusText = "正在加载二维码…"
    @State private var qrImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let img = qrImage {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                        .frame(width: 220, height: 220)
                }

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("重新加载") {
                    Task { await loadQR() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("网易云登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadQR() }
        }
    }

    private func loadQR() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        statusText = "正在获取二维码…"

        do {
            struct KeyResp: Decodable {
                let code: Int
                struct D: Decodable { let unikey: String }
                let data: D?
            }
            let keyData = try await APIClient.get(
                "/api/netease/login/qr/key",
                query: ["timestamp": String(Int(Date().timeIntervalSince1970))],
                provider: .netease,
                cookie: nil
            )
            let keyResp = try APIClient.decodeJSON(KeyResp.self, from: keyData)
            guard let unikey = keyResp.data?.unikey else {
                statusText = "无法获取 unikey"
                return
            }

            // 二维码图片：Worker 会本地渲染 PNG。
            struct QRResp: Decodable {
                let code: Int
                struct D: Decodable {
                    let qrimg: String?
                }
                let data: D?
            }
            let qrData = try await APIClient.get(
                "/api/netease/login/qr/create",
                query: ["key": unikey, "qrimg": "true", "timestamp": String(Int(Date().timeIntervalSince1970))],
                provider: .netease,
                cookie: nil
            )
            let qrResp = try APIClient.decodeJSON(QRResp.self, from: qrData)
            if let base64 = qrResp.data?.qrimg,
               let range = base64.range(of: "base64,"),
               let imgData = Data(base64Encoded: String(base64[range.upperBound...])),
               let img = UIImage(data: imgData) {
                qrImage = img
                statusText = "用网易云 App 扫码"
                await pollCheck(unikey: unikey)
            } else {
                statusText = "二维码生成失败"
            }
        } catch {
            statusText = "加载失败：\(error.localizedDescription)"
        }
    }

    private func pollCheck(unikey: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                struct CheckResp: Decodable {
                    let code: Int
                    let message: String?
                    let cookie: String?
                }
                let data = try await APIClient.get(
                    "/api/netease/login/qr/check",
                    query: ["key": unikey, "timestamp": String(Int(Date().timeIntervalSince1970))],
                    provider: .netease,
                    cookie: nil
                )
                let resp = try APIClient.decodeJSON(CheckResp.self, from: data)
                switch resp.code {
                case 800:
                    statusText = "二维码已过期，点重新加载"
                    return
                case 801:
                    statusText = "等待扫码…"
                case 802:
                    statusText = "已扫码，等待确认…"
                case 803:
                    statusText = "登录成功"
                    if let cookie = resp.cookie {
                        onDone(cookie)
                    }
                    return
                default:
                    statusText = resp.message ?? "状态 \(resp.code)"
                }
            } catch {
                // 网络抖动继续轮询
            }
        }
    }
}
