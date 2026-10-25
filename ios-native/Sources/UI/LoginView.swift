import SwiftUI

/// 复刻原版 Web 的扫码登录窗口（src/components/login/window/LoginWindow.tsx + LoginTile / LoginMessage）。
///
/// 层级：窗底 #1a1a1d / 24pt 圆角 / 1px 16% 外描边
/// → 页头（24pt 平台记号 + 16pt 半粗「登录到 …」+ 32×32 关闭钮）
/// → 窄版正文：200×200 圆角 12 的 tile，下面竖排居中的消息区。
/// 二维码在 tile 里是 176×176 的白底；过期时换成卡片底 + 1px 8%，码淡到 10%，中央一个 56pt 深色刷新圆钮。
///
/// 四个平台共用这一份窗口，差别只有记号的字与底色、标题、扫码提示、风控码。
struct LoginView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    /// 要登录哪个平台；不传就跟随首页当前选中的平台
    var provider: MusicProvider?
    /// 页面内浮层模式下由外部收起；为 nil 时退回 dismiss（系统 sheet）
    var onClose: (() -> Void)?

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    @State private var image: UIImage?
    @State private var scene: Scene = .preparing
    @State private var failureText = ""
    @State private var failureCode: Int = 0
    @State private var pollTask: Task<Void, Never>?

    private enum Scene {
        case preparing
        case code
        case scanned
        case success
        case expired
        case failed
    }

    private enum M {
        static let corner: CGFloat = 24
        static let headerTop: CGFloat = 16
        static let headerLead: CGFloat = 24
        static let headerTrail: CGFloat = 16
        static let headerGap: CGFloat = 10
        static let titleLine: CGFloat = 32
        static let markLead: CGFloat = 24
        static let closeSize: CGFloat = 32

        static let bodyLead: CGFloat = 24
        static let bodyTop: CGFloat = 12
        static let bodyBottom: CGFloat = 20
        static let narrowGap: CGFloat = 16

        static let tile: CGFloat = 200
        static let tileCorner: CGFloat = 12
        static let code: CGFloat = 176
        static let refreshSize: CGFloat = 56
        static let refreshIcon: CGFloat = 22
        static let disc: CGFloat = 88
        static let discIcon: CGFloat = 34
        static let arc: CGFloat = 54
        static let arcMark: CGFloat = 30

        static let headlineSize: CGFloat = 20
        static let headlineLine: CGFloat = 28
        static let noteTop: CGFloat = 6
        static let noteSize: CGFloat = 13
        static let quoteCorner: CGFloat = 8
        static let quoteV: CGFloat = 8
        static let quoteH: CGFloat = 10
        static let quoteSize: CGFloat = 12
        static let actionTop: CGFloat = 16
        static let actionMin: CGFloat = 32
        static let actionH: CGFloat = 32
        static let actionInset: CGFloat = 12
        static let actionSize: CGFloat = 13
    }

    private enum C {
        static let t1 = FoliaTheme.text
        static let t2 = FoliaTheme.text.opacity(0.62)
        static let line = FoliaTheme.text.opacity(0.08)
        static let line2 = FoliaTheme.text.opacity(0.16)
        static let fill = FoliaTheme.text.opacity(0.07)
        static let accent = WallTheme.midnight.accent
        static let win = Color(hex: 0x1A1A1D)
        static let card = Color(hex: 0x232327)
        static let refresh = Color(hex: 0x17171A)
        /// 加载弧的走色用平台自己的记号色（原版 --login-pc），在 `markColor` 里取
    }

    private static let moveAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)

    /// 当前平台
    private var target: MusicProvider { provider ?? library.selectedProvider }

    /// 加载弧的走色（原版 --login-pc 跟随平台记号色）
    private var markColor: Color { Color(hex: target.markColorHex) }

    // MARK: - 主体

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: M.narrowGap) {
                    tile
                    messageBlock
                }
                .padding(.horizontal, M.bodyLead)
                .padding(.top, M.bodyTop)
                .padding(.bottom, M.bodyBottom)
                .frame(maxWidth: .infinity)
            }
        }
        .background(C.win)
        .clipShape(RoundedRectangle(cornerRadius: M.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: M.corner, style: .continuous)
                .strokeBorder(C.line2, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 20)
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
        .onDisappear { pollTask?.cancel() }
        .onChange(of: target) { _ in start() }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: M.headerGap) {
                ProviderMark(provider: target, size: M.markLead)
                Text("登录到 \(target.label)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: M.titleLine)
            .frame(maxWidth: .infinity, alignment: .leading)

            SheetCloseButton {
                pollTask?.cancel()
                close()
            }
            .frame(width: M.closeSize, height: M.closeSize)
        }
        .padding(.leading, M.headerLead)
        .padding(.trailing, M.headerTrail)
        .padding(.top, M.headerTop)
    }

    // MARK: - 二维码那一块（LoginTile）

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: M.tileCorner, style: .continuous)
                .fill(onPaper ? Color.white : C.card)
            tilePicture
        }
        .frame(width: M.tile, height: M.tile)
        .clipShape(RoundedRectangle(cornerRadius: M.tileCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: M.tileCorner, style: .continuous)
                .strokeBorder(onPaper ? Color.clear : C.line, lineWidth: 1)
        )
        .animation(Self.moveAnimation, value: scene)
    }

    private var onPaper: Bool {
        image != nil && (scene == .code || scene == .expired)
    }

    @ViewBuilder
    private var tilePicture: some View {
        if let image {
            if scene == .expired {
                expiredCode(image)
            } else {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: M.code, height: M.code)
            }
        } else if scene == .scanned || scene == .success {
            discIcon(system: scene == .success ? "checkmark" : "iphone")
        } else if scene == .failed {
            discIcon(system: "exclamationmark.triangle")
        } else {
            preparing
        }
    }

    private func expiredCode(_ code: UIImage) -> some View {
        ZStack {
            Image(uiImage: code)
                .interpolation(.none)
                .resizable()
                .frame(width: M.code, height: M.code)
                .opacity(0.1)
            refreshButton
        }
    }

    private var preparing: some View {
        ZStack {
            Circle()
                .strokeBorder(C.line, lineWidth: 2)
            ArcShape()
                .stroke(markColor, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
            ProviderMark(provider: target, size: M.arcMark)
        }
        .frame(width: M.arc, height: M.arc)
    }

    private func discIcon(system: String) -> some View {
        ZStack {
            Circle().fill(C.fill)
            Image(systemName: system)
                .font(.system(size: M.discIcon, weight: .regular))
                .foregroundStyle(C.t1)
        }
        .frame(width: M.disc, height: M.disc)
    }

    private var refreshButton: some View {
        Button {
            start()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: M.refreshIcon, weight: .regular))
                .foregroundStyle(Color.white)
                .frame(width: M.refreshSize, height: M.refreshSize)
                .background(Circle().fill(C.refresh))
                .contentShape(Circle())
        }
        .buttonStyle(LoginRefreshPressStyle())
        .accessibilityLabel("刷新二维码")
    }

    // MARK: - 消息区（LoginMessage）

    private var messageBlock: some View {
        VStack(spacing: 0) {
            Text(headline)
                .font(.system(size: M.headlineSize, weight: .semibold))
                .foregroundStyle(C.t1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: M.headlineLine)
            if let note {
                Text(note)
                    .font(.system(size: M.noteSize))
                    .foregroundStyle(C.t2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, M.noteTop)
            }
            actions
                .padding(.top, M.actionTop)
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if scene == .expired || scene == .failed {
                if needsWebVerification {
                    Button {
                        if let url = URL(string: "https://music.163.com") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("在浏览器登录一次")
                            .font(.system(size: M.actionSize))
                            .foregroundStyle(C.win)
                            .padding(.horizontal, M.actionInset)
                            .frame(height: M.actionH)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(C.accent)
                            )
                    }
                    .buttonStyle(LoginActionPressStyle())
                }
                Button {
                    start()
                } label: {
                    Text("刷新二维码")
                        .font(.system(size: M.actionSize))
                        .foregroundStyle(C.win)
                        .padding(.horizontal, M.actionInset)
                        .frame(height: M.actionH)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(C.accent)
                        )
                }
                .buttonStyle(LoginActionPressStyle())
            } else if scene == .scanned {
                Text("二维码仍然有效：请在手机上完成确认，不要关掉这个窗口")
                    .font(.system(size: M.quoteSize))
                    .foregroundStyle(C.t2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, M.quoteH)
                    .padding(.vertical, M.quoteV)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: M.quoteCorner, style: .continuous)
                            .fill(C.fill)
                    )
            } else if scene == .success {
                Text("正在读取账号…")
                    .font(.system(size: M.actionSize))
                    .foregroundStyle(C.t2)
            }
        }
        .frame(minHeight: M.actionMin)
    }

    // MARK: - 文案

    private var headline: String {
        switch scene {
        case .preparing: return "正在获取二维码…"
        case .code: return "使用\(target.shortName)APP扫码"
        case .scanned: return "扫描成功！请在手机上确认。"
        case .success: return "登录成功！"
        case .expired: return "二维码已过期"
        case .failed: return "登录没有成功"
        }
    }

    private var note: String? {
        switch scene {
        case .preparing: return nil
        case .code: return target.scanHint
        case .scanned: return nil
        case .success: return nil
        case .expired: return "点中间的圆钮换一张新的二维码。"
        case .failed:
            if needsWebVerification {
                return "网易云要求先完成安全验证：请在浏览器打开 music.163.com 登录一次，再回来扫码。\n\(failureText)"
            }
            return failureText
        }
    }

    private var needsWebVerification: Bool {
        scene == .failed && target == .netease && Self.riskControlCodes.contains(failureCode)
    }

    private static let riskControlCodes: Set<Int> = [-462, -460, 8821]

    // MARK: - 扫码流程

    private func start() {
        pollTask?.cancel()
        image = nil
        failureText = ""
        failureCode = 0
        scene = .preparing
        let platform = target
        pollTask = Task {
            do {
                let code = try await platform.makeQRCode()
                if let ready = Self.decode(code.image) {
                    image = ready
                } else {
                    image = await Self.loadRemote(code.image)
                }
                scene = .code
                await poll(platform: platform, key: code.key)
            } catch {
                failureText = (error as? LocalizedError)?.errorDescription ?? "获取二维码失败"
                scene = .failed
            }
        }
    }

    /// 平台回来的可能是 `data:image/png;base64,...`，也可能直接是 http 地址
    private static func decode(_ text: String) -> UIImage? {
        if let comma = text.firstIndex(of: ","), text.hasPrefix("data:") {
            let base64 = String(text[text.index(after: comma)...])
            if let data = Data(base64Encoded: base64) { return UIImage(data: data) }
        }
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: bare), let image = UIImage(data: data) { return image }
        return nil
    }

    private static let imageCache = NSCache<NSURL, UIImage>()

    private func poll(platform: MusicProvider, key: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            switch await platform.pollQR(key: key) {
            case .waiting:
                scene = .code
            case .scanned:
                scene = .scanned
            case .confirmed:
                scene = .success
                if let account = try? await platform.loadAccount(), let account {
                    library.signIn(provider: platform, session: account)
                } else {
                    failureText = "已拿到登录凭证，但读取账号失败，请点刷新二维码重试。"
                    scene = .failed
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                close()
                return
            case .expired:
                scene = .expired
                return
            case .failed(let reason):
                failureText = reason
                failureCode = await platform.lastQRCode()
                scene = .failed
                return
            }
        }
    }

    /// 图片地址形式的二维码（波点的 imageUrl）没法在解码函数里同步取，留一个备用入口
    static func loadRemote(_ text: String) async -> UIImage? {
        guard let url = URL(string: text) else { return nil }
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        let session = foliaURLSession()
        guard let (data, _) = try? await session.data(from: url),
              let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// 一道 90° 的弧（原版 login-arc 的 border-top）
private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - 1,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

private struct LoginActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}

private struct LoginRefreshPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}
