#if canImport(UIKit)
import Foundation

/// Severity of a message recorded with `Reproo.log` (sent as the protocol's console `level`).
public enum LogLevel: String {
    case error, warn, info
}

extension Reproo {
    /// Records a message for the next report – typically an error the app handled, e.g.
    /// `Reproo.log("Saving the harvest report failed: 422")`. Sent as console output (the last 30,
    /// identical consecutive messages folded); e-mail addresses and tokens are scrubbed before sending.
    public static func log(_ message: String, level: LogLevel = .error) {
        let text = Redaction.clip(Redaction.scrub(message), RuntimeLimits.consoleMessageLength)
        guard !text.isEmpty else { return }
        State.shared.update { state in
            if let last = state.console.last, last.level == level, last.message == text {
                state.console[state.console.count - 1].count += 1
                state.console[state.console.count - 1].timestamp = Date()
            } else {
                state.console.append(ConsoleEvent(level: level, message: text, count: 1, timestamp: Date()))
            }
        }
    }

    /// Nothing to do since 0.8.1: requests of every `URLSession` – Alamofire's too – are recorded
    /// without changing how they run (see `NetworkCapture`). Kept so existing calls still compile.
    @available(*, deprecated, message: "Every URLSession is captured since reproo 0.8.1 – remove the call.")
    public static func instrument(_ configuration: URLSessionConfiguration) {}

    /// Records a request the SDK cannot see (another networking stack). Never pass headers or bodies:
    /// method, URL, status (nil when no response arrived) and duration are all a report needs. A request
    /// without a response while the device has no connection is marked offline.
    public static func recordNetworkRequest(method: String, url: URL, status: Int?, duration: TimeInterval, error: String? = nil) {
        NetworkCapture.append(NetworkEvent(
            method: String(method.uppercased().prefix(10)),
            url: Redaction.sanitize(url: url),
            status: status,
            durationMs: max(0, Int((duration * 1000).rounded())),
            error: error.map { Redaction.clip(Redaction.scrub($0), 200) },
            errorCode: nil,
            offline: status == nil ? NetworkCapture.failedOffline(error: nil) : nil,
            responseType: nil,
            timestamp: Date()
        ))
    }
}

enum RuntimeLimits {
    static let networkEvents = 30
    static let consoleEvents = 30
    static let urlLength = 500
    static let consoleMessageLength = 500
}

/// Metadata of one HTTP request – never headers or bodies (protocol v1 `NetworkEvent`).
struct NetworkEvent: Equatable {
    let method: String
    /// Sanitized: no credentials, no fragment, sensitive query values redacted.
    let url: String
    /// HTTP status; nil when the request failed before a response.
    let status: Int?
    let durationMs: Int
    let error: String?
    /// "<domain>:<code>" of the error, e.g. "NSURLErrorDomain:-1009".
    let errorCode: String?
    /// The request failed while the device had no connection – not a failure of the app's servers.
    let offline: Bool?
    let responseType: String?
    let timestamp: Date

    init(method: String, url: String, status: Int?, durationMs: Int, error: String?, errorCode: String? = nil, offline: Bool? = nil, responseType: String?, timestamp: Date) {
        self.method = method
        self.url = url
        self.status = status
        self.durationMs = durationMs
        self.error = error
        self.errorCode = errorCode
        self.offline = offline
        self.responseType = responseType
        self.timestamp = timestamp
    }

    func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
        var json: [String: Any] = [
            "method": method,
            "url": url,
            "status": status ?? 0,
            "ok": status.map { (200..<400).contains($0) } ?? false,
            "failed": status == nil,
            "durationMs": durationMs,
            "initiator": "other",
            "timestamp": iso.string(from: timestamp),
        ]
        if let error { json["error"] = error }
        if let errorCode { json["errorCode"] = errorCode }
        if let offline { json["offline"] = offline }
        if let responseType { json["responseType"] = responseType }
        return json
    }
}

/// A message recorded with `Reproo.log` (protocol v1 `ConsoleEvent`).
struct ConsoleEvent: Equatable {
    let level: LogLevel
    let message: String
    var count: Int
    var timestamp: Date

    func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
        ["level": level.rawValue, "kind": "console", "message": message, "count": count, "timestamp": iso.string(from: timestamp)]
    }
}

/// Records the app's HTTP requests by watching its own `URLSession` tasks – it never sends, forwards or
/// changes a request: streams, delegates (authentication, certificate pinning, redirects), per-task
/// delegates, cookies, caches, upload bodies and the app's own `URLProtocol`s behave exactly as without
/// reproo. Each task is noted when it is resumed and recorded once it completes (method, URL, status,
/// duration, error – never headers or bodies). Every session is seen: `URLSession.shared`, the app's
/// own and Alamofire's.
enum NetworkCapture {
    private static let installLock = NSLock()
    private static var installed = false

    static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true
        TaskObserver.install()
    }

    /// Marks the SDK's own requests (on its own sessions, to the platform): never recorded, whatever host
    /// they go to (a crash or an offline report from before the host changed). The mark stays in the process.
    static let ownRequestKey = "no.reproo.own-request"

    static func own(_ request: URLRequest) -> URLRequest {
        guard let marked = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return request }
        URLProtocol.setProperty(true, forKey: ownRequestKey, in: marked)
        return marked as URLRequest
    }

    static func isOwn(_ request: URLRequest) -> Bool {
        URLProtocol.property(forKey: ownRequestKey, in: request) != nil
    }

    static func shouldCapture(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let snapshot = State.shared.snapshot
        guard let configuration = snapshot.configuration, configuration.captureNetwork else { return false }
        // Never record the reporting platform's own traffic.
        return !(url.host == configuration.host.host && url.port == configuration.host.port)
    }

    static func record(request: URLRequest, response: URLResponse?, error: Error?, started: Date) {
        guard let url = request.url else { return }
        let http = response as? HTTPURLResponse
        append(NetworkEvent(
            method: String((request.httpMethod ?? "GET").uppercased().prefix(10)),
            url: Redaction.sanitize(url: url),
            status: http?.statusCode,
            durationMs: max(0, Int((Date().timeIntervalSince(started) * 1000).rounded())),
            error: error.map { Redaction.clip(Redaction.scrub($0.localizedDescription), 200) },
            errorCode: error.map(errorCode),
            offline: error.map { failedOffline(error: $0) },
            responseType: http?.mimeType,
            timestamp: started
        ))
    }

    /// "NSURLErrorDomain:-1009" – stable across languages, unlike the localized description.
    static func errorCode(_ error: Error) -> String {
        let error = error as NSError
        return Redaction.clip("\(error.domain):\(error.code)", 80)
    }

    /// Errors that by themselves say the device has no usable connection.
    private static let noConnectionCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
    ]

    /// A failed request counts as offline when the device had no connection at that moment (as the
    /// path monitor last said) or the error itself says so.
    static func failedOffline(error: Error?, connectivity: ConnectivityState? = State.shared.read({ $0.connectivity })) -> Bool {
        if connectivity?.status == .offline { return true }
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return false }
        return noConnectionCodes.contains(error.code)
    }

    static func append(_ event: NetworkEvent) {
        // The request reaches the crash journal before the response reaches the app – a crash while
        // handling it still has the request in its report.
        State.shared.update(journal: BlackBox.shared.journalEvent(["network": event.json(Journal.iso)])) { $0.network.append(event) }
    }
}

/// Notes the app's `URLSession` tasks as they are resumed and records them when they complete. `resume`
/// is wrapped on the classes that implement it for data, upload and download tasks (found on tasks of a
/// throwaway session, as AFNetworking and Sentry do); the wrapper only attaches an observer of the task's
/// `state` (key-value observable) and then calls the original – the task runs as it would without it.
enum TaskObserver {
    private static var watchKey: UInt8 = 0
    private static let resumeSelector = NSSelectorFromString("resume")

    static func install() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://reproo.invalid/") else { return }
        // Never resumed: no request is made.
        let tasks: [URLSessionTask] = [session.dataTask(with: url), session.uploadTask(with: URLRequest(url: url), from: Data()), session.downloadTask(with: url)]
        var wrapped: [AnyClass] = []
        for task in tasks {
            var current: AnyClass? = object_getClass(task)
            while let cls = current, cls != NSObject.self {
                if implementsResume(cls), !wrapped.contains(where: { $0 == cls }) {
                    wrapResume(of: cls)
                    wrapped.append(cls)
                }
                current = class_getSuperclass(cls)
            }
            task.cancel()
        }
    }

    /// The class has a `resume` of its own (not only the one it inherits).
    private static func implementsResume(_ cls: AnyClass) -> Bool {
        guard let method = class_getInstanceMethod(cls, resumeSelector) else { return false }
        guard let superclass = class_getSuperclass(cls), let inherited = class_getInstanceMethod(superclass, resumeSelector) else { return true }
        return method_getImplementation(method) != method_getImplementation(inherited)
    }

    private static func wrapResume(of cls: AnyClass) {
        guard let method = class_getInstanceMethod(cls, resumeSelector) else { return }
        typealias Resume = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Resume.self)
        let selector = resumeSelector
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            if let task = object as? URLSessionTask { TaskObserver.willResume(task) }
            original(object, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Starts watching a task that is about to run for the first time (a resume after suspend, or of a
    /// subclass whose `resume` calls its superclass's, finds the watch already there).
    static func willResume(_ task: URLSessionTask) {
        guard objc_getAssociatedObject(task, &watchKey) == nil, task.state == .suspended else { return }
        guard let request = task.originalRequest ?? task.currentRequest, !NetworkCapture.isOwn(request), let url = request.url, NetworkCapture.shouldCapture(url) else { return }
        let watch = TaskWatch(request: request, started: Date())
        objc_setAssociatedObject(task, &watchKey, watch, .OBJC_ASSOCIATION_RETAIN)
        watch.observation = task.observe(\.state, options: [.new]) { [weak watch] task, _ in
            guard task.state == .completed, let watch, watch.claim() else { return }
            NetworkCapture.record(request: watch.request, response: task.response, error: task.error, started: watch.started)
        }
    }
}

/// One task being watched: what it asked for and when, recorded once when it completes. Lives as long as the task.
final class TaskWatch {
    let request: URLRequest
    let started: Date
    var observation: NSKeyValueObservation?
    private let lock = NSLock()
    private var recorded = false

    init(request: URLRequest, started: Date) {
        self.request = request
        self.started = started
    }

    /// True the first time only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if recorded { return false }
        recorded = true
        return true
    }
}

/// Privacy filters for runtime evidence, mirroring the Web SDK (the server sanitizes again).
enum Redaction {
    private static let sensitiveParameter = regex(
        "^(?:token|code|password|passwd|secret|key|apikey|api_key|auth|authorization|session|sessionid|signature|sig|jwt|access_token|id_token|refresh_token|otp)$|token|secret|passw|api[-_]?key|signature|credential|sess(?:ion)?[-_]?id"
    )

    // Order matters: the most specific patterns first.
    private static let rules: [(NSRegularExpression, String)] = [
        (regex("\\beyJ[\\w-]{2,}\\.[\\w-]{2,}\\.[\\w-]*"), "[jwt]"),
        (regex("\\b(Bearer)\\s+[\\w~+/.-]{8,}=*"), "$1 [redacted]"),
        (regex("(passw(?:or)?d|passord|pwd|secret|token|api[-_]?key|access[-_]?key|private[-_]?key|sess(?:ion)?[-_]?id|jwt)([\\w-]*[\"']?\\s*[:=]\\s*)(\"[^\"]*\"?|'[^']*'?|[^\\s\"'&,;)}\\]]+)"), "$1$2[redacted]"),
        (regex("\\b[\\w.%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"), "[email]"),
        (regex("\\b[A-Fa-f0-9]{32,}\\b"), "[secret]"),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo should fail the first test run, not ship.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func isSensitiveParameter(_ name: String) -> Bool {
        sensitiveParameter.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Redacts JWTs, bearer tokens, `password=…`/`token=…` pairs, e-mail addresses and long hex secrets.
    static func scrub(_ text: String) -> String {
        guard text.count >= 5 else { return text }
        var result = text
        for (pattern, template) in rules {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// The URL without credentials and fragment, sensitive query values redacted.
    static func sanitize(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return clip(url.absoluteString.components(separatedBy: CharacterSet(charactersIn: "?#"))[0], RuntimeLimits.urlLength)
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        let query = components.percentEncodedQuery
        components.percentEncodedQuery = nil
        var result = components.string ?? ""
        if let query, !query.isEmpty {
            let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let separator = pair.firstIndex(of: "=") else { return String(pair) }
                let name = String(pair[..<separator])
                let rawValue = String(pair[pair.index(after: separator)...])
                if isSensitiveParameter(name.removingPercentEncoding ?? name) { return "\(name)=[redacted]" }
                let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
                let scrubbed = scrub(value)
                return scrubbed == value ? String(pair) : "\(name)=\(scrubbed)"
            }
            result += "?" + pairs.joined(separator: "&")
        }
        return clip(result, RuntimeLimits.urlLength)
    }

    static func clip(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max)) : text
    }
}
#endif
