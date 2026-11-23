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

    // MARK: runtime.sendNativeMessage

    private static var replies: [ObjectIdentifier: (pipe: HostPipe, reply: (Any?, (any Error)?) -> Void)] = [:]

    /// Run, send one message, hand back the first answer, stop.
    static func send(_ message: Any, to name: String, origin: String, reply: @escaping (Any?, (any Error)?) -> Void) {
        let pipe: HostPipe
        do { pipe = HostPipe(program: try program(for: name, origin: origin), origin: origin) } catch { reply(nil, error); return }
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

    /// Run, and pass messages both ways until either end lets go.
    static func connect(_ port: WKWebExtension.MessagePort, origin: String, extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No native messaging host named.") }
        let program = try program(for: name, origin: origin)
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
                    guard let ended = live.removeValue(forKey: key) else { return }
                    if !ended.port.isDisconnected { ended.port.disconnect() }
                }
            }
        }
        live[key] = (pipe, port, extensionID)
        do { try pipe.start() } catch { live[key] = nil; pipe.stop(); throw error }
        port.messageHandler = { message, _ in
            guard let message else { return }
            try? pipe.write(message)
        }
        port.disconnectHandler = { _ in
            log.info("port to \(name, privacy: .public) closed")
            pipe.stop()
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
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child still holding it).
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it's killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome; messages to it are held to the same.
    static let frameCap = 1 << 20

    private let process = Process()
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
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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
            let how = process.terminationReason == .uncaughtSignal ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
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
#endif
