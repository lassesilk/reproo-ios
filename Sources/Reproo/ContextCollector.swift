#if canImport(UIKit)
import UIKit

/// Builds the protocol v1 `ClientContext` (see packages/protocol/src/index.ts).
enum ContextCollector {
    @MainActor
    static func collect(state: State.Values) -> [String: Any] {
        build(state: state, device: deviceInfo())
    }

    /// Device, OS and viewport – read on the main thread (UIDevice/UIScreen). The crash black box
    /// captures them once at configure and reuses them from its background writer.
    @MainActor
    static func deviceInfo() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        return [
            "device": [
                "type": device.userInterfaceIdiom == .pad ? "tablet" : "mobile",
                "model": hardwareModel(),
                "vendor": "Apple",
            ],
            "os": ["name": device.systemName, "version": device.systemVersion],
            "viewport": [
                "width": Int(screen.bounds.width),
                "height": Int(screen.bounds.height),
                "pixelRatio": Double(screen.scale),
            ],
        ]
    }

    /// The context of a state snapshot plus `deviceInfo()`. Safe on any thread.
    static func build(state: State.Values, device: [String: Any], now: Date = Date()) -> [String: Any] {
        let configuration = state.configuration
        let iso = ISO8601DateFormatter()

        var user: [String: Any] = [:]
        if let id = state.user.id { user["id"] = id }
        if let role = state.user.role { user["role"] = role }
        if let name = state.user.name, !name.isEmpty { user["name"] = name }
        if let email = state.user.email, !email.isEmpty { user["email"] = email }

        let context: [String: Any] = [
            "sdk": ["name": "reproo-ios", "version": Reproo.sdkVersion],
            "platform": "ios",
            "sessionId": state.sessionId,
            "environment": configuration?.environment as Any,
            "release": (configuration?.release ?? configuration?.version) as String? as Any,
            "commitSha": configuration?.commitSha as Any,
            "route": state.route as Any,
            "app": [
                "name": configuration?.appName as Any,
                "version": configuration?.version as Any,
                "build": configuration?.build as Any,
                "id": configuration?.appId as Any,
            ].compactMapValues(unwrap),
            "device": device["device"] as Any,
            "os": device["os"] as Any,
            "locale": preferredLocale(),
            "timezone": TimeZone.current.identifier,
            "screen": ["name": state.screen as Any].compactMapValues(unwrap),
            "viewport": device["viewport"] as Any,
            "user": user,
            "custom": jsonSafe(state.custom),
            "breadcrumbs": state.breadcrumbs.map { $0.json(iso) },
            "network": state.network.map { $0.json(iso) },
            "console": state.console.map { $0.json(iso) },
            "connectivity": state.connectivity?.json(iso) as Any,
            "timestamp": iso.string(from: now),
        ]
        return context.compactMapValues(unwrap)
    }

    /// The tester's device language (e.g. "nb-NO"), not the host app's: an English-only app on a
    /// Norwegian phone should still get the reporting widget in Norwegian.
    static func preferredLocale() -> String {
        (Locale.preferredLanguages.first ?? Locale.current.identifier).replacingOccurrences(of: "_", with: "-")
    }

    /// e.g. "iPhone17,1" (simulator: the simulated model identifier).
    static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func unwrap(_ value: Any) -> Any? {
        if case Optional<Any>.none = value { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first?.value }
        return value
    }

    /// Keeps only JSON-serialisable values (custom context is filtered again on the server).
    private static func jsonSafe(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.filter { JSONSerialization.isValidJSONObject(["value": $0.value]) }
    }
}
#endif
