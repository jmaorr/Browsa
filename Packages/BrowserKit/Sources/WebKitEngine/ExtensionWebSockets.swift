#if os(macOS)
import Foundation
import WebKit

/// Real WebSockets for extensions' service workers. WebKit's own `WebSocket` freezes a service
/// worker (it waits on the thread the worker runs on), so Browsa's compat script replaces it with one
/// that connects over a native-messaging port named `browsa.websocket`, and Browsa opens the socket.
///
/// Messages from the worker: `{type: "open", url, protocols}`, `{type: "send", text}` or
/// `{type: "send", binary: <base64>}`, `{type: "close", code, reason}`.
/// Messages to the worker: `{type: "open", protocol}`, `{type: "message", text | binary}`,
/// `{type: "sent", bytes}`, `{type: "error", reason}`, `{type: "close", code, reason, wasClean}`.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWebSocket: NSObject, URLSessionWebSocketDelegate {
    static let portName = "browsa.websocket"
    /// Most sockets one extension may have open at once.
    static let limitPerExtension = 16
    private static var open: [String: Int] = [:]
    private static let maxMessageBytes = 1 << 20

    private let port: WKWebExtension.MessagePort
    private let extensionID: String
    private let origin: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    /// Keeps each socket alive until it closes.
    private static var live: Set<ExtensionWebSocket> = []

    static func accept(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        let socket = ExtensionWebSocket(port: port, extensionID: context.uniqueIdentifier, origin: context.baseURL)
        live.insert(socket)
        socket.start()
    }

    private init(port: WKWebExtension.MessagePort, extensionID: String, origin: URL) {
        self.port = port
        self.extensionID = extensionID
        self.origin = origin
    }

    private func start() {
        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.received(message) }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(sendClose: false, code: .goingAway) }
        }
    }

    private func received(_ message: Any?) {
        guard let m = message as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "open":
            guard task == nil else { return }
            guard let text = m["url"] as? String, let url = URL(string: text),
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
                fail("Browsa only opens ws: and wss: URLs with a host"); return
            }
            guard Self.open[extensionID, default: 0] < Self.limitPerExtension else {
                fail("Too many open sockets"); return
            }
            Self.open[extensionID, default: 0] += 1
            var request = URLRequest(url: url)
            // As a socket opened by the extension's background would: its own origin, no cookies.
            request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
            request.httpShouldHandleCookies = false
            let protocols = (m["protocols"] as? [String]) ?? []
            if !protocols.isEmpty { request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            let task = session!.webSocketTask(with: request)
            task.maximumMessageSize = Self.maxMessageBytes
            self.task = task
            task.resume()
            receiveNext()
        case "send":
            guard let task else { return }
            let frame: URLSessionWebSocketTask.Message
            var bytes = 0
            if let text = m["text"] as? String {
                guard text.utf8.count <= Self.maxMessageBytes else { fail("Message too large"); return }
                frame = .string(text); bytes = text.utf8.count
            } else if let b64 = m["binary"] as? String, let data = Data(base64Encoded: b64) {
                guard data.count <= Self.maxMessageBytes else { fail("Message too large"); return }
                frame = .data(data); bytes = data.count
            } else { return }
            task.send(frame) { [weak self] error in
                MainActor.assumeIsolated {
                    if let error { self?.fail(error.localizedDescription) } else { self?.post(["type": "sent", "bytes": bytes]) }
                }
            }
        case "close":
            let code = URLSessionWebSocketTask.CloseCode(rawValue: (m["code"] as? Int) ?? 1000) ?? .normalClosure
            let reason = (m["reason"] as? String)?.data(using: .utf8)
            task?.cancel(with: code, reason: reason)
            if task == nil { finish(sendClose: true, code: code) }
        default:
            break
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                switch result {
                case .success(.string(let text)): self.post(["type": "message", "text": text]); self.receiveNext()
                case .success(.data(let data)): self.post(["type": "message", "binary": data.base64EncodedString()]); self.receiveNext()
                case .success: self.receiveNext()
                case .failure: break   // the delegate reports the close or the error
                }
            }
        }
    }

    private func post(_ message: [String: Any]) {
        guard !finished else { return }
        port.sendMessage(message) { _ in }
    }

    private func fail(_ reason: String) {
        post(["type": "error", "reason": reason])
        finish(sendClose: true, code: .abnormalClosure)
    }

    private func finish(sendClose: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String = "", wasClean: Bool = false) {
        guard !finished else { return }
        if sendClose { post(["type": "close", "code": code.rawValue, "reason": reason, "wasClean": wasClean]) }
        finished = true
        if task != nil { Self.open[extensionID, default: 1] -= 1 }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        port.disconnect()
        Self.live.remove(self)
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { post(["type": "open", "protocol": `protocol` ?? ""]) }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            finish(sendClose: true, code: closeCode, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "", wasClean: true)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            post(["type": "error", "reason": error.localizedDescription])
            finish(sendClose: true, code: .abnormalClosure)
        }
    }
}
#endif
