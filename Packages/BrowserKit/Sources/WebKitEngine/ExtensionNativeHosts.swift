// Adapted from Search's ExtensionNative.swift (https://github.com/driceroland/Search).
// Copyright (c) 2026 Office Commun. Used under the MIT License:
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation
import OSLog
import WebKit

/// Chrome's native messaging, for extensions that talk to an app on this Mac: a password manager
/// unlocking with its desktop app (1Password, Bitwarden's Touch ID), a clipper handing a page to an app.
///
/// Those apps register with Chrome by leaving a JSON file in Chrome's NativeMessagingHosts folder: a
/// name, the program to run, and which extensions may run it (`allowed_origins`). Browsa reads the
/// same files, runs the same program with the extension's origin as its argument, and speaks the same
/// protocol: each message a 4-byte little-endian length and JSON, over the program's stdin and stdout.
/// Only a host that lists the extension's `chrome-extension://<id>/` origin is run. Some hosts also
/// check which browser is calling (1Password asks you to add it under Settings › Browser › Add
/// Browser); that's the app's decision.
///
/// Works only outside the App Sandbox (a sandboxed browser's child inherits its sandbox), which is how
/// Browsa Mac ships.
@available(macOS 15.4, *)
@MainActor
enum ExtensionNativeHosts {
    nonisolated static let log = Logger(subsystem: "com.orriginal.browsa", category: "ExtensionNative")

    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac. Chrome's own come first.
    nonisolated static var folders: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return [
            support.appending(path: "Google/Chrome/NativeMessagingHosts"),
            support.appending(path: "Chromium/NativeMessagingHosts"),
            support.appending(path: "Microsoft Edge/NativeMessagingHosts"),
            support.appending(path: "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appending(path: "Arc/User Data/NativeMessagingHosts"),
            URL(filePath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(filePath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(filePath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            support.appending(path: "Vivaldi/NativeMessagingHosts"),
            support.appending(path: "com.operasoftware.Opera/NativeMessagingHosts"),
        ]
    }

    /// The program registered for `name`, if it lets `origin` in. Errors read as Chrome's do.
    nonisolated static func program(for name: String, origin: String, in folders: [URL] = folders) throws -> URL {
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw Refused(why: "Invalid native messaging host name specified.")
        }
        for folder in folders {
            let file = folder.appending(path: name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String else { continue }
            guard (manifest["allowed_origins"] as? [String] ?? []).contains(origin) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(filePath: path) : folder.appending(path: path)
            guard FileManager.default.isExecutableFile(atPath: program.path(percentEncoded: false)) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }
        throw Refused(why: "Specified native messaging host not found.")
    }

    // MARK: Throttle

    /// Recent starts per extension and host. A host that refuses at once (1Password's does, for a
    /// browser it doesn't trust) gets started again and again by the extension's retries; past
    /// `burst` starts in `window` seconds, further ones are refused until the window has passed.
    private static var starts: [String: [Date]] = [:]
    static let burst = 5
    static let window: TimeInterval = 10

    static func admit(_ name: String, origin: String, now: Date = Date()) throws {
        let key = origin + " " + name
        var recent = (starts[key] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < burst else {
            starts[key] = recent
            log.notice("host \(name, privacy: .public) started \(recent.count) times in \(Int(window))s; holding off")
            throw Refused(why: "Native host is being started too often; try again shortly.")
        }
        recent.append(now)
        starts[key] = recent
    }

    // MARK: runtime.sendNativeMessage

    private static var replies: [ObjectIdentifier: (pipe: HostPipe, reply: (Any?, (any Error)?) -> Void)] = [:]

    /// Run, send one message, hand back the first answer, stop.
    static func send(_ message: Any, to name: String, origin: String, reply: @escaping (Any?, (any Error)?) -> Void) {
        let pipe: HostPipe
        do {
            let program = try program(for: name, origin: origin)
            try admit(name, origin: origin)
            pipe = HostPipe(program: program, origin: origin)
        } catch { reply(nil, error); return }
        let key = ObjectIdentifier(pipe)
        replies[key] = (pipe, reply)
        pipe.onMessage = { message in
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(key, message.value, nil) } }
        }
        pipe.onExit = {
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(key, nil, Refused(why: "Native host has exited.")) } }
        }
        do {
            try pipe.start()
            try pipe.write(message)
        } catch {
            answer(key, nil, error)
        }
    }

    private static func answer(_ key: ObjectIdentifier, _ message: Any?, _ error: (any Error)?) {
        guard let waiting = replies.removeValue(forKey: key) else { return }
        waiting.pipe.stop()
        waiting.reply(message, error)
    }

    // MARK: runtime.connectNative

    private static var live: [ObjectIdentifier: (pipe: HostPipe, port: WKWebExtension.MessagePort, extensionID: String)] = [:]
    private static var alive: [ObjectIdentifier: Timer] = [:]
    /// The compat script's own messages on a port to an app (extension-compat.js), never passed on.
    static let beatKey = "__browsaNative"
    static let aliveInterval: TimeInterval = 25

    /// Run, and pass messages both ways until either end lets go.
    static func connect(_ port: WKWebExtension.MessagePort, origin: String, extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No native messaging host named.") }
        let program = try program(for: name, origin: origin)
        try admit(name, origin: origin)
        // A new port is often a worker starting over; the one before may have left its host running.
        stopOrphans()
        let pipe = HostPipe(program: program, origin: origin)
        let key = ObjectIdentifier(pipe)
        let started = Date()
        pipe.onTerminated = { how in
            log.notice("host \(name, privacy: .public) ended: \(how, privacy: .public), after \(Int(Date().timeIntervalSince(started)))s")
        }
        pipe.onMessage = { message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { live[key]?.port.sendMessage(message.value, completionHandler: nil) }
            }
        }
        pipe.onExit = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    alive.removeValue(forKey: key)?.invalidate()
                    guard let ended = live.removeValue(forKey: key) else { return }
                    if !ended.port.isDisconnected { ended.port.disconnect() }
                }
            }
        }
        live[key] = (pipe, port, extensionID)
        do { try pipe.start() } catch { live[key] = nil; pipe.stop(); throw error }
        port.messageHandler = { message, _ in
            guard let message else { return }
            // The compat script's beat is for WebKit's sake, not the host's.
            if (message as? [String: Any])?[beatKey] != nil { return }
            try? pipe.write(message)
        }
        port.disconnectHandler = { _ in
            log.info("port to \(name, privacy: .public) closed")
            MainActor.assumeIsolated { alive.removeValue(forKey: key)?.invalidate() }
            pipe.stop()
        }
        // WebKit unloads a worker that hasn't posted on an open port for two minutes, even with an app
        // attached. The compat script answers this with a beat, which keeps the worker as Chrome would.
        alive[key] = Timer.scheduledTimer(withTimeInterval: aliveInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let item = live[key], !item.port.isDisconnected else { alive.removeValue(forKey: key)?.invalidate(); return }
                item.port.sendMessage([beatKey: "alive"], completionHandler: nil)
            }
        }
        log.info("connected \(extensionID, privacy: .public) to host \(name, privacy: .public)")
    }

    /// WebKit doesn't always say when a port goes: an extension unloaded or a worker restarted leaves
    /// its ports disconnected without calling their disconnect handlers, and each host would run on
    /// until Browsa quit. Hosts whose ports have gone are stopped here.
    static func stopOrphans() {
        for item in live.values where item.port.isDisconnected { item.pipe.stop() }
    }

    /// Every host started for an extension (or for all of them), as extensions are unloaded.
    static func stopAll(for extensionID: String? = nil) {
        for (key, item) in live where extensionID == nil || item.extensionID == extensionID {
            live[key] = nil
            item.port.disconnectHandler = nil
            item.pipe.stop()
            if !item.port.isDisconnected { item.port.disconnect() }
        }
    }
}

/// A message on its way between a host's reader thread and the main thread. Only ever read on main.
struct NativeMessage: @unchecked Sendable {
    let value: Any
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child still holding it).
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it's killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome; messages to it are held to the same.
    static let frameCap = 1 << 20

    private let process: SpawnedHost
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    /// Held around each use of the input handle, so it's never written once closed.
    private let writing = NSLock()
    /// Set before `start`, and not changed after.
    var onMessage: (@Sendable (NativeMessage) -> Void)?
    var onExit: (@Sendable () -> Void)?
    var onTerminated: (@Sendable (String) -> Void)?
    private var stopped = false
    private var outputClosed = false
    private var finished = false
    private var inputClosed = false
    private var ending = false

    init(program: URL, origin: String) {
        // Not Foundation's Process: it puts the child in a process group of its own, and 1Password's
        // helper refuses a browser whose host isn't in the browser's process group ("BrowserSupport
        // was not part of the main browser's tree"). Chrome spawns hosts plainly; so does this.
        process = SpawnedHost(program: program, arguments: [origin], input: input, output: output)
        // Writing to a host that has already gone would raise SIGPIPE and take Browsa with it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.outputClosed = true
                self.lock.unlock()
                self.finish()
                // As in Chrome, a host whose output has closed is done with, even if it runs on.
                self.end()
                return
            }
            self.take(chunk)
        }
        // The end is when the host's output closes (it may exit right after writing its last reply),
        // but a child of the host's may hold that output open, so an exit ends things after a grace.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let now = self.stopped || self.outputClosed
            let first = self.stopped ? "stopped by Browsa" : self.outputClosed ? "its output closed first" : "exited on its own"
            self.lock.unlock()
            let how = process.signaled ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
            self.onTerminated?("\(how), \(first)")
            if now {
                self.finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) { self.finish(); self.end() }
            }
        }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { end() } else { finish() }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= Self.frameCap else { throw ExtensionNativeHosts.Refused(why: "Message too long for a native host.") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        writing.lock()
        defer { writing.unlock() }
        guard !inputClosed else { throw ExtensionNativeHosts.Refused(why: "Native host has exited.") }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    /// Splits what arrived into messages: a 4-byte little-endian length, then that many bytes of JSON.
    static func frames(in buffer: inout Data) -> (messages: [Any], overlong: Bool) {
        var messages: [Any] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if length > frameCap { buffer = Data(); return (messages, true) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer.removeSubrange(start..<(start + 4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        if buffer.isEmpty { buffer = Data() }
        return (messages, false)
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        buffer.append(chunk)
        let (messages, overlong) = Self.frames(in: &buffer)
        let deliver = onMessage
        lock.unlock()
        for message in messages { deliver?(NativeMessage(value: message)) }
        // As in Chrome, a host claiming a message past the cap is done with.
        if overlong { finish(); end() }
    }

    /// Stops the host as Chrome does: input closed and SIGTERM, then SIGKILL after a grace.
    private func end() {
        lock.lock()
        let first = !ending
        ending = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.global().async {
            self.writing.lock()
            if !self.inputClosed {
                self.inputClosed = true
                try? self.input.fileHandleForWriting.close()
            }
            self.writing.unlock()
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let exit = onExit
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        exit?()
    }
}
/// A host program started with posix_spawn, as Chrome starts them: in Browsa's own process group
/// (Foundation's Process gives each child a group of its own), with only stdin, stdout and stderr
/// passed on. Enough of Process's surface for HostPipe.
@available(macOS 15.4, *)
final class SpawnedHost: @unchecked Sendable {
    private let program: URL
    private let arguments: [String]
    private let input: Pipe
    private let output: Pipe
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var running = false
    private var source: (any DispatchSourceProcess)?
    private(set) var terminationStatus: Int32 = 0
    private(set) var signaled = false
    /// Set before `run`. Called once, on a background queue, when the host has exited.
    var terminationHandler: (@Sendable (SpawnedHost) -> Void)?

    init(program: URL, arguments: [String], input: Pipe, output: Pipe) {
        self.program = program
        self.arguments = arguments
        self.input = input
        self.output = output
    }

    var processIdentifier: pid_t { lock.lock(); defer { lock.unlock() }; return pid }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func run() throws {
        let path = program.path(percentEncoded: false)
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the host, and its signals start out as a new
        // program's would. No POSIX_SPAWN_SETPGROUP: it stays in Browsa's process group.
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, path, &actions, &attributes, argv, environ)
        // The child's ends belong to the child now; holding them would keep its output from closing.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        guard result == 0 else {
            throw ExtensionNativeHosts.Refused(why: "Couldn't start the native host (\(String(cString: strerror(result)))).")
        }
        lock.lock()
        pid = child
        running = true
        let watch = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
        source = watch
        lock.unlock()
        watch.setEventHandler { [weak self] in self?.reap(blocking: true) }
        watch.resume()
        // It may have exited before the watch was in place.
        reap(blocking: false)
    }

    private func reap(blocking: Bool) {
        lock.lock()
        guard running else { return lock.unlock() }
        var status: Int32 = 0
        let done = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        guard done == pid || (done == -1 && errno == ECHILD) else { return lock.unlock() }
        running = false
        // WIFSIGNALED / WTERMSIG / WEXITSTATUS, which Swift doesn't import.
        let low = status & 0x7f
        signaled = low != 0 && low != 0x7f
        terminationStatus = signaled ? low : (status >> 8) & 0xff
        source?.cancel()
        source = nil
        let handler = terminationHandler
        lock.unlock()
        handler?(self)
    }

    /// SIGTERM, as Process.terminate does.
    func terminate() {
        let target = processIdentifier
        if target > 0, isRunning { kill(target, SIGTERM) }
    }
}
#endif
