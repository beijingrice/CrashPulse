import Foundation

struct ProcessGroup: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String

    init?(path: String?) {
        guard let path, !path.isEmpty else { return nil }
        self = Self.bundle(for: path) ?? Self(id: path, name: (path as NSString).lastPathComponent)
    }

    static func bundle(for path: String?) -> Self? {
        guard let path, let boundary = path.range(of: ".app/Contents/", options: .caseInsensitive) else {
            return nil
        }
        let id = String(path[..<path.index(boundary.lowerBound, offsetBy: 4)])
        let name = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
        return Self(id: id, name: name)
    }

    init(row: ProcessRow) {
        self = Self(path: row.path) ?? Self(pid: row.pid, name: row.name, identity: row.identity)
    }

    init(pid: Int32, name: String?, identity: ProcessIdentity?) {
        let instance = identity.map { ":\($0.startSeconds):\($0.startMicroseconds)" } ?? ""
        self.init(id: "pid:\(pid)\(instance)", name: name ?? "PID \(pid)")
    }

    private init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct ActivityPoint: Codable, Equatable, Identifiable, Sendable {
    var id: Date { at }
    let at: Date
    let measuredCPUPercent: Double?
    let triggerCPUPercent: Double?
}

struct ProcessContribution: Codable, Equatable, Identifiable {
    var id: String { "\(identity.pid):\(processStartTicks)" }
    let identity: ProcessIdentity
    let processStartTicks: UInt64
    let name: String
    let path: String?
    let app: ProcessGroup
    let firstObservedAt: Date
    let lastObservedAt: Date
    let observedSeconds: Double
    let cpuCoreSeconds: Double
    let cpuShare: Double
    let cpuEnergyWattHours: Double?
    let energyObservedSeconds: Double
}

struct EventEvidence: Codable, Equatable {
    enum Basis: String, Codable { case aboveBaseline, observedCPU }
    enum Impact: String, Codable { case activity, review, sustained }

    let suspectedApp: ProcessGroup?
    let basis: Basis
    let impact: Impact
    let topProcesses: [ProcessContribution]
    var suspectedAppCPUShare: Double? = nil
    var suspectedAppCPUWattHours: Double? = nil
    var suspectedAppExtraCPUWattHours: Double? = nil
    let measuredCPUCoreSeconds: Double
    let measuredCPUWattHours: Double?
    let estimatedExtraCPUWattHours: Double?
    let foregroundSamples: Int
    let backgroundSamples: Int
    var batterySamples: Int? = nil
    var pluggedInSamples: Int? = nil
    let before: [ActivityPoint]
    let during: [ActivityPoint]
    let after: [ActivityPoint]
    let afterComplete: Bool
}

struct RecurringActivity: Encodable {
    let app: ProcessGroup
    let events: Int
    let days: Int
}

struct ForensicsTracker {
    static let beforeSeconds: TimeInterval = 30
    static let afterSeconds: TimeInterval = 15
    static let rollingSeconds: TimeInterval = 180
    private static let maxFrames = 192
    private static let maxCases = 24
    private static let maxProcessesPerCase = 4_096
    private static let scanBoundaryTolerance: TimeInterval = 0.5

    fileprivate struct Instance: Hashable {
        let identity: ProcessIdentity
        let startTicks: UInt64
    }

    // Names and paths live once per process instance in `labels`, not in every retained window.
    // A rolling window holds every sampled process, so per-window strings dominated memory.
    fileprivate struct Label {
        var name: String?
        var path: String?
        var bundle: ProcessGroup?
        var lastSeen: Date
    }

    private struct Window {
        let instance: Instance
        let from: Date
        let to: Date
        let seconds: Double
        let cpu: Double
        let energy: Double?

        init?(_ row: ProcessRow, maxElapsed: Double) {
            guard let id = row.identity, let timing = row.cpuWindow, let cpu = row.cpuPercent,
                  cpu.isFinite, cpu >= 0,
                  timing.elapsedSeconds.isFinite, timing.elapsedSeconds > 0, timing.elapsedSeconds <= maxElapsed,
                  row.sampledAt > timing.startedAt,
                  abs(row.sampledAt.timeIntervalSince(timing.startedAt) - timing.elapsedSeconds) <= 2 else { return nil }
            instance = Instance(identity: id, startTicks: timing.processStartTicks)
            from = timing.startedAt
            to = row.sampledAt
            seconds = timing.elapsedSeconds
            self.cpu = cpu
            energy = row.cpuPower?.intervalWattHours
        }
    }

    private struct Frame {
        struct TriggerReading {
            let from: Date
            let to: Date
            let cpu: Double
        }

        let start: Date
        let end: Date
        let windows: [Window]
        let measuredCPU: Double?
        let foregroundAppID: String?
        let supply: PowerSupply?

        func point(triggerCPU: Double? = nil) -> ActivityPoint {
            ActivityPoint(at: end, measuredCPUPercent: measuredCPU, triggerCPUPercent: triggerCPU)
        }

        func triggerReading(_ instance: Instance, app: ProcessGroup?, labels: [Instance: Label]) -> TriggerReading? {
            guard let app else {
                return windows.first { $0.instance == instance }.map {
                    TriggerReading(from: $0.from, to: $0.to, cpu: $0.cpu)
                }
            }
            let members = windows.filter { labels[$0.instance]?.bundle?.id == app.id }
            guard let from = members.map(\.from).max(), let to = members.map(\.to).min(), from < to else {
                return nil
            }
            return TriggerReading(from: from, to: to, cpu: members.reduce(0) { $0 + $1.cpu })
        }
    }

    private struct Measurement {
        var cpu = 0.0
        var seconds = 0.0
        var energy = 0.0
        var energySeconds = 0.0

        mutating func add(_ window: Window, fraction: Double) {
            let elapsed = window.seconds * fraction
            seconds += elapsed
            cpu += window.cpu / 100 * elapsed
            if let wattHours = window.energy {
                energy += wattHours * fraction
                energySeconds += elapsed
            }
        }
    }

    private struct Contributor {
        var name: String?
        var path: String?
        let first: Date
        var last: Date
        var total = Measurement()

        func group(_ instance: Instance) -> ProcessGroup {
            ProcessGroup(path: path) ?? ProcessGroup(pid: instance.identity.pid, name: name, identity: instance.identity)
        }
    }

    private struct Recording {
        var event: HighCPUEvent
        let trigger: Instance
        let baseline: [Instance: Measurement]
        let before: [ActivityPoint]
        let maxElapsed: Double
        let afterWindow: TimeInterval
        var during: [ActivityPoint] = []
        var after: [ActivityPoint] = []
        var contributors: [Instance: Contributor] = [:]
        var total = Measurement()
        var through: Date
        var foreground: [String: Int] = [:]
        var knownForegroundSamples = 0
        var batterySamples = 0
        var pluggedInSamples = 0
        var latestContextPoint: Date?
        var afterComplete = false

        mutating func ingest(_ frame: Frame, labels: [Instance: Label]) {
            if frame.end > through && frame.start < event.lastObservedAt {
                for window in frame.windows {
                    let lower = max(through, window.from)
                    let upper = min(event.lastObservedAt, window.to)
                    guard upper > lower else { continue }
                    let fraction = upper.timeIntervalSince(lower) / window.to.timeIntervalSince(window.from)
                    total.add(window, fraction: fraction)
                    let key = window.instance
                    guard contributors[key] != nil || contributors.count < ForensicsTracker.maxProcessesPerCase else { continue }
                    let label = labels[key]
                    var contribution = contributors[key] ?? Contributor(name: label?.name, path: label?.path,
                                                                         first: lower, last: upper)
                    contribution.name = label?.name ?? contribution.name
                    contribution.path = label?.path ?? contribution.path
                    contribution.last = max(upper, contribution.last)
                    contribution.total.add(window, fraction: fraction)
                    contributors[key] = contribution
                }
            }
            // A scan belongs to the event if it includes an observed trigger interval.
            let triggerWindow = frame.triggerReading(trigger, app: event.triggerApp, labels: labels)
            let point = frame.point(triggerCPU: triggerWindow?.cpu)
            if let triggerWindow, triggerWindow.from >= event.startedAt, triggerWindow.to <= event.lastObservedAt,
               frame.end > (latestContextPoint ?? .distantPast) {
                during.append(point)
                latestContextPoint = frame.end
                if let appID = frame.foregroundAppID {
                    foreground[appID, default: 0] += 1
                    knownForegroundSamples += 1
                }
                if frame.supply == .battery { batterySamples += 1 }
                if frame.supply == .adapter { pluggedInSamples += 1 }
                if during.count > 90 {
                    let last = during.count - 1
                    during = during.enumerated().filter { $0.offset.isMultiple(of: 2) || $0.offset == last }
                        .map(\.element)
                }
            }
            let tolerance = ForensicsTracker.scanBoundaryTolerance
            if event.endReason != nil, frame.end > event.lastObservedAt.addingTimeInterval(tolerance),
               frame.start >= event.lastObservedAt.addingTimeInterval(-tolerance),
               frame.end <= event.lastObservedAt.addingTimeInterval(afterWindow + tolerance),
               frame.end > (after.last?.at ?? .distantPast) {
                after.append(point)
            }
        }

        func evidence() -> EventEvidence {
            struct AppComparison {
                let app: ProcessGroup
                var cpu = 0.0
                var excess = 0.0
                var energy = 0.0
                var extraEnergy = 0.0
                var observedEnergy = false
                var comparableEnergy = false
            }
            var apps: [String: AppComparison] = [:]
            var extraEnergy = 0.0
            var extraEnergyAvailable = false
            var ranked: [ProcessContribution] = []
            for (key, value) in contributors where value.total.cpu > 0 || value.total.energy > 0 {
                let app = value.group(key)
                var metrics = apps[app.id] ?? AppComparison(app: app)
                metrics.cpu += value.total.cpu
                metrics.energy += value.total.energy
                metrics.observedEnergy = metrics.observedEnergy || value.total.energySeconds > 0
                if let prior = baseline[key], prior.seconds >= 10 {
                    metrics.excess += max(0, value.total.cpu - prior.cpu / prior.seconds * value.total.seconds)
                    if prior.energySeconds >= 10 && value.total.energySeconds > 0 {
                        let difference = max(0, value.total.energy
                          - prior.energy / prior.energySeconds * value.total.energySeconds)
                        extraEnergyAvailable = true
                        extraEnergy += difference
                        metrics.extraEnergy += difference
                        metrics.comparableEnergy = true
                    }
                } else {
                    let birth = Date(timeIntervalSince1970: Double(key.identity.startSeconds)
                                     + Double(key.identity.startMicroseconds) / 1e6)
                    if birth >= event.startedAt.addingTimeInterval(-maxElapsed), birth <= event.lastObservedAt {
                        // A new process near the onset can contribute even without a CPU baseline.
                        metrics.excess += value.total.cpu
                        if birth >= event.startedAt && value.total.energySeconds > 0 {
                            extraEnergy += value.total.energy
                            metrics.extraEnergy += value.total.energy
                            metrics.comparableEnergy = true
                            extraEnergyAvailable = true
                        }
                    }
                }
                apps[app.id] = metrics
                ranked.append(ProcessContribution(identity: key.identity, processStartTicks: key.startTicks,
                    name: value.name ?? "PID \(key.identity.pid)", path: value.path, app: app,
                    firstObservedAt: value.first, lastObservedAt: value.last, observedSeconds: value.total.seconds,
                    cpuCoreSeconds: value.total.cpu, cpuShare: total.cpu > 0 ? value.total.cpu / total.cpu : 0,
                    cpuEnergyWattHours: value.total.energySeconds > 0 ? value.total.energy : nil,
                    energyObservedSeconds: value.total.energySeconds))
            }
            let useBaseline = apps.values.contains { $0.excess >= 5 }
            let leading = apps.values.sorted { left, right in
                let lhs = useBaseline ? left.excess : left.cpu
                let rhs = useBaseline ? right.excess : right.cpu
                return lhs == rhs ? left.app.id < right.app.id : lhs > rhs
            }.first
            ranked.sort {
                if $0.cpuCoreSeconds != $1.cpuCoreSeconds { return $0.cpuCoreSeconds > $1.cpuCoreSeconds }
                return $0.id < $1.id
            }
            let front = leading.map { foreground[$0.app.id] ?? 0 } ?? 0
            let back = knownForegroundSamples - front
            let impact: EventEvidence.Impact
            if back >= 2, back > front, useBaseline, event.observedDurationSeconds >= 90 {
                impact = .sustained
            } else if useBaseline, front == 0,
                      (leading?.excess ?? 0) >= 25 || (leading?.extraEnergy ?? 0) >= 0.04 {
                impact = .review
            } else {
                impact = .activity
            }
            return EventEvidence(suspectedApp: leading?.app, basis: useBaseline ? .aboveBaseline : .observedCPU,
                                 impact: impact, topProcesses: Array(ranked.prefix(3)),
                                 suspectedAppCPUShare: leading.flatMap { total.cpu > 0 ? $0.cpu / total.cpu : nil },
                                 suspectedAppCPUWattHours: leading.flatMap { $0.observedEnergy ? $0.energy : nil },
                                 suspectedAppExtraCPUWattHours: leading.flatMap { $0.comparableEnergy ? $0.extraEnergy : nil },
                                 measuredCPUCoreSeconds: total.cpu,
                                 measuredCPUWattHours: total.energySeconds > 0 ? total.energy : nil,
                                 estimatedExtraCPUWattHours: extraEnergyAvailable ? extraEnergy : nil,
                                 foregroundSamples: front, backgroundSamples: back,
                                 batterySamples: batterySamples, pluggedInSamples: pluggedInSamples,
                                 before: before, during: during,
                                 after: after, afterComplete: afterComplete)
        }
    }

    private let maxElapsed: Double
    private let afterWindow: TimeInterval
    private var frames: [Frame] = []
    private var labels: [Instance: Label] = [:]
    private var cases: [UUID: Recording] = [:]

    init(intervalSeconds: Int) {
        maxElapsed = Double(intervalSeconds * 2)
        afterWindow = max(Self.afterSeconds, Double(intervalSeconds * 3))
    }

    var activity: [ActivityPoint] { frames.map { $0.point() } }

    mutating func ingest(_ snapshot: Snapshot, events: [HighCPUEvent]) -> [HighCPUEvent] {
        let windows = snapshot.enumerationIssue == nil ? snapshot.rows.compactMap { Window($0, maxElapsed: maxElapsed) } : []
        let at = max(snapshot.sampledAt, windows.map(\.to).max() ?? snapshot.sampledAt)
        if frames.last.map({ $0.end > at }) == true {
            frames.removeAll(keepingCapacity: true)
            labels.removeAll(keepingCapacity: true)
        }
        if !windows.isEmpty {
            for row in snapshot.rows {
                guard let identity = row.identity, let timing = row.cpuWindow else { continue }
                let key = Instance(identity: identity, startTicks: timing.processStartTicks)
                var label = labels[key] ?? Label(lastSeen: at)
                label.name = row.name ?? label.name
                if let path = row.path, path != label.path {
                    label.path = path
                    label.bundle = ProcessGroup.bundle(for: path)
                }
                label.lastSeen = at
                labels[key] = label
            }
        }
        let foreground = snapshot.foregroundPID.flatMap { pid in
            snapshot.rows.first { $0.pid == pid }.flatMap { ProcessGroup(path: $0.path)?.id }
        }
        frames.append(Frame(start: windows.map(\.from).min() ?? snapshot.sampledAt, end: at, windows: windows,
                            measuredCPU: windows.isEmpty ? nil : windows.reduce(0) { $0 + $1.cpu },
                            foregroundAppID: foreground, supply: snapshot.powerSupply))
        let cutoff = at.addingTimeInterval(-Self.rollingSeconds)
        if let index = frames.firstIndex(where: { $0.end >= cutoff }), index > 0 { frames.removeFirst(index) }
        if frames.count > Self.maxFrames { frames.removeFirst(frames.count - Self.maxFrames) }
        // Every instance in a retained frame was seen at or after that frame's end, so it keeps its label.
        let oldest = frames.first?.end ?? at
        labels = labels.filter { $0.value.lastSeen >= oldest }
        return update(events, at: at, stopping: false)
    }

    mutating func stop(events: [HighCPUEvent], at: Date) -> [HighCPUEvent] {
        update(events, at: at, stopping: true)
    }

    private mutating func update(_ events: [HighCPUEvent], at: Date, stopping: Bool) -> [HighCPUEvent] {
        var updates: [UUID: HighCPUEvent] = [:]
        var changedIDs: Set<UUID> = []
        for event in events {
            changedIDs.insert(event.id)
            if cases[event.id] != nil {
                cases[event.id]?.event = event
            } else if cases.count < Self.maxCases {
                cases[event.id] = start(event)
            } else {
                updates[event.id] = event
            }
        }

        for id in Array(cases.keys) {
            guard var recording = cases.removeValue(forKey: id) else { continue }
            let end = recording.event.lastObservedAt.addingTimeInterval(afterWindow + Self.scanBoundaryTolerance)
            let inAfter = recording.event.endReason != nil
            let previouslyCounted = recording.through
            let previouslyAfter = recording.after.count
            let trailingContext = recording.event.lastObservedAt.addingTimeInterval(1)
            for frame in frames where frame.end > previouslyCounted && frame.end >= recording.event.startedAt {
                if !inAfter && frame.start > trailingContext { break }
                if inAfter && frame.end > end { break }
                recording.ingest(frame, labels: labels)
            }
            recording.through = max(recording.through, recording.event.lastObservedAt)
            let expired = inAfter && at >= end
            recording.afterComplete = expired && recording.after.filter { $0.measuredCPUPercent != nil }.count >= 2
            if changedIDs.contains(id) || recording.after.count != previouslyAfter || expired || stopping {
                recording.event.forensics = recording.evidence()
                updates[id] = recording.event
            }
            if !stopping && !expired { cases[id] = recording }
        }
        return Array(updates.values)
    }

    private func start(_ event: HighCPUEvent) -> Recording {
        let trigger = Instance(identity: event.identity, startTicks: event.processStartTicks)
        let before = event.startedAt.addingTimeInterval(-Self.beforeSeconds)
        var baseline: [Instance: Measurement] = [:]
        for frame in frames where frame.end > before && frame.start < event.startedAt {
            for window in frame.windows {
                let lower = max(before, window.from)
                let upper = min(event.startedAt, window.to)
                guard upper > lower else { continue }
                let fraction = upper.timeIntervalSince(lower) / window.to.timeIntervalSince(window.from)
                baseline[window.instance, default: Measurement()].add(window, fraction: fraction)
            }
        }
        let context = frames.filter { $0.end >= before && $0.end <= event.startedAt }.map { frame in
            frame.point(triggerCPU: frame.triggerReading(trigger, app: event.triggerApp, labels: labels)?.cpu)
        }
        return Recording(event: event, trigger: trigger, baseline: baseline, before: context,
                         maxElapsed: maxElapsed, afterWindow: afterWindow,
                         through: event.startedAt)
    }
}
