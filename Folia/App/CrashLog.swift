import Foundation

/// 现场记录的崩溃/异常日志。
///
/// 之前的「闪退」有两种完全不同的成因，日志外观却一样（都是回到加载界面）：
///   1. ObjC 异常杀进程 —— `WKURLSchemeTask` 取消后仍被回调，WebKit 抛 NSInternalInconsistencyException；
///   2. 内容进程被系统回收 —— 网页里 OOM 或 React 抛未捕获错误，导致 WebProcess 退出。
/// 只有留下调用栈才能分清，所以这里把两者都落到沙盒的 Documents 里，
/// 用户在「文件」App 里可以直接取出来。
enum CrashLog {
    /// **每次启动一个新文件**。
    ///
    /// 早先所有启动共用 `folia-crash.log`，超过 256KB 就整体截断。冷启动时
    /// `CacheSweeper.sweepOnColdLaunch()` 会立刻先写一行，于是「上一次进程是怎么死的」
    /// 那几行经常在用户去取日志之前就被覆盖掉 —— 这恰恰是定位「大退重进进歌单闪退」
    /// 唯一需要的证据。改成按启动分文件后，上一个进程的记录一定还在。
    private static let fileName = "folia-crash.log"
    private static let limit = 256 * 1024

    /// 本次启动专属的日志文件。第一次写日志时才建。
    private static var sessionURL: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("folia-crash-\(stamp).log")
    }()

    /// 兼容旧调用方：指向本次启动那份。
    static var fileURL: URL? { sessionURL }

    /// 保留几份历史启动日志。用户取日志时通常要「这次 + 上次」，给 6 份足够。
    private static let keepSessions = 6

    static func install() {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")

        // 这两个 API 要的是 C 函数指针，不能捕获上下文，
        // 所以只能指向文件顶层的全局函数。
        NSSetUncaughtExceptionHandler(foliaUncaughtExceptionHandler)

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, foliaFatalSignalHandler)
        }
        trimOldSessions()
    }

    static func note(_ text: String) {
        write(text)
    }

    static func write(_ text: String) {
        guard let url = sessionURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > UInt64(limit) {
                // 超过上限就整体截断，避免无限增长把一个装机用户的沙盒塞满。
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: data)
            } else {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
        NSLog("[Folia] %@", text)
    }

    /// 只保留最近的几份启动日志，避免 Documents 里堆成一片。
    private static func trimOldSessions() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let sessions = names
            .filter { $0.hasPrefix("folia-crash-") && $0.hasSuffix(".log") }
            .sorted(by: >)
        guard sessions.count > keepSessions else { return }
        for name in sessions.dropFirst(keepSessions) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

/// 未捕获的 ObjC 异常：WKURLSchemeTask 重复回调、数组越界等都会走到这里。
private func foliaUncaughtExceptionHandler(_ exception: NSException) {
    let trace = exception.callStackSymbols.joined(separator: "\n")
    CrashLog.write("""
    ==== UNCAUGHT EXCEPTION ====
    name: \(exception.name.rawValue)
    reason: \(exception.reason ?? "-")
    \(trace)
    """)
}

/// 信号类崩溃（野指针、栈溢出）拿不到 NSException，只能记信号名。
private func foliaFatalSignalHandler(_ code: Int32) {
    CrashLog.write("==== FATAL SIGNAL \(code) ====")
    signal(code, SIG_DFL)
    raise(code)
}
