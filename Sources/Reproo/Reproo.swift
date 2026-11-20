#if canImport(UIKit)
import UIKit

/// reproo – let testers report problems from your iOS app.
///
/// ```swift
/// Reproo.configure(projectKey: "rp_pk_…", host: URL(string: "https://app.reproo.no")!, environment: "staging")
/// Reproo.setUser(id: "u-123", role: "advisor")
/// Reproo.setContext(["screen": "CreateCustomer", "featureFlags": ["newCustomerFlow": true]])
/// Reproo.addBreadcrumb(type: .action, message: "Pressed Save")
/// Reproo.log("Saving failed: 422", level: .error)
/// Reproo.reportProblem()
/// ```
///
/// Requests of every `URLSession` are recorded automatically (method, URL, status, duration – never
/// headers or bodies) without changing how they run. Crashes are recorded
/// and sent on the next launch, where the tester is asked what they were doing – unless the project
/// has crash capture turned off. Without a connection, «report a problem» opens a native composer and
/// the report is sent by itself once the device is online again (see OfflineReports.swift).
///
/// Never crashes the app over its setup: `configure` without a valid project key (empty, or the guide's
/// "rp_pk_…" placeholder) or host logs one warning and leaves reproo off – no crash handlers, no network –
/// and `reportProblem()` before a valid `configure` logs and does nothing.
public enum Reproo {
    public static let sdkVersion = "0.8.1"

    /// Configures the SDK. Version and build default to the app bundle's values.
    /// `release` and `commitSha` identify the running build so the agent can analyse the exact
    /// source (falls back to the version when no release is given). Without `commitSha` the commit
    /// comes from the built Info.plist's `ReprooCommit`, which a one-time Run Script phase sets from
    /// git (see BuildCommit.swift and the README) – nothing to pass per release. `captureNetwork` records the
    /// app's `URLSession.shared` requests for the next report. `captureCrashes` keeps the recent
    /// activity on disk, records crashes and sends them on the next launch (see CrashCapture.swift) –
    /// unless the project has crash capture turned off, as the platform last said (see CrashSetting).
    /// `shakeToReport` opens the report when the tester shakes the device (off by default; see
    /// ShakeToReport.swift). Without a valid `projectKey` or `host` nothing is configured (see `Setup`).
    public static func configure(
        projectKey: String,
        host: URL,
        environment: String? = nil,
        version: String? = nil,
        build: String? = nil,
        appName: String? = nil,
        release: String? = nil,
        commitSha: String? = nil,
        attachScreenshot: Bool = true,
        captureNetwork: Bool = true,
        captureCrashes: Bool = true,
        shakeToReport: Bool = false
    ) {
        let projectKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Setup.problem(projectKey: projectKey, host: host) {
            // Off – e.g. a development build without a key: nothing installed, nothing sent.
            Setup.warn(problem)
            return
        }
        State.shared.update {
            $0.configuration = Configuration(
                projectKey: projectKey,
                host: host,
                environment: environment,
                version: version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: build ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                appName: appName ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
                appId: Bundle.main.bundleIdentifier,
                release: release,
                commitSha: BuildCommit.resolve(explicit: commitSha, info: BuildCommit.fromInfoPlist()),
                attachScreenshot: attachScreenshot,
                captureNetwork: captureNetwork,
                captureCrashes: captureCrashes
            )
        }
        if captureNetwork { NetworkCapture.install() }
        ShakeToReport.isEnabled = shakeToReport
        if shakeToReport { ShakeToReport.install() }
        // Before crash capture: an unasked crash prompt of an older build moves into the follow-ups first,
        // and the connection is watched from now on.
        OfflineReports.prepare()
        if captureCrashes && CrashSetting.cached(host: host, projectKey: projectKey) != false { CrashCapture.install() } else { CrashCapture.discardStoredData() }
        signal(projectKey: projectKey, host: host) { CrashSetting.received($0, host: host, projectKey: projectKey) }
        // Launch: what waits in the outbox goes now (crash capture sends its own reports above).
        OfflineReports.deliver()
    }

    /// Tells the platform the SDK runs in this app (the project's "SDK installed" step); the answer
    /// carries the project's crash setting and the reporter fields the offline composer shows, both
    /// kept for later launches. Best effort, on the SDK's own session, so it is never recorded as the
    /// app's network activity.
    static func signal(projectKey: String, host: URL, session: URLSession = CrashCapture.session, defaults: UserDefaults = .standard, crashSetting: @escaping (Bool) -> Void) {
        guard let url = URL(string: "/api/v1/project", relativeTo: host) else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(projectKey, forHTTPHeaderField: "x-reproo-project-key")
        request.setValue("ios/\(sdkVersion)", forHTTPHeaderField: "x-reproo-sdk")
        session.dataTask(with: NetworkCapture.own(request)) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            ProjectConfigCache.received(status: status, data: data, host: host, projectKey: projectKey, defaults: defaults)
            guard let enabled = CrashSetting.enabled(status: status, data: data) else { return }
            crashSetting(enabled)
        }.resume()
    }

    /// Identifies the tester (optional). The role helps the AI recognise permission issues. Name and
    /// e-mail are sent like the Web SDK's (the report page then does not ask for them) and fill in the
    /// offline composer's fields when the project asks for them.
    public static func setUser(id: String?, role: String?, name: String? = nil, email: String? = nil) {
        State.shared.update { $0.user = UserInfo(id: id, role: role, name: name, email: email) }
    }

    /// Reports written without a connection that wait on this device to be sent (at most 20, each kept
    /// for 7 days). For apps that want to show it, e.g. «2 rapporter venter på nett».
    public static var pendingReportCount: Int {
        OfflineReports.shared?.outbox.count() ?? 0
    }

    /// Adds app context. `screen` names the current screen, `route` the current route (e.g.
    /// "/kommuner/:id/rediger") and `userRole` sets the role; everything else is sent as custom
    /// context (filtered server-side by the project's allowlist). Pass `NSNull()` to remove a key.
    public static func setContext(_ context: [String: Any]) {
        // Screen and route go to the crash journal right away (see BlackBox.appendJournal).
        var journal: [String: Any] = [:]
        for key in ["screen", "route"] where context.keys.contains(key) {
            journal[key] = context[key] as? String ?? NSNull()
        }
        State.shared.update(journal: journal.isEmpty ? nil : BlackBox.shared.journalEvent(journal)) { state in
            for (key, value) in context {
                switch key {
                case "screen": state.screen = value as? String
                case "route": state.route = value as? String
                case "userRole": state.user.role = value as? String
                default:
                    if value is NSNull { state.custom.removeValue(forKey: key) } else { state.custom[key] = value }
                }
            }
        }
    }

    /// Records a breadcrumb (last 50 are kept and sent with the next report). E-mail addresses and
    /// tokens are scrubbed right away – breadcrumbs are also kept on disk for crash reports.
    public static func addBreadcrumb(type: BreadcrumbType = .custom, message: String) {
        addBreadcrumb(type: type, message: message, data: nil)
    }

    /// `data`: the SDK's own structured details (connectivity changes) – never the app's values.
    static func addBreadcrumb(type: BreadcrumbType, message: String, data: [String: String]?) {
        let breadcrumb = Breadcrumb(type: type, message: Redaction.clip(Redaction.scrub(message), 300), data: data)
        State.shared.update(journal: BlackBox.shared.journalEvent(["breadcrumb": breadcrumb.json(Journal.iso)])) { $0.breadcrumbs.append(breadcrumb) }
    }

    /// Presents the reporting UI on top of the current screen: the report page, or – when the device
    /// is offline – the native composer, which keeps the report on the device until it can be sent.
    /// Before a valid `configure` (no key in a development build, say) it logs a warning and does nothing.
    @MainActor
    public static func reportProblem(from presenter: UIViewController? = nil) {
        guard let configuration = State.shared.snapshot.configuration else {
            Setup.warn("Reproo.reportProblem(): reproo is off – call Reproo.configure(...) with the app's project key first.")
            return
        }
        guard let host = presenter ?? UIApplication.shared.topViewController else { return }
        addBreadcrumb(type: .action, message: "Opened reproo report dialog")
        let screenshot = configuration.attachScreenshot ? ScreenCapture.captureKeyWindow() : nil
        let snapshot = State.shared.snapshot
        let context = ContextCollector.collect(state: snapshot)
        // Once the report exists (or is saved for later), what this snapshot holds is that report's – the next one starts fresh.
        let controller = ReportViewController(
            configuration: configuration,
            context: context,
            screenshot: screenshot,
            reported: snapshot,
            startsWithComposer: ReportViewController.opensComposer(connectivity: snapshot.connectivity)
        )
        controller.modalPresentationStyle = .pageSheet
        // A visible handle: the web content scrolls inside the sheet, so testers need an obvious place to drag it closed.
        controller.sheetPresentationController?.prefersGrabberVisible = true
        host.present(controller, animated: true)
    }
}

public enum BreadcrumbType: String {
    case navigation, action, network, error, log, custom
}

struct Breadcrumb: Equatable {
    let type: BreadcrumbType
    let message: String
    let data: [String: String]?
    let timestamp = Date()

    init(type: BreadcrumbType, message: String, data: [String: String]? = nil) {
        self.type = type
        self.message = message
        self.data = data
    }

    /// Protocol v1 breadcrumb.
    func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
        var json: [String: Any] = ["type": type.rawValue, "message": message, "timestamp": iso.string(from: timestamp)]
        if let data { json["data"] = data }
        return json
    }
}

struct Configuration {
    let projectKey: String
    let host: URL
    let environment: String?
    let version: String?
    let build: String?
    let appName: String?
    /// The app's bundle identifier – which app a report came from (the project's SDK tab lists them per key).
    let appId: String?
    let release: String?
    let commitSha: String?
    let attachScreenshot: Bool
    let captureNetwork: Bool
    let captureCrashes: Bool
}

struct UserInfo {
    var id: String?
    var role: String?
    var name: String?
    var email: String?
}

/// Thread-safe SDK state.
final class State {
    static let shared = State()

    struct Values {
        var configuration: Configuration?
        var user = UserInfo()
        var screen: String?
        var route: String?
        var custom: [String: Any] = [:]
        var breadcrumbs: [Breadcrumb] = []
        var network: [NetworkEvent] = []
        var console: [ConsoleEvent] = []
        /// The connection as the path monitor last reported it (nil before its first answer).
        var connectivity: ConnectivityState?
        let sessionId = UUID().uuidString
    }

    private let lock = NSLock()
    private var values = Values()

    var snapshot: Values {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// Reads under the lock – e.g. a snapshot together with the crash journal's position, so the
    /// black box knows exactly which journal lines its snapshot already contains.
    func read<T>(_ body: (Values) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(values)
    }

    /// After a report was created from `reported` (a snapshot): drops the breadcrumbs, requests and
    /// log messages it contained, so the next report does not repeat them. Matched by value, not by
    /// time – a request that was still running when the snapshot was taken is not part of it. A log
    /// message repeated since then (count and time changed) stays: it happened again. The black box
    /// is rewritten with the rest, so a later crash report starts from the same state.
    func discard(reported: Values) {
        update { state in
            state.breadcrumbs.removeAll { reported.breadcrumbs.contains($0) }
            state.network.removeAll { reported.network.contains($0) }
            state.console.removeAll { reported.console.contains($0) }
        }
    }

    /// `journal`: the change as one crash-journal line (breadcrumbs, screen/route, requests), written to
    /// disk right away under the same lock – the black box itself is only rewritten later.
    func update(journal: Data? = nil, _ change: (inout Values) -> Void) {
        do {
            lock.lock()
            defer { lock.unlock() }
            change(&values)
            if let journal { BlackBox.shared.appendJournal(journal) }
            if values.breadcrumbs.count > 50 { values.breadcrumbs.removeFirst(values.breadcrumbs.count - 50) }
            if values.network.count > RuntimeLimits.networkEvents { values.network.removeFirst(values.network.count - RuntimeLimits.networkEvents) }
            if values.console.count > RuntimeLimits.consoleEvents { values.console.removeFirst(values.console.count - RuntimeLimits.consoleEvents) }
        }
        // Outside the lock: the black box takes its own snapshot later, on its own queue.
        BlackBox.shared.scheduleWrite()
    }
}

extension UIApplication {
    /// nil where no application object exists (unit-test bundles without a host app).
    static var sharedIfAvailable: UIApplication? {
        UIApplication.value(forKey: "sharedApplication") as? UIApplication
    }

    var topViewController: UIViewController? {
        var top = appKeyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// The app's key window – never the SDK's own (see UIWindow.appKeyWindow).
    var appKeyWindow: UIWindow? {
        UIWindow.appKeyWindow(among: connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows))
    }
}

extension UIWindow {
    /// The key window among `windows` – unless it is the SDK's own (the follow-up question's, which is
    /// shown without taking it): then the app's window beneath it, so the report sheet is never presented
    /// on the question and the screenshot is the app's screen. nil when none is key.
    static func appKeyWindow(among windows: [UIWindow], isKey: (UIWindow) -> Bool = { $0.isKeyWindow }) -> UIWindow? {
        guard let key = windows.first(where: isKey) else { return nil }
        guard key.rootViewController is FollowUpPromptController else { return key }
        let beneath = (key.windowScene?.windows ?? windows).filter { !$0.isHidden && !($0.rootViewController is FollowUpPromptController) }
        return beneath.first { $0.windowLevel == .normal } ?? beneath.first
    }
}
#endif
