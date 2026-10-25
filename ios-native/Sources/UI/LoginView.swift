import SwiftUI

/// 扫码登录：key → 二维码图片 → 轮询 801/802/803。
struct LoginView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var statusText = "正在获取二维码…"
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                    if let image {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 220, height: 220)

                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .multilineTextAlignment(.center)

                Button("重新获取") {
                    start()
                }
                .font(.system(size: 13))
                .foregroundStyle(FoliaTheme.text)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FoliaTheme.background.ignoresSafeArea())
            .navigationTitle("网易云登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        pollTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .tint(FoliaTheme.text)
        .onAppear(perform: start)
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        image = nil
        statusText = "正在获取二维码…"
        pollTask = Task {
            do {
                let key = try await NeteaseAPI.shared.qrKey()
                let base64 = try await NeteaseAPI.shared.qrImage(key: key)
                if let comma = base64.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(base64[base64.index(after: comma)...])) {
                    image = UIImage(data: data)
                }
                statusText = "请用网易云 App 扫码"
                await poll(key: key)
            } catch {
                statusText = (error as? LocalizedError)?.errorDescription ?? "获取二维码失败"
            }
        }
    }

    private func poll(key: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            switch await NeteaseAPI.shared.checkQR(key: key) {
            case .waiting:
                statusText = "请用网易云 App 扫码"
            case .scanned:
                statusText = "已扫描，请在手机上确认"
            case .confirmed:
                statusText = "登录成功"
                if let account = try? await NeteaseAPI.shared.currentAccount() {
                    library.signIn(session: account)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
                return
            case .expired:
                statusText = "二维码已过期，请重新获取"
                return
            case .failed(let reason):
                statusText = reason
                return
            }
        }
    }
}
