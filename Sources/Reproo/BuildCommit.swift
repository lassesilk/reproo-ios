#if canImport(UIKit)
import Foundation

/// The git commit the app was built from, with nothing to change per release: a one-time Run Script
/// phase in the app target writes it into the built Info.plist as `ReprooCommit` (see the README), and
/// `configure` reads it when no `commitSha` is passed. A `commitSha` the app passes itself always wins.
enum BuildCommit {
    /// The Info.plist key the app's build sets.
    static let infoKey = "ReprooCommit"

    /// `explicit` when the app passed one; otherwise what `info` holds, if it is a commit – a build without
    /// git (no `git`, no repository) leaves the key out, and anything else is ignored too.
    static func resolve(explicit: String?, info: @autoclosure () -> Any?) -> String? {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return explicit }
        return valid(info() as? String)
    }

    /// 7–64 hex characters (an abbreviated to a full SHA-256 commit id, lower-cased like git prints them);
    /// nil otherwise – an empty value or an unexpanded build setting such as `$(REPROO_COMMIT)` included.
    static func valid(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "\\A[0-9a-fA-F]{7,64}\\z", options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    /// The `ReprooCommit` of the app's Info.plist; nil when its build does not set one.
    static func fromInfoPlist(_ bundle: Bundle = .main) -> Any? {
        bundle.object(forInfoDictionaryKey: infoKey)
    }
}
#endif
