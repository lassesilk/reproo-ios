#if canImport(UIKit)
import UIKit

/// Offline reports – capture now, ask later. Without a connection «report a problem» opens a native
/// composer (or the report page offers to save when sending fails); the report is frozen at that
/// moment and kept on the device. It is sent by itself when the connection is back – at launch, when
/// the app comes to the foreground, when the connection returns (or moves to another network) while
/// it runs, right after it was saved while the device is online, when a pause the platform asked for
/// (`Retry-After`) is over, and after a send that got no answer (OutboxSender) – and the AI's questions
/// are asked the next time the app is open with a connection (FollowUpPrompt).
///
/// Files live in Application Support/no.reproo (excluded from backup, protected until first unlock),
/// apart from crash capture's folder, which is deleted when crash capture is turned off:
///
///   outbox/<clientReportId>/item.json, screenshot.jpg   reports waiting to be sent (Outbox)
///   followups.json                                      reports whose tester may still be asked (FollowUpStore)
final class OfflineReports {
    /// The app's own instance; nil only when Application Support cannot be found.
    static let shared: OfflineReports? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return OfflineReports(directory: support.appendingPathComponent("no.reproo", isDirectory: true), session: session, afterRun: { FollowUpPrompt.scheduleCheck() })
    }()

    /// Dedicated session for the outbox and the follow-ups: ephemeral, never seen by NetworkCapture,
    /// and patient – creating a report runs the AI's first turn before the platform answers.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    private static let lock = NSLock()
    private static var prepared = false

    let directory: URL
    let outbox: Outbox
    let followUps: FollowUpStore
    let sender: OutboxSender
    private let isOnline: () -> Bool

    /// The defaults are the app's; tests replace the connection, the clock, the timer of the runs the sender
    /// plans by itself (when the platform's pause ends, after one without an answer), whether protected
    /// files can be read, and what follows a run.
    init(directory: URL, session: URLSession, now: @escaping () -> Date = Date.init, backgroundTask: @escaping OutboxSender.BackgroundTask = ApplicationBackgroundTask.begin,
         isOnline: @escaping () -> Bool = { !ConnectivityMonitor.shared.isOffline }, schedule: @escaping OutboxSender.Schedule = OutboxSender.after,
         protectedDataAvailable: (() -> Bool)? = nil, afterRun: @escaping () -> Void = {}) {
        self.directory = directory
        self.isOnline = isOnline
        outbox = Outbox(directory: directory.appendingPathComponent("outbox", isDirectory: true), now: now, protectedDataAvailable: protectedDataAvailable)
        followUps = FollowUpStore(url: directory.appendingPathComponent("followups.json"), now: now)
        sender = OutboxSender(outbox: outbox, followUps: followUps, session: session, now: now, backgroundTask: backgroundTask, isOnline: isOnline, schedule: schedule, afterRun: afterRun)
    }

    /// From configure(), once per process: an unasked crash prompt of an older build moves into the
    /// follow-ups, the connection is watched, and the outbox is sent when the app comes back.
    static func prepare() {
        lock.lock()
        guard !prepared else {
            lock.unlock()
            return
        }
        prepared = true
        lock.unlock()
        migrateLegacyPrompt()
        let connectivity = ConnectivityMonitor.shared
        connectivity.onOnline { deliver() }
        connectivity.start()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in deliver() }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in FollowUpPrompt.scheduleCheck() }
        // Relaunched in the background before the first unlock, the outbox, crash capture's files and an older
        // build's crash prompt could not be read: the unlock moves and sends them.
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in
            migrateLegacyPrompt()
            deliver()
        }
    }

    /// An unasked crash prompt of an older build moves into the follow-ups – once it can be read.
    private static func migrateLegacyPrompt() {
        guard let shared, let crashStore = CrashStore.standard() else { return }
        shared.followUps.migrateLegacyPrompt(at: crashStore.promptURL)
    }

    /// Sends what waits – crash reports and the outbox, one after another – and then asks what can be
    /// asked. Nothing is tried while the device is known to be offline: the connection's return triggers it.
    static func deliver() {
        guard State.shared.snapshot.configuration != nil, !ConnectivityMonitor.shared.isOffline else { return }
        CrashCapture.deliverPending()
        shared?.deliver()
    }

    /// Sends this outbox unless the device is known to be offline; a run under way takes it along.
    func deliver() {
        guard isOnline() else { return }
        sender.run()
    }

    /// The platform refuses a message over 2000 characters as JavaScript counts them (UTF-16 units) –
    /// a refused report would be deleted, so it is cut on the device, never in the middle of a character.
    static func clipMessage(_ message: String, limit: Int = 2000) -> String {
        guard message.utf16.count > limit else { return message }
        var clipped = ""
        var units = 0
        for character in message {
            units += character.utf16.count
            if units > limit { break }
            clipped.append(character)
        }
        return clipped
    }

    enum SaveResult: Equatable {
        case saved
        /// 20 reports already wait: the tester is told, nothing saved is dropped.
        case full
        case failed
    }

    /// Keeps a report for later: the context frozen when the tester opened the report, their message
    /// and the screenshot (≤ 1600 px JPEG, like the one the report page attaches). Saved while the
    /// device is online (the report page could not reach the platform, or the connection just returned),
    /// it is sent right away – nothing else may come to trigger it while the app stays open.
    func save(clientReportId: String, message: String, reporter: [String: String]?, context: [String: Any], screenshot: UIImage?, configuration: Configuration, now: Date = Date()) -> SaveResult {
        let text = Self.clipMessage(message.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return .failed }
        let reporter = reporter?.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let item = OutboxItem(
            clientReportId: clientReportId,
            capturedAt: now,
            message: text,
            reporter: reporter?.isEmpty == false ? reporter : nil,
            context: context,
            host: configuration.host,
            projectKey: configuration.projectKey
        )
        do {
            try outbox.save(item, screenshot: screenshot.flatMap(ScreenCapture.jpegData))
            deliver()
            return .saved
        } catch Outbox.SaveError.full {
            return .full
        } catch {
            return .failed
        }
    }
}

/// The reporter fields of the project configuration (`GET /api/v1/project` → `reporter`), and the
/// privacy notice for testers (`privacy.url`), as the platform last answered – the offline composer has
/// no platform to ask. Kept per platform and project key, like the crash setting.
enum ProjectConfigCache {
    enum Mode: String {
        case off, optional, required

        var isShown: Bool { self != .off }
    }

    struct Fields: Equatable {
        var name: Mode
        var email: Mode
        /// The customer's own privacy notice for its testers; nil: the platform's /personvern.
        var privacyNotice: URL? = nil

        static let none = Fields(name: .off, email: .off)
    }

    static func fields(host: URL, projectKey: String, defaults: UserDefaults = .standard) -> Fields? {
        guard let stored = defaults.dictionary(forKey: key(host: host, projectKey: projectKey)) else { return nil }
        return Fields(
            name: (stored["nameMode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off,
            email: (stored["emailMode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off,
            privacyNotice: (stored["privacyUrl"] as? String).flatMap(httpURL)
        )
    }

    /// Only a successful answer with the reporter fields changes what is known.
    static func received(status: Int?, data: Data?, host: URL, projectKey: String, defaults: UserDefaults = .standard) {
        guard let status, (200..<300).contains(status),
              let json = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let reporter = json["reporter"] as? [String: Any] else { return }
        let fields = Fields(name: (reporter["nameMode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off, email: (reporter["emailMode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off)
        var stored = ["nameMode": fields.name.rawValue, "emailMode": fields.email.rawValue]
        // null, or a platform older than the setting: nothing stored – the platform's own notice.
        if let notice = ((json["privacy"] as? [String: Any])?["url"] as? String).flatMap(httpURL) { stored["privacyUrl"] = notice.absoluteString }
        defaults.set(stored, forKey: key(host: host, projectKey: projectKey))
    }

    /// The privacy notice the composer links to: the project's own, else the platform's /personvern.
    static func privacyNotice(_ fields: Fields, host: URL) -> URL? {
        fields.privacyNotice ?? URL(string: "/personvern", relativeTo: host)?.absoluteURL
    }

    /// Only http(s) is ever linked.
    private static func httpURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func key(host: URL, projectKey: String) -> String {
        "no.reproo.projectConfig|\(ReportViewController.origin(of: host))|\(projectKey)"
    }
}
#endif
