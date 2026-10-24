import AgentModeCore
import Foundation
import Network

/// Internet reachability for P1 (design §8.4). `NWPathMonitor` reports route changes at once; HTTPS
/// probes run on every change and every `probeIntervalSeconds`, at most one every 10 s and never two
/// at a time. Each probe asks every configured URL in parallel and counts as reachable if any
/// `ProbeEvaluator` accepts.
@MainActor
final class NetworkMonitor {
    static let minimumGap: TimeInterval = 10
    nonisolated static let timeout: TimeInterval = 10
    /// `ProbeEvaluator` checks this host's body for "Success", so it gets a GET; the rest get a HEAD.
    nonisolated static let bodyCheckedHost = "captive.apple.com"

    private let config: AgentModeConfig
    private let emit: @MainActor (Event) -> Void
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.jsanchez.agentmode.network", qos: .utility)
    private let session: URLSession
    private var timer: Timer?
    private var lastPath: String?
    private var inFlight = false
    private var pending = false
    private var lastStart: Date?
    private var retryScheduled = false
    private(set) var reachable: Bool?

    init(config: AgentModeConfig, emit: @escaping @MainActor (Event) -> Void) {
        self.config = config
        self.emit = emit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // Probes carry no state between requests: no cookies stored or sent.
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let summary = Self.describe(path)
            MainLoop.async { self?.pathChanged(summary) }
        }
        // The first update arrives right away and triggers the startup probe.
        pathMonitor.start(queue: pathQueue)
        let interval = TimeInterval(config.probeIntervalSeconds)
        timer = MainLoop.repeating(every: interval, first: interval) { [weak self] in
            self?.requestProbe()
        }
    }

    private func pathChanged(_ summary: String) {
        guard summary != lastPath else { return }
        lastPath = summary
        Log.info("network: path \(summary)")
        requestProbe()
    }

    func requestProbe() {
        pending = true
        startPendingProbe()
    }

    private func startPendingProbe() {
        guard pending, !inFlight else { return }
        let wait = lastStart.map { $0.addingTimeInterval(Self.minimumGap).timeIntervalSinceNow } ?? 0
        guard wait <= 0 else {
            if !retryScheduled {
                retryScheduled = true
                MainLoop.after(wait) { [weak self] in
                    self?.retryScheduled = false
                    self?.startPendingProbe()
                }
            }
            return
        }
        pending = false
        inFlight = true
        lastStart = Date()
        let urls = config.probeURLs
        let session = session
        Task { [weak self] in
            let outcomes = await Self.probe(urls, session: session)
            self?.finish(outcomes)
        }
    }

    private func finish(_ outcomes: [Outcome]) {
        inFlight = false
        let reachable = outcomes.contains(where: \.reachable)
        self.reachable = reachable
        Log.info(
            "network: probe \(reachable ? "reachable" : "unreachable") (\(outcomes.map(\.summary).joined(separator: "; ")))"
        )
        emit(.probe(reachable: reachable))
        startPendingProbe()
    }

    // MARK: Probing (off the main actor)

    struct Outcome: Sendable {
        var url: URL
        var reachable: Bool
        var summary: String
    }

    private nonisolated static func probe(_ urls: [URL], session: URLSession) async -> [Outcome] {
        await withTaskGroup(of: Outcome.self) { group in
            for url in urls {
                group.addTask { await probe(url, session: session) }
            }
            var outcomes: [Outcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { $0.url.absoluteString < $1.url.absoluteString }
        }
    }

    private nonisolated static func probe(_ url: URL, session: URLSession) async -> Outcome {
        let checksBody = url.host(percentEncoded: false)?.lowercased() == bodyCheckedHost
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = checksBody ? "GET" : "HEAD"
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = checksBody ? String(decoding: data, as: UTF8.self) : nil
            let reachable = ProbeEvaluator.isReachable(url: url, statusCode: status, body: body)
            return Outcome(url: url, reachable: reachable, summary: "\(host) HTTP \(status.map(String.init) ?? "?")")
        } catch let error as URLError {
            return Outcome(url: url, reachable: false, summary: "\(host) error \(error.code.rawValue)")
        } catch {
            return Outcome(url: url, reachable: false, summary: "\(host) error \(error.localizedDescription)")
        }
    }

    private nonisolated static func describe(_ path: NWPath) -> String {
        var interfaces: [String] = []
        for name in path.availableInterfaces.map(\.name) where !interfaces.contains(name) {
            interfaces.append(name)
        }
        return "\(path.status) [\(interfaces.joined(separator: ","))]"
    }
}

/// Any HTTP answer proves connectivity, so redirects are reported as they are, not followed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
