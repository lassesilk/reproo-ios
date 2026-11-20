#if canImport(UIKit)
import os
import UIKit

/// App-private files the SDK keeps between launches: excluded from backups, readable once the
/// device has been unlocked after a restart (a send in the background must still find them).
enum ProtectedFiles {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// What reading a protected file gave.
    enum Contents {
        case missing
        /// There, but not readable now – between a restart and the first unlock, or another error.
        case unreadable
        case data(Data)
    }

    static func read(_ url: URL) -> Contents {
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
    }

    static func readJSON(_ url: URL) -> Any? {
        guard case .data(let data) = read(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// One report written without a connection, waiting to be sent (`outbox/<clientReportId>/item.json`;
/// the screenshot lies next to it as `screenshot.jpg`). Besides the protocol's fields it keeps where
/// it goes – the platform and project key it was written for, as a crash report does.
struct OutboxItem {
    let clientReportId: String
    /// When the tester saved it – sent as `offline.capturedAt`, and the start of its 7 days.
    let capturedAt: Date
    let message: String
    /// `{name?, email?}` as the tester gave them.
    let reporter: [String: String]?
    /// The context frozen when the tester opened the report (protocol `ClientContext`).
    let context: [String: Any]
    let host: URL
    let projectKey: String
    var attempts = 0
    var lastAttemptAt: Date?
    /// Set once the platform has the report – before the screenshot goes, so a retry never makes a second one.
    var reportId: String?
    var reporterToken: String?
    var screenshotUploaded = false

    init(clientReportId: String, capturedAt: Date, message: String, reporter: [String: String]?, context: [String: Any], host: URL, projectKey: String) {
        self.clientReportId = clientReportId
        self.capturedAt = capturedAt
        self.message = message
        self.reporter = reporter
        self.context = context
        self.host = host
        self.projectKey = projectKey
    }

    init?(json: Any?) {
        let iso = ISO8601DateFormatter()
        guard let json = json as? [String: Any],
              let clientReportId = json["clientReportId"] as? String,
              let capturedAt = (json["capturedAt"] as? String).flatMap(iso.date(from:)),
              let message = json["message"] as? String,
              let context = json["context"] as? [String: Any],
              let host = (json["host"] as? String).flatMap(URL.init(string:)),
              let projectKey = json["projectKey"] as? String else { return nil }
        self.init(clientReportId: clientReportId, capturedAt: capturedAt, message: message, reporter: json["reporter"] as? [String: String], context: context, host: host, projectKey: projectKey)
        attempts = json["attempts"] as? Int ?? 0
        lastAttemptAt = (json["lastAttemptAt"] as? String).flatMap(iso.date(from:))
        reportId = json["reportId"] as? String
        reporterToken = json["reporterToken"] as? String
        screenshotUploaded = json["screenshotUploaded"] as? Bool ?? false
    }

    var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "version": 1,
            "clientReportId": clientReportId,
            "capturedAt": iso.string(from: capturedAt),
            "message": message,
            "reporter": reporter as Any? ?? NSNull(),
            "context": context,
            "host": host.absoluteString,
            "projectKey": projectKey,
            "attempts": attempts,
            "lastAttemptAt": lastAttemptAt.map(iso.string(from:)) as Any? ?? NSNull(),
            "reportId": reportId as Any? ?? NSNull(),
            "reporterToken": reporterToken as Any? ?? NSNull(),
            "screenshotUploaded": screenshotUploaded,
        ]
    }

    /// `CreateReportRequest` of an offline report. `hostOrigin` is the platform's own origin – what
    /// the SDK's web view sends – so the allowlist and the key's platform check behave as for the widget.
    var requestBody: [String: Any] {
        var body: [String: Any] = [
            "context": context,
            "message": message,
            "clientReportId": clientReportId,
            "offline": ["capturedAt": ISO8601DateFormatter().string(from: capturedAt)],
            "hostOrigin": ReportViewController.origin(of: host),
        ]
        if let reporter, !reporter.isEmpty { body["reporter"] = reporter }
        return body
    }

    /// The same report saved again before the platform has it: what the tester wrote now, keeping when
    /// it was first saved and how often sending was tried.
    func resaved(over existing: OutboxItem) -> OutboxItem {
        var item = OutboxItem(clientReportId: clientReportId, capturedAt: existing.capturedAt, message: message, reporter: reporter, context: context, host: host, projectKey: projectKey)
        item.attempts = existing.attempts
        item.lastAttemptAt = existing.lastAttemptAt
        return item
    }

    /// The first words of the message, for the follow-up question («Problemet du lagret …»).
    var snippet: String {
        let words = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(59)) + "…" : words
    }

    /// What `clientReportId` may be (the protocol's rule) – also a safe folder name.
    static func isValidClientReportId(_ id: String) -> Bool {
        (8...128).contains(id.count) && id.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil && !id.allSatisfy { $0 == "." }
    }
}

/// Reports written without a connection, on disk until they are sent: at most 20, each for 7 days
/// from when it was saved. A full outbox refuses a new report (the tester is told) instead of
/// dropping one that was saved; expired reports are deleted with a debug log line and nothing else.
/// Between a restart and the first unlock (an app relaunched in the background) the folders can be
/// listed but not read: then nothing is deleted, counted as sendable or sent.
final class Outbox {
    static let maxItems = 20
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// A folder without its item.json is taken for one the app died writing only once it is this old.
    static let incompleteGrace: TimeInterval = 10 * 60

    enum SaveError: Error, Equatable {
        case full
        case invalid
        case storage
    }

    let directory: URL
    private let now: () -> Date
    private let protectedDataAvailable: (() -> Bool)?
    private let lock = NSLock()
    private static let log = Logger(subsystem: "no.reproo", category: "outbox")

    /// `protectedDataAvailable`: whether the items can be read now (tests); by default the probe file tells.
    init(directory: URL, now: @escaping () -> Date = Date.init, protectedDataAvailable: (() -> Bool)? = nil) {
        self.directory = directory
        self.now = now
        self.protectedDataAvailable = protectedDataAvailable
    }

    func folder(_ clientReportId: String) -> URL { directory.appendingPathComponent(clientReportId, isDirectory: true) }
    func itemURL(_ clientReportId: String) -> URL { folder(clientReportId).appendingPathComponent("item.json") }
    func screenshotURL(_ clientReportId: String) -> URL { folder(clientReportId).appendingPathComponent("screenshot.jpg") }
    /// A known file with the items' protection (hidden, so never taken for an item): it cannot be read
    /// before the first unlock after a restart, exactly like the items.
    var probeURL: URL { directory.appendingPathComponent(".protected") }

    /// Whether the items can be read now. No probe yet: nothing was saved since this SDK wrote one.
    var isReadable: Bool {
        if let protectedDataAvailable { return protectedDataAvailable() }
        if case .unreadable = ProtectedFiles.read(probeURL) { return false }
        return true
    }

    /// Saves a report. One item per id: saving the same id again (the widget saves again when its answer
    /// came late) replaces the report – what the tester wrote last, with or without the screenshot,
    /// keeping when it was first saved – as long as the platform does not have it yet; once it does,
    /// the saved one is kept. The screenshot is written first: an item.json is only ever next to its
    /// complete screenshot.
    func save(_ new: OutboxItem, screenshot: Data?) throws {
        guard OutboxItem.isValidClientReportId(new.clientReportId) else { throw SaveError.invalid }
        lock.lock()
        defer { lock.unlock() }
        guard let waiting = purge() else { throw SaveError.storage }
        guard waiting.contains(new.clientReportId) || waiting.count < Self.maxItems else { throw SaveError.full }
        var item = new
        if waiting.contains(new.clientReportId), let existing = OutboxItem(json: ProtectedFiles.readJSON(itemURL(new.clientReportId))) {
            if existing.reportId != nil { return }
            item = new.resaved(over: existing)
        }
        do {
            try ProtectedFiles.prepare(directory)
            if !FileManager.default.fileExists(atPath: probeURL.path) { try ProtectedFiles.write(Data("reproo".utf8), to: probeURL) }
            try ProtectedFiles.prepare(folder(item.clientReportId))
            if let screenshot {
                try ProtectedFiles.write(screenshot, to: screenshotURL(item.clientReportId))
            } else {
                try? FileManager.default.removeItem(at: screenshotURL(item.clientReportId))
            }
            try ProtectedFiles.write(try JSONSerialization.data(withJSONObject: item.json), to: itemURL(item.clientReportId))
        } catch {
            throw SaveError.storage
        }
    }

    /// What waits, oldest first (expired items are deleted on the way); nothing while the outbox cannot be read.
    func items() -> [OutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return (purge() ?? []).compactMap { OutboxItem(json: ProtectedFiles.readJSON(itemURL($0))) }.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// While the outbox cannot be read: the saved items there are, unread.
    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return purge()?.count ?? folders().filter { FileManager.default.fileExists(atPath: itemURL($0.lastPathComponent).path) }.count
    }

    /// Rewrites a waiting item (attempts, report id and token, screenshot sent) – not one removed meanwhile.
    /// Whether it is still there: gone, the report page's report owns it (`report-created` with its id).
    @discardableResult
    func update(_ item: OutboxItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: itemURL(item.clientReportId).path) else { return false }
        if let data = try? JSONSerialization.data(withJSONObject: item.json) { try? ProtectedFiles.write(data, to: itemURL(item.clientReportId)) }
        return true
    }

    /// Whether there was an item to remove.
    @discardableResult
    func remove(_ clientReportId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? FileManager.default.removeItem(at: folder(clientReportId))) != nil
    }

    func screenshot(_ clientReportId: String) -> Data? {
        try? Data(contentsOf: screenshotURL(clientReportId))
    }

    private func folders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
    }

    /// Ids of the items that still count – nil while the outbox cannot be read (before the first unlock
    /// after a restart), and then nothing is deleted. Expired items are deleted; a folder without its
    /// item.json (the app died while saving) once it is older than a few minutes. An item.json that is
    /// there but cannot be read is left alone; one that is no item this SDK can send is kept as long as
    /// an item would be. Under the lock.
    private func purge() -> [String]? {
        guard isReadable else { return nil }
        var ids: [String] = []
        for folder in folders() {
            let id = folder.lastPathComponent
            switch ProtectedFiles.read(itemURL(id)) {
            case .missing:
                // Half written – or being written right now by another process: only an old one goes.
                if age(of: folder) >= Self.incompleteGrace { try? FileManager.default.removeItem(at: folder) }
            case .unreadable:
                continue
            case .data(let data):
                guard let item = OutboxItem(json: try? JSONSerialization.jsonObject(with: data)) else {
                    if age(of: itemURL(id)) >= Self.maxAge { try? FileManager.default.removeItem(at: folder) }
                    continue
                }
                if now().timeIntervalSince(item.capturedAt) >= Self.maxAge {
                    try? FileManager.default.removeItem(at: folder)
                    Self.log.debug("Deleted an offline report that could not be sent within 7 days")
                    continue
                }
                ids.append(id)
            }
        }
        return ids
    }

    /// How long ago a file or folder was created (file metadata – readable before the first unlock too).
    private func age(of url: URL) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let created = values?.creationDate ?? values?.contentModificationDate else { return 0 }
        return now().timeIntervalSince(created)
    }
}

/// What a response means for something the SDK keeps until the platform has it.
enum DeliveryOutcome: Equatable {
    case delivered
    /// No answer at all (no response, a timeout): kept, and tried again soon while the device is online.
    case unanswered
    /// Kept for a later run; `after`: the platform asked to wait that long (`Retry-After`).
    case retry(after: TimeInterval?)
    /// Will never succeed: deleted.
    case rejected(status: Int)

    /// No response or a timeout, 402, 408, 425, 429 and 5xx are worth another try; any other 4xx is
    /// permanent. A 2xx only counts with the platform's JSON – a captive portal answers 200 with its own page.
    static func classify(status: Int?, retryAfter: String?, delivered json: [String: Any]?, now: Date) -> DeliveryOutcome {
        guard let status else { return .unanswered }
        switch status {
        case 200..<300:
            return json == nil ? .retry(after: nil) : .delivered
        case 429:
            return .retry(after: parseRetryAfter(retryAfter, now: now) ?? 60)
        case 402, 408, 425, 500...:
            return .retry(after: parseRetryAfter(retryAfter, now: now))
        case 400..<500:
            return .rejected(status: status)
        default:
            return .retry(after: nil)
        }
    }

    /// `Retry-After`: seconds or an HTTP date; at most a day (a wrong clock or value must not park the outbox for good).
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let seconds: TimeInterval
        if let number = Double(value) {
            seconds = number
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: value) else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        return min(max(seconds, 0), 24 * 60 * 60)
    }
}

/// Sends the outbox: one report at a time, oldest first, on launch, when the app comes to the
/// foreground and when the connection returns. For each report:
///   1. `POST /api/v1/reports` with the frozen context, the message, `clientReportId` and `offline.capturedAt`;
///   2. the report id and reporter token are stored in the item before anything else;
///   3. the screenshot is uploaded;
///   4. the item is deleted and a follow-up entry added, so the tester is asked the AI's questions later.
/// Anything worth another try ends the run (the platform said to wait, or the connection is gone):
/// the report stays and keeps its place. Retries reuse `clientReportId`, so a lost response never
/// makes a second report; a report the report page sent meanwhile (the same id) is skipped before each
/// step. A run that reaches the background finishes in a background task. When the platform asked to
/// wait (`Retry-After` on a 429, or on a 5xx such as `503 project_not_ready`), nothing is sent before
/// that time, and another run follows when it is over, as long as the process lives. A run that got no
/// answer at all while the device is online (a poor connection, a network that lets nothing through,
/// the platform unreachable) is followed by another one – after 30 s, doubling up to 10 minutes, as
/// long as the process lives; any answer starts that count again. Nothing is read or sent before the
/// first unlock after a restart.
final class OutboxSender {
    typealias BackgroundTask = (_ name: String, _ expiration: @escaping () -> Void) -> () -> Void
    /// Runs `work` after `delay` seconds (tests run it by hand).
    typealias Schedule = (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

    static let after: Schedule = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private let outbox: Outbox
    private let followUps: FollowUpStore
    private let session: URLSession
    private let now: () -> Date
    private let backgroundTask: BackgroundTask
    private let isOnline: () -> Bool
    private let schedule: Schedule
    private let afterRun: () -> Void
    private let queue = DispatchQueue(label: "no.reproo.outbox", qos: .utility)
    private var running = false
    private var runAgain = false
    private var completions: [() -> Void] = []
    private var currentTask: URLSessionTask?
    private var cancelled = false
    /// The platform asked to wait (429 / Retry-After): no run before then.
    private var pausedUntil: Date?
    /// This run ended because a request got no answer at all.
    private var unanswered = false
    /// The pause after a run without an answer.
    private var retryBackoff = RecheckBackoff()
    /// The next run this process plans by itself: when the platform's pause ends, or after a run without an answer.
    private var retry: DispatchWorkItem?

    /// `afterRun` runs once nothing is being sent any more (the app's follow-up questions may be due).
    init(outbox: Outbox, followUps: FollowUpStore, session: URLSession, now: @escaping () -> Date = Date.init, backgroundTask: @escaping BackgroundTask = ApplicationBackgroundTask.begin,
         isOnline: @escaping () -> Bool = { !ConnectivityMonitor.shared.isOffline }, schedule: @escaping Schedule = OutboxSender.after, afterRun: @escaping () -> Void = {}) {
        self.outbox = outbox
        self.followUps = followUps
        self.session = session
        self.now = now
        self.backgroundTask = backgroundTask
        self.isOnline = isOnline
        self.schedule = schedule
        self.afterRun = afterRun
    }

    /// Until when the platform asked to wait (tests).
    var pause: Date? { queue.sync { pausedUntil } }

    /// Whether a run is under way (tests).
    var isRunning: Bool { queue.sync { running } }

    /// Sends what waits. A call during a run asks for one more run afterwards (the connection may have
    /// just returned). `completion` runs on the sender's queue once nothing is being sent.
    func run(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if let completion { completions.append(completion) }
            guard !running else {
                runAgain = true
                return
            }
            start()
        }
    }

    /// On the queue.
    private func start() {
        unanswered = false
        cancelled = false
        if let pausedUntil, now() < pausedUntil {
            finish()
            return
        }
        // Before the first unlock after a restart nothing can be read: the next trigger sends it.
        guard outbox.isReadable else {
            finish()
            return
        }
        running = true
        let end = backgroundTask("reproo: send saved reports") { [weak self] in
            // Out of background time: stop what is under way; the report stays and goes next time.
            self?.queue.async {
                self?.cancelled = true
                self?.currentTask?.cancel()
            }
        }
        var remaining = outbox.items()
        func next() {
            guard !cancelled, !remaining.isEmpty else {
                end()
                running = false
                if runAgain && !cancelled {
                    runAgain = false
                    start()
                } else {
                    runAgain = false
                    finish()
                }
                return
            }
            send(remaining.removeFirst()) { carryOn in
                if !carryOn { remaining.removeAll() }
                next()
            }
        }
        next()
    }

    private func finish() {
        planRetry()
        afterRun()
        let completions = self.completions
        self.completions = []
        completions.forEach { $0() }
    }

    /// The run that follows this one by itself, if any – it replaces one planned earlier. On the queue.
    /// - The platform asked to wait (`Retry-After`): another run when the pause ends – also after a run
    ///   during the pause, which sent nothing. Offline by then, the connection's return sends it.
    /// - A run without any answer while online: another run soon. Offline, the connection's return
    ///   sends it; out of background time, the next foreground does.
    /// Any answer (or nothing left to send) starts the count of runs without an answer again.
    private func planRetry() {
        retry?.cancel()
        retry = nil
        let pauseLeft = pausedUntil.map { $0.timeIntervalSince(now()) } ?? 0
        if pauseLeft > 0 {
            retryBackoff.reset()
            plan(after: pauseLeft)
            return
        }
        guard unanswered else {
            retryBackoff.reset()
            return
        }
        guard !cancelled, isOnline() else { return }
        plan(after: retryBackoff.next())
    }

    /// A run after `delay` seconds while the process lives – only while the device is online.
    private func plan(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOnline() else { return }
            self.run()
        }
        retry = work
        schedule(delay, work)
    }

    /// One item through steps 1–4. `done(true)`: on to the next item; `done(false)`: end the run. An item
    /// gone meanwhile – sent from the report page after all (`report-created` with its id), while this run
    /// was under way – is skipped before each step: created again, the platform's replay would issue a
    /// new reporter token, and the page's would no longer work.
    private func send(_ original: OutboxItem, done: @escaping (Bool) -> Void) {
        var item = original
        guard item.reportId == nil else {
            guard outbox.update(item) else {
                done(true)
                return
            }
            uploadScreenshot(item, done: done)
            return
        }
        item.attempts += 1
        item.lastAttemptAt = now()
        guard outbox.update(item) else {
            done(true)
            return
        }
        perform(createRequest(item)) { [self] outcome, json in
            switch outcome {
            case .delivered:
                let report = json?["report"] as? [String: Any]
                guard let reportId = report?["id"] as? String else {
                    // Stored without an id to follow up on (should not happen): nothing more to do.
                    outbox.remove(item.clientReportId)
                    done(true)
                    return
                }
                item.reportId = reportId
                item.reporterToken = json?["reporterToken"] as? String
                // Gone while it was being created: the page's report – no screenshot or follow-up of its own.
                guard outbox.update(item) else {
                    done(true)
                    return
                }
                uploadScreenshot(item, done: done)
            case .unanswered:
                unanswered = true
                done(false)
            case .retry(let after):
                if let after { pausedUntil = now().addingTimeInterval(after) }
                done(false)
            case .rejected:
                outbox.remove(item.clientReportId)
                done(true)
            }
        }
    }

    private func uploadScreenshot(_ original: OutboxItem, done: @escaping (Bool) -> Void) {
        var item = original
        guard !item.screenshotUploaded, let token = item.reporterToken, let reportId = item.reportId,
              let screenshot = outbox.screenshot(item.clientReportId) else {
            complete(item)
            done(true)
            return
        }
        perform(Self.attachmentRequest(host: item.host, reportId: reportId, reporterToken: token, jpeg: screenshot)) { [self] outcome, _ in
            switch outcome {
            case .delivered:
                item.screenshotUploaded = true
                outbox.update(item)
                complete(item)
                done(true)
            case .unanswered:
                unanswered = true
                done(false)
            case .retry(let after):
                if let after { pausedUntil = now().addingTimeInterval(after) }
                done(false)
            case .rejected:
                // The report is there; a screenshot the platform refuses (too large, the report gone) is given up.
                complete(item)
                done(true)
            }
        }
    }

    /// Step 4: the report has arrived – the tester may get the AI's questions later. An item gone
    /// meanwhile was sent from the report page after all (the same id): that conversation is the page's.
    private func complete(_ item: OutboxItem) {
        guard outbox.remove(item.clientReportId), let reportId = item.reportId, let token = item.reporterToken else { return }
        followUps.add(FollowUp(reportId: reportId, reporterToken: token, kind: .offline, capturedAt: item.capturedAt, snippet: item.snippet, host: item.host, projectKey: item.projectKey, createdAt: now()))
    }

    private func createRequest(_ item: OutboxItem) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: item.requestBody) else { return nil }
        var request = URLRequest(url: item.host.appendingPathComponent("api/v1/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(item.projectKey, forHTTPHeaderField: "x-reproo-project-key")
        request.setValue("ios/\(Reproo.sdkVersion)", forHTTPHeaderField: "x-reproo-sdk")
        request.httpBody = body
        return request
    }

    /// `POST /api/v1/reports/{id}/attachments`, multipart `file` + `kind=screenshot`.
    static func attachmentRequest(host: URL, reportId: String, reporterToken: String, jpeg: Data) -> URLRequest {
        let boundary = "reproo-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nscreenshot\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"app-screen.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: host.appendingPathComponent("api/v1/reports").appendingPathComponent(reportId).appendingPathComponent("attachments"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterToken, forHTTPHeaderField: "x-reproo-reporter-token")
        request.setValue("ios/\(Reproo.sdkVersion)", forHTTPHeaderField: "x-reproo-sdk")
        request.httpBody = body
        return request
    }

    /// Runs a request and hands its outcome back on the queue. A request that cannot be built is permanent.
    private func perform(_ request: URLRequest?, completion: @escaping (DeliveryOutcome, [String: Any]?) -> Void) {
        guard let request else {
            completion(.rejected(status: 0), nil)
            return
        }
        let task = session.dataTask(with: NetworkCapture.own(request)) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let outcome = DeliveryOutcome.classify(status: http?.statusCode, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), delivered: json, now: self?.now() ?? Date())
            guard let self else { return }
            self.queue.async {
                self.currentTask = nil
                completion(outcome, json)
            }
        }
        currentTask = task
        task.resume()
    }
}

/// Lets a send that runs into the background finish (about 30 s). Begun and ended on the main
/// thread, in that order; without an application (unit tests) it does nothing.
enum ApplicationBackgroundTask {
    private final class Token {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var ended = false
    }

    static func begin(name: String, expiration: @escaping () -> Void) -> () -> Void {
        let token = Token()
        DispatchQueue.main.async {
            guard !token.ended, let application = UIApplication.sharedIfAvailable else { return }
            token.identifier = MainActor.assumeIsolated {
                application.beginBackgroundTask(withName: name) {
                    expiration()
                    end(token, application)
                }
            }
        }
        return {
            DispatchQueue.main.async {
                token.ended = true
                guard let application = UIApplication.sharedIfAvailable else { return }
                end(token, application)
            }
        }
    }

    private static func end(_ token: Token, _ application: UIApplication) {
        guard token.identifier != .invalid else { return }
        let identifier = token.identifier
        token.identifier = .invalid
        MainActor.assumeIsolated { application.endBackgroundTask(identifier) }
    }
}
#endif
