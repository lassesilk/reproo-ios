#if canImport(UIKit)
import UIKit
import WebKit

/// An existing report the widget should reopen instead of its start screen (follow-up questions).
struct ReportResume {
    let reportId: String
    let reporterToken: String
}

/// Whether the report page's first load worked. A load error, an HTTP status ≥ 400 for the page
/// itself, or no finished load within 12 s means the page is not coming – the native composer takes
/// over (or, for a report's conversation, a short «you're offline» note). Decided once.
struct FirstLoadWatch: Equatable {
    enum Event {
        case response(status: Int, mainFrame: Bool)
        case finished
        case failed(domain: String, code: Int)
        case timedOut
    }

    enum Outcome: Equatable {
        case pending, loaded, failed
    }

    private(set) var outcome: Outcome = .pending

    /// The outcome this event decided, or `.pending` when it decided nothing (new).
    mutating func handle(_ event: Event) -> Outcome {
        guard outcome == .pending else { return .pending }
        switch event {
        case .response(let status, let mainFrame):
            guard mainFrame, status >= 400 else { return .pending }
            outcome = .failed
        case .finished:
            outcome = .loaded
        case .failed(let domain, let code):
            // A navigation replaced by another one, or one the SDK cancelled itself: not the page failing.
            if domain == NSURLErrorDomain && code == NSURLErrorCancelled { return .pending }
            if domain == "WebKitErrorDomain" && code == 102 { return .pending }
            outcome = .failed
        case .timedOut:
            outcome = .failed
        }
        return outcome
    }
}

/// Hosts the reporting widget (`/embed/report`) in a WKWebView. The page is top-level here, so
/// the bridge script posts the SDK's "init" message to `window` – exactly what the widget expects
/// from its parent in the Web SDK iframe – and forwards widget events to native code. Without a
/// connection the native composer is shown instead (from the start, or once the page fails to load),
/// with the same screenshot and context; the report then waits in the outbox.
final class ReportViewController: UIViewController {
    static let firstLoadTimeout: TimeInterval = 12

    private let configuration: Configuration
    /// The context frozen when the tester opened the sheet – also what an offline report keeps.
    let context: [String: Any]
    private let screenshot: UIImage?
    private let resume: ReportResume?
    /// The state snapshot `context` was built from; cleared from the SDK's buffers once the widget
    /// has created the report or it was saved for later (nil: nothing to clear, e.g. a reopened report).
    private var reported: State.Values?
    private let startsWithComposer: Bool
    private let offline: OfflineReports?
    private let strings = ComposerStrings.forLocale(ContextCollector.preferredLocale())
    private(set) var webView: WKWebView!
    private var firstLoad = FirstLoadWatch()
    private var firstLoadTimer: DispatchWorkItem?
    /// Runs once a reopened report's page has loaded (its follow-up entry can go).
    var onResumeLoaded: (() -> Void)?

    enum Content: Equatable {
        case page, composer, saved, offlineNotice
    }

    private(set) var content: Content = .page
    private var child: UIViewController?

    init(configuration: Configuration, context: [String: Any], screenshot: UIImage?, resume: ReportResume? = nil, reported: State.Values? = nil, startsWithComposer: Bool = false, offline: OfflineReports? = OfflineReports.shared) {
        self.configuration = configuration
        self.context = context
        self.screenshot = screenshot
        self.resume = resume
        self.reported = reported
        self.startsWithComposer = startsWithComposer && resume == nil && offline != nil
        self.offline = offline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Known to be offline when the tester asks: the page cannot load, so the composer comes first.
    static func opensComposer(connectivity: ConnectivityState?) -> Bool {
        connectivity?.status == .offline
    }

    /// The page did not load, and the device is not known to be offline: slow, or the platform did not
    /// answer – the composer says the page does not respond, never that the tester is offline.
    static func pageUnreachable(connectivity: ConnectivityState?) -> Bool {
        connectivity?.status != .offline
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if startsWithComposer {
            showComposer()
        } else {
            loadPage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        firstLoadTimer?.cancel()
        // The sheet is gone: a question that waited for it may be asked now.
        FollowUpPrompt.scheduleCheck(after: 0.6)
    }

    private func loadPage() {
        let contentController = WKUserContentController()
        // Named like the bridge's message source – "uatai" is protocol v1's bridge identifier, shared with the widget.
        contentController.add(WeakMessageHandler(target: self), name: "uatai")
        if let resume, let script = Self.resumeScript(projectKey: configuration.projectKey, host: configuration.host, resume: resume) {
            contentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let script = bridgeScript() {
            contentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController = contentController

        webView = WKWebView(frame: view.bounds, configuration: webConfiguration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The widget scrolls its own message list. Without the page-level rubber band, a downward drag
        // on the header reaches the sheet, so it can be swiped closed instead of bouncing back.
        webView.scrollView.bounces = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)

        var components = URLComponents(url: configuration.host.appendingPathComponent("embed/report"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "k", value: configuration.projectKey),
            URLQueryItem(name: "locale", value: ContextCollector.preferredLocale()),
        ]
        guard let url = components?.url else { return }
        webView.load(URLRequest(url: url))
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.firstLoadEvent(.timedOut) }
        }
        firstLoadTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstLoadTimeout, execute: timer)
    }

    /// JavaScript bridge: answers the widget's "ready" with "init" (+ optional screenshot) and
    /// forwards close/report events to native (report-created with the `clientReportId` the report was
    /// created with). No `hostOrigin`: the widget takes the host's origin from
    /// the message event – here the platform's own, as the page posts to itself. `capabilities`
    /// tells the widget it may offer «save and send when online» when creating the report fails.
    func bridgeScript() -> String? {
        var initMessage: [String: Any] = [
            "source": "uatai",
            "type": "init",
            "projectKey": configuration.projectKey,
            "context": context,
        ]
        if let locale = context["locale"] { initMessage["locale"] = locale }
        if offline != nil && resume == nil { initMessage["capabilities"] = ["outbox"] }
        guard let initData = try? JSONSerialization.data(withJSONObject: initMessage), let initJSON = String(data: initData, encoding: .utf8) else { return nil }

        var attachJSON = "null"
        if let screenshot, let jpeg = ScreenCapture.jpegData(screenshot) {
            let attach: [String: Any] = [
                "source": "uatai",
                "type": "attach",
                "fileName": "app-screen.jpg",
                "dataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: attach), let json = String(data: data, encoding: .utf8) { attachJSON = json }
        }

        // save-offline only from the page itself (the widget posts to its parent, which is the page).
        return """
        (function () {
          var initMessage = \(initJSON);
          var attachMessage = \(attachJSON);
          var sent = false;
          function text(value) { return typeof value === 'string' ? value : null; }
          window.addEventListener('message', function (event) {
            var data = event.data;
            if (!data || data.source !== 'uatai') return;
            if (data.type === 'ready' && !sent) {
              sent = true;
              window.postMessage(initMessage, '*');
              if (attachMessage) setTimeout(function () { window.postMessage(attachMessage, '*'); }, 300);
            }
            if (data.type === 'close' || data.type === 'report-created' || data.type === 'report-completed') {
              window.webkit.messageHandlers.uatai.postMessage({ type: data.type, reportId: data.reportId || null, statusUrl: data.statusUrl || null, clientReportId: text(data.clientReportId) });
            }
            if (data.type === 'save-offline' && event.source === window) {
              var reporter = data.reporter && typeof data.reporter === 'object' ? { name: text(data.reporter.name), email: text(data.reporter.email) } : null;
              var screenshot = typeof data.screenshot === 'boolean' ? data.screenshot : null;
              window.webkit.messageHandlers.uatai.postMessage({ type: data.type, message: text(data.message), reporter: reporter, clientReportId: text(data.clientReportId), screenshot: screenshot });
            }
          });
        })();
        """
    }

    /// Seeds the widget's own resume entry – sessionStorage `uatai.report.<projectKey>` = {id, token},
    /// what the widget stores after creating a report – before its scripts run, so it reopens that
    /// report's conversation. Only on the platform's origin: the token is a secret.
    static func resumeScript(projectKey: String, host: URL, resume: ReportResume) -> String? {
        let payload: [String: Any] = [
            "origin": origin(of: host),
            "key": "uatai.report.\(projectKey)",
            "value": ["id": resume.reportId, "token": resume.reporterToken],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function () {
          var resume = \(json);
          if (window.location.origin !== resume.origin) return;
          try { window.sessionStorage.setItem(resume.key, JSON.stringify(resume.value)); } catch (error) {}
        })();
        """
    }

    /// `window.location.origin` of a page on `url` (default ports omitted, like browsers do).
    static func origin(of url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        var host = (url.host ?? "").lowercased()
        if host.contains(":") { host = "[\(host)]" }
        guard let port = url.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    func handle(message: [String: Any]) {
        switch message["type"] as? String {
        case "close":
            dismiss(animated: true)
        case "report-created":
            // Once: the widget may announce the same report again after a reload.
            discardReported()
            // Saved for later, then sent from the page after all («Prøv igjen», the same id): the page's
            // report owns it now – the outbox neither sends it again nor asks about it later.
            if let clientReportId = message["clientReportId"] as? String, OutboxItem.isValidClientReportId(clientReportId) {
                offline?.outbox.remove(clientReportId)
            }
        case "save-offline":
            saveFromWidget(message)
        default:
            break
        }
    }

    private func discardReported() {
        if let reported {
            self.reported = nil
            State.shared.discard(reported: reported)
        }
    }

    // MARK: Offline

    /// The widget could not create the report (no response) and the tester chose to keep it: saved with
    /// the widget's `clientReportId` – the one it sent on every attempt, so an attempt that did reach
    /// the platform is never stored twice, and saving again keeps one item. The screenshot the SDK
    /// attached goes with it unless the tester removed it in the widget (`screenshot: false`; a widget
    /// that does not say keeps it). Every save is answered with `save-offline-result`: the widget says
    /// «Lagret …» or why it could not be saved itself.
    private func saveFromWidget(_ message: [String: Any]) {
        let clientReportId = message["clientReportId"] as? String
        var result = OfflineReports.SaveResult.failed
        if let text = message["message"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let clientReportId, OutboxItem.isValidClientReportId(clientReportId) {
            let reporter = (message["reporter"] as? [String: Any])?.compactMapValues { $0 as? String }
            let screenshot = message["screenshot"] as? Bool ?? true
            result = saveOffline(ComposerInput(message: text, name: reporter?["name"], email: reporter?["email"], includeScreenshot: screenshot), clientReportId: clientReportId, confirm: false)
        }
        postToPage(Self.saveOfflineResult(clientReportId: clientReportId, result: result))
    }

    /// `{source, type: "save-offline-result", clientReportId, ok, reason?}` – reason "full" (20 reports
    /// already wait) or "failed" (anything else: nothing usable to save, the phone could not write it).
    static func saveOfflineResult(clientReportId: String?, result: OfflineReports.SaveResult) -> [String: Any] {
        var message: [String: Any] = [
            "source": "uatai",
            "type": "save-offline-result",
            "clientReportId": clientReportId as Any? ?? NSNull(),
            "ok": result == .saved,
        ]
        switch result {
        case .saved:
            break
        case .full:
            message["reason"] = "full"
        case .failed:
            message["reason"] = "failed"
        }
        return message
    }

    /// Posts a message into the report page the way the bridge posts "init" (`window.postMessage(…, '*')`):
    /// the widget takes it as its host's, since the page posts to itself. Replaced in tests.
    lazy var postToPage: ([String: Any]) -> Void = { [weak self] message in
        guard let script = ReportViewController.postMessageScript(message) else { return }
        self?.webView?.evaluateJavaScript(script)
    }

    static func postMessageScript(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.postMessage(\(json), '*');"
    }

    /// Saves the report in the outbox; on success the SDK's buffers start fresh and (`confirm`) the sheet says so.
    func saveOffline(_ input: ComposerInput, clientReportId: String = UUID().uuidString, confirm: Bool = true) -> OfflineReports.SaveResult {
        guard let offline else { return .failed }
        let result = offline.save(
            clientReportId: clientReportId,
            message: input.message,
            reporter: input.reporter,
            context: context,
            screenshot: input.includeScreenshot ? screenshot : nil,
            configuration: configuration
        )
        if result == .saved {
            discardReported()
            if confirm { showStatus(.saved) }
        }
        return result
    }

    /// One navigation event of the page; decides once whether the first load worked.
    @discardableResult
    func firstLoadEvent(_ event: FirstLoadWatch.Event) -> FirstLoadWatch.Outcome {
        let outcome = firstLoad.handle(event)
        switch outcome {
        case .loaded:
            firstLoadTimer?.cancel()
            let loaded = onResumeLoaded
            onResumeLoaded = nil
            loaded?()
        case .failed:
            firstLoadTimer?.cancel()
            pageDidNotLoad()
        case .pending:
            break
        }
        return outcome
    }

    private func pageDidNotLoad() {
        webView?.stopLoading()
        if resume != nil || offline == nil {
            // A report's conversation needs the platform; the question is asked again next time.
            showStatus(.offlineNotice)
        } else {
            showComposer(pageUnreachable: Self.pageUnreachable(connectivity: State.shared.read { $0.connectivity }))
        }
    }

    func showComposer(pageUnreachable: Bool = false) {
        let user = State.shared.snapshot.user
        let fields = ProjectConfigCache.fields(host: configuration.host, projectKey: configuration.projectKey) ?? .none
        let composer = ComposerViewController(
            strings: strings,
            screenshot: screenshot,
            fields: fields,
            privacyNotice: ProjectConfigCache.privacyNotice(fields, host: configuration.host),
            name: user.name,
            email: user.email,
            pageUnreachable: pageUnreachable
        )
        composer.onCancel = { [weak self] in self?.dismiss(animated: true) }
        composer.onSave = { [weak self] input in self?.saveOffline(input) ?? .failed }
        composer.onDirtyChange = { [weak self] dirty in self?.isModalInPresentation = dirty }
        embed(UINavigationController(rootViewController: composer), as: .composer)
    }

    private func showStatus(_ status: Content) {
        let panel = status == .saved ? StatusPanelViewController.saved(strings) : StatusPanelViewController.offline(strings)
        panel.onButton = { [weak self] in self?.dismiss(animated: true) }
        isModalInPresentation = false
        embed(panel, as: status)
    }

    /// Replaces what the sheet shows (the page goes for good: nothing it does matters any more).
    private func embed(_ controller: UIViewController, as content: Content) {
        if let child {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        if let webView, webView.superview != nil {
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        child = controller
        self.content = content
    }
}

extension ReportViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 200
        decisionHandler(firstLoadEvent(.response(status: status, mainFrame: navigationResponse.isForMainFrame)) == .failed ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        firstLoadEvent(.finished)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        firstLoadEvent(.failed(domain: error.domain, code: error.code))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        firstLoadEvent(.failed(domain: error.domain, code: error.code))
    }
}

extension ReportViewController: WKUIDelegate {
    /// The widget's links that open in a new tab – the report's status page, the privacy notice – open in
    /// the browser: a web view without this ignores them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

/// Avoids the retain cycle WKUserContentController → handler → controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ReportViewController?
    init(target: ReportViewController) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(message: body)
    }
}

enum ScreenCapture {
    /// Snapshot of the app's key window (never the SDK's own question window), taken before the report sheet is shown.
    @MainActor
    static func captureKeyWindow() -> UIImage? {
        guard let window = UIApplication.shared.appKeyWindow else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
    }

    /// JPEG, max 1600 px wide – under the platform's 4 MB limit per attachment even for the largest
    /// screen (an app's screen is far below it; noise, the worst case, about 3 MB).
    static func jpegData(_ image: UIImage) -> Data? {
        let maxWidth: CGFloat = 1600
        let scale = min(1, maxWidth / max(image.size.width * image.scale, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
#endif
