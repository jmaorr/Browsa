import Foundation
import Network

/// Browsa's MCP endpoint: `POST http://127.0.0.1:<port>/mcp`, JSON in and JSON out (MCP's
/// Streamable HTTP transport, without the optional event stream). Only this Mac can reach it, and
/// every request needs the bearer token from Settings, so a web page can't talk to it either.
@MainActor
final class AgentServer {
    typealias Handler = @MainActor (_ body: Data, _ session: String) async -> Data?

    let port: UInt16
    private let token: String
    private let handler: Handler
    private var listener: NWListener?
    private(set) var isRunning = false
    /// Why it isn't running, for Settings.
    private(set) var problem: String?

    init(port: UInt16, token: String, handler: @escaping Handler) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.isRunning = true; self?.problem = nil
                    case .failed(let error): self?.isRunning = false; self?.problem = error.localizedDescription; self?.stop()
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    Task { @MainActor in await self.respond(to: request, on: connection) }
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        // A page in a browser can reach localhost; it can't send our token, and it always sends an Origin.
        if let origin = request.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {
            return send(.init(status: 403, body: "Forbidden"), on: connection)
        }
        // Supper's photos, from the app bundle.
        if request.method == "GET", request.path.hasPrefix("/demo/img/") {
            let name = (request.path as NSString).lastPathComponent
            guard name.hasPrefix("supper-"), name.hasSuffix(".jpg"),
                  let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "jpg"),
                  let data = try? Data(contentsOf: url) else { return send(.init(status: 404, body: "Not found"), on: connection) }
            return send(.init(status: 200, contentType: "image/jpeg", data: data), on: connection)
        }
        // Supper, the demo site agents can practise on. Public, read-only, and only on this Mac.
        if request.method == "GET", request.path == "/demo" || request.path == "/demo/",
           let url = Bundle.main.url(forResource: "supper", withExtension: "html"), let page = try? Data(contentsOf: url) {
            var response = HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", data: page)
            // Always the copy in this build, never one a restored tab cached.
            response.headers["Cache-Control"] = "no-store"
            return send(response, on: connection)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return send(.init(status: 401, body: "Add the token from Browsa's Settings"), on: connection)
        }
        guard request.path == "/mcp" else { return send(.init(status: 404, body: "Not found"), on: connection) }
        switch request.method {
        case "POST":
            let session = request.headers["mcp-session-id"] ?? UUID().uuidString
            let reply = await handler(request.body, session)
            var response = reply.map { HTTPResponse(status: 200, contentType: "application/json", data: $0) }
                ?? HTTPResponse(status: 202, body: "")
            response.headers["Mcp-Session-Id"] = session
            send(response, on: connection)
        case "DELETE":
            send(.init(status: 200, body: ""), on: connection)
        default:
            // No server-to-client event stream yet.
            send(.init(status: 405, body: "Method not allowed"), on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Just enough HTTP/1.1 for one request per connection.
struct HTTPRequest {
    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    /// Nil until the whole request (headers and `Content-Length` bytes of body) has arrived.
    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        self.headers = headers
        body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
    }
}

struct HTTPResponse {
    var status: Int
    var contentType = "text/plain; charset=utf-8"
    var data: Data
    var headers: [String: String] = [:]

    init(status: Int, contentType: String, data: Data) {
        self.status = status
        self.contentType = contentType
        self.data = data
    }

    init(status: Int, body: String) {
        self.status = status
        data = Data(body.utf8)
    }

    var serialized: Data {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + data
    }
}
