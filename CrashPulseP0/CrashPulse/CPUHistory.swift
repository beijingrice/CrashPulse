import Darwin
import Foundation

struct CPUHistoryReport: Encodable {
    let schemaVersion = 4
    let generatedAt: Date
    let policy: HighCPUPolicy
    let events: [HighCPUEvent]
    let batteryToday: BatteryUsageReport?
    let recurringBackgroundActivity: [RecurringActivity]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct CPUHistoryStore {
    enum StoreError: LocalizedError, Equatable {
        case alreadyMonitoring
        case unsupportedVersion(Int)
        case eventNotFound
        case fileOperation(String, Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyMonitoring:
                "CrashPulse is already recording to this history directory."
            case .unsupportedVersion(let version):
                "The CPU history uses an unsupported format (version \(version))."
            case .eventNotFound:
                "This event is no longer in history."
            case .fileOperation(let operation, let number):
                "\(operation) failed (errno \(number))."
            }
        }
    }

    // A lock file has a persistent inode, while the data file is replaced on each commit.
    final class WriterLock {
        private let descriptor: Int32

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
        }
    }

    fileprivate struct HistoryFile: Codable, Equatable {
        var schemaVersion = 4
        var events: [HighCPUEvent]
        var batteryDay: BatteryUsageDay? = nil
    }

    let directory: URL
    let policy: HighCPUPolicy
    var calendar: Calendar = .autoupdatingCurrent

    var fileURL: URL { directory.appendingPathComponent("cpu-history.json") }

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("CrashPulse", isDirectory: true)
    }

    func startRecording(intervalSeconds: Int, now: Date = Date()) throws -> CPUHistoryRecorder {
        let lock = try lockForWriting()
        let file = try recover(now: now, lock: lock)
        return CPUHistoryRecorder(store: self, lock: lock, file: file, intervalSeconds: intervalSeconds)
    }

    func report(now: Date = Date()) throws -> CPUHistoryReport {
        // Avoid creating a journal on a first read. A running recorder updates it
        // atomically, so readers can use the latest complete file without its lock.
        let file: HistoryFile
        if !FileManager.default.fileExists(atPath: directory.path) {
            file = HistoryFile(events: [])
        } else {
            do {
                file = try recover(now: now, lock: lockForWriting())
            } catch StoreError.alreadyMonitoring {
                // The recording process owns repair. Show whatever records are readable.
                file = try read().file
            }
        }
        return report(file, now: now)
    }

    fileprivate func report(_ file: HistoryFile, now: Date) -> CPUHistoryReport {
        let events = bounded(file.events, now: now)
        let background = events.filter {
            guard let evidence = $0.forensics else { return false }
            return $0.ignoredAt == nil && evidence.backgroundSamples >= 2
                && evidence.backgroundSamples > evidence.foregroundSamples
        }
        let byApp = Dictionary(grouping: background) { $0.forensics?.suspectedApp?.id }
        let recurring = byApp.values.compactMap { entries -> RecurringActivity? in
            guard let app = entries.first?.forensics?.suspectedApp else { return nil }
            let days = Set(entries.map { calendar.startOfDay(for: $0.startedAt) }).count
            guard days >= 2 else { return nil }
            return RecurringActivity(app: app, events: entries.count, days: days)
        }.sorted { $0.events == $1.events ? $0.app.id < $1.app.id : $0.events > $1.events }
        return CPUHistoryReport(generatedAt: now, policy: policy, events: events,
                                batteryToday: BatteryUsageDay.current(file.batteryDay, at: now, calendar: calendar)?.report,
                                recurringBackgroundActivity: recurring)
    }

    func setIgnored(_ ignored: Bool, id: UUID, now: Date = Date()) throws {
        let lock = try lockForWriting()
        var file = try recover(now: now, lock: lock)
        guard let index = file.events.firstIndex(where: { $0.id == id }) else { throw StoreError.eventNotFound }
        file.events[index].ignoredAt = ignored ? now : nil
        try write(file, lock: lock)
    }

    fileprivate func bounded(_ events: [HighCPUEvent], now: Date) -> [HighCPUEvent] {
        let cutoff = now.addingTimeInterval(-Double(policy.retentionSeconds))
        return Array(events.filter { $0.lastObservedAt > cutoff }.sorted {
            if $0.lastObservedAt != $1.lastObservedAt { return $0.lastObservedAt > $1.lastObservedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(policy.maximumEvents))
    }

    fileprivate func write(_ file: HistoryFile, lock: WriterLock) throws {
        let data = try JSONEncoder().encode(file)
        var template = Array(directory.appendingPathComponent(".cpu-history.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw StoreError.fileOperation("Creating history temp file", errno) }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { unlink(temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let result = withExtendedLifetime(lock) { rename(temporary, fileURL.path) }
        guard result == 0 else { throw StoreError.fileOperation("Replacing CPU history", errno) }
    }

    private func lockForWriting() throws -> WriterLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = directory.appendingPathComponent(".cpu-history.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError.fileOperation("Opening the history lock", errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let number = errno
            close(descriptor)
            if number == EWOULDBLOCK { throw StoreError.alreadyMonitoring }
            throw StoreError.fileOperation("Locking the history", number)
        }
        return WriterLock(descriptor: descriptor)
    }

    // Decodes each record separately so that one unreadable entry cannot hide the rest.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct StoredVersion: Decodable {
        let schemaVersion: Int
    }

    private struct StoredHistory: Decodable {
        let events: [Lossy<HighCPUEvent>]
        let batteryDay: Lossy<BatteryUsageDay>?
    }

    /// `damaged` is true when the file or some of its records could not be decoded.
    private func read() throws -> (file: HistoryFile, damaged: Bool) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (HistoryFile(events: []), false)
        }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(StoredVersion.self, from: data).schemaVersion else {
            return (HistoryFile(events: []), true)
        }
        // A newer format is left untouched for the app version that wrote it.
        guard (1...4).contains(version) else { throw StoreError.unsupportedVersion(version) }
        guard let stored = try? decoder.decode(StoredHistory.self, from: data) else {
            return (HistoryFile(events: []), true)
        }
        var events = stored.events.compactMap(\.value)
        for index in events.indices { events[index].migrateEnergyUnit() }
        let batteryDay = stored.batteryDay?.value
        let damaged = events.count != stored.events.count || (stored.batteryDay != nil && batteryDay == nil)
        return (HistoryFile(schemaVersion: version, events: events, batteryDay: batteryDay), damaged)
    }

    private func recover(now: Date, lock: WriterLock) throws -> HistoryFile {
        let (before, damaged) = try read()
        if damaged { try quarantine(now: now, lock: lock) }
        let events = bounded(before.events, now: now).map { event in
            var event = event
            if event.endReason == nil { event.endReason = .monitorInterrupted }
            return event
        }
        let day = BatteryUsageDay.current(before.batteryDay, at: now, calendar: calendar)
        let recovered = HistoryFile(events: events, batteryDay: day)
        if damaged || recovered != before { try write(recovered, lock: lock) }
        return recovered
    }

    // Keep the original bytes beside the journal so recording can resume without losing them.
    private func quarantine(now: Date, lock: WriterLock) throws {
        let stamp = Int(now.timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent("cpu-history.damaged-\(stamp)-\(suffix).json")
        let result = withExtendedLifetime(lock) { rename(fileURL.path, destination.path) }
        guard result == 0 else { throw StoreError.fileOperation("Moving unreadable CPU history", errno) }
        try? FileHandle.standardError.write(contentsOf: Data(
            "CrashPulse: Moved unreadable CPU history to \(destination.path)\n".utf8))
    }
}

final class CPUHistoryRecorder {
    private let store: CPUHistoryStore
    private static let batteryCheckpointSeconds: TimeInterval = 30
    private var lock: CPUHistoryStore.WriterLock?
    private var tracker: HighCPUTracker
    private var forensics: ForensicsTracker
    private var battery: BatteryUsageTracker
    private var events: [HighCPUEvent]
    private var dirty = false
    private var batteryDirty = false
    private var nextBatteryCheckpoint: Date?
    private var nextExpiration: Date?

    fileprivate init(store: CPUHistoryStore, lock: CPUHistoryStore.WriterLock,
                     file: CPUHistoryStore.HistoryFile, intervalSeconds: Int) {
        self.store = store
        self.lock = lock
        events = file.events
        tracker = HighCPUTracker(policy: store.policy, intervalSeconds: intervalSeconds)
        forensics = ForensicsTracker(intervalSeconds: intervalSeconds)
        battery = BatteryUsageTracker(day: file.batteryDay, intervalSeconds: intervalSeconds, calendar: store.calendar)
        nextExpiration = events.last?.lastObservedAt.addingTimeInterval(Double(store.policy.retentionSeconds))
    }

    func ingest(_ snapshot: Snapshot) throws {
        guard let lock else { return }
        let updates = forensics.ingest(snapshot, events: tracker.ingest(snapshot))
        if battery.ingest(snapshot) { batteryDirty = true }
        try commit(updates, now: snapshot.sampledAt, lock: lock)
    }

    func report(now: Date = Date()) -> CPUHistoryReport {
        store.report(.init(events: events, batteryDay: battery.day), now: now)
    }

    var activity: [ActivityPoint] { forensics.activity }

    func setIgnored(_ ignored: Bool, id: UUID, now: Date = Date()) throws {
        guard let lock, let index = events.firstIndex(where: { $0.id == id }) else {
            throw CPUHistoryStore.StoreError.eventNotFound
        }
        events[index].ignoredAt = ignored ? now : nil
        dirty = true
        try commit([], now: now, lock: lock)
    }

    func stop(now: Date = Date()) throws {
        guard let lock else { return }
        defer { self.lock = nil }
        let updates = forensics.stop(events: tracker.endAll(.monitorStopped), at: now)
        try commit(updates, now: now, lock: lock, flushBattery: true)
    }

    private func commit(_ updates: [HighCPUEvent], now: Date, lock: CPUHistoryStore.WriterLock,
                        flushBattery: Bool = false) throws {
        if !updates.isEmpty {
            var changed = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for event in events where changed[event.id] != nil {
                changed[event.id]?.ignoredAt = event.ignoredAt
            }
            events.removeAll { changed[$0.id] != nil }
            events.append(contentsOf: changed.values)
            dirty = true
        }
        if dirty || (nextExpiration.map { $0 <= now } ?? false) {
            let bounded = store.bounded(events, now: now)
            if bounded != events {
                events = bounded
                dirty = true
            }
            nextExpiration = events.last?.lastObservedAt.addingTimeInterval(Double(store.policy.retentionSeconds))
        }
        let untilCheckpoint = nextBatteryCheckpoint?.timeIntervalSince(now) ?? 0
        let batteryDue = batteryDirty && (flushBattery || untilCheckpoint <= 0
                                          || untilCheckpoint > Self.batteryCheckpointSeconds)
        guard dirty || batteryDue else { return }
        try store.write(.init(events: events, batteryDay: battery.day), lock: lock)
        dirty = false
        if batteryDirty {
            batteryDirty = false
            nextBatteryCheckpoint = now.addingTimeInterval(Self.batteryCheckpointSeconds)
        }
    }
}
