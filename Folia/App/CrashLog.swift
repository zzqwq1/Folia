import Foundation

/// 现场记录的崩溃/异常日志。
///
/// 之前的「闪退」有两种完全不同的成因，日志外观却一样（都是回到加载界面）：
///   1. ObjC 异常杀进程 —— `WKURLSchemeTask` 取消后仍被回调，WebKit 抛 NSInternalInconsistencyException；
///   2. 内容进程被系统回收 —— 网页里 OOM 或 React 抛未捕获错误，导致 WebProcess 退出。
/// 只有留下调用栈才能分清，所以这里把两者都落到沙盒的 Documents 里，
/// 用户在「文件」App 里可以直接取出来。
enum CrashLog {
    /// 单个日志文件，所有启动追加写入。
    ///
    /// 之前按启动分文件，用户要导出一堆文件。改成单文件追加，
    /// 每次启动加一条分隔线，超过1MB自动截断。
    private static let limit = 1024 * 1024

    /// 单个日志文件。
    private static var sessionURL: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("folia.log")
    }()

    /// 兼容旧调用方。
    static var fileURL: URL? { sessionURL }

    static func install() {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")

        // 这两个 API 要的是 C 函数指针，不能捕获上下文，
        // 所以只能指向文件顶层的全局函数。
        NSSetUncaughtExceptionHandler(foliaUncaughtExceptionHandler)

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, foliaFatalSignalHandler)
        }
        // 每次启动写一条分隔线
        note("")
        note("==== app launch ====")
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
