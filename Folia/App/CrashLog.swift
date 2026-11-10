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

    /// 写日志的串行队列。
    ///
    /// 原来是在调用线程上同步 `FileHandle` 写。改动之后主线程每 5 秒就有一条节拍
    /// （回落 + 水位），而且崩溃现场是「进程被内存顶到边缘」—— 这时在调用线程上
    /// 同步做文件 IO，等于把最紧张的那几毫秒再拉长。统一挪到后台串行队列，
    /// 顺序不变、现场不丢。
    private static let queue = DispatchQueue(label: "folia.crashlog", qos: .utility)

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

        // **信号处理器里不能再同步写日志。** 那等于在崩溃线程上重入 `FileHandle`，
        // 只要死的那一刻主线程正拿着文件锁，这里就当场死锁，现场一条都留不下。
        // 处理器只把队列上已有的内容排出去，然后交回系统默认处理。
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
        queue.async { writeNow(text) }
    }

    /// 崩溃现场专用：不等队列，直接同步落盘。
    ///
    /// 只给未捕获异常处理器用 —— 那条 `UNCAUGHT EXCEPTION` 之后进程可能
    /// 立刻被系统终止，排队写等于必然丢。
    static func writeSynchronously(_ text: String) {
        writeNow(text)
    }

    /// 把写队列上还没落盘的内容尽快排出去（非阻塞）。
    ///
    /// 只给信号处理器用：那里既不能同步等队列（会吊死进程、丢掉系统崩溃报告），
    /// 也不能做任何可能加锁的事。这里只追加一个空块，让已经在队列里的写入
    /// 尽快执行完，然后交回默认信号处理。
    static func flushBarrier() {
        queue.async {}
    }

    /// 立即落盘（只在写队列上、或崩溃现场同步调用）。
    private static func writeNow(_ text: String) {
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
    CrashLog.writeSynchronously("""
    ==== UNCAUGHT EXCEPTION ====
    name: \(exception.name.rawValue)
    reason: \(exception.reason ?? "-")
    \(trace)
    """)
}

/// 信号类崩溃（野指针、栈溢出）拿不到 NSException，只能记信号名。
///
/// **这里只能做异步信号安全的事。** 早先它在处理器里调 `CrashLog.write`，
/// 也就是在崩溃线程上同步打开/写/关闭 `FileHandle`；只要死的那一刻主线程
/// 正拿着文件锁（日志节拍每 5 秒就写一条），这里就当场重入死锁，
/// 现场只剩下一堆没头的日志。现在只把队列上已有的内容排出去，
/// 然后交回系统默认处理。
private func foliaFatalSignalHandler(_ code: Int32) {
    CrashLog.flushBarrier()
    signal(code, SIG_DFL)
    raise(code)
}
