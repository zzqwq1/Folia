import Foundation

/// 现场记录的崩溃/异常日志。
///
/// 之前的「闪退」有两种完全不同的成因，日志外观却一样（都是回到加载界面）：
///   1. ObjC 异常杀进程 —— `WKURLSchemeTask` 取消后仍被回调，WebKit 抛 NSInternalInconsistencyException；
///   2. 内容进程被系统回收 —— 网页里 OOM 或 React 抛未捕获错误，导致 WebProcess 退出。
/// 只有留下调用栈才能分清，所以这里把两者都落到沙盒的 Documents 里，
/// 用户在「文件」App 里可以直接取出来。
enum CrashLog {
    private static let fileName = "folia-crash.log"
    private static let limit = 256 * 1024

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    static func install() {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")

        NSSetUncaughtExceptionHandler { exception in
            let trace = exception.callStackSymbols.joined(separator: "\n")
            write("""
            ==== UNCAUGHT EXCEPTION ====
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "-")
            \(trace)
            """)
        }

        // 信号类崩溃（野指针、栈溢出）拿不到 NSException，只能记信号名。
        // 这类崩溃基本不会出现在本壳里，留下信号足以区分即可。
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, { code in
                write("==== FATAL SIGNAL \(code) ====")
                exit(code)
            })
        }
    }

    static func note(_ text: String) {
        write(text)
    }

    static func write(_ text: String) {
        guard let url = fileURL else { return }
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
