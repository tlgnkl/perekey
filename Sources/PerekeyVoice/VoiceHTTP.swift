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
/// any request. None is allowed until the app allows one, and the app allows
/// none while voice is off.
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
        /// A redirect to a host the purpose may not reach; it was not followed.
        case redirectRefused(host: String)
        /// No network for the whole `connectivityTimeout`.
        case offline
    }

    /// Hosts a redirect may lead to, by purpose.
    public typealias RedirectRule = @Sendable (Purpose, URL) -> Bool

    public static let shared = VoiceHTTP()

    /// Requests the record keeps, the latest ones.
    static let recordLimit = 200

    let session: URLSession
    let router: Router
    private let state: OSAllocatedUnfairLock<(log: [Request], allowed: Set<Purpose>)>

    /// `requestTimeout` is the longest wait for the next bytes of a response.
    /// Without a network a request waits for one up to `connectivityTimeout`,
    /// then fails with `offline`.
    public init(
        allowed: Set<Purpose> = [], requestTimeout: TimeInterval = 60, connectivityTimeout: TimeInterval = 120,
        redirects: @escaping RedirectRule = VoiceHTTP.trustedRedirect
    ) {
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
        let state = OSAllocatedUnfairLock(initialState: (log: [Request](), allowed: allowed))
        self.state = state
        router = Router(connectivityTimeout: connectivityTimeout, redirects: redirects) { host, purpose in
            state.withLock {
                $0.log.append(Request(host: host, purpose: purpose))
                if $0.log.count > Self.recordLimit { $0.log.removeFirst($0.log.count - Self.recordLimit) }
            }
        }
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Model downloads may be redirected only over HTTPS to Hugging Face and
    /// its CDNs: `huggingface.co`, `hf.co` and their subdomains. Other
    /// purposes are not redirected.
    public static let trustedRedirect: RedirectRule = { purpose, url in
        guard purpose == .modelDownload, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased()
        else { return false }
        return ["huggingface.co", "hf.co"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The latest requests, up to 200, in order; a redirect counts as a
    /// request to its host.
    public var requests: [Request] { state.withLock { $0.log } }

    public func clearRequests() { state.withLock { $0.log.removeAll() } }

    /// The purposes requests may have. None by default.
    public var allowed: Set<Purpose> {
        get { state.withLock { $0.allowed } }
        set { state.withLock { $0.allowed = newValue } }
    }

    /// Sends `request` and hands its body to `receive` chunk by chunk, on a
    /// serial queue, as it arrives. `accept` sees the response first; when it
    /// returns false the body is not read and the response is returned as is.
    /// A throw from `receive` cancels the request and is rethrown. Redirects
    /// the purpose allows are followed and keep the `Range` header. `waiting`
    /// hears true while the request waits for a network and false when it
    /// has one again. Cancelling the calling task cancels the request and
    /// throws `CancellationError`.
    @discardableResult
    public func stream(
        _ request: URLRequest, purpose: Purpose,
        accept: @escaping @Sendable (HTTPURLResponse) -> Bool = { _ in true },
        waiting: (@Sendable (Bool) -> Void)? = nil,
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
                        accept: accept, receive: receive, waiting: waiting, continuation: continuation))
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
final class Router: NSObject, URLSessionDataDelegate, Sendable {
    struct Handler {
        let purpose: VoiceHTTP.Purpose
        let range: String?
        let accept: @Sendable (HTTPURLResponse) -> Bool
        let receive: @Sendable (Data) throws -> Void
        let waiting: (@Sendable (Bool) -> Void)?
        let continuation: CheckedContinuation<HTTPURLResponse, Error>
        var response: HTTPURLResponse?
        var rejected = false
        var isWaiting = false
        var failure: Error?
    }

    let record: @Sendable (String, VoiceHTTP.Purpose) -> Void
    private let connectivityTimeout: TimeInterval
    private let redirects: VoiceHTTP.RedirectRule
    private let handlers = OSAllocatedUnfairLock(initialState: [Int: Handler]())

    init(
        connectivityTimeout: TimeInterval, redirects: @escaping VoiceHTTP.RedirectRule,
        record: @escaping @Sendable (String, VoiceHTTP.Purpose) -> Void
    ) {
        self.connectivityTimeout = connectivityTimeout
        self.redirects = redirects
        self.record = record
    }

    func add(_ task: URLSessionTask, _ handler: Handler) {
        handlers.withLockUnchecked { $0[task.taskIdentifier] = handler }
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
        handlers.withLockUnchecked { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let handler = handler(task) else { return completionHandler(nil) }
        guard let url = request.url, redirects(handler.purpose, url) else {
            update(task) { $0.failure = VoiceHTTP.Failure.redirectRefused(host: request.url?.host() ?? "") }
            task.cancel()
            return completionHandler(nil)
        }
        var next = request
        if let range = handler.range { next.setValue(range, forHTTPHeaderField: "Range") }
        record(url.host() ?? "", handler.purpose)
        completionHandler(next)
    }

    /// Called once, when a request finds no network. It goes on waiting up to
    /// `connectivityTimeout`.
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let handler = handler(task) else { return }
        update(task) { $0.isWaiting = true }
        handler.waiting?(true)
        DispatchQueue.global().asyncAfter(deadline: .now() + connectivityTimeout) { [weak self] in
            guard let self, self.handler(task)?.isWaiting == true else { return }
            self.update(task) { $0.failure = VoiceHTTP.Failure.offline }
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handler(dataTask), let http = response as? HTTPURLResponse else {
            update(dataTask) { $0.failure = URLError(.badServerResponse) }
            return completionHandler(.cancel)
        }
        if handler.isWaiting { handler.waiting?(false) }
        let accepted = handler.failure == nil && handler.accept(http)
        update(dataTask) {
            $0.response = http
            $0.rejected = !accepted
            $0.isWaiting = false
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
        guard let handler = handlers.withLockUnchecked({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
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
