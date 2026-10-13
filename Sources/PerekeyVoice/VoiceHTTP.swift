// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// The one HTTP client of voice input. Everything voice sends to the network
/// goes through it: model downloads now, cloud speech and language models
/// later. Its session is ephemeral, with no cache and no cookies, so nothing
/// of a request outlives it.
///
/// Every request is recorded with its host and purpose, redirects included,
/// so a test can show that voice made no request. The record keeps hosts
/// only, never paths or bodies. A purpose that is not allowed fails before
/// any request: the app allows none while voice is off.
///
/// Sessions of FluidAudio and WhisperKit are not seen here; their loaders are
/// kept out of the sources by scripts/check-voice-loaders.sh.
public final class VoiceHTTP: Sendable {
    public enum Purpose: String, Sendable, CaseIterable {
        case modelDownload
        case cloudSpeech
        case cloudLanguageModel
    }

    public struct Request: Sendable, Equatable {
        public let host: String
        public let purpose: Purpose
    }

    public enum Failure: Error, Equatable {
        /// The purpose is not allowed; no request was made.
        case blocked(Purpose)
    }

    public static let shared = VoiceHTTP()

    private let session: URLSession
    private let router: Router
    private let state = OSAllocatedUnfairLock(initialState: (log: [Request](), allowed: Set(Purpose.allCases)))

    /// `requestTimeout` is the longest wait for the next bytes of a response.
    public init(requestTimeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 6 * 3_600
        configuration.waitsForConnectivity = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.perekey.voice.http"
        router = Router()
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: queue)
        router.record = { [state] host, purpose in
            state.withLock { $0.log.append(Request(host: host, purpose: purpose)) }
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Every request made so far, in order; a redirect counts as a request to its host.
    public var requests: [Request] { state.withLock { $0.log } }

    public func clearRequests() { state.withLock { $0.log.removeAll() } }

    /// The purposes requests may have. All by default.
    public var allowed: Set<Purpose> {
        get { state.withLock { $0.allowed } }
        set { state.withLock { $0.allowed = newValue } }
    }

    /// Sends `request` and hands its body to `receive` chunk by chunk, on a
    /// serial queue, as it arrives. `accept` sees the response first; when it
    /// returns false the body is not read and the response is returned as is.
    /// A throw from `receive` cancels the request and is rethrown. Redirects
    /// are followed and keep the `Range` header. Cancelling the calling task
    /// cancels the request and throws `CancellationError`.
    @discardableResult
    public func stream(
        _ request: URLRequest, purpose: Purpose,
        accept: @escaping @Sendable (HTTPURLResponse) -> Bool = { _ in true },
        receive: @escaping @Sendable (Data) throws -> Void
    ) async throws -> HTTPURLResponse {
        guard allowed.contains(purpose) else { throw Failure.blocked(purpose) }
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                router.add(
                    task,
                    Router.Handler(
                        purpose: purpose, range: request.value(forHTTPHeaderField: "Range"),
                        accept: accept, receive: receive, continuation: continuation))
                router.record(request.url?.host() ?? "", purpose)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The whole body of `request`, for small answers.
    public func data(for request: URLRequest, purpose: Purpose) async throws -> (Data, HTTPURLResponse) {
        let body = OSAllocatedUnfairLock(initialState: Data())
        let response = try await stream(request, purpose: purpose) { chunk in
            body.withLock { $0.append(chunk) }
        }
        return (body.withLock { $0 }, response)
    }
}

/// The session delegate: routes the callbacks of each task to its handler.
private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Handler {
        let purpose: VoiceHTTP.Purpose
        let range: String?
        let accept: @Sendable (HTTPURLResponse) -> Bool
        let receive: @Sendable (Data) throws -> Void
        let continuation: CheckedContinuation<HTTPURLResponse, Error>
        var response: HTTPURLResponse?
        var rejected = false
        var failure: Error?
    }

    /// Set once in `VoiceHTTP.init`, before the session starts any task.
    nonisolated(unsafe) var record: @Sendable (String, VoiceHTTP.Purpose) -> Void = { _, _ in }
    private let handlers = OSAllocatedUnfairLock(initialState: [Int: Handler]())

    func add(_ task: URLSessionTask, _ handler: Handler) {
        handlers.withLock { $0[task.taskIdentifier] = handler }
    }

    private func update(_ task: URLSessionTask, _ change: (inout Handler) -> Void) {
        handlers.withLockUnchecked { all in
            if var handler = all[task.taskIdentifier] {
                change(&handler)
                all[task.taskIdentifier] = handler
            }
        }
    }

    private func handler(_ task: URLSessionTask) -> Handler? {
        handlers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let handler = handler(task) else { return completionHandler(nil) }
        var next = request
        if let range = handler.range { next.setValue(range, forHTTPHeaderField: "Range") }
        record(next.url?.host() ?? "", handler.purpose)
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handler(dataTask), let http = response as? HTTPURLResponse else {
            update(dataTask) { $0.failure = URLError(.badServerResponse) }
            return completionHandler(.cancel)
        }
        let accepted = handler.accept(http)
        update(dataTask) {
            $0.response = http
            $0.rejected = !accepted
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(dataTask), handler.failure == nil else { return }
        do {
            try handler.receive(data)
        } catch {
            update(dataTask) { $0.failure = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let handler = handlers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = handler.failure {
            handler.continuation.resume(throwing: failure)
        } else if let response = handler.response, handler.rejected || error == nil {
            handler.continuation.resume(returning: response)
        } else if let error = error as? URLError, error.code == .cancelled {
            handler.continuation.resume(throwing: CancellationError())
        } else {
            handler.continuation.resume(throwing: error ?? URLError(.badServerResponse))
        }
    }
}
