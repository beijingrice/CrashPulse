import Darwin
import Foundation

struct MachTimebase: Codable, Sendable {
    let numerator: UInt32
    let denominator: UInt32

    var isValid: Bool { numerator > 0 && denominator > 0 }

    func nanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numerator) / Double(denominator)
    }
}

struct SampleClock: Sendable {
    let awakeTicks: UInt64
    let continuousTicks: UInt64

    func crossedSleep(since earlier: Self, timebase: MachTimebase) -> Bool {
        guard awakeTicks >= earlier.awakeTicks, continuousTicks >= earlier.continuousTicks else {
            return true
        }
        let awake = awakeTicks - earlier.awakeTicks
        let continuous = continuousTicks - earlier.continuousTicks
        // The two clock reads are separate. Ignore small read/scheduling skew.
        return continuous > awake && timebase.nanoseconds(continuous - awake) >= 5_000_000
    }
}

struct ProcessIdentity: Codable, Hashable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct ProcessResources: Codable, Sendable {
    let userTicks: UInt64
    let systemTicks: UInt64
    let startTicks: UInt64
    let residentBytes: UInt64
    let footprintBytes: UInt64
    var cpuEnergyNanojoules: UInt64? = nil
}

enum IssueCategory: String, Codable, Sendable {
    case permissionDenied, exited, partialRead, unexpectedResult, enumerationFull
    case missingIdentity, identityChanged, counterRegression, counterOverflow
    case invalidInterval, timebaseUnavailable, sleepWake, systemError
}

enum ReadStage: String, Codable, Sendable {
    case enumeration, name, path, identity, resources, identityRecheck, cpu
}

struct ReadIssue: Error, Codable, Equatable, Sendable {
    let stage: ReadStage
    let category: IssueCategory
    var errorNumber: Int32? = nil
    var returnValue: Int32? = nil

    static func system(_ stage: ReadStage, _ result: Int32, _ number: Int32) -> Self {
        let category: IssueCategory
        switch number {
        case EPERM, EACCES: category = .permissionDenied
        case ESRCH, ENOENT: category = .exited
        case 0: category = .unexpectedResult
        default: category = .systemError
        }
        return Self(stage: stage, category: category, errorNumber: number == 0 ? nil : number, returnValue: result)
    }
}

struct ProcessRead: Sendable {
    let pid: Int32
    var name: String? = nil
    var path: String? = nil
    var identity: ProcessIdentity? = nil
    var effectiveUID: UInt32? = nil
    var parentPID: UInt32? = nil
    var resources: ProcessResources? = nil
    let clock: SampleClock
    let sampledAt: Date
    var issues: [ReadIssue] = []
}

enum SamplingState: String, Codable, Sendable {
    case sampled, baseline, inaccessible, exited, unavailable

    var label: String {
        switch self {
        case .sampled: "Sampled"
        case .baseline: "Waiting for baseline"
        case .inaccessible: "Inaccessible"
        case .exited: "Exited"
        case .unavailable: "Unavailable"
        }
    }
}

struct CPUWindow: Codable, Equatable, Sendable {
    let processStartTicks: UInt64
    let startTicks: UInt64
    let endTicks: UInt64
    let startedAt: Date
    let elapsedSeconds: Double
}

struct ProcessCPUPower: Codable, Equatable, Sendable {
    let watts: Double
    let intervalWattHours: Double

    init?(before: UInt64?, after: UInt64?, elapsedSeconds: Double) {
        guard let before, let after, after > 0, after >= before,
              elapsedSeconds > 0, elapsedSeconds.isFinite else { return nil }
        intervalWattHours = Double(after - before) / 3.6e12
        watts = intervalWattHours * 3_600 / elapsedSeconds
    }
}

enum PowerSupply: String, Codable, Sendable {
    case adapter, battery, ups
}

struct ProcessRow: Codable, Identifiable, Equatable, Sendable {
    enum ID: Hashable {
        case verified(ProcessIdentity)
        case unverified(Int32)
    }

    var id: ID { identity.map(ID.verified) ?? .unverified(pid) }
    let pid: Int32
    let name: String?
    let path: String?
    let identity: ProcessIdentity?
    let effectiveUID: UInt32?
    let parentPID: UInt32?
    let sampledAt: Date
    let cpuPercent: Double?
    let residentBytes: UInt64?
    let footprintBytes: UInt64?
    let state: SamplingState
    let issues: [ReadIssue]
    var cpuWindow: CPUWindow? = nil
    var cpuPower: ProcessCPUPower? = nil
}

struct Coverage: Codable, Sendable {
    var enumerated = 0
    var identity = 0
    var resource = 0
    var cpu = 0
    var memory = 0
    var baseline = 0
    var failed = 0
    var name = 0
    var path = 0
    var issueCounts: [String: Int] = [:]
}

struct Snapshot: Codable, Sendable {
    let sampledAt: Date
    let scanMilliseconds: Double?
    let coverage: Coverage
    let enumerationIssue: ReadIssue?
    let rows: [ProcessRow]
    var powerSupply: PowerSupply? = nil
    var batterySupplyConfirmed: Bool? = nil
    var foregroundPID: Int32? = nil
}

struct SnapshotInput: Sendable {
    let sampledAt: Date
    let scanMilliseconds: Double?
    let rows: [ProcessRead]
    var enumerationIssue: ReadIssue? = nil
    var resetForWake = false
    var powerSupply: PowerSupply? = nil
    var batterySupplyConfirmed: Bool? = nil
}

struct SamplingEngine {
    let timebase: MachTimebase

    private struct Baseline {
        let identity: ProcessIdentity
        let resources: ProcessResources
        let clock: SampleClock
        let sampledAt: Date
    }

    private var previous: [Int32: Baseline] = [:]

    init(timebase: MachTimebase) {
        self.timebase = timebase
    }

    mutating func sample(_ input: SnapshotInput) -> Snapshot {
        var next: [Int32: Baseline] = [:]
        next.reserveCapacity(input.rows.count)
        var coverage = Coverage()
        coverage.enumerated = input.rows.count
        if let issue = input.enumerationIssue {
            coverage.issueCounts[issue.category.rawValue, default: 0] += 1
        }
        var rows = input.rows.map { read in
            var issues = read.issues
            var cpu: Double?
            var cpuWindow: CPUWindow?
            var cpuPower: ProcessCPUPower?
            var state: SamplingState
            let coreIssues = issues.filter {
                $0.stage == .identity || $0.stage == .identityRecheck || $0.stage == .resources
            }
            let resources = coreIssues.isEmpty && read.identity != nil ? read.resources : nil
            if let resources, let identity = read.identity {
                coverage.resource += 1
                coverage.memory += 1
                state = .baseline
                if input.resetForWake {
                    issues.append(ReadIssue(stage: .cpu, category: .sleepWake))
                } else if let old = previous[read.pid] {
                    if old.identity == identity && old.resources.startTicks == resources.startTicks {
                        switch cpuPercent(from: old, to: resources, at: read.clock) {
                        case .success(let (value, elapsedSeconds)):
                            cpu = value
                            cpuWindow = CPUWindow(processStartTicks: resources.startTicks,
                                                  startTicks: old.clock.awakeTicks, endTicks: read.clock.awakeTicks,
                                                  startedAt: old.sampledAt, elapsedSeconds: elapsedSeconds)
                            cpuPower = ProcessCPUPower(before: old.resources.cpuEnergyNanojoules,
                                                      after: resources.cpuEnergyNanojoules,
                                                      elapsedSeconds: elapsedSeconds)
                            state = .sampled
                        case .failure(let issue):
                            issues.append(issue)
                            if issue.category != .sleepWake {
                                state = .unavailable
                            }
                        }
                    } else {
                        issues.append(ReadIssue(stage: .cpu, category: .identityChanged))
                    }
                }
                next[read.pid] = Baseline(identity: identity, resources: resources, clock: read.clock,
                                          sampledAt: read.sampledAt)
            } else if coreIssues.contains(where: { $0.category == .exited }) {
                state = .exited
            } else if coreIssues.contains(where: { $0.category == .permissionDenied }) {
                state = .inaccessible
            } else {
                state = .unavailable
                if coreIssues.isEmpty {
                    let stage: ReadStage = read.identity == nil ? .identity : .resources
                    let category: IssueCategory = read.identity == nil ? .missingIdentity : .partialRead
                    issues.append(ReadIssue(stage: stage, category: category))
                }
            }

            if read.identity != nil { coverage.identity += 1 }
            if read.name != nil { coverage.name += 1 }
            if read.path != nil { coverage.path += 1 }
            switch state {
            case .sampled: coverage.cpu += 1
            case .baseline: coverage.baseline += 1
            default: coverage.failed += 1
            }
            for category in Set(issues.map(\.category)) {
                coverage.issueCounts[category.rawValue, default: 0] += 1
            }
            return ProcessRow(pid: read.pid, name: read.name, path: read.path,
                              identity: read.identity, effectiveUID: read.effectiveUID, parentPID: read.parentPID,
                              sampledAt: read.sampledAt, cpuPercent: cpu, residentBytes: resources?.residentBytes,
                              footprintBytes: resources?.footprintBytes, state: state, issues: issues,
                              cpuWindow: cpuWindow, cpuPower: cpuPower)
        }
        previous = input.enumerationIssue == nil ? next : [:]
        rows.sort {
            let lhs = $0.cpuPercent ?? -1
            let rhs = $1.cpuPercent ?? -1
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }
        return Snapshot(sampledAt: input.sampledAt, scanMilliseconds: input.scanMilliseconds,
                        coverage: coverage, enumerationIssue: input.enumerationIssue, rows: rows,
                        powerSupply: input.powerSupply, batterySupplyConfirmed: input.batterySupplyConfirmed)
    }

    private func cpuPercent(from old: Baseline, to new: ProcessResources, at clock: SampleClock)
        -> Result<(percent: Double, elapsedSeconds: Double), ReadIssue> {
        guard timebase.isValid else {
            return .failure(ReadIssue(stage: .cpu, category: .timebaseUnavailable))
        }
        guard clock.awakeTicks > old.clock.awakeTicks else {
            return .failure(ReadIssue(stage: .cpu, category: .invalidInterval))
        }
        guard !clock.crossedSleep(since: old.clock, timebase: timebase) else {
            return .failure(ReadIssue(stage: .cpu, category: .sleepWake))
        }
        guard new.userTicks >= old.resources.userTicks, new.systemTicks >= old.resources.systemTicks else {
            return .failure(ReadIssue(stage: .cpu, category: .counterRegression))
        }
        let user = new.userTicks - old.resources.userTicks
        let system = new.systemTicks - old.resources.systemTicks
        let (total, overflow) = user.addingReportingOverflow(system)
        guard !overflow else {
            return .failure(ReadIssue(stage: .cpu, category: .counterOverflow))
        }
        let cpuNanoseconds = timebase.nanoseconds(total)
        let elapsedNanoseconds = timebase.nanoseconds(clock.awakeTicks - old.clock.awakeTicks)
        return .success((100 * cpuNanoseconds / elapsedNanoseconds, elapsedNanoseconds / 1e9))
    }
}
