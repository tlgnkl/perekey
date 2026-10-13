// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import os

/// A small HTTP/1.1 server on 127.0.0.1 for download tests: one request per
/// connection, the response from `handler`.
final class TestServer: Sendable {
    struct Request: Sendable {
        /// As sent, query included.
        let target: String
        /// Lowercased names.
        let headers: [String: String]

        var path: String { String(target.prefix { $0 != "?" }) }
        var range: String? { headers["range"] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// Sends this many bytes of the body, then resets the connection.
        var cutAfter: Int?
        /// Sends `cutAfter` bytes, then neither sends nor closes.
        var stall = false
    }

    typealias Handler = @Sendable (Request, Int) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-server")
    private let state: OSAllocatedUnfairLock<(requests: [Request], handler: Handler)>
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var base: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { state.withLock { $0.requests } }

    /// `handler` gets the request and how many came before it to the same path.
    init(_ handler: @escaping Handler) async throws {
        state = OSAllocatedUnfairLock(initialState: ([], handler))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.withLock { $0?.resume(); $0 = nil }
                case .failed(let error), .waiting(let error):
                    ready.withLock { $0?.resume(throwing: error); $0 = nil }
                case .cancelled:
                    ready.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    func setHandler(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }

    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: buffer[..<end.lowerBound])
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(target: target, headers: headers)
        let response = state.withLock { state in
            let earlier = state.requests.filter { $0.path == request.path }.count
            state.requests.append(request)
            return state.handler(request, earlier)
        }
        var head = "HTTP/1.1 \(response.status) Status\r\nConnection: close\r\nContent-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body.prefix(response.cutAfter ?? response.body.count))
        if response.stall || response.cutAfter != nil {
            // The client reads what came before the connection drops: a reset
            // throws away what it has not read yet.
            connection.send(content: bytes, completion: .contentProcessed { _ in
                guard !response.stall else { return }
                connection.queue?.asyncAfter(deadline: .now() + 0.3) { connection.forceCancel() }
            })
            return
        }
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.queue?.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        })
    }
}

extension TestServer {
    /// Serves `files` by path with `Range` support, the way the Hugging Face CDN does.
    static func files(_ files: [String: Data], ranges: Bool = true) -> Handler {
        { request, _ in
            guard let body = files[request.path] else { return Response(status: 404) }
            return serve(body, request: request, ranges: ranges)
        }
    }

    static func serve(_ body: Data, request: Request, ranges: Bool = true) -> Response {
        guard ranges, let range = request.range, range.hasPrefix("bytes="),
            let start = Int(range.dropFirst(6).prefix { $0 != "-" })
        else {
            return Response(status: 200, body: body)
        }
        guard start < body.count else {
            return Response(status: 416, headers: ["Content-Range": "bytes */\(body.count)"])
        }
        return Response(
            status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
            body: body.subdata(in: start..<body.count))
    }
}
