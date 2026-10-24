import SwiftUI
import UIKit

/// 在原生 App 里跑一个 WKWebView，让用户用网易云账号扫码登录。
/// 登录成功后从返回的 JSON 里把 cookie 抓出来（含 MUSIC_U），交给原生层用。
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
        qrImage = nil

        do {
            // 第一步：unikey。原生路径走 Worker 的 weapi，不依赖本机隧道。
            struct KeyResp: Decodable {
                struct D: Decodable {
                    let code: Int?
                    let unikey: String?
                }
                let code: Int?
                let data: D?
            }
            let ts = String(Int(Date().timeIntervalSince1970))
            let keyData = try await APIClient.get(
                "/api/native/netease/login/qr/key",
                query: ["timestamp": ts],
                provider: .netease,
                cookie: nil
            )
            let keyResp = try APIClient.decodeJSON(KeyResp.self, from: keyData)
            guard let unikey = keyResp.data?.unikey, !unikey.isEmpty else {
                statusText = "无法获取 unikey"
                return
            }

            // 第二步：二维码。qrimg 是 dataURL 形式的 PNG base64。
            struct QRResp: Decodable {
                struct D: Decodable {
                    let qrurl: String?
                    let qrimg: String?
                }
                let code: Int?
                let data: D?
            }
            let qrData = try await APIClient.get(
                "/api/native/netease/login/qr/create",
                query: ["key": unikey, "qrimg": "true", "timestamp": ts],
                provider: .netease,
                cookie: nil
            )
            let qrResp = try APIClient.decodeJSON(QRResp.self, from: qrData)
            if let dataUrl = qrResp.data?.qrimg,
               let commaIdx = dataUrl.firstIndex(of: ","),
               let imgData = Data(base64Encoded: String(dataUrl[dataUrl.index(after: commaIdx)...])),
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
        struct CheckResp: Decodable {
            let code: Int?
            let message: String?
            let cookie: String?
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            do {
                let ts = String(Int(Date().timeIntervalSince1970))
                let data = try await APIClient.get(
                    "/api/native/netease/login/qr/check",
                    query: ["key": unikey, "timestamp": ts],
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
                    if let cookie = resp.cookie, !cookie.isEmpty {
                        onDone(cookie)
                    } else {
                        statusText = "登录成功但 cookie 为空"
                    }
                    return
                default:
                    statusText = resp.message ?? "状态 \(resp.code ?? -1)"
                }
            } catch {
                // 网络抖动继续轮询
            }
        }
    }
}
