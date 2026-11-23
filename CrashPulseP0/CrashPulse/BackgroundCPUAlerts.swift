import Foundation

enum BackgroundAlertPermission: Equatable {
    case unavailable, notRequested, denied, allowed, quiet

    var allowsDelivery: Bool { self == .allowed || self == .quiet }
}

struct BackgroundAlertMark: Codable, Equatable {
    let appKey: String
    let at: Date
}

struct BackgroundCPUAlert: Sendable {
    enum Level: Sendable { case sustained, severe }

    static let eventIDKey = "eventID"
    static let cooldown: TimeInterval = 15 * 60
    let eventID: UUID
    let name: String
    let level: Level
    let averageCPU: Double
    let seconds: Int

    static func eventID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[eventIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    static func destination(for id: UUID, in history: CPUHistoryReport) -> UUID? {
        history.events.contains { $0.id == id && $0.ignoredAt == nil } ? id : nil
    }
}

/// When each app last raised a background alert. Cooldowns are kept apart from the event history,
/// so clearing or pruning events never shortens one. Entries expire on their own.
struct AlertCooldowns: Codable, Equatable {
    private var lastAlertByApp: [String: Date] = [:]

    func allows(_ appKey: String, at now: Date) -> Bool {
        lastAlertByApp[appKey].map { now.timeIntervalSince($0) >= BackgroundCPUAlert.cooldown } ?? true
    }

    mutating func record(_ appKey: String, at date: Date) {
        lastAlertByApp[appKey] = max(lastAlertByApp[appKey] ?? date, date)
    }

    func pruned(now: Date) -> AlertCooldowns {
        var copy = self
        copy.lastAlertByApp = lastAlertByApp.filter { now.timeIntervalSince($0.value) < BackgroundCPUAlert.cooldown }
        return copy
    }
}

/// Foreground evidence for the scan. Ticks share the CPU sampler's awake clock.
/// `observedSince` is when the frontmost app became known, not when it last changed.
struct BackgroundForeground: Equatable, Sendable {
    let pid: Int32
    let appKey: String
    let observedSince: UInt64
    var graceUntil: [String: UInt64] = [:]

    func includesBackground(appKey candidate: String, pids: [Int32], from start: UInt64) -> Bool {
        candidate != appKey && !pids.contains(pid)
            && start >= observedSince && start >= graceUntil[candidate, default: 0]
    }
}

/// Follows the frontmost app for background alerts. Switching apps keeps every other app's
/// background window: only the app that comes forward stops counting, and the app that left
/// waits out a short grace. An unknown frontmost app ends tracking, because nothing is known
/// about what was in front meanwhile.
struct ForegroundTracker {
    private(set) var current: BackgroundForeground?
    private var departed: [String: UInt64] = [:]
    var graceTicks: UInt64 = 0
    /// Departures stay listed past their grace, so a late sample that started inside it still sees it.
    var retentionTicks: UInt64 = 0

    mutating func update(_ identity: (pid: Int32, key: String)?, now: UInt64) {
        guard let identity else { return reset() }
        guard let previous = current else {
            current = BackgroundForeground(pid: identity.pid, appKey: identity.key, observedSince: now)
            return
        }
        guard previous.pid != identity.pid || previous.appKey != identity.key else { return }
        departed = departed.filter { $0.value &+ retentionTicks > now }
        departed[previous.appKey] = now + graceTicks
        current = BackgroundForeground(pid: identity.pid, appKey: identity.key,
                                       observedSince: previous.observedSince, graceUntil: departed)
    }

    mutating func reset() {
        current = nil
        departed.removeAll(keepingCapacity: true)
    }
}

struct BackgroundCPUWindow {
    private struct Segment {
        let cpu: Double
        var seconds: Double
    }

    private var segments: [Segment] = []
    private var seconds = 0.0

    mutating func append(cpu: Double, seconds duration: Double) {
        segments.append(Segment(cpu: cpu, seconds: duration))
        seconds += duration
        while let first = segments.first, seconds - first.seconds >= 60 {
            seconds -= first.seconds
            segments.removeFirst()
        }
        if seconds > 60 {
            segments[0].seconds -= seconds - 60
            seconds = 60
        }
    }

    func alert(eventID: UUID, name: String) -> BackgroundCPUAlert? {
        if let average = average(over: 20), average >= 250 {
            return BackgroundCPUAlert(eventID: eventID, name: name, level: .severe, averageCPU: average, seconds: 20)
        }
        if let average = average(over: 60), average >= 100 {
            return BackgroundCPUAlert(eventID: eventID, name: name, level: .sustained, averageCPU: average, seconds: 60)
        }
        return nil
    }

    private func average(over duration: Double) -> Double? {
        guard seconds >= duration else { return nil }
        var remaining = duration
        var coreSeconds = 0.0
        for segment in segments.reversed() {
            let used = min(remaining, segment.seconds)
            coreSeconds += segment.cpu * used
            remaining -= used
            if remaining <= 0 { break }
        }
        return coreSeconds / duration
    }
}
