#if canImport(UIKit)
import UIKit

/// A report the platform has, whose tester may still be asked the AI's questions: a report sent from
/// the outbox, or a crash. Kept until the tester was asked (and the page opened), said no (and the
/// platform heard it), or the report is finished (or gone) – while the agent still investigates it
/// stays, as its questions may come.
struct FollowUp: Equatable {
    enum Kind: String {
        case offline, crash
    }

    static let maxEntries = 20
    /// The reporter token is valid for 7 days from when it was issued.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    let reportId: String
    let reporterToken: String
    let kind: Kind
    /// When the problem happened: saved offline, or the crash.
    let capturedAt: Date
    /// The tester's first words (offline reports), to recognise the problem in the question.
    let snippet: String?
    /// «Nei takk»: never asked again; kept until the platform has heard `finish_now`.
    var declined: Bool
    /// Where the report lives (the platform and project key it was sent to).
    let host: URL
    let projectKey: String
    /// When the entry was stored – the token's age.
    let createdAt: Date

    init(reportId: String, reporterToken: String, kind: Kind, capturedAt: Date, snippet: String?, declined: Bool = false, host: URL, projectKey: String, createdAt: Date) {
        self.reportId = reportId
        self.reporterToken = reporterToken
        self.kind = kind
        self.capturedAt = capturedAt
        self.snippet = snippet
        self.declined = declined
        self.host = host
        self.projectKey = projectKey
        self.createdAt = createdAt
    }

    init?(json: Any?) {
        let iso = ISO8601DateFormatter()
        guard let json = json as? [String: Any],
              let reportId = json["reportId"] as? String,
              let reporterToken = json["reporterToken"] as? String,
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let capturedAt = (json["capturedAt"] as? String).flatMap(iso.date(from:)),
              let host = (json["host"] as? String).flatMap(URL.init(string:)),
              let projectKey = json["projectKey"] as? String else { return nil }
        let createdAt = (json["createdAt"] as? String).flatMap(iso.date(from:)) ?? capturedAt
        self.init(reportId: reportId, reporterToken: reporterToken, kind: kind, capturedAt: capturedAt, snippet: json["snippet"] as? String,
                  declined: json["declined"] as? Bool ?? false, host: host, projectKey: projectKey, createdAt: createdAt)
    }

    var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "reportId": reportId,
            "reporterToken": reporterToken,
            "kind": kind.rawValue,
            "capturedAt": iso.string(from: capturedAt),
            "snippet": snippet as Any? ?? NSNull(),
            "declined": declined,
            "host": host.absoluteString,
            "projectKey": projectKey,
            "createdAt": iso.string(from: createdAt),
        ]
    }
}

/// `followups.json` – one list for offline reports and crashes (it replaces the crash prompt's single
/// `prompt.json`): at most 20 entries, each for 7 days. Reporter tokens are secrets: the file is
/// app-private, protected and never backed up.
final class FollowUpStore {
    let url: URL
    private let now: () -> Date
    private let lock = NSLock()

    init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// Waiting entries, oldest first; expired ones are dropped on the way.
    func entries() -> [FollowUp] {
        lock.lock()
        defer { lock.unlock() }
        guard let all = read() else { return [] }
        let current = all.filter { now().timeIntervalSince($0.createdAt) < FollowUp.maxAge }
        if current.count != all.count { write(current) }
        return current
    }

    /// Adds an entry, or replaces the one for the same report. The oldest go when there are more than 20.
    /// Whether it was written.
    @discardableResult
    func add(_ entry: FollowUp) -> Bool {
        change { entries in
            entries.removeAll { $0.reportId == entry.reportId }
            entries.append(entry)
        }
    }

    func remove(reportId: String) {
        change { $0.removeAll { $0.reportId == reportId } }
    }

    func markDeclined(reportId: String) {
        change { entries in
            for index in entries.indices where entries[index].reportId == reportId { entries[index].declined = true }
        }
    }

    /// Crash capture turned off: its follow-ups go with everything else it stored.
    func removeAll(kind: FollowUp.Kind) {
        change { $0.removeAll { $0.kind == kind } }
    }

    /// An unasked crash prompt of an SDK before 0.7 (`ai.uatai/prompt.json`) becomes a crash entry, so
    /// an updated app still asks about it – or drops it, if the platform has finished the report since.
    /// The file goes once its entry is written (or when there is nothing in it to ask about): before the
    /// first unlock after a restart it cannot be read, and it stays for a later try.
    func migrateLegacyPrompt(at legacyURL: URL) {
        guard case .data(let data) = ProtectedFiles.read(legacyURL) else { return }
        if let prompt = PendingPrompt(json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]),
           !add(FollowUp(reportId: prompt.reportId, reporterToken: prompt.reporterToken, kind: .crash, capturedAt: prompt.createdAt, snippet: nil,
                         host: prompt.host, projectKey: prompt.projectKey, createdAt: prompt.createdAt)) {
            return
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// Nothing is changed while the file is there but cannot be read (before the first unlock after a
    /// restart): writing then would replace every entry with the one change. Whether it was written.
    @discardableResult
    private func change(_ body: (inout [FollowUp]) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entries = read()?.filter({ now().timeIntervalSince($0.createdAt) < FollowUp.maxAge }) else { return false }
        body(&entries)
        entries.sort { $0.createdAt < $1.createdAt }
        if entries.count > FollowUp.maxEntries { entries.removeFirst(entries.count - FollowUp.maxEntries) }
        return write(entries)
    }

    /// nil: the file is there but cannot be read now.
    private func read() -> [FollowUp]? {
        switch ProtectedFiles.read(url) {
        case .missing:
            return []
        case .unreadable:
            return nil
        case .data(let data):
            return ((try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []).compactMap(FollowUp.init(json:)).sorted { $0.createdAt < $1.createdAt }
        }
    }

    @discardableResult
    private func write(_ entries: [FollowUp]) -> Bool {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries.map(\.json)) else { return false }
        try? ProtectedFiles.prepare(url.deletingLastPathComponent())
        return (try? ProtectedFiles.write(data, to: url)) != nil
    }
}

/// The platform's side of a follow-up: is there anything to ask, and «Nei takk».
enum FollowUpClient {
    enum Decision: Hashable {
        /// The report waits for the tester's words: ask. `explained`: what waits is a possible answer
        /// to the problem (stage `EXPLAINED`), not the agent's questions.
        case ask(explained: Bool)
        /// Still being investigated (`NEW` / `INVESTIGATING`): the agent has not asked yet, or is
        /// writing – keep it and look again later.
        case wait
        /// Nothing to answer any more (finished, the token expired, the report is gone): forget it.
        case drop
        /// No answer worth acting on (offline, rate limited, a server error, a captive portal): ask another time.
        case later
    }

    /// What `finish_now` («Nei takk») got.
    enum FinishOutcome: Equatable {
        /// Heard (2xx), or nothing left to finish (404, 410): the entry goes.
        case heard
        /// 409: not taken right now – the agent is writing, or the report is finished. Not heard: a look
        /// at the report decides.
        case conflict
        /// No answer, or none worth acting on: said again at the next look.
        case later
    }

    /// The platform is still working on these: its questions may come.
    static let workingStatuses: Set<String> = ["NEW", "INVESTIGATING"]

    /// `GET /api/v1/reports/{id}` → ask only while `report.acceptsMessages`; a report still being
    /// investigated is kept, any other is done.
    static func decision(status: Int?, data: Data?) -> Decision {
        guard let status else { return .later }
        switch status {
        case 200..<300:
            guard let json = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                  let report = json["report"] as? [String: Any] else { return .later }
            if report["acceptsMessages"] as? Bool == true { return .ask(explained: report["stage"] as? String == "EXPLAINED") }
            if let state = report["status"] as? String, workingStatuses.contains(state) { return .wait }
            return .drop
        case 401, 403, 404, 410:
            return .drop
        default:
            return .later
        }
    }

    /// The oldest entry whose report takes the tester's words now (not declined), and whether what
    /// waits is a possible answer (`explained`). Reports that are done – finished, gone, or the token
    /// expired – are dropped on the way; one the agent still investigates stays (right after sending,
    /// the questions have not been asked yet) and `waiting` says to look again later. Stops at the
    /// first request without a usable answer. The completion runs on the session's queue.
    static func next(store: FollowUpStore, session: URLSession, completion: @escaping (_ question: (entry: FollowUp, explained: Bool)?, _ waiting: Bool) -> Void) {
        func look(_ remaining: ArraySlice<FollowUp>, waiting: Bool) {
            guard let entry = remaining.first else {
                completion(nil, waiting)
                return
            }
            fetch(entry, session: session) { decision in
                switch decision {
                case .ask(let explained):
                    completion((entry, explained), waiting)
                case .wait:
                    look(remaining.dropFirst(), waiting: true)
                case .drop:
                    store.remove(reportId: entry.reportId)
                    look(remaining.dropFirst(), waiting: waiting)
                case .later:
                    completion(nil, waiting)
                }
            }
        }
        look(ArraySlice(store.entries().filter { !$0.declined }), waiting: false)
    }

    static func finishOutcome(status: Int?) -> FinishOutcome {
        guard let status else { return .later }
        if (200..<300).contains(status) || [404, 410].contains(status) { return .heard }
        return status == 409 ? .conflict : .later
    }

    static func fetch(_ entry: FollowUp, session: URLSession, completion: @escaping (Decision) -> Void) {
        var request = URLRequest(url: reportURL(entry))
        request.setValue(entry.reporterToken, forHTTPHeaderField: "x-reproo-reporter-token")
        request.setValue("ios/\(Reproo.sdkVersion)", forHTTPHeaderField: "x-reproo-sdk")
        session.dataTask(with: NetworkCapture.own(request)) { data, response, _ in
            completion(decision(status: (response as? HTTPURLResponse)?.statusCode, data: data))
        }.resume()
    }

    /// «Nei takk»: the platform writes the report from what it has – waiting for questions
    /// (`AWAITING_REPORTER`) as well as with a possible answer (`EXPLAINED`, where it counts as silence).
    static func finishNow(_ entry: FollowUp, session: URLSession, completion: @escaping (FinishOutcome) -> Void) {
        var request = URLRequest(url: reportURL(entry).appendingPathComponent("actions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(entry.reporterToken, forHTTPHeaderField: "x-reproo-reporter-token")
        request.setValue("ios/\(Reproo.sdkVersion)", forHTTPHeaderField: "x-reproo-sdk")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "finish_now"])
        session.dataTask(with: NetworkCapture.own(request)) { _, response, _ in
            completion(finishOutcome(status: (response as? HTTPURLResponse)?.statusCode))
        }.resume()
    }

    /// A declined entry until the platform has heard it: `finish_now`; heard (or nothing left to finish)
    /// → the entry goes. A 409 is no answer to it, so the report is looked at: one that no longer waits
    /// for the tester is forgotten; one that still waits, or is being worked on (its next question may
    /// come), is kept and `lookAgain` asks for another try soon. Anything else keeps it for the next
    /// look. The completion runs on the session's queue.
    static func decline(_ entry: FollowUp, store: FollowUpStore, session: URLSession, completion: @escaping (_ lookAgain: Bool) -> Void) {
        finishNow(entry, session: session) { outcome in
            switch outcome {
            case .heard:
                store.remove(reportId: entry.reportId)
                completion(false)
            case .later:
                completion(false)
            case .conflict:
                fetch(entry, session: session) { decision in
                    switch decision {
                    case .drop:
                        store.remove(reportId: entry.reportId)
                        completion(false)
                    case .ask, .wait:
                        completion(true)
                    case .later:
                        completion(false)
                    }
                }
            }
        }
    }

    private static func reportURL(_ entry: FollowUp) -> URL {
        entry.host.appendingPathComponent("api/v1/reports").appendingPathComponent(entry.reportId)
    }
}

/// The question to the tester – nb for Norwegian devices (nb/nn/no, like the widget), else English.
/// Never anything technical: no code, signals or exception names.
struct FollowUpPromptText: Equatable {
    let title: String
    let message: String
    let accept: String
    let decline: String

    /// A crash older than an hour gets its time; an offline report always does («Problemet du lagret 12.11 kl. 14:32»).
    /// `explained`: what waits for the tester of an offline report is a possible answer to the problem
    /// (stage `EXPLAINED`), not questions – the question says so; the title stays. A crash keeps its
    /// question: its conversation shows whatever waits.
    static func make(for entry: FollowUp, locale: String, explained: Bool = false, now: Date = Date(), timeZone: TimeZone = .current) -> FollowUpPromptText {
        let norwegian = CrashPromptStrings.forLocale(locale) == .norwegian
        let moment = moment(entry.capturedAt, norwegian: norwegian, timeZone: timeZone)
        switch entry.kind {
        case .crash:
            let strings = CrashPromptStrings.forLocale(locale)
            let title: String
            if now.timeIntervalSince(entry.capturedAt) > 60 * 60 {
                title = norwegian ? "\(strings.title) \(moment)" : "\(strings.title) on \(moment)"
            } else {
                title = strings.title
            }
            return FollowUpPromptText(title: title, message: strings.message, accept: strings.tell, decline: strings.decline)
        case .offline:
            let question: String
            let accept: String
            if explained {
                question = norwegian ? "Reproo har et mulig svar på problemet du lagret. Vil du se det?" : "Reproo may have an answer to the problem you saved. Do you want to see it?"
                accept = norwegian ? "Se svaret" : "See the answer"
            } else {
                question = norwegian
                    ? "Rapporten er sendt. Vil du svare på et par korte spørsmål, så blir den bedre?"
                    : "The report has been sent. Would you like to answer a few short questions to make it better?"
                accept = norwegian ? "Svar nå" : "Answer now"
            }
            let quoted = entry.snippet.flatMap { $0.isEmpty ? nil : (norwegian ? "«\($0)»" : "“\($0)”") }
            return FollowUpPromptText(
                title: norwegian ? "Problemet du lagret \(moment)" : "The problem you saved on \(moment)",
                message: quoted.map { "\($0)\n\n\(question)" } ?? question,
                accept: accept,
                decline: norwegian ? "Nei takk" : "No thanks"
            )
        }
    }

    /// «12.11 kl. 14:32» / «12 Nov at 14:32» in the device's time zone.
    static func moment(_ date: Date, norwegian: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = norwegian ? "d.M 'kl.' HH:mm" : "d MMM 'at' HH:mm"
        return formatter.string(from: date)
    }
}

/// When to look again at reports the platform is still investigating: the questions usually follow
/// within a minute of sending, so after 30 s, doubling up to 10 minutes; back to 30 s once a question
/// was found or nothing waits any more.
struct RecheckBackoff: Equatable {
    static let first: TimeInterval = 30
    static let maximum: TimeInterval = 10 * 60

    private(set) var delay = RecheckBackoff.first

    /// The delay before this look; the next one is twice as long.
    mutating func next() -> TimeInterval {
        let current = delay
        delay = min(delay * 2, Self.maximum)
        return current
    }

    mutating func reset() {
        delay = Self.first
    }
}

/// What became of a question put on screen, looked at once a second until it is answered: UIKit may
/// refuse to show it without a word, and something may take it off screen without an answer.
struct PromptWatch: Equatable {
    enum Outcome: Equatable {
        /// On screen – or just gone, and the next look decides.
        case watching
        case answered
        /// Never seen on screen: show it again.
        case refused
        /// Seen, then gone twice in a row without an answer: this question is over; ask again later.
        case vanished
    }

    private(set) var seen = false
    private var missing = 0

    /// Whether the tester can see it: its alert is presented, in a window that is shown and still belongs
    /// to a connected scene. A window whose scene has gone – an iPad window closed from the app switcher,
    /// a scene disconnected in the background – keeps its alert presented without showing it anywhere.
    static func isOnScreen(presented: Bool, windowHidden: Bool, scene: UIScene.ActivationState?) -> Bool {
        guard presented, !windowHidden, let scene else { return false }
        return scene != .unattached
    }

    mutating func look(answered: Bool, onScreen: Bool) -> Outcome {
        if answered { return .answered }
        if onScreen {
            seen = true
            missing = 0
            return .watching
        }
        guard seen else { return .refused }
        // An action's handler runs only once the alert is gone: one look without it is no vanishing yet.
        missing += 1
        return missing >= 2 ? .vanished : .watching
    }
}

/// When FollowUpPrompt looks: one look or question at a time, and a check asked for meanwhile – the app
/// came back, a report was sent, the look at reports still being investigated came due – is not lost: it
/// follows shortly once the question is over (like the outbox's runAgain). Reports still being
/// investigated are looked at again after a growing pause (RecheckBackoff).
struct PromptTurns: Equatable {
    /// How soon a check follows a question that is over.
    static let soon: TimeInterval = 1

    /// A question is being looked up, shown, or its conversation opened.
    private(set) var busy = false
    /// A check was asked for while busy.
    private(set) var checkAgain = false
    private var backoff = RecheckBackoff()

    /// A check: true → look now; false → busy, and it follows once the question is over.
    mutating func begin() -> Bool {
        guard !busy else {
            checkAgain = true
            return false
        }
        busy = true
        return true
    }

    /// What a look found. Whether to plan the next look at reports still being investigated – also when
    /// a question was found: they wait while it is on screen. Back to 30 s once a question was found or
    /// nothing waits any more. A question keeps the turn until it is over (`end`).
    mutating func looked(question: Bool, waiting: Bool) -> Bool {
        if question || !waiting { backoff.reset() }
        return waiting
    }

    /// The pause before that look; the next one is twice as long.
    mutating func nextRecheck() -> TimeInterval {
        backoff.next()
    }

    /// The look or the question is over. Whether to check again soon: a check was asked for meanwhile, or
    /// `next` – the tester said «Nei takk», and another report may wait for them.
    mutating func end(next: Bool = false) -> Bool {
        let again = checkAgain || next
        busy = false
        checkAgain = false
        return again
    }
}

/// The transparent screen of the question's own window. Rotation and status bar stay the app's.
final class FollowUpPromptController: UIViewController {
    private weak var app: UIViewController?

    init(app: UIViewController?) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        self.view = view
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { app?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations }
    override var preferredStatusBarStyle: UIStatusBarStyle { app?.preferredStatusBarStyle ?? super.preferredStatusBarStyle }
    override var prefersStatusBarHidden: Bool { app?.prefersStatusBarHidden ?? super.prefersStatusBarHidden }
}

/// Asks the tester about their reports once the app is active, online and no reproo sheet is shown –
/// one question at a time, the oldest report that takes their words first (`GET /api/v1/reports/{id}`
/// → `acceptsMessages`). Finished reports are dropped; while one is still being investigated it is
/// looked at again with a growing pause (RecheckBackoff) as long as the app stays in the foreground.
/// The question is an alert in a window of its own, above the app's (alert level) and shown without
/// taking the key window: the SDK never presents on the app's controllers to ask, so nothing the app
/// presents or dismisses takes it away unanswered – and should it vanish anyway (or its window's scene
/// go), a later look asks again. A check that comes while a question is on screen follows once it is
/// over. «Svar nå» / «Se svaret» opens the report's conversation where the app's screen is (like «Meld
/// inn problem»; the entry goes once that page has loaded – it stays if it cannot load); «Nei takk» is
/// remembered and `finish_now` is sent until the platform has heard it – and the next report is looked at.
@MainActor
enum FollowUpPrompt {
    /// One look or question at a time; when to look again at reports still being investigated (or
    /// declined ones the platform did not take yet).
    private static var turns = PromptTurns()
    /// «Nei takk» on its way to the platform.
    private static var finishing: Set<String> = []
    private static var recheck: DispatchWorkItem?
    /// The question on screen (its window lives as long as this).
    private static var shown: Shown?

    /// One question on screen.
    private final class Shown {
        let entry: FollowUp
        let explained: Bool
        let window: UIWindow
        /// The app's key window – it stays key while the question is shown.
        weak var appWindow: UIWindow?
        let alert: UIAlertController
        let attempt: Int
        var answered = false
        /// Its window has gone (answered, shown again, vanished): nothing more to watch or answer.
        var closed = false
        var watch = PromptWatch()
        /// Its scene's disconnection, which takes the question away at once.
        var disconnection: NSObjectProtocol?

        init(entry: FollowUp, explained: Bool, window: UIWindow, appWindow: UIWindow?, alert: UIAlertController, attempt: Int) {
            self.entry = entry
            self.explained = explained
            self.window = window
            self.appWindow = appWindow
            self.alert = alert
            self.attempt = attempt
        }

        var isOnScreen: Bool {
            PromptWatch.isOnScreen(presented: alert.presentingViewController != nil, windowHidden: window.isHidden, scene: window.windowScene?.activationState)
        }
    }

    /// From any thread.
    nonisolated static func scheduleCheck(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { check() }
        }
    }

    static func check() {
        guard let offline = OfflineReports.shared, State.shared.snapshot.configuration != nil else { return }
        let store = offline.followUps
        let session = OfflineReports.session
        guard !ConnectivityMonitor.shared.isOffline else { return }
        retryDeclined(store: store, session: session)
        guard let application = UIApplication.sharedIfAvailable, application.applicationState == .active,
              store.entries().contains(where: { !$0.declined }),
              // A question is being looked up or on screen: this check follows once it is over.
              turns.begin() else { return }
        FollowUpClient.next(store: store, session: session) { question, waiting in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if turns.looked(question: question != nil, waiting: waiting) { scheduleRecheck() }
                    guard let question else {
                        endTurn()
                        return
                    }
                    ask(question.entry, explained: question.explained, store: store, session: session)
                }
            }
        }
    }

    /// The look or the question is over: a check asked for meanwhile follows soon – and, after «Nei takk»
    /// (`next`), a look at the next report.
    private static func endTurn(next: Bool = false) {
        if turns.end(next: next) { scheduleCheck(after: PromptTurns.soon) }
    }

    /// Only while the app is in the foreground: a look that comes due in the background does nothing,
    /// and the next activation looks anyway.
    private static func scheduleRecheck() {
        guard recheck == nil, UIApplication.sharedIfAvailable?.applicationState == .active else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                recheck = nil
                check()
            }
        }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + turns.nextRecheck(), execute: work)
    }

    /// A presentation in progress (or a host on its way in or out) makes UIKit refuse another one silently.
    static func canPresent(on host: UIViewController?) -> Bool {
        guard let host, host.viewIfLoaded?.window != nil, !host.isBeingDismissed, !host.isBeingPresented, host.transitionCoordinator == nil else { return false }
        return true
    }

    /// A reproo sheet (report page, composer) is on screen: no question on top of it.
    static func sheetShown(root: UIViewController?) -> Bool {
        var controller = root
        while let current = controller {
            if current is ReportViewController { return true }
            controller = current.presentedViewController
        }
        return false
    }

    /// The window a question is shown in: above the app's windows, transparent, rotating like `app`.
    static func makeWindow(scene: UIWindowScene?, app: UIViewController?) -> UIWindow {
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.windowLevel = .alert
        window.backgroundColor = .clear
        window.rootViewController = FollowUpPromptController(app: app)
        window.accessibilityIdentifier = "reproo-follow-up-window"
        return window
    }

    /// The controller on top in `window` (the app's screen a conversation opens on).
    static func top(of window: UIWindow?) -> UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func ask(_ entry: FollowUp, explained: Bool, store: FollowUpStore, session: URLSession, attempt: Int = 0) {
        guard store.entries().contains(where: { $0.reportId == entry.reportId && !$0.declined }) else {
            endTurn()
            return
        }
        let application = UIApplication.sharedIfAvailable
        let scenes = application?.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive } ?? []
        let scene = scenes.first { UIWindow.appKeyWindow(among: $0.windows) != nil } ?? scenes.first
        let appWindow = scene.flatMap { UIWindow.appKeyWindow(among: $0.windows) }
        guard let application, application.applicationState == .active, let scene, !sheetShown(root: appWindow?.rootViewController) else {
            // Right after activation the scene may not be active yet, or a reproo sheet is still on its way out.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { ask(entry, explained: explained, store: store, session: session, attempt: attempt + 1) } }
            } else {
                endTurn()
            }
            return
        }

        let text = FollowUpPromptText.make(for: entry, locale: ContextCollector.preferredLocale(), explained: explained)
        let window = makeWindow(scene: scene, app: top(of: appWindow))
        let alert = UIAlertController(title: text.title, message: text.message, preferredStyle: .alert)
        let question = Shown(entry: entry, explained: explained, window: window, appWindow: appWindow, alert: alert, attempt: attempt)
        alert.addAction(UIAlertAction(title: text.decline, style: .cancel) { [weak question] _ in
            MainActor.assumeIsolated {
                guard let question, !question.closed else { return }
                question.answered = true
                close(question)
                decline(entry, store: store, session: session)
                endTurn(next: true)
            }
        })
        let accept = UIAlertAction(title: text.accept, style: .default) { [weak question] _ in
            MainActor.assumeIsolated {
                guard let question, !question.closed else { return }
                question.answered = true
                close(question)
                open(entry, store: store, appWindow: question.appWindow)
            }
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        shown = question
        // Shown without becoming the key window: «report a problem» (shake) and its screenshot stay the app's.
        window.isHidden = false
        window.rootViewController?.present(alert, animated: true)
        question.disconnection = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { [weak question] _ in
            MainActor.assumeIsolated {
                guard let question, !question.closed else { return }
                vanished(question)
            }
        }
        watch(question, store: store, session: session)
    }

    /// Once a second until the tester answers: refused by UIKit → shown again (up to 10 times); vanished
    /// without an answer – or its window lost its scene – → the window goes, and a later look asks again.
    /// Never «busy» with nothing on screen.
    private static func watch(_ question: Shown, store: FollowUpStore, session: URLSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard !question.closed else { return }
                switch question.watch.look(answered: question.answered, onScreen: question.isOnScreen) {
                case .answered:
                    break
                case .watching:
                    watch(question, store: store, session: session)
                case .refused:
                    close(question)
                    if question.attempt < 10 {
                        ask(question.entry, explained: question.explained, store: store, session: session, attempt: question.attempt + 1)
                    } else {
                        endTurn()
                    }
                case .vanished:
                    vanished(question)
                }
            }
        }
    }

    /// Gone without an answer: this question is over, and a later look asks again.
    private static func vanished(_ question: Shown) {
        close(question)
        endTurn()
        scheduleRecheck()
    }

    /// The question's window goes. Should UIKit have made it the key window after all, the app's is key again.
    private static func close(_ question: Shown) {
        question.closed = true
        if let disconnection = question.disconnection { NotificationCenter.default.removeObserver(disconnection) }
        question.disconnection = nil
        let hadKey = question.window.isKeyWindow
        question.window.isHidden = true
        if shown === question { shown = nil }
        if hadKey, let appWindow = question.appWindow, !appWindow.isHidden, !appWindow.isKeyWindow { appWindow.makeKey() }
    }

    /// The report's conversation, on the app's screen once the question's window has gone.
    private static func open(_ entry: FollowUp, store: FollowUpStore, appWindow: UIWindow?, attempt: Int = 0) {
        let host = top(of: appWindow) ?? UIApplication.sharedIfAvailable?.topViewController
        guard canPresent(on: host), let host else {
            // The alert or the app's screen is still moving.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { open(entry, store: store, appWindow: appWindow, attempt: attempt + 1) } }
            } else {
                endTurn()
            }
            return
        }
        // No check right behind it: the conversation's sheet looks again when it goes (ReportViewController).
        _ = turns.end()
        Reproo.presentFollowUp(entry, from: host) { store.remove(reportId: entry.reportId) }
    }

    /// «Nei takk»: never asked again, and `finish_now` goes until the platform has heard it.
    static func decline(_ entry: FollowUp, store: FollowUpStore, session: URLSession) {
        store.markDeclined(reportId: entry.reportId)
        finish(entry, store: store, session: session)
    }

    /// «Nei takk» not yet heard by the platform (offline when it was said, or not taken then): sent again.
    private static func retryDeclined(store: FollowUpStore, session: URLSession) {
        for entry in store.entries() where entry.declined { finish(entry, store: store, session: session) }
    }

    private static func finish(_ entry: FollowUp, store: FollowUpStore, session: URLSession) {
        guard !finishing.contains(entry.reportId) else { return }
        finishing.insert(entry.reportId)
        FollowUpClient.decline(entry, store: store, session: session) { lookAgain in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    finishing.remove(entry.reportId)
                    if lookAgain { scheduleRecheck() }
                }
            }
        }
    }
}

extension Reproo {
    /// The report page, reopened on a report's conversation (no screenshot: this screen is not the one
    /// the report is about). `loaded` runs once the page has loaded.
    @MainActor
    static func presentFollowUp(_ entry: FollowUp, from host: UIViewController, loaded: @escaping () -> Void) {
        let snapshot = State.shared.snapshot
        guard let current = snapshot.configuration else { return }
        let configuration = Configuration(
            projectKey: entry.projectKey,
            host: entry.host,
            environment: current.environment,
            version: current.version,
            build: current.build,
            appName: current.appName,
            appId: current.appId,
            release: current.release,
            commitSha: current.commitSha,
            attachScreenshot: false,
            captureNetwork: current.captureNetwork,
            captureCrashes: current.captureCrashes
        )
        let controller = ReportViewController(
            configuration: configuration,
            context: ContextCollector.collect(state: snapshot),
            screenshot: nil,
            resume: ReportResume(reportId: entry.reportId, reporterToken: entry.reporterToken)
        )
        controller.onResumeLoaded = loaded
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.prefersGrabberVisible = true
        host.present(controller, animated: true)
    }
}
#endif
