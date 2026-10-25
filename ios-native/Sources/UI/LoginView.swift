import SwiftUI

/// 复刻原版 Web 的扫码登录窗口（src/components/login/window/LoginWindow.tsx + LoginTile / LoginMessage）。
///
/// 层级：与设置页同一个 Sheet 外壳（窗底 #1a1a1d / 24pt 圆角 / 1px 16% 外描边）
/// → 页头（24pt 网易云记号 + 16pt 半粗「登录到 网易云音乐」+ 32×32 关闭钮）
/// → 窄版正文（原版 `max-width:803px` 分支）：200×200 圆角 12 的 tile，下面竖排居中的消息区
/// （20pt / 28 行高标题 + 13pt 说明 + 32pt 高操作按钮）。
/// 二维码在 tile 里是 176×176 的白底；过期时换成卡片底 + 1px 8%，码淡到 10%，中央一个 56pt 深色刷新圆钮。
struct LoginView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    /// 取得的二维码图：过期态要把它淡淡地留在原地
    @State private var image: UIImage?
    @State private var scene: Scene = .preparing
    /// 失败原因（原版平台或本地服务的原话）
    @State private var failureText = ""
    @State private var pollTask: Task<Void, Never>?

    /// 原版登录的几种样子（loginView.ts 里跟扫码有关的那几个）
    private enum Scene {
        case preparing   // 正在取二维码：记号 + 一道转着的弧
        case code        // 二维码已在
        case scanned     // 手机上扫了，等确认
        case success     // 登录成功
        case expired     // 过期：码淡着留下，中央刷新钮
        case failed      // 取码或轮询失败
    }

    /// LoginWindow / LoginTile / LoginMessage 的像素值（Tailwind × 4）
    private enum M {
        static let corner: CGFloat = 24           // Sheet rounded-2xl
        static let headerTop: CGFloat = 16        // header pt-4
        static let headerLead: CGFloat = 24       // header pl-6
        static let headerTrail: CGFloat = 16      // header pr-4
        static let headerGap: CGFloat = 10        // titleLead 的 gap-2.5
        static let titleLine: CGFloat = 32        // leading-8
        static let markLead: CGFloat = 24         // LEAD
        static let closeSize: CGFloat = 32        // h-8 w-8

        static let bodyLead: CGFloat = 24         // body px-6
        static let bodyTop: CGFloat = 12          // body pt-3
        static let bodyBottom: CGFloat = 20       // body pb-5
        static let narrowGap: CGFloat = 16        // 窄版 gap-4

        static let tile: CGFloat = 200            // h-[200px] w-[200px]
        static let tileCorner: CGFloat = 12       // rounded-xl
        static let code: CGFloat = 176            // h-[176px] w-[176px]
        static let refreshSize: CGFloat = 56      // h-14 w-14
        static let refreshIcon: CGFloat = 22      // RefreshCw 22
        static let disc: CGFloat = 88             // Disc h-[88px] w-[88px]
        static let discIcon: CGFloat = 34         // Disc 里的图形
        static let arc: CGFloat = 54              // preparing h-[54px] w-[54px]
        static let arcMark: CGFloat = 30          // preparing 里的记号

        static let headlineSize: CGFloat = 20     // text-xl
        static let headlineLine: CGFloat = 28     // leading-7
        static let noteTop: CGFloat = 6           // mt-1.5
        static let noteSize: CGFloat = 13         // text-[13px]
        static let quoteCorner: CGFloat = 8       // rounded-lg
        static let quoteV: CGFloat = 8            // py-2
        static let quoteH: CGFloat = 10           // px-2.5
        static let quoteSize: CGFloat = 12        // text-xs
        static let actionTop: CGFloat = 16        // mt-4
        static let actionMin: CGFloat = 32        // min-h-8
        static let actionH: CGFloat = 32          // kit Button h-8
        static let actionInset: CGFloat = 12      // kit Button px-3
        static let actionSize: CGFloat = 13       // kit Button text-[13px]
    }

    /// 与原版 CSS 变量一一对应（kitTheme.ts 的 --st-*）
    private enum C {
        static let t1 = FoliaTheme.text
        static let t2 = FoliaTheme.text.opacity(0.62)
        static let line = FoliaTheme.text.opacity(0.08)
        static let line2 = FoliaTheme.text.opacity(0.16)
        static let fill = FoliaTheme.text.opacity(0.07)
        static let accent = WallTheme.midnight.accent
        /// --st-win：窗口的底色
        static let win = Color(hex: 0x1A1A1D)
        /// --st-card：tile 的卡片底
        static let card = Color(hex: 0x232327)
        /// 刷新圆钮：原版固定 #17171a（白底二维码上的深色钮，不跟主题）
        static let refresh = Color(hex: 0x17171A)
        /// 加载弧的走色：原版是平台的码色 --login-pc
        static let mark = Color(hex: 0xDC2626)
    }

    /// kit 缓动：ease-out (0.22, 1, 0.36, 1)，move 0.22
    private static let moveAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)

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
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: M.headerGap) {
                NeteaseMark(size: M.markLead)
                Text("登录到 网易云音乐")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: M.titleLine)
            .frame(maxWidth: .infinity, alignment: .leading)

            SheetCloseButton {
                pollTask?.cancel()
                dismiss()
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

    /// 二维码（含过期那一张）要白底才扫得出来；其余是卡片底 + 1px 8%（原版 onWhite / framed）
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

    /// 过期：码淡到 10% 留在原地，正中一个刷新圆钮
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

    /// 正在取二维码：平台的记号，外面一道转着的弧（login-arc：2px 环，顶边是码色）
    private var preparing: some View {
        ZStack {
            Circle()
                .strokeBorder(C.line, lineWidth: 2)
            ArcShape()
                .stroke(C.mark, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
            NeteaseMark(size: M.arcMark)
        }
        .frame(width: M.arc, height: M.arc)
    }

    /// scanned / failed 的圆形画（Disc：88pt / 7% 底）
    private func discIcon(system: String) -> some View {
        ZStack {
            Circle().fill(C.fill)
            Image(systemName: system)
                .font(.system(size: M.discIcon, weight: .regular))
                .foregroundStyle(C.t1)
        }
        .frame(width: M.disc, height: M.disc)
    }

    /// 过期态中央的刷新圆钮（56pt / #17171A / 白 RefreshCw 22 / 按下 scale 0.95）
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

    /// 操作行（mt-4 / min-h-8 / gap-2）：有过期或失败就给「刷新二维码」，等确认时给原版那句安静小框
    private var actions: some View {
        HStack(spacing: 8) {
            if scene == .expired || scene == .failed {
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

    // MARK: - 文案（原版 zh-CN 的 home.loginTitle / home.loginNote / home.qrScanned …）

    private var headline: String {
        switch scene {
        case .preparing: return "正在获取二维码…"
        case .code: return "使用网易云APP扫码"
        case .scanned: return "扫描成功！请在手机上确认。"
        case .success: return "登录成功！"
        case .expired: return "二维码已过期"
        case .failed: return "登录没有成功"
        }
    }

    private var note: String? {
        switch scene {
        case .preparing: return nil
        case .code: return "打开网易云音乐APP > 发现 > 扫一扫"
        case .scanned: return nil
        case .success: return nil
        case .expired: return "点中间的圆钮换一张新的二维码。"
        case .failed: return failureText
        }
    }

    // MARK: - 扫码流程

    private func start() {
        pollTask?.cancel()
        image = nil
        failureText = ""
        scene = .preparing
        pollTask = Task {
            do {
                let key = try await NeteaseAPI.shared.qrKey()
                let base64 = try await NeteaseAPI.shared.qrImage(key: key)
                if let comma = base64.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(base64[base64.index(after: comma)...])) {
                    image = UIImage(data: data)
                }
                scene = .code
                await poll(key: key)
            } catch {
                failureText = (error as? LocalizedError)?.errorDescription ?? "获取二维码失败"
                scene = .failed
            }
        }
    }

    private func poll(key: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            switch await NeteaseAPI.shared.checkQR(key: key) {
            case .waiting:
                scene = .code
            case .scanned:
                scene = .scanned
            case .confirmed:
                scene = .success
                if let account = try? await NeteaseAPI.shared.currentAccount() {
                    library.signIn(session: account)
                } else {
                    // 803 已经拿到 cookie，账号资料却取不到：不能让窗口静默关掉（看起来就是「登录没反应」）
                    failureText = "已拿到登录凭证，但读取账号失败，请点刷新二维码重试。"
                    scene = .failed
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
                return
            case .expired:
                scene = .expired
                return
            case .failed(let reason):
                failureText = reason
                scene = .failed
                return
            }
        }
    }
}

/// 一道 90° 的弧（原版 login-arc 的 border-top：从顶点顺时针四分之一，边是码色）
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

/// kit Button 的按下反馈：缩放 0.97（enabled:active:scale-[0.97]）
private struct LoginActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}

/// 过期态刷新圆钮的按下反馈：active:scale-95
private struct LoginRefreshPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}
