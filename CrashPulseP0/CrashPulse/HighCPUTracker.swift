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
    var forensics: EventEvidence? = nil
    var ignoredAt: Date? = nil
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
    private struct Baseline {
        let identity: ProcessIdentity
        let startTicks: UInt64
        var through: UInt64
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
        var endTicks: UInt64
    }

    private var streaks: [Int32: Streak] = [:]
    private var baselines: [Int32: Baseline] = [:]
    private let policy: HighCPUPolicy
    private let maximumInterval: Double

    init(policy: HighCPUPolicy, intervalSeconds: Int) {
        self.policy = policy
        maximumInterval = Double(intervalSeconds * 2)
    }

    mutating func ingest(_ snapshot: Snapshot) -> [HighCPUEvent] {
        guard snapshot.enumerationIssue == nil else { return endAll(.samplingGap) }
        var updates: [HighCPUEvent] = []
        var next: [Int32: Streak] = [:]
        var observedBaselines: [Int32: Baseline] = [:]
        for row in snapshot.rows {
            let prior = streaks.removeValue(forKey: row.pid)
            guard let window = row.cpuWindow, let cpu = row.cpuPercent, let identity = row.identity else {
                if let ended = finish(prior, reason: endReason(for: row)) { updates.append(ended) }
                continue
            }
            guard window.elapsedSeconds > 0, window.elapsedSeconds <= maximumInterval else {
                if let ended = finish(prior, reason: .samplingGap) { updates.append(ended) }
                continue
            }
            let wallElapsed = row.sampledAt.timeIntervalSince(window.startedAt)
            guard wallElapsed > 0, abs(wallElapsed - window.elapsedSeconds) <= 2 else {
                if let ended = finish(prior, reason: .clockChanged) { updates.append(ended) }
                continue
            }

            var continuing = prior
            if let prior {
                let changed = prior.event.identity != identity || prior.event.processStartTicks != window.processStartTicks
                if changed || prior.endTicks != window.startTicks {
                    if let ended = finish(prior, reason: changed ? .processChanged : .samplingGap) {
                        updates.append(ended)
                    }
                    continuing = nil
                }
            }
            let previousBaseline = baselines[row.pid].flatMap { old in
                old.identity == identity && old.startTicks == window.processStartTicks && old.through == window.startTicks
                    ? old : nil
            }
            var baseline = previousBaseline ?? Baseline(identity: identity, startTicks: window.processStartTicks,
                                                        through: window.startTicks)
            let established = baseline.seconds >= 15 ? baseline.average : nil
            let threshold = continuing?.event.triggerThresholdCPUPercent
                ?? established.map { max(45, $0 + 35, $0 * 1.5) }
                ?? policy.thresholdPercent
            baseline.through = window.endTicks
            if cpu < threshold { baseline.observe(cpu: cpu, seconds: window.elapsedSeconds) }
            observedBaselines[row.pid] = baseline
            guard cpu >= threshold else {
                if let ended = finish(continuing, reason: .belowThreshold) { updates.append(ended) }
                continue
            }
            var streak = continuing ?? makeStreak(row, identity: identity, window: window)
            if continuing == nil {
                streak.event.baselineCPUPercent = established
                streak.event.triggerThresholdCPUPercent = threshold
            }

            streak.event.name = row.name ?? streak.event.name
            streak.event.path = row.path ?? streak.event.path
            streak.event.lastObservedAt = row.sampledAt
            streak.event.observedDurationSeconds += window.elapsedSeconds
            streak.event.peakCPUPercent = max(streak.event.peakCPUPercent, cpu)
            if let power = row.cpuPower {
                streak.event.observedCPUEnergyWattHours = (streak.event.observedCPUEnergyWattHours ?? 0)
                    + power.intervalWattHours
                streak.event.energyObservedDurationSeconds = (streak.event.energyObservedDurationSeconds ?? 0)
                    + window.elapsedSeconds
            }
            streak.endTicks = window.endTicks
            if streak.event.observedDurationSeconds >= policy.minimumDurationSeconds {
                updates.append(streak.event)
            }
            next[row.pid] = streak
        }
        updates.append(contentsOf: streaks.values.compactMap { finish($0, reason: .processMissing) })
        streaks = next
        baselines = observedBaselines
        return updates
    }

    mutating func endAll(_ reason: HighCPUEvent.EndReason) -> [HighCPUEvent] {
        let updates = streaks.values.compactMap { finish($0, reason: reason) }
        streaks.removeAll(keepingCapacity: true)
        baselines.removeAll(keepingCapacity: true)
        return updates
    }

    private func makeStreak(_ row: ProcessRow, identity: ProcessIdentity, window: CPUWindow) -> Streak {
        let event = HighCPUEvent(id: UUID(), identity: identity, processStartTicks: window.processStartTicks,
                                 name: row.name, path: row.path, startedAt: window.startedAt,
                                 lastObservedAt: window.startedAt, observedDurationSeconds: 0, peakCPUPercent: 0)
        return Streak(event: event, endTicks: window.startTicks)
    }

    private func finish(_ streak: Streak?, reason: HighCPUEvent.EndReason) -> HighCPUEvent? {
        guard let streak, streak.event.observedDurationSeconds >= policy.minimumDurationSeconds else { return nil }
        var event = streak.event
        event.endReason = reason
        return event
    }

    private func endReason(for row: ProcessRow) -> HighCPUEvent.EndReason {
        if row.state == .exited { return .processExited }
        if row.issues.contains(where: { $0.category == .identityChanged }) { return .processChanged }
        if row.issues.contains(where: { $0.category == .sleepWake }) { return .samplingGap }
        return .sampleUnavailable
    }
}
