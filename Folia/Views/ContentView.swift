import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @EnvironmentObject private var state: WebShellState

    var body: some View {
        ZStack {
            Color(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255)
                .ignoresSafeArea()
            WebShellView(state: state)
                .ignoresSafeArea()
            if let reason = state.offlineReason {
                OfflineNotice(reason: reason, detail: state.failureDetail) { state.reload() }
            }
        }
        .statusBarHidden(false)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 回前台只重启会话，不重设 category：后者会把正在播放的音乐按停。
            AudioSessionController.shared.reactivate()
        }
    }
}

/// 把承载线上页的 WKWebView 容器接进 SwiftUI。
struct WebShellView: UIViewRepresentable {
    let state: WebShellState

    func makeUIView(context: Context) -> WebContainerView {
        WebContainerView(state: state)
    }

    func updateUIView(_ uiView: WebContainerView, context: Context) {}
}

/// 线上页加载失败时的提示层。壳加载的是线上站点，断网就没有页面可用，
/// 必须给出可见的说明与重试入口，不能让用户面对一片黑。
///
/// 这一层必须自己挡住整屏：下面的 `WebShellView` 是 `UIViewRepresentable`
/// （WKWebView），UIKit 视图会把落在自己身上的触摸直接吃掉，
/// SwiftUI 只画不接的卡片浮在上面时「重试」按下去没有任何反应。
/// 所以这里铺满一层真实背景 + `contentShape`，让触摸先落到卡片上。
private struct OfflineNotice: View {
    let reason: String
    let detail: String?
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                // 空白处也吞掉触摸，避免穿透到下面的网页。
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44, weight: .light))
                Text(reason)
                    .font(.headline)
                Text("Folia 需要联网加载播放页，请检查网络后重试。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("网络恢复后会自动重新加载。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let detail {
                    // 现场信息：真机上一眼能看出是脚本没跑到、还是资源没下来。
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: retry) {
                    Text("重试")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .contentShape(Rectangle())
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(24)
        }
    }
}
