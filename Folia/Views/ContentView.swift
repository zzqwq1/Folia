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
            if state.showsBlockingNotice, let reason = state.offlineReason {
                OfflineNotice(reason: reason, detail: state.failureDetail) { state.reload() }
            } else if state.isOfflineCopy {
                // 已经回退到包内副本、页面本身可用：只留一条不挡操作的提示条。
                OfflineBanner { state.reload() }
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .statusBarHidden(false)
        // 回前台时**不要**在这里再调 `reactivate()`。
        //
        // `setActive(true)` 的副作用是让系统重新评估本 App 的音频资格，
        // WebKit 的媒体元素会因此被按停一次 —— 用户看到的就是「切回桌面再回来，歌停了一下」。
        // 回前台的会话恢复统一由 WebContainerView 的 `recoverAudioPath` 负责：
        // 它先判断页面是不是真的被静音了，没被掐断就完全不动音频。
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

/// 已经跑在包内离线副本上时的轻提示。
///
/// 页面本身是可用的，所以不能像 `OfflineNotice` 那样铺满整屏把播放器挡住——
/// 用户会以为 App 坏了。这里只在顶部留一条细窄的说明 + 「重新连接」，
/// 点完由容器重新走一次线上加载，成功就自己消失。
private struct OfflineBanner: View {
    let reconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .medium))
            Text("离线版本 · 功能可能不全")
                .font(.caption)
            Spacer(minLength: 8)
            Button(action: reconnect) {
                Text("重新连接")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.14), in: Capsule())
            .contentShape(Rectangle())
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.top, 8)
        .padding(.horizontal, 16)
        // 只占顶部这一条，不参与下方的布局拉伸；页面其余部分照常可点。
        .fixedSize(horizontal: false, vertical: true)
    }
}
