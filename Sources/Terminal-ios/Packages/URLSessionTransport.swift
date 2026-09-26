// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real transport: `URLSession` bridged into the shell's synchronous world.
///
/// Kept in its own file so the local check runner (which builds the pure-logic
/// layer on Windows) can skip it: this is the only file that needs a platform
/// networking stack, and the policy it enforces lives in `MirrorPolicy`, which
/// *is* covered locally.
///
/// Rules it cannot relax:
/// - `MirrorPolicy.validate` runs first, so only allow-listed HTTPS hosts are
///   ever contacted.
/// - the response body is size-capped before it is used;
/// - nothing here executes anything - it returns bytes.
final class URLSessionTransport: ManifestTransport {

    private let session: URLSession
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Terminal-ios/1.0"]
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    func fetch(_ url: URL, byteLimit: Int) -> FetchResult<Data> {
        if case .failure(let reason) = MirrorPolicy.validate(urlString: url.absoluteString) {
            return .failure(reason)
        }
        var outcome: FetchResult<Data>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                outcome = .failure("HTTP \(http.statusCode) from \(url.host ?? "?")")
                return
            }
            guard let data else {
                outcome = .failure("empty response")
                return
            }
            guard data.count <= byteLimit else {
                outcome = .failure("response exceeds \(byteLimit) bytes")
                return
            }
            outcome = .success(data)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure("timed out after \(Int(timeout))s")
        }
        return outcome ?? .failure("no response")
    }
}
