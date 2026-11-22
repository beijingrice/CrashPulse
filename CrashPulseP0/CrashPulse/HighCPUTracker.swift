import Foundation

struct HighCPUPolicy: Encodable {
    let thresholdPercent = 80.0
    let minimumDurationSeconds = 30.0
    let retentionSeconds = 7 * 24 * 60 * 60
    let maximumEvents = 512
}

struct HighCPUEvent: Codable, Equatable, Identifiable {
    enum EndReason: String, Codable {
        case belowThreshold, processExited, processMissing, processChanged, sampleUnavailable
        case samplingGap, clockChanged, monitorStopped, monitorInterrupted
    }

    let id: UUID
    let identity: ProcessIdentity
    let processStartTicks: UInt64
    var name: String?
    var path: String?
    let startedAt: Date
    var lastObservedAt: Date
    var observedDurationSeconds: Double
    var peakCPUPercent: Double
    var endReason: EndReason?
    var observedCPUEnergyWattHours: Double? = nil
    var energyObservedDurationSeconds: Double? = nil
    var baselineCPUPercent: Double? = nil
    var triggerThresholdCPUPercent: Double? = nil
    var triggerApp: ProcessGroup? = nil
    var incompleteAppSamples: Bool? = nil
    var forensics: EventEvidence? = nil
    var ignoredAt: Date? = nil
    var backgroundAlert: BackgroundAlertMark? = nil
    // Present only while reading a version 1 history file.
    var observedCPUEnergyJoules: Double? = nil

    mutating func migrateEnergyUnit() {
        if let legacy = observedCPUEnergyJoules, observedCPUEnergyWattHours == nil {
            observedCPUEnergyWattHours = legacy / 3_600
        }
        observedCPUEnergyJoules = nil
    }
}

struct HighCPUTracker {
    private enum Unit: Hashable {
        case process(Int32)
        case app(String)
    }

    private struct Instance: Hashable {
        let identity: ProcessIdentity
        let startTicks: UInt64
    }

    private struct Member {
        let row: ProcessRow
        let identity: ProcessIdentity
        let window: CPUWindow
        let cpu: Double

        var instance: Instance { Instance(identity: identity, startTicks: window.processStartTicks) }

        init(_ row: ProcessRow, identity: ProcessIdentity, window: CPUWindow, cpu: Double) {
            self.row = row
            self.identity = identity
            self.window = window
            self.cpu = cpu
        }
    }

    private struct Reading {
        let app: ProcessGroup?
        let members: [Member]
        let lead: Member
        let startedAt: Date
        let endedAt: Date
        let duration: Double
        let startTicks: UInt64
        let endTicks: UInt64
        let cpu: Double
        let energy: Double?
        let complete: Bool

        var endpoints: [Instance: UInt64] {
            Dictionary(uniqueKeysWithValues: members.map { ($0.instance, $0.window.endTicks) })
        }

        init?(app: ProcessGroup?, members: [Member], complete: Bool) {
            guard let lead = members.max(by: Self.precedes),
                  let startTicks = members.map(\.window.startTicks).max(),
                  let endTicks = members.map(\.window.endTicks).min(), startTicks < endTicks,
                  let startedAt = members.map(\.window.startedAt).max(),
                  let endedAt = members.map(\.row.sampledAt).min(), endedAt > startedAt else { return nil }

            let sharedTicks = Double(endTicks - startTicks)
            let duration = lead.window.elapsedSeconds * sharedTicks / Double(lead.window.endTicks - lead.window.startTicks)
            guard abs(endedAt.timeIntervalSince(startedAt) - duration) <= 2 else { return nil }
            self.app = app
            self.members = members
            self.lead = lead
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.duration = duration
            self.startTicks = startTicks
            self.endTicks = endTicks
            self.complete = complete
            cpu = members.reduce(0) { $0 + $1.cpu }
            let measuredEnergy = members.compactMap { member in
                member.row.cpuPower.map {
                    $0.intervalWattHours * sharedTicks / Double(member.window.endTicks - member.window.startTicks)
                }
            }
            energy = measuredEnergy.isEmpty ? nil : measuredEnergy.reduce(0, +)
        }

        private static func precedes(_ left: Member, _ right: Member) -> Bool {
            if left.cpu != right.cpu { return left.cpu < right.cpu }
            return left.row.pid > right.row.pid
        }

        func continues(_ endpoints: [Instance: UInt64]) -> Bool {
            members.contains { endpoints[$0.instance] == $0.window.startTicks }
        }

        func interruption(_ endpoints: [Instance: UInt64]) -> HighCPUEvent.EndReason {
            members.contains { endpoints[$0.instance] != nil } ? .samplingGap : .processChanged
        }
    }

    private struct Baseline {
        var endpoints: [Instance: UInt64] = [:]
        var seconds = 0.0
        var average = 0.0

        mutating func observe(cpu: Double, seconds elapsed: Double) {
            let weight = elapsed / min(120, seconds + elapsed)
            average += (cpu - average) * weight
            seconds = min(120, seconds + elapsed)
        }
    }

    private struct Streak {
        var event: HighCPUEvent
        var endpoints: [Instance: UInt64]
        var background: BackgroundCPUWindow?
        var backgroundEndTicks: UInt64?
        var alerted = false
    }

    struct AlertScan {
        let foreground: BackgroundForeground
        let mayAlert: (UUID, String) -> Bool
    }

    private struct AppMembers {
        let group: ProcessGroup
        var rows: [ProcessRow] = []
    }

    private struct PathGroup {
        let bundle: ProcessGroup?
    }

    private var streaks: [Unit: Streak] = [:]
    private var baselines: [Unit: Baseline] = [:]
    private var pathGroups: [String: PathGroup] = [:]
    private let policy: HighCPUPolicy
    private let maximumInterval: Double
    private(set) var alerts: [BackgroundCPUAlert] = []

    init(policy: HighCPUPolicy, intervalSeconds: Int) {
        self.policy = policy
        maximumInterval = Double(intervalSeconds * 2)
    }

    mutating func ingest(_ snapshot: Snapshot, alertScan: AlertScan? = nil) -> [HighCPUEvent] {
        alerts.removeAll(keepingCapacity: true)
        guard snapshot.enumerationIssue == nil else { return endAll(.samplingGap) }
        var apps: [String: AppMembers] = [:]
        var updates: [HighCPUEvent] = []
        var next: [Unit: Streak] = [:]
        var observedPaths: [String: PathGroup] = [:]
        observedPaths.reserveCapacity(pathGroups.count)
        var observedBaselines: [Unit: Baseline] = [:]

        for row in snapshot.rows {
            let group = row.path.flatMap { path in
                let cached = observedPaths[path] ?? pathGroups[path] ?? PathGroup(bundle: ProcessGroup.bundle(for: path))
                observedPaths[path] = cached
                return cached.bundle
            }
            if let group {
                apps[group.id, default: AppMembers(group: group)].rows.append(row)
            } else {
                observe(.process(row.pid), app: nil, rows: [row], next: &next,
                        observedBaselines: &observedBaselines, updates: &updates, alertScan: alertScan)
            }
        }

        for app in apps.values {
            observe(.app(app.group.id), app: app.group, rows: app.rows, next: &next,
                    observedBaselines: &observedBaselines, updates: &updates, alertScan: alertScan)
        }
        updates.append(contentsOf: streaks.values.compactMap { finish($0, reason: .processMissing) })
        streaks = next
        baselines = observedBaselines
        pathGroups = observedPaths
        return updates
    }

    private mutating func observe(_ unit: Unit, app: ProcessGroup?, rows: [ProcessRow], next: inout [Unit: Streak],
                                  observedBaselines: inout [Unit: Baseline], updates: inout [HighCPUEvent],
                                  alertScan: AlertScan?) {
        let prior = streaks.removeValue(forKey: unit)
        let members = rows.compactMap(member)
        let complete = members.count == rows.count
        guard let reading = Reading(app: app, members: members, complete: complete) else {
            let reason: HighCPUEvent.EndReason
            if !members.isEmpty {
                reason = .samplingGap
            } else if let row = rows.first, rows.count == 1 {
                reason = endReason(for: row)
            } else if rows.allSatisfy({ $0.state == .exited }) {
                reason = .processExited
            } else {
                reason = .sampleUnavailable
            }
            if let event = finish(prior, reason: reason) { updates.append(event) }
            return
        }

        var continuing = prior
        if let prior, !reading.continues(prior.endpoints) {
            if let event = finish(prior, reason: reading.interruption(prior.endpoints)) { updates.append(event) }
            continuing = nil
        }
        var baseline = baselines[unit].flatMap { reading.continues($0.endpoints) ? $0 : nil } ?? Baseline()
        let established = baseline.seconds >= 15 ? baseline.average : nil
        let threshold = continuing?.event.triggerThresholdCPUPercent
            ?? established.map { max(45, $0 + 35, $0 * 1.5) }
            ?? policy.thresholdPercent
        let endpoints = reading.endpoints
        baseline.endpoints = endpoints
        if reading.complete && reading.cpu < threshold { baseline.observe(cpu: reading.cpu, seconds: reading.duration) }
        observedBaselines[unit] = baseline

        guard reading.cpu >= threshold else {
            let reason: HighCPUEvent.EndReason = reading.complete ? .belowThreshold : .sampleUnavailable
            if let event = finish(continuing, reason: reason) { updates.append(event) }
            return
        }

        var streak = continuing ?? Streak(event: makeEvent(reading, baseline: established, threshold: threshold),
                                           endpoints: endpoints)
        streak.event.lastObservedAt = reading.endedAt
        streak.event.observedDurationSeconds += reading.duration
        streak.event.peakCPUPercent = max(streak.event.peakCPUPercent, reading.cpu)
        if let energy = reading.energy {
            streak.event.observedCPUEnergyWattHours = (streak.event.observedCPUEnergyWattHours ?? 0) + energy
            streak.event.energyObservedDurationSeconds = (streak.event.energyObservedDurationSeconds ?? 0) + reading.duration
        }
        if app != nil {
            streak.event.incompleteAppSamples = (streak.event.incompleteAppSamples ?? false) || !reading.complete
        } else {
            streak.event.name = reading.lead.row.name ?? streak.event.name
            streak.event.path = reading.lead.row.path ?? streak.event.path
        }
        streak.endpoints = endpoints
        if let alert = Self.evaluateAlert(&streak, reading: reading, rows: rows, scan: alertScan) {
            alerts.append(alert)
        }
        if streak.alerted || streak.event.observedDurationSeconds >= policy.minimumDurationSeconds {
            updates.append(streak.event)
        }
        next[unit] = streak
    }

    private static func evaluateAlert(_ streak: inout Streak, reading: Reading, rows: [ProcessRow],
                                      scan: AlertScan?) -> BackgroundCPUAlert? {
        guard !streak.alerted, let scan, reading.complete,
              let appKey = reading.app?.id ?? reading.lead.row.path, appKey.hasPrefix("/"),
              scan.foreground.includesBackground(appKey: appKey, pids: rows.map(\.pid), from: reading.startTicks)
        else {
            streak.background = nil
            streak.backgroundEndTicks = nil
            return nil
        }
        let start = max(reading.startTicks, streak.backgroundEndTicks ?? 0)
        guard start < reading.endTicks else { return nil }
        let seconds = reading.duration * Double(reading.endTicks - start) / Double(reading.endTicks - reading.startTicks)
        if streak.background == nil { streak.background = BackgroundCPUWindow() }
        streak.background?.append(cpu: reading.cpu, seconds: seconds)
        streak.backgroundEndTicks = reading.endTicks
        let name = reading.app?.name ?? reading.lead.row.name ?? (appKey as NSString).lastPathComponent
        guard let alert = streak.background?.alert(eventID: streak.event.id, name: name),
              scan.mayAlert(streak.event.id, appKey) else { return nil }
        streak.event.backgroundAlert = BackgroundAlertMark(appKey: appKey, at: reading.endedAt)
        streak.background = nil
        streak.alerted = true
        return alert
    }

    mutating func endAll(_ reason: HighCPUEvent.EndReason) -> [HighCPUEvent] {
        let updates = streaks.values.compactMap { finish($0, reason: reason) }
        streaks.removeAll(keepingCapacity: true)
        baselines.removeAll(keepingCapacity: true)
        pathGroups.removeAll(keepingCapacity: true)
        return updates
    }

    private func member(_ row: ProcessRow) -> Member? {
        guard let window = row.cpuWindow, let cpu = row.cpuPercent, let identity = row.identity,
              cpu.isFinite, cpu >= 0,
              window.elapsedSeconds.isFinite, window.elapsedSeconds > 0, window.elapsedSeconds <= maximumInterval,
              window.endTicks > window.startTicks else { return nil }
        let wallElapsed = row.sampledAt.timeIntervalSince(window.startedAt)
        guard wallElapsed > 0, abs(wallElapsed - window.elapsedSeconds) <= 2 else { return nil }
        return Member(row, identity: identity, window: window, cpu: cpu)
    }

    private func makeEvent(_ reading: Reading, baseline: Double?, threshold: Double) -> HighCPUEvent {
        let lead = reading.lead
        return HighCPUEvent(id: UUID(), identity: lead.identity, processStartTicks: lead.window.processStartTicks,
                            name: lead.row.name, path: lead.row.path, startedAt: reading.startedAt,
                            lastObservedAt: reading.startedAt, observedDurationSeconds: 0, peakCPUPercent: 0,
                            baselineCPUPercent: baseline, triggerThresholdCPUPercent: threshold, triggerApp: reading.app)
    }

    private func finish(_ streak: Streak?, reason: HighCPUEvent.EndReason) -> HighCPUEvent? {
        guard let streak, streak.alerted || streak.event.observedDurationSeconds >= policy.minimumDurationSeconds
        else { return nil }
        var event = streak.event
        event.endReason = reason
        return event
    }

    private func endReason(for row: ProcessRow) -> HighCPUEvent.EndReason {
        if row.state == .exited { return .processExited }
        if row.issues.contains(where: { $0.category == .identityChanged }) { return .processChanged }
        if row.issues.contains(where: { $0.category == .sleepWake }) { return .samplingGap }
        if let window = row.cpuWindow {
            if window.elapsedSeconds <= 0 || window.elapsedSeconds > maximumInterval { return .samplingGap }
            let wallElapsed = row.sampledAt.timeIntervalSince(window.startedAt)
            if wallElapsed <= 0 || abs(wallElapsed - window.elapsedSeconds) > 2 { return .clockChanged }
        }
        return .sampleUnavailable
    }
}
