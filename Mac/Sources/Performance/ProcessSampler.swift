import Darwin
import Foundation
import WebKit

/// Reads CPU time and memory for Browsa's own processes: the app and the WebKit helpers it starts.
///
/// Everything here is the same data Activity Monitor shows. `proc_pid_rusage` works on any process
/// run by the same user, so a Developer ID app needs no extra rights for its own helpers.
enum ProcessSampler {
    struct Reading {
        let pid: pid_t
        /// User plus system CPU time so far, in nanoseconds.
        let cpuNanoseconds: UInt64
        /// The "physical footprint", Activity Monitor's Memory column, in bytes.
        let footprint: UInt64
    }

    /// CPU times come in Mach ticks (24 MHz on Apple silicon); this turns them into nanoseconds.
    private static let ticksToNanoseconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()

    static func read(_ pid: pid_t) -> Reading? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return Reading(pid: pid, cpuNanoseconds: UInt64(ticks * ticksToNanoseconds), footprint: info.ri_phys_footprint)
    }

    /// The process's short name, such as `com.apple.WebKit.WebContent`.
    static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// macOS records which app is responsible for each XPC helper; that's how Activity Monitor groups
    /// WebKit's processes under the app. The call isn't in a public header, so it's looked up at run time
    /// and the panel falls back to the processes it can name from tabs when it isn't there.
    nonisolated(unsafe) private static let responsibleProcess: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// Browsa and every helper macOS counts as Browsa's: page, graphics and networking processes,
    /// extension background pages, service workers and the spare process kept ready for new tabs.
    static func browsaProcesses() -> [pid_t] {
        let me = getpid()
        guard let responsibleProcess else { return [me] }
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [me] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [me] }
        return pids.prefix(Int(count)).filter { $0 > 0 && ($0 == me || responsibleProcess($0) == me) }
    }

    /// The process a web view's page runs in.
    @MainActor static func webProcess(of webView: WKWebView) -> pid_t? {
        pid(webView, "_webProcessIdentifier")
    }

    /// The graphics process, shared by every tab.
    @MainActor static func graphicsProcess(of webView: WKWebView) -> pid_t? {
        pid(webView, "_gpuProcessIdentifier")
    }

    /// The networking process for the web view's profile.
    @MainActor static func networkProcess(of webView: WKWebView) -> pid_t? {
        pid(webView.configuration.websiteDataStore, "_networkProcessIdentifier")
    }

    /// WebKit's process IDs are read-only SPI properties. Asked only after checking they exist, so a
    /// WebKit without them gives nil instead of an exception.
    @MainActor private static func pid(_ object: NSObject, _ key: String) -> pid_t? {
        guard object.responds(to: NSSelectorFromString(key)),
              let number = object.value(forKey: key) as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }
}
