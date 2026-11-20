#if canImport(UIKit)
import ObjectiveC
import UIKit

/// Opt-in shake gesture: `Reproo.configure(…, shakeToReport: true)` opens the report when the tester shakes
/// the device (Simulator: Device → Shake) – off by default.
///
/// UIKit delivers a shake as a motion event to the first responder and up the responder chain to the
/// window. The SDK gives UIWindow its own `motionEnded(_:with:)` that calls the implementation it had – an
/// override the app added to UIWindow, or UIResponder's – and then opens the report. Only UIWindow's method
/// is touched, never UIResponder's, which every view and view controller shares; windows of subclasses that
/// override it reach it through `super`. A shake while a reproo sheet or the follow-up question is up opens
/// nothing.
enum ShakeToReport {
    /// Whether a shake opens the report (main thread; set by `configure`).
    static var isEnabled = false
    /// Tests: what a shake does instead of opening the report.
    static var onShake: (@MainActor (UIWindow) -> Void)?

    /// Installs the hook once; later calls do nothing.
    static func install() {
        _ = installed
    }

    private static let installed: Void = {
        let selector = #selector(UIResponder.motionEnded(_:with:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        typealias MotionEnded = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
        let previous = unsafeBitCast(method_getImplementation(method), to: MotionEnded.self)
        let block: @convention(block) (UIWindow, UIEvent.EventSubtype, UIEvent?) -> Void = { window, motion, event in
            previous(window, selector, motion, event)
            guard motion == .motionShake, isEnabled else { return }
            Task { @MainActor in shaken(in: window) }
        }
        let implementation = imp_implementationWithBlock(block)
        // UIWindow inherits it from UIResponder: add UIWindow's own. Already its own (an app's extension
        // override): replace UIWindow's – `previous` still calls it.
        if !class_addMethod(UIWindow.self, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }()

    @MainActor
    static func shaken(in window: UIWindow) {
        guard isEnabled, State.shared.snapshot.configuration != nil else { return }
        // The follow-up question's window, or a reproo sheet already on screen: never a second one.
        if window.rootViewController is FollowUpPromptController { return }
        if UIApplication.sharedIfAvailable?.topViewController is ReportViewController { return }
        if let onShake {
            onShake(window)
            return
        }
        Reproo.reportProblem()
    }
}
#endif
