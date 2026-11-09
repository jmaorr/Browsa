import Foundation
import Network

/// A tiny localhost HTTP server for SpikeBrowsa: the control channel and the mock dev servers.
/// One request per connection, like `AgentServer`, and it reuses that file's `HTTPRequest`.
@MainActor
final class SpikeHTTPServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        /// The JSON body as a dictionary, or empty.
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    typealias Handler = @MainActor (Request) async -> HTTPResponse

    let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private(set) var problem: String?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, port] state in
                MainActor.assumeIsolated {
                    if case .failed(let error) = state {
                        self?.problem = error.localizedDescription
                        NSLog("SpikeBrowsa: port \(port) failed: \(error)")
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
    }

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
                    let full = Self.target(of: buffer)
                    let r = Request(method: request.method, path: request.path, query: Self.query(full),
                                    headers: request.headers, body: request.body)
                    Task { @MainActor in
                        let response = await self.handler(r)
                        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// The request target from the first line, query included (`HTTPRequest` drops the query).
    private static func target(of data: Data) -> String {
        guard let end = data.firstRange(of: Data("\r\n".utf8)),
              let line = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return "/" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    private static func query(_ target: String) -> [String: String] {
        guard let items = URLComponents(string: "http://x" + target)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}

extension HTTPResponse {
    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", data: data)
    }

    static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", data: Data(html.utf8))
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }

    static var ok: HTTPResponse { .json(["ok": true]) }
}
