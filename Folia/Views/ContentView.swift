import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var state: WebShellState

    var body: some View {
        ZStack {
            Color(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255)
                .ignoresSafeArea()
            WebShellView()
                .ignoresSafeArea()
            if let reason = state.offlineReason {
                OfflineNotice(reason: reason, detail: state.failureDetail) { state.reload() }
            }
        }
        .statusBarHidden(false)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            AudioSessionController.shared.configure()
        }
    }
}

/// 线上页加载失败时的提示层。壳加载的是线上站点，断网就没有页面可用，
/// 必须给出可见的说明与重试入口，不能让用户面对一片黑。
private struct OfflineNotice: View {
    let reason: String
    let detail: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .light))
            Text(reason)
                .font(.headline)
            Text("Folia 需要联网加载播放页，请检查网络后重试。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let detail {
                // 现场信息：真机上一眼能看出是脚本没跑到、还是资源没下来。
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(32)
    }
}
