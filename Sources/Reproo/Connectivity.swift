#if canImport(UIKit)
import Foundation
import Network

/// The device's connection as the protocol's `ClientContext.connectivity` describes it.
struct ConnectivityState: Equatable {
    enum Status: String {
        case online, offline, unknown
    }

    enum InterfaceType: String {
        case wifi, cellular, ethernet, other
    }

    var status: Status
    var type: InterfaceType?
    /// iOS `isExpensive` (cellular, a personal hotspot).
    var expensive: Bool?
    /// iOS Low Data Mode.
    var constrained: Bool?
    /// When the status last changed; nil until a change was seen (the first answer is not a change).
    var since: Date?

    /// Protocol v1 `connectivity`. Interface details only while online: offline they describe nothing.
    func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
        var json: [String: Any] = ["status": status.rawValue]
        if status == .online {
            if let type { json["type"] = type.rawValue }
            if let expensive { json["expensive"] = expensive }
            if let constrained { json["constrained"] = constrained }
        }
        if let since { json["since"] = iso.string(from: since) }
        return json
    }
}

/// One answer of the path monitor, reduced to what a report needs.
struct ConnectivityPath: Equatable {
    var status: ConnectivityState.Status
    var type: ConnectivityState.InterfaceType?
    var expensive: Bool
    var constrained: Bool
}

/// The seam between ConnectivityMonitor and `NWPathMonitor`: tests feed paths by hand.
protocol PathMonitoring: AnyObject {
    func start(queue: DispatchQueue, update: @escaping (ConnectivityPath) -> Void)
    func cancel()
}

/// `NWPathMonitor`: answers once right after `start` and again on every change.
final class NetworkPathMonitor: PathMonitoring {
    private let monitor = NWPathMonitor()

    func start(queue: DispatchQueue, update: @escaping (ConnectivityPath) -> Void) {
        monitor.pathUpdateHandler = { path in update(Self.path(path)) }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    static func path(_ path: NWPath) -> ConnectivityPath {
        let status: ConnectivityState.Status
        switch path.status {
        case .satisfied: status = .online
        case .unsatisfied: status = .offline
        // A connection could be made on demand (e.g. a VPN): neither claim holds yet.
        case .requiresConnection: status = .unknown
        @unknown default: status = .unknown
        }
        let type: ConnectivityState.InterfaceType
        if path.usesInterfaceType(.wifi) {
            type = .wifi
        } else if path.usesInterfaceType(.cellular) {
            type = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            type = .ethernet
        } else {
            type = .other
        }
        return ConnectivityPath(status: status, type: status == .online ? type : nil, expensive: path.isExpensive, constrained: path.isConstrained)
    }
}

/// Watches the device's connection while the app runs: the current state goes into every report's
/// context, and each loss and return becomes a breadcrumb («Lost connection» / «Connection restored
/// (wifi)») – so «no coverage» is never read as a server error, and sync problems get a timeline.
/// Connectivity regained – or another network while online (cellular → wifi) – is one of the moments
/// the outbox is sent.
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private let makeMonitor: () -> PathMonitoring
    private let now: () -> Date
    private let queue = DispatchQueue(label: "no.reproo.connectivity", qos: .utility)
    private let lock = NSLock()
    private var monitor: PathMonitoring?
    private var current: ConnectivityState?
    /// The last definite status (online or offline): an «unknown» in between is no loss and no return.
    private var lastKnown: ConnectivityState.Status?
    /// The interface of the last online answer.
    private var lastOnlineType: ConnectivityState.InterfaceType?
    private var onlineHandler: (() -> Void)?

    init(monitor: @escaping () -> PathMonitoring = { NetworkPathMonitor() }, now: @escaping () -> Date = Date.init) {
        self.makeMonitor = monitor
        self.now = now
    }

    /// nil before the monitor's first answer.
    var state: ConnectivityState? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Only a definite «offline» counts: unknown is treated as maybe online (the report page then
    /// shows whether it loads).
    var isOffline: Bool {
        state?.status == .offline
    }

    /// Called (on the monitor's queue) when the device is back online after having been offline, or
    /// online over another kind of interface than before (cellular → wifi): a send that got nowhere may
    /// get through now.
    func onOnline(_ handler: @escaping () -> Void) {
        lock.lock()
        onlineHandler = handler
        lock.unlock()
    }

    /// Starts watching (once per process).
    func start() {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let monitor = makeMonitor()
        self.monitor = monitor
        lock.unlock()
        monitor.start(queue: queue) { [weak self] path in self?.handle(path) }
    }

    func stop() {
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    /// One answer of the path monitor. Internal for tests.
    func handle(_ path: ConnectivityPath) {
        lock.lock()
        let previous = current
        let previousKnown = lastKnown
        let previousType = lastOnlineType
        var next = ConnectivityState(status: path.status, type: path.type, expensive: path.expensive, constrained: path.constrained, since: previous?.since)
        if let previous, previous.status != path.status { next.since = now() }
        current = next
        if path.status != .unknown { lastKnown = path.status }
        if path.status == .online { lastOnlineType = path.type }
        let handler = onlineHandler
        lock.unlock()

        State.shared.update { $0.connectivity = next }
        guard let previousKnown, path.status != .unknown else { return }
        if previousKnown == path.status {
            // Another network while online: the context follows (no breadcrumb), and what waits is tried on it.
            if path.status == .online && path.type != previousType { handler?() }
            return
        }
        if path.status == .offline {
            Reproo.addBreadcrumb(type: .network, message: "Lost connection", data: ["connectivity": "offline"])
        } else {
            let type = path.type ?? .other
            Reproo.addBreadcrumb(type: .network, message: "Connection restored (\(type.rawValue))", data: ["connectivity": "online", "type": type.rawValue])
            handler?()
        }
    }
}
#endif
