#if canImport(UIKit)
import Foundation
import os

/// What `Reproo.configure` accepts, and the developer warnings when it does not: an app built without a key
/// (a development build, a CI build) or with the guide's "rp_pk_…" placeholder runs with reproo off instead
/// of crashing or sending requests that can only fail.
enum Setup {
    /// A public project key as the platform accepts it (PUBLIC_KEY_PATTERN in the platform's
    /// src/server/security/tokens.ts): `rp_pk_…`, and `uat_pk_…` from before reproo.
    static let keyPattern = "\\A(?:rp|uat)_pk_[A-Za-z0-9_]{16,64}\\z"

    private static let log = Logger(subsystem: "no.reproo", category: "setup")
    private static let lock = NSLock()
    private static var warned = Set<String>()

    /// Why `configure` with these values leaves reproo off, or nil when it can start.
    static func problem(projectKey: String, host: URL) -> String? {
        if projectKey.isEmpty {
            return "Reproo.configure(): no project key – reproo is off. Pass the iOS app's public key (rp_pk_…) from the project's SDK setup in reproo."
        }
        if projectKey.range(of: keyPattern, options: .regularExpression) == nil {
            let shown = projectKey.count > 12 ? "\(projectKey.prefix(12))…" : projectKey
            return "Reproo.configure(): \"\(shown)\" is not a project key – reproo is off. Copy the iOS app's public key (rp_pk_ and 24 letters and digits) from the project's SDK setup in reproo."
        }
        guard let scheme = host.scheme?.lowercased(), scheme == "https" || scheme == "http", host.host?.isEmpty == false else {
            return "Reproo.configure(): host \"\(host.absoluteString)\" is not a web address (e.g. https://app.reproo.no) – reproo is off."
        }
        return nil
    }

    /// Writes `message` to the console (Xcode and Console.app) – each message once per run, however often
    /// the app calls the SDK.
    static func warn(_ message: String) {
        lock.lock()
        let first = warned.insert(message).inserted
        lock.unlock()
        guard first else { return }
        log.warning("\(message, privacy: .public)")
    }

    /// Messages written so far (tests).
    static var warnings: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return warned
    }
}
#endif
