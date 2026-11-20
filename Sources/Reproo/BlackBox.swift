#if canImport(UIKit)
import Foundation
import MachO

/// Files crash capture keeps in Application Support/ai.uatai (excluded from backup, protected
/// until the device is first unlocked). Everything is deleted once it has been sent.
///
///   blackbox.json  the current run: protocol `ClientContext` + host/project key (rewritten ~0.5 s after changes)
///   journal.jsonl  the current run's breadcrumbs, screen/route changes and requests since that rewrite,
///                  appended the moment they happen (one "<seq>\t<json>" line each)
///   images.json    the current run's binary images (name, UUID, load address, __TEXT size)
///   crash.record   written by the C signal/exception handlers when the app crashes
///   crashed/<id>/  a crashed run's files, moved aside at the next launch (<id> is its clientReportId)
///   pending/<id>.json  crash reports waiting to be sent (request body + where to send it)
///   prompt.json    SDKs before 0.7: report id + reporter token of a sent crash, until the tester was
///                  asked – moved into the follow-ups (no.reproo/followups.json) by the next configure()
final class CrashStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/ai.uatai of the app. Keeps the SDK's former name: an app updated from an
    /// older build still finds its crashed run, pending reports and unasked prompt there.
    static func standard() -> CrashStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return CrashStore(directory: support.appendingPathComponent("ai.uatai", isDirectory: true))
    }

    var blackBoxURL: URL { directory.appendingPathComponent("blackbox.json") }
    var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }
    var imagesURL: URL { directory.appendingPathComponent("images.json") }
    var recordURL: URL { directory.appendingPathComponent("crash.record") }
    var crashedDirectory: URL { directory.appendingPathComponent("crashed", isDirectory: true) }
    var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    var promptURL: URL { directory.appendingPathComponent("prompt.json") }

    func prepare() throws {
        let manager = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        for url in [directory, crashedDirectory, pendingDirectory] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: protection)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try? root.setResourceValues(values)
    }

    func write(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Called at launch before this run writes anything: when the previous run left a crash record,
    /// moves the record, black box, journal and image list aside so this run cannot overwrite them.
    @discardableResult
    func stashCrashedRun() -> URL? {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: recordURL.path))?[.size] as? NSNumber, size.intValue > 0 else { return nil }
        let run = crashedDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: run, withIntermediateDirectories: true)
            try manager.moveItem(at: recordURL, to: run.appendingPathComponent("crash.record"))
            try? manager.moveItem(at: blackBoxURL, to: run.appendingPathComponent("blackbox.json"))
            try? manager.moveItem(at: journalURL, to: run.appendingPathComponent("journal.jsonl"))
            try? manager.moveItem(at: imagesURL, to: run.appendingPathComponent("images.json"))
            return run
        } catch {
            remove(run)
            return nil
        }
    }

    func crashedRuns() -> [URL] {
        contents(of: crashedDirectory).filter(\.hasDirectoryPath)
    }

    /// Whether every file of a crashed run can be read now. Between a restart and the first unlock they
    /// are there but cannot be – which must not be taken for a run without its record or black box.
    func canRead(run: URL) -> Bool {
        !contents(of: run).contains { url in
            if case .unreadable = ProtectedFiles.read(url) { return true }
            return false
        }
    }

    /// Oldest first.
    func pendingReports() -> [URL] {
        contents(of: pendingDirectory)
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) < modificationDate($1) }
    }

    /// Deletes everything crash capture stored (`configure(captureCrashes: false)`, or the project turned it off).
    func removeAll() {
        remove(directory)
    }

    private func contents(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Keeps the current run's context on disk, so a crash report can tell what the tester did right
/// before the crash. The full context is rewritten debounced (~0.5 s) on a private serial queue,
/// never under the State lock, and atomically – a crash mid-write leaves the previous version. What
/// happens in between – the tap that crashes the app a millisecond later, the response it crashed
/// on – is appended to a journal right away and merged into the context on the next launch.
final class BlackBox {
    static let shared = BlackBox()

    static let writeDelay: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "no.reproo.blackbox", qos: .utility)
    private let lock = NSLock()
    /// One rewrite at a time (snapshot → write → trim), so a later snapshot is always written later.
    private let flushLock = NSLock()
    private var store: CrashStore?
    private var device: [String: Any] = [:]
    private var launchedAt = Date()
    private var scheduled = false
    private var writtenImageCount: UInt32 = 0
    /// The journal: an O_APPEND file, its lines since the last rewrite, the last line's number.
    private var journalFD: Int32 = -1
    private var journalLines: [(seq: UInt64, line: Data)] = []
    private var journalSeq: UInt64 = 0
    /// Bumped on every start(): a rewrite never trims a journal of another start.
    private var generation = 0

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return store != nil
    }

    /// Starts writing this run's black box to `store` (the previous run's files must be stashed first).
    func start(store: CrashStore, launchedAt: Date = Date()) {
        let device = Thread.isMainThread ? MainActor.assumeIsolated { ContextCollector.deviceInfo() } : [:]
        // The previous run's files (it did not crash, or they would have been moved aside) must never be
        // paired with a crash of this run: a crash before the first rewrite would claim that run's
        // release, commit, user and actions – and its load addresses.
        store.remove(store.blackBoxURL)
        store.remove(store.imagesURL)
        // This run's images now, synchronously (cheap): frames of an early crash still resolve correctly.
        let imageCount = _dyld_image_count()
        let imagesWritten = (try? store.write(BinaryImages.document(BinaryImages.loaded()), to: store.imagesURL)) != nil
        let journal = open(store.journalURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        lock.lock()
        if journalFD >= 0 { close(journalFD) }
        self.store = store
        self.launchedAt = launchedAt
        self.device = device
        writtenImageCount = imagesWritten ? imageCount : 0
        journalFD = journal
        journalLines = []
        journalSeq = 0
        generation += 1
        lock.unlock()
        if device.isEmpty {
            DispatchQueue.main.async { self.setDevice(MainActor.assumeIsolated { ContextCollector.deviceInfo() }) }
        }
        scheduleWrite(after: 0)
    }

    /// Once it returns nothing is written any more: a rewrite under way finishes first, so a removal
    /// right after (crash capture turned off) finds every file instead of racing a late write.
    func stop() {
        flushLock.lock()
        defer { flushLock.unlock() }
        lock.lock()
        store = nil
        if journalFD >= 0 { close(journalFD) }
        journalFD = -1
        journalLines = []
        lock.unlock()
    }

    // MARK: Journal

    /// One journal event as JSON (nil while the black box is off, so nothing is encoded for nothing).
    func journalEvent(_ event: [String: Any]) -> Data? {
        guard isEnabled, JSONSerialization.isValidJSONObject(event) else { return nil }
        return try? JSONSerialization.data(withJSONObject: event)
    }

    /// Appends one event to the journal with write(2), right now: a crash a millisecond later still
    /// finds it on disk. Called by State.update under the State lock, so the black box's snapshot
    /// (taken under the same lock) and the journal's line numbers never disagree.
    func appendJournal(_ event: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard journalFD >= 0 else { return }
        journalSeq += 1
        var line = Data("\(journalSeq)\t".utf8)
        line.append(event)
        line.append(0x0A)
        Self.writeAll(journalFD, line)
        journalLines.append((journalSeq, line))
    }

    private func journalMark() -> (seq: UInt64, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (journalSeq, generation)
    }

    /// After a rewrite: the journal keeps only the lines the black box does not contain yet. Replaced
    /// atomically (rename), so a crash in between leaves either journal – the black box records the
    /// last line it contains (journalSeq), so no line is lost or counted twice.
    private func trimJournal(upTo mark: (seq: UInt64, generation: Int), store: CrashStore) {
        lock.lock()
        defer { lock.unlock() }
        guard mark.generation == generation, journalFD >= 0 else { return }
        let rest = journalLines.filter { $0.seq > mark.seq }
        guard rest.count < journalLines.count else { return }
        let temporary = store.journalURL.appendingPathExtension("tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        Self.writeAll(fd, rest.reduce(into: Data()) { $0.append($1.line) })
        guard rename(temporary.path, store.journalURL.path) == 0 else {
            close(fd)
            unlink(temporary.path)
            return
        }
        close(journalFD)
        journalFD = fd
        journalLines = rest
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return }
                pointer += written
                remaining -= written
            }
        }
    }

    func setDevice(_ device: [String: Any]) {
        lock.lock()
        self.device = device
        lock.unlock()
        scheduleWrite()
    }

    func scheduleWrite(after delay: TimeInterval = BlackBox.writeDelay) {
        lock.lock()
        guard store != nil, !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [self] in flush() }
    }

    /// Writes now (on the calling thread). Called by the debounced timer; tests call it directly.
    func flush() {
        flushLock.lock()
        defer { flushLock.unlock() }
        lock.lock()
        scheduled = false
        let store = self.store
        let device = self.device
        let launchedAt = self.launchedAt
        let writtenImageCount = self.writtenImageCount
        lock.unlock()
        guard let store else { return }

        let (state, mark) = State.shared.read { ($0, journalMark()) }
        if let document = Self.document(state: state, device: device, launchedAt: launchedAt, journalSeq: mark.seq),
           (try? store.write(document, to: store.blackBoxURL)) != nil {
            trimJournal(upTo: mark, store: store)
        }
        // Binary images change only when a library is loaded – rewrite the list only then.
        let imageCount = _dyld_image_count()
        if imageCount != writtenImageCount {
            try? store.write(BinaryImages.document(BinaryImages.loaded()), to: store.imagesURL)
            self.lock.lock()
            self.writtenImageCount = imageCount
            self.lock.unlock()
        }
    }

    /// The run's context plus where its crash report goes and the last journal line it contains. Nil before configure().
    static func document(state: State.Values, device: [String: Any], launchedAt: Date, journalSeq: UInt64 = 0, now: Date = Date()) -> [String: Any]? {
        guard let configuration = state.configuration else { return nil }
        let iso = ISO8601DateFormatter()
        return [
            "version": 1,
            "host": configuration.host.absoluteString,
            "projectKey": configuration.projectKey,
            "launchedAt": iso.string(from: launchedAt),
            "writtenAt": iso.string(from: now),
            "journalSeq": journalSeq,
            "context": ContextCollector.build(state: state, device: device, now: now),
        ]
    }
}

/// The crash journal's lines, merged into a crashed run's context on the next launch.
enum Journal {
    /// Shared: ISO8601DateFormatter is thread-safe once configured.
    static let iso = ISO8601DateFormatter()

    /// Lines after `seq` (those the black box does not contain), oldest first. Unreadable lines are skipped.
    static func events(_ data: Data?, after seq: UInt64) -> [[String: Any]] {
        guard let data else { return [] }
        return data.split(separator: 0x0A).compactMap { line -> [String: Any]? in
            guard let tab = line.firstIndex(of: 0x09),
                  let number = UInt64(String(decoding: line[line.startIndex..<tab], as: UTF8.self)), number > seq else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line[line.index(after: tab)...]))) as? [String: Any]
        }
    }

    /// Applies journal events to a protocol `ClientContext`: breadcrumbs and requests appended (within
    /// the SDK's limits), the latest screen and route.
    static func apply(_ events: [[String: Any]], to context: [String: Any]) -> [String: Any] {
        guard !events.isEmpty else { return context }
        var context = context
        var breadcrumbs = context["breadcrumbs"] as? [[String: Any]] ?? []
        var network = context["network"] as? [[String: Any]] ?? []
        for event in events {
            if let breadcrumb = event["breadcrumb"] as? [String: Any] { breadcrumbs.append(breadcrumb) }
            if let request = event["network"] as? [String: Any] { network.append(request) }
            if event.keys.contains("screen") {
                if let screen = event["screen"] as? String { context["screen"] = ["name": screen] } else { context["screen"] = [String: Any]() }
            }
            if event.keys.contains("route") {
                if let route = event["route"] as? String { context["route"] = route } else { context.removeValue(forKey: "route") }
            }
        }
        context["breadcrumbs"] = Array(breadcrumbs.suffix(50))
        context["network"] = Array(network.suffix(RuntimeLimits.networkEvents))
        return context
    }
}

/// A Mach-O image loaded in the process (app executable, debug dylib, frameworks, system libraries).
struct BinaryImage: Equatable {
    /// File name, e.g. "AcmeJakt.debug.dylib", "libswiftCore.dylib".
    let name: String
    let uuid: String?
    /// Address of the Mach-O header (= start of __TEXT).
    let loadAddress: UInt
    /// __TEXT size: addresses in [loadAddress, loadAddress + size) belong to this image.
    let size: UInt
    /// Inside the app bundle (the app's own code – and the statically linked SDK).
    let inApp: Bool

    func contains(_ address: UInt) -> Bool {
        address >= loadAddress && address - loadAddress < size
    }

    var json: [String: Any] {
        var json: [String: Any] = ["name": name, "loadAddress": hex(loadAddress), "size": size, "inApp": inApp]
        if let uuid { json["uuid"] = uuid }
        return json
    }

    init(name: String, uuid: String?, loadAddress: UInt, size: UInt, inApp: Bool) {
        self.name = name
        self.uuid = uuid
        self.loadAddress = loadAddress
        self.size = size
        self.inApp = inApp
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let load = (json["loadAddress"] as? String).flatMap(parseHex),
              let size = (json["size"] as? NSNumber)?.uintValue else { return nil }
        self.init(name: name, uuid: json["uuid"] as? String, loadAddress: load, size: size, inApp: json["inApp"] as? Bool ?? false)
    }
}

enum BinaryImages {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func loaded(bundlePath: String = Bundle.main.bundlePath) -> [BinaryImage] {
        let bundle = withoutPrivatePrefix(bundlePath) + "/"
        var images: [BinaryImage] = []
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let cName = _dyld_get_image_name(index) else { continue }
            let path = String(cString: cName)
            let (uuid, size) = describe(header)
            images.append(BinaryImage(
                name: (path as NSString).lastPathComponent,
                uuid: uuid,
                loadAddress: UInt(bitPattern: header),
                size: size,
                inApp: withoutPrivatePrefix(path).hasPrefix(bundle)
            ))
        }
        return images
    }

    static func document(_ images: [BinaryImage]) -> [String: Any] {
        ["version": 1, "arch": architecture, "images": images.map(\.json)]
    }

    static func images(from document: [String: Any]?) -> [BinaryImage] {
        (document?["images"] as? [[String: Any]] ?? []).compactMap(BinaryImage.init(json:))
    }

    /// LC_UUID (as "95E8FF83-…") and the __TEXT segment size of a loaded image.
    static func describe(_ header: UnsafePointer<mach_header>) -> (uuid: String?, size: UInt) {
        guard header.pointee.magic == MH_MAGIC_64 else { return (nil, 0) }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var uuid: String?
        var size: UInt = 0
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                uuid = UUID(uuid: cursor.loadUnaligned(as: uuid_command.self).uuid).uuidString
            } else if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.loadUnaligned(as: segment_command_64.self)
                let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { size = UInt(segment.vmsize) }
            }
            guard command.cmdsize > 0 else { break }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return (uuid, size)
    }

    /// "/private/var/containers/…" and "/var/containers/…" are the same place.
    private static func withoutPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}

func hex(_ value: UInt) -> String {
    "0x" + String(value, radix: 16)
}

func parseHex(_ text: String) -> UInt? {
    let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? text.dropFirst(2) : Substring(text)
    return UInt(digits, radix: 16)
}
#endif
