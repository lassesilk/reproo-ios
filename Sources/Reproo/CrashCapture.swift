#if canImport(UIKit)
import UIKit
import ReprooCrash

/// Crash capture: when the app crashes (a fatal signal – Swift runtime traps such as a force
/// unwrap of nil arrive as SIGTRAP – or an uncaught Objective-C exception), the C handlers write a
/// small record next to the black box. On the next launch the record and the crashed run's black
/// box become a crash report, sent to `POST /api/v1/crashes` – then, and like the outbox when the app
/// comes to the foreground or the connection returns, until the platform has it; the tester is then
/// asked what they were doing (a follow-up, see FollowUps.swift). Frames of the app's own code are
/// symbolicated on the device when the same build is running again. The tester never sees technical
/// details: the prompt and the widget only talk about "the app closed unexpectedly".
enum CrashCapture {
    private static let installLock = NSLock()
    private static var installed = false
    private static var observingApplicationState = false
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    /// Where this run's crash reports are sent from (set while installed); `fallback`: the configuration
    /// when it was installed, for a crashed run without its own.
    private static var delivery: (store: CrashStore, session: URLSession, followUps: FollowUpStore?, fallback: Configuration?)?
    /// A send is under way (on `queue`): the triggers may overlap.
    private static var sending = false

    /// Turning crashed runs into reports and sending them – never on the launching thread.
    static let queue = DispatchQueue(label: "no.reproo.crash", qos: .utility)
    /// Reports that could not be sent are retried on later launches for a week, then dropped.
    static let maxPendingAge: TimeInterval = 7 * 24 * 60 * 60
    /// A crash loop must not pile up reports: only the newest are kept.
    static let maxPendingReports = 5

    /// Dedicated session for the platform: ephemeral (no cookies or cache) and never seen by
    /// NetworkCapture, which only instruments `URLSession.shared` and opted-in configurations.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static var isInstalled: Bool {
        installLock.lock()
        defer { installLock.unlock() }
        return installed
    }

    static func install() {
        guard let store = CrashStore.standard() else { return }
        install(store: store, session: session)
    }

    static func install(store: CrashStore, session: URLSession, signalHandlers: Bool = true, followUps: FollowUpStore? = OfflineReports.shared?.followUps) {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        // A removal queued when crash capture was turned off (by the app or the project) finishes before this run's files exist.
        queue.sync {}
        guard (try? store.prepare()) != nil else { return }
        installed = true
        let configuration = State.shared.snapshot.configuration
        delivery = (store, session, followUps, configuration)

        // 1. Move the previous run's crash aside before this run writes anything.
        store.stashCrashedRun()
        // 2. This run's black box – the previous run's files are removed and this run's image list is
        //    written before a handler could record a crash that would be paired with them.
        BlackBox.shared.start(store: store)
        // 3. This run's handlers.
        if reproo_crash_open_record(store.recordURL.path) == 0 {
            if signalHandlers {
                _ = reproo_crash_install_signal_handlers()
                // The alternate signal stack is per thread: the main thread needs its own when configure() runs elsewhere.
                if !Thread.isMainThread { DispatchQueue.main.async { _ = reproo_crash_install_alternate_stack() } }
            }
            installExceptionHandler()
        }
        observeApplicationState()
        // 4. Crashed runs → reports → platform → "tell us what happened".
        deliver(store: store, session: session, followUps: followUps, fallback: configuration)
    }

    /// Sends this run's pending crash reports (the app came to the foreground, the connection returned,
    /// the device was unlocked).
    static func deliverPending() {
        installLock.lock()
        let delivery = self.delivery
        installLock.unlock()
        guard let delivery else { return }
        deliver(store: delivery.store, session: delivery.session, followUps: delivery.followUps, fallback: delivery.fallback)
    }

    /// One send at a time; the follow-ups are asked about afterwards. Crashed runs become reports first –
    /// also the ones that could not be read earlier (relaunched in the background before the first unlock
    /// after a restart), once they can.
    private static func deliver(store: CrashStore, session: URLSession, followUps: FollowUpStore?, fallback: Configuration?) {
        queue.async {
            guard !sending else { return }
            sending = true
            prepareReports(store: store, fallback: fallback)
            sendPendingReports(store: store, session: session, followUps: followUps) {
                sending = false
                FollowUpPrompt.scheduleCheck()
            }
        }
    }

    /// Restores the previous handlers, closes the record and stops the black box (crash capture turned
    /// off later in the run; tests).
    static func uninstall() {
        installLock.lock()
        defer { installLock.unlock() }
        guard installed else { return }
        reproo_crash_uninstall()
        uninstallExceptionHandler()
        BlackBox.shared.stop()
        installed = false
        delivery = nil
    }

    /// `configure(captureCrashes: false)`, or the project has crash capture turned off (CrashSetting):
    /// nothing is installed – and when it was installed earlier in this run, it is uninstalled (handlers
    /// restored, black box stopped) – and anything stored is deleted, crash follow-ups included.
    static func discardStoredData() {
        guard let store = CrashStore.standard() else { return }
        discardStoredData(store: store)
    }

    static func discardStoredData(store: CrashStore, followUps: FollowUpStore? = OfflineReports.shared?.followUps) {
        uninstall()
        queue.async {
            store.removeAll()
            followUps?.removeAll(kind: .crash)
        }
    }

    // MARK: Uncaught exceptions

    private static let uncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exception in
        CrashCapture.record(exception)
        CrashCapture.previousExceptionHandler?(exception)
    }

    /// Chains to the handler that was set before (another crash reporter), which still runs.
    static func installExceptionHandler() {
        let current = NSGetUncaughtExceptionHandler()
        if let current, unsafeBitCast(current, to: UnsafeRawPointer.self) == unsafeBitCast(uncaughtExceptionHandler, to: UnsafeRawPointer.self) { return }
        previousExceptionHandler = current
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
    }

    /// Puts the previous handler back (tests).
    static func uninstallExceptionHandler() {
        guard let current = NSGetUncaughtExceptionHandler(),
              unsafeBitCast(current, to: UnsafeRawPointer.self) == unsafeBitCast(uncaughtExceptionHandler, to: UnsafeRawPointer.self) else { return }
        NSSetUncaughtExceptionHandler(previousExceptionHandler)
        previousExceptionHandler = nil
    }

    /// Runs inside the uncaught exception handler (not a signal handler): Foundation is fine here,
    /// but State's lock is not – the exception may have been raised while it was held. The reason is
    /// scrubbed before it reaches the disk (Redaction uses no State lock).
    static func record(_ exception: NSException) {
        let name = exception.name.rawValue
        let reason = Redaction.clip(Redaction.scrub(exception.reason ?? ""), 2000)
        let addresses = exception.callStackReturnAddresses.map(\.uintValue)
        name.withCString { name in
            reason.withCString { reason in
                addresses.withUnsafeBufferPointer { buffer in
                    _ = reproo_crash_record_exception(name, reason, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
    }

    private static func observeApplicationState() {
        guard !observingApplicationState else { return }
        observingApplicationState = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in reproo_crash_set_foreground(0) }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in reproo_crash_set_foreground(1) }
        }
        DispatchQueue.main.async {
            // Background launches (push, background fetch) start outside the foreground.
            if let application = UIApplication.sharedIfAvailable {
                reproo_crash_set_foreground(application.applicationState == .background ? 0 : 1)
            }
        }
    }

    // MARK: Next launch

    /// Turns stashed crashed runs into pending reports (one JSON file each, sent until accepted). A run
    /// whose files cannot be read now (before the first unlock after a restart) is kept as it is – never
    /// taken for a broken one – and becomes a report at a later delivery.
    static func prepareReports(store: CrashStore, fallback: Configuration?, symbolicator: Symbolicator = Symbolicator(), now: Date = Date()) {
        let runs = store.crashedRuns()
        if !runs.isEmpty {
            for run in runs {
                guard store.canRead(run: run) else { continue }
                guard let report = CrashReportBuilder.report(fromRun: run, fallback: fallback, symbolicator: symbolicator, now: now) else {
                    store.remove(run)
                    continue
                }
                do {
                    try store.write(report.json, to: store.pendingDirectory.appendingPathComponent("\(report.clientReportId).json"))
                    store.remove(run)
                } catch {
                    // Kept for the next launch.
                }
            }
        }
        for url in store.pendingReports().dropLast(maxPendingReports) { store.remove(url) }
    }

    /// Sends pending reports one after another. 2xx → the report is deleted, and a follow-up stored
    /// when the report still waits for the tester; a rejected report (bad request, unknown key, crash
    /// reporting turned off) is deleted; network errors, 402, 429 and 5xx keep it for a later try. A
    /// report that cannot be read now (before the first unlock after a restart) is skipped, never deleted.
    static func sendPendingReports(store: CrashStore, session: URLSession, followUps: FollowUpStore?, now: Date = Date(), completion: @escaping () -> Void) {
        var remaining = store.pendingReports()
        func next() {
            guard !remaining.isEmpty else {
                completion()
                return
            }
            let url = remaining.removeFirst()
            let contents = ProtectedFiles.read(url)
            if case .unreadable = contents {
                next()
                return
            }
            guard case .data(let data) = contents, let report = PendingCrashReport(json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]),
                  now.timeIntervalSince(report.createdAt) < maxPendingAge else {
                store.remove(url)
                next()
                return
            }
            CrashUploader.send(report, session: session) { outcome in
                queue.async {
                    switch outcome {
                    case .accepted(let followUp):
                        // Not when crash capture was turned off meanwhile: its removal (on this queue) took the report.
                        if FileManager.default.fileExists(atPath: url.path) { followUps?.add(followUp) }
                        store.remove(url)
                    case .acceptedWithoutPrompt, .rejected:
                        store.remove(url)
                    case .retryLater:
                        break
                    }
                    next()
                }
            }
        }
        next()
    }
}

// MARK: - Project setting

/// The project's «Capture crashes automatically» setting, as the platform last reported it: the start
/// signal's answer (GET /api/v1/project) carries `crashReporting.enabled`. configure() has to decide
/// before that answer arrives, so the last answer is kept per platform and project key. Turned off:
/// everything stored is deleted and recording stops for the rest of the run, and later launches record
/// nothing until an answer says it is on again. Not known yet (first launch, no answer, a platform that
/// does not send it): `captureCrashes` alone decides. The platform re-checks every crash report anyway.
enum CrashSetting {
    /// The last answer for this platform and project key; nil before the first.
    static func cached(host: URL, projectKey: String, defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: key(host: host, projectKey: projectKey)) as? Bool
    }

    /// `crashReporting.enabled` of a successful answer; nil when there is nothing to go by (offline, an
    /// error, an unknown key, a platform that does not send it) – then what was known stays.
    static func enabled(status: Int?, data: Data?) -> Bool? {
        guard let status, (200..<300).contains(status),
              let json = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else { return nil }
        return (json["crashReporting"] as? [String: Any])?["enabled"] as? Bool
    }

    static func received(_ enabled: Bool, host: URL, projectKey: String) {
        received(enabled, host: host, projectKey: projectKey, defaults: .standard, store: CrashStore.standard(), session: CrashCapture.session)
    }

    /// Keeps the answer and applies it to this run – unless the app has been reconfigured since the
    /// signal was sent (another platform or project key, or crash capture turned off by the app).
    static func received(_ enabled: Bool, host: URL, projectKey: String, defaults: UserDefaults, store: CrashStore?, session: URLSession, signalHandlers: Bool = true, followUps: FollowUpStore? = OfflineReports.shared?.followUps) {
        defaults.set(enabled, forKey: key(host: host, projectKey: projectKey))
        guard let configuration = State.shared.snapshot.configuration, configuration.captureCrashes,
              key(host: configuration.host, projectKey: configuration.projectKey) == key(host: host, projectKey: projectKey),
              let store else { return }
        if enabled {
            // Turned on again while this run recorded nothing: from now on (nothing changes when it already records).
            CrashCapture.install(store: store, session: session, signalHandlers: signalHandlers, followUps: followUps)
        } else {
            CrashCapture.discardStoredData(store: store, followUps: followUps)
        }
    }

    /// The platform's origin and the project key: one app may report to more than one project. The
    /// UserDefaults key keeps the SDK's former name, so an updated app remembers the last answer.
    static func key(host: URL, projectKey: String) -> String {
        "ai.uatai.crashReporting|\(ReportViewController.origin(of: host))|\(projectKey)"
    }
}

// MARK: - Crash record

/// The record written by the C handlers (format: ReprooCrash.h).
struct CrashRecord: Equatable {
    enum Kind: String {
        case signal, exception
    }

    var type: Kind
    var signal: Int32?
    var exceptionName: String?
    var reason: String?
    /// Swift runtime message, e.g. "MyApp/CheckoutForm.swift:24: Fatal error: Unexpectedly found nil …".
    var message: String?
    var message2: String?
    var crashedAt: Date?
    var inForeground: Bool?
    /// The crashing instruction (signal crashes).
    var pc: UInt?
    /// arm64 link register at the crash.
    var lr: UInt?
    /// Return addresses of the crashed thread, innermost first.
    var returnAddresses: [UInt]

    /// Lenient: a record cut short by the dying process still yields what was written.
    init?(_ text: String) {
        var type: Kind?
        var signal: Int32?
        var exceptionName: String?
        var reason: String?
        var message: String?
        var message2: String?
        var crashedAt: Date?
        var inForeground: Bool?
        var pc: UInt?
        var lr: UInt?
        var returnAddresses: [UInt] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch parts[0] {
            case "type": type = Kind(rawValue: value)
            case "signal": signal = Int32(value)
            case "exception_name": exceptionName = value.isEmpty ? nil : value
            case "reason": reason = value.isEmpty ? nil : value
            case "message": message = value.isEmpty ? nil : value
            case "message2": message2 = value.isEmpty ? nil : value
            case "time": crashedAt = Double(value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            case "foreground": inForeground = value == "1"
            case "pc": pc = parseHex(value)
            case "lr": lr = parseHex(value)
            case "frame": if let address = parseHex(value) { returnAddresses.append(address) }
            default: break
            }
        }
        guard let type else { return nil }
        self.type = type
        self.signal = signal
        self.exceptionName = exceptionName
        self.reason = reason
        self.message = message
        self.message2 = message2
        self.crashedAt = crashedAt
        self.inForeground = inForeground
        self.pc = pc
        self.lr = lr
        self.returnAddresses = returnAddresses
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS: return "SIGSYS"
        default: return "SIG\(signal)"
        }
    }
}

// MARK: - Report

/// One frame as sent (protocol `CrashFrame`).
struct CrashFrame: Equatable {
    let address: UInt
    let image: String?
    let offset: UInt?
    let symbol: String?
    let inApp: Bool

    var json: [String: Any] {
        var json: [String: Any] = ["address": hex(address), "inApp": inApp]
        if let image { json["image"] = image }
        if let offset { json["offset"] = hex(offset) }
        if let symbol { json["symbol"] = symbol }
        return json
    }
}

/// A crash report waiting to be sent: the request body plus where it goes (the crashed run's
/// platform and project key – the app may have been reconfigured since).
struct PendingCrashReport {
    let clientReportId: String
    let createdAt: Date
    let host: URL
    let projectKey: String
    /// `CreateCrashReportRequest`: {context, crash, clientReportId}.
    let body: [String: Any]

    init(clientReportId: String, createdAt: Date, host: URL, projectKey: String, body: [String: Any]) {
        self.clientReportId = clientReportId
        self.createdAt = createdAt
        self.host = host
        self.projectKey = projectKey
        self.body = body
    }

    init?(json: [String: Any]?) {
        guard let json,
              let clientReportId = json["clientReportId"] as? String,
              let createdAt = (json["createdAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)),
              let host = (json["host"] as? String).flatMap(URL.init(string:)),
              let projectKey = json["projectKey"] as? String,
              let body = json["body"] as? [String: Any] else { return nil }
        self.init(clientReportId: clientReportId, createdAt: createdAt, host: host, projectKey: projectKey, body: body)
    }

    var json: [String: Any] {
        [
            "version": 1,
            "clientReportId": clientReportId,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "host": host.absoluteString,
            "projectKey": projectKey,
            "body": body,
        ]
    }
}

enum CrashReportBuilder {
    /// A crashed run (record + black box + images) → pending report. Nil when the record is unreadable.
    static func report(fromRun run: URL, fallback: Configuration?, symbolicator: Symbolicator, now: Date = Date()) -> PendingCrashReport? {
        guard let data = try? Data(contentsOf: run.appendingPathComponent("crash.record")),
              let record = CrashRecord(String(decoding: data, as: UTF8.self)) else { return nil }
        let blackBox = readJSON(run.appendingPathComponent("blackbox.json"))
        let imagesDocument = readJSON(run.appendingPathComponent("images.json"))
        guard let host = (blackBox?["host"] as? String).flatMap(URL.init(string:)) ?? fallback?.host,
              let projectKey = blackBox?["projectKey"] as? String ?? fallback?.projectKey else { return nil }

        // The id stashCrashedRun gave the run: processing the same run again (the app died before the
        // run was removed) yields the same report, which the platform recognises as a retry.
        let clientReportId = run.lastPathComponent
        let crash = crashPayload(
            record: record,
            images: BinaryImages.images(from: imagesDocument),
            arch: imagesDocument?["arch"] as? String ?? BinaryImages.architecture,
            launchedAt: blackBox?["launchedAt"] as? String,
            symbolicator: symbolicator
        )
        // What happened after the black box was last rewritten – often the action that crashed the app.
        let journal = Journal.events(try? Data(contentsOf: run.appendingPathComponent("journal.jsonl")), after: (blackBox?["journalSeq"] as? NSNumber)?.uint64Value ?? 0)
        let context = Journal.apply(journal, to: blackBox?["context"] as? [String: Any] ?? minimalContext(fallback))
        return PendingCrashReport(
            clientReportId: clientReportId,
            createdAt: now,
            host: host,
            projectKey: projectKey,
            body: ["context": context, "crash": crash, "clientReportId": clientReportId]
        )
    }

    static func crashPayload(record: CrashRecord, images: [BinaryImage], arch: String, launchedAt: String?, symbolicator: Symbolicator) -> [String: Any] {
        let frames = self.frames(record: record, images: images, symbolicator: symbolicator)
        var crash: [String: Any] = [
            "type": record.type.rawValue,
            "frames": frames.map(\.json),
            "binaryImages": binaryImages(images, frames: frames, arch: arch),
            "symbolication": symbolication(frames),
        ]
        if record.type == .signal, let signal = record.signal { crash["signal"] = CrashRecord.signalName(signal) }
        if let exceptionName = record.exceptionName { crash["exceptionName"] = exceptionName }
        if let reason = reason(record) { crash["reason"] = reason }
        if let crashedAt = record.crashedAt { crash["crashedAt"] = ISO8601DateFormatter().string(from: crashedAt) }
        if let launchedAt { crash["launchedAt"] = launchedAt }
        if let inForeground = record.inForeground { crash["inForeground"] = inForeground }
        return crash
    }

    /// Exception reason or the Swift runtime message, scrubbed like log messages.
    static func reason(_ record: CrashRecord) -> String? {
        let raw: String
        switch record.type {
        case .exception: raw = record.reason ?? record.message ?? ""
        case .signal: raw = [record.message, record.message2].compactMap { $0 }.joined(separator: " ")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Redaction.clip(Redaction.scrub(trimmed), 2000)
    }

    /// Top first. Every frame gets its image and offset (the platform can symbolicate with the
    /// build's dSYM); frames of the app's own code also get a symbol when this launch runs the
    /// same build. The SDK's own code is never "in app".
    static func frames(record: CrashRecord, images: [BinaryImage], symbolicator: Symbolicator) -> [CrashFrame] {
        var entries: [(address: UInt, isReturnAddress: Bool)] = []
        if let pc = record.pc { entries.append((pc, false)) }
        if let lr = callerInLinkRegister(record) { entries.append((lr, true)) }
        entries += record.returnAddresses.map { ($0, true) }
        return entries.prefix(64).map { entry in
            let address = stripPointerAuthentication(entry.address)
            guard let image = images.first(where: { $0.contains(address) }) else {
                return CrashFrame(address: address, image: nil, offset: nil, symbol: nil, inApp: false)
            }
            let offset = address - image.loadAddress
            var symbol: String?
            if image.inApp, let uuid = image.uuid {
                symbol = symbolicator.symbol(imageUUID: uuid, offset: offset, isReturnAddress: entry.isReturnAddress)
            }
            let sdkCode = Symbolicator.isSDKImage(image.name) || symbol.map(Symbolicator.isSDKSymbol) == true
            return CrashFrame(address: address, image: image.name, offset: offset, symbol: symbol.map { Redaction.clip($0, 500) }, inApp: image.inApp && !sdkCode)
        }
    }

    /// A leaf function (one that calls nothing) has no frame record of its own, so the frame-pointer
    /// walk skips its caller – which is still in the link register. Otherwise the link register
    /// points back into the crashing function (or repeats the first return address) and is left out.
    static func callerInLinkRegister(_ record: CrashRecord) -> UInt? {
        guard let pc = record.pc.map(stripPointerAuthentication), let raw = record.lr else { return nil }
        let lr = stripPointerAuthentication(raw)
        let distance = lr > pc ? lr - pc : pc - lr
        guard lr != 0, distance > 4096, lr != record.returnAddresses.first.map(stripPointerAuthentication) else { return nil }
        return lr
    }

    static func symbolication(_ frames: [CrashFrame]) -> String {
        let appFrames = frames.filter(\.inApp)
        let resolved = appFrames.filter { $0.symbol != nil }.count
        if resolved == 0 { return "none" }
        return resolved == appFrames.count ? "symbolicated" : "partial"
    }

    /// The app's images first, then the system images the frames point into (at most 50).
    static func binaryImages(_ images: [BinaryImage], frames: [CrashFrame], arch: String) -> [[String: Any]] {
        let referenced = Set(frames.compactMap(\.image))
        let chosen = images.filter(\.inApp) + images.filter { !$0.inApp && referenced.contains($0.name) }
        return chosen.prefix(50).map { image in
            var json: [String: Any] = ["name": image.name, "loadAddress": hex(image.loadAddress), "arch": arch]
            if let uuid = image.uuid { json["uuid"] = uuid }
            return json
        }
    }

    /// Without a black box (the app crashed before it was first written) the report still gets
    /// through – without the crashed run's release, screen and activity.
    static func minimalContext(_ fallback: Configuration?) -> [String: Any] {
        var context: [String: Any] = [
            "sdk": ["name": "reproo-ios", "version": Reproo.sdkVersion],
            "platform": "ios",
            "sessionId": UUID().uuidString,
            "locale": ContextCollector.preferredLocale(),
            "timezone": TimeZone.current.identifier,
        ]
        if let environment = fallback?.environment { context["environment"] = environment }
        // The bundle identifier is the same in every run: which app crashed is known even without the black box.
        if let appId = fallback?.appId { context["app"] = ["id": appId] }
        return context
    }

    /// arm64e return addresses may carry a pointer-authentication signature in the high bits.
    static func stripPointerAuthentication(_ address: UInt) -> UInt {
        address >> 47 == 0 ? address : address & 0x0000_000F_FFFF_FFFF
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Symbolication

/// Resolves frames of the app's own code on the device: when an image with the crashed image's
/// UUID is loaded again (same build), `dladdr(load address now + offset)` gives the mangled
/// symbol, which `swift_demangle` turns into "MyApp.CheckoutForm.init(cart: …)".
/// No file or line: that needs the build's dSYM.
final class Symbolicator {
    private let currentImages: () -> [BinaryImage]
    private lazy var loadAddressByUUID: [String: UInt] = {
        var map: [String: UInt] = [:]
        for image in currentImages() {
            if let uuid = image.uuid { map[uuid] = image.loadAddress }
        }
        return map
    }()

    /// Default: the app's own images loaded now.
    init(currentImages: @escaping () -> [BinaryImage] = { BinaryImages.loaded().filter(\.inApp) }) {
        self.currentImages = currentImages
    }

    func symbol(imageUUID: String, offset: UInt, isReturnAddress: Bool) -> String? {
        guard let loadAddress = loadAddressByUUID[imageUUID] else { return nil }
        // A return address points after the call; the call may be the function's last instruction
        // (calls to `fatalError` and friends never return), so look up the byte before it.
        let address = loadAddress + offset - (isReturnAddress && offset > 0 ? 1 : 0)
        return Self.symbol(at: address)
    }

    static func symbol(at address: UInt) -> String? {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let cName = info.dli_sname else { return nil }
        let name = String(cString: cName)
        if name.hasSuffix("mh_execute_header") || name.hasSuffix("mh_dylib_header") { return nil }
        // Far from the nearest symbol: a stripped binary, where the name would be misleading.
        if let start = info.dli_saddr, address &- UInt(bitPattern: start) > 0x40000 { return nil }
        return demangle(name) ?? name
    }

    private typealias SwiftDemangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: SwiftDemangle? = {
        guard let function = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(function, to: SwiftDemangle.self)
    }()

    static func demangle(_ name: String) -> String? {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_T"), let swiftDemangle else { return nil }
        return name.withCString { cName -> String? in
            guard let demangled = swiftDemangle(cName, strlen(cName), nil, nil, 0) else { return nil }
            defer { free(demangled) }
            return String(cString: demangled)
        }
    }

    private static let symbolPrefixes = try! NSRegularExpression(
        pattern: "^(?:specialized |merged |@objc |static |dynamic |partial apply for |(?:implicit )?closure #\\d+ .*? in |reabstraction thunk helper .*? from |outlined (?:copy|consume|destroy|init with take) of )"
    )

    /// The SDK's Swift module – also under its former name: a crash recorded by an older build of the
    /// app is sent by the updated one, with that build's images.
    static let sdkModules = ["Reproo", "UATAI"]
    /// Prefixes of the C handlers' functions (ReprooCrash), current and former.
    static let sdkCFunctionPrefixes = ["reproo_", "uatai_"]

    /// The SDK linked as its own image (a dynamic framework).
    static func isSDKImage(_ name: String) -> Bool {
        sdkModules.contains(name)
    }

    /// The SDK's own code (statically linked into the app): "Reproo.…", closures in it, the C handlers.
    static func isSDKSymbol(_ symbol: String) -> Bool {
        if sdkCFunctionPrefixes.contains(where: symbol.hasPrefix) { return true }
        // Mangled: "$s6Reproo…" – the length prefix keeps "ReprooTests" ("$s11ReprooTests") apart.
        for module in sdkModules {
            let mangled = "$s\(module.utf8.count)\(module)"
            if symbol.hasPrefix(mangled) || symbol.hasPrefix("_" + mangled) { return true }
        }
        var value = symbol
        for _ in 0..<10 {
            let stripped = symbolPrefixes.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            if stripped == value { break }
            value = stripped
        }
        return sdkModules.contains { value.hasPrefix("\($0).") }
    }
}

// MARK: - Upload

/// `prompt.json` of SDKs before 0.7: report id + reporter token of a sent crash, until the tester was
/// asked. Read once to move it into the follow-ups (FollowUpStore.migrateLegacyPrompt).
struct PendingPrompt: Equatable {
    let reportId: String
    let reporterToken: String
    let host: URL
    let projectKey: String
    let createdAt: Date

    init(reportId: String, reporterToken: String, host: URL, projectKey: String, createdAt: Date) {
        self.reportId = reportId
        self.reporterToken = reporterToken
        self.host = host
        self.projectKey = projectKey
        self.createdAt = createdAt
    }

    init?(json: [String: Any]?) {
        guard let json,
              let reportId = json["reportId"] as? String,
              let reporterToken = json["reporterToken"] as? String,
              let host = (json["host"] as? String).flatMap(URL.init(string:)),
              let projectKey = json["projectKey"] as? String,
              let createdAt = (json["createdAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)) else { return nil }
        self.init(reportId: reportId, reporterToken: reporterToken, host: host, projectKey: projectKey, createdAt: createdAt)
    }

    var json: [String: Any] {
        [
            "reportId": reportId,
            "reporterToken": reporterToken,
            "host": host.absoluteString,
            "projectKey": projectKey,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
        ]
    }
}

enum CrashUploadOutcome: Equatable {
    /// Stored, and the report waits for the tester: ask.
    case accepted(FollowUp)
    /// Stored, but there is nothing to ask (past the fair-use limit, a retry of a finished report).
    case acceptedWithoutPrompt
    /// Will never succeed (bad request, unknown or revoked key, crash reporting turned off).
    case rejected(status: Int)
    /// Offline, rate limited or a server error: try again on a later launch.
    case retryLater
}

enum CrashUploader {
    static func send(_ report: PendingCrashReport, session: URLSession, now: @escaping () -> Date = Date.init, completion: @escaping (CrashUploadOutcome) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: report.body) else {
            completion(.rejected(status: 0))
            return
        }
        var request = URLRequest(url: report.host.appendingPathComponent("api/v1/crashes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(report.projectKey, forHTTPHeaderField: "x-reproo-project-key")
        request.httpBody = body
        session.dataTask(with: NetworkCapture.own(request)) { data, response, _ in
            completion(outcome(status: (response as? HTTPURLResponse)?.statusCode, data: data, report: report, now: now()))
        }.resume()
    }

    static func outcome(status: Int?, data: Data?, report: PendingCrashReport, now: Date) -> CrashUploadOutcome {
        guard let status else { return .retryLater }
        switch status {
        case 200..<300:
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let response = json?["report"] as? [String: Any]
            // Only a report that still takes the tester's words is worth asking about.
            guard let reportId = response?["id"] as? String,
                  let token = json?["reporterToken"] as? String,
                  response?["acceptsMessages"] as? Bool == true else { return .acceptedWithoutPrompt }
            // The question names the crash's time when it lies back (sent days later, after a time offline).
            let crashedAt = ((report.body["crash"] as? [String: Any])?["crashedAt"] as? String).flatMap(ISO8601DateFormatter().date(from:))
            return .accepted(FollowUp(reportId: reportId, reporterToken: token, kind: .crash, capturedAt: crashedAt ?? report.createdAt, snippet: nil, host: report.host, projectKey: report.projectKey, createdAt: now))
        case 402, 408, 425, 429, 500...:
            return .retryLater
        default:
            // 400 validation_failed, 401 missing/invalid/revoked key, 403 crash_reporting_disabled, 404, 410 …
            return .rejected(status: status)
        }
    }
}

// MARK: - Prompt

/// «Appen ble avsluttet uventet» – nb for Norwegian devices (nb/nn/no, like the widget), else English.
struct CrashPromptStrings: Equatable {
    let title: String
    let message: String
    let tell: String
    let decline: String

    static let norwegian = CrashPromptStrings(
        title: "Appen ble avsluttet uventet",
        message: "Vil du fortelle hva du gjorde rett før? Det hjelper utviklerne å rette feilen.",
        tell: "Fortell hva som skjedde",
        decline: "Nei takk"
    )

    static let english = CrashPromptStrings(
        title: "The app closed unexpectedly",
        message: "Would you like to tell us what you were doing just before? It helps the developers fix it.",
        tell: "Tell us what happened",
        decline: "No thanks"
    )

    static func forLocale(_ locale: String) -> CrashPromptStrings {
        let value = locale.lowercased()
        return value.hasPrefix("nb") || value.hasPrefix("no") || value.hasPrefix("nn") ? .norwegian : .english
    }
}

#endif
