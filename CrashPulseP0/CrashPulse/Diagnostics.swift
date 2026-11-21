import Darwin
import Foundation
import Security

struct RunInfo: Codable, Sendable {
    let bundleIdentifier: String
    let appVersion: String?
    let buildNumber: String?
    let configuration: String
    let sandboxEntitlement: Bool?
    let sandboxQueryError: String?
    let pid: Int32
    let effectiveUID: UInt32
    let osVersion: String

    var canRecordHistory: Bool {
        configuration == "Sandbox Off" && sandboxEntitlement == false && effectiveUID != 0
    }

    static func current() -> Self {
        let bundle = Bundle.main
        var sandbox: Bool?
        var queryError: String?
        if let task = SecTaskCreateFromSelf(nil) {
            var error: Unmanaged<CFError>?
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, &error)
            if let error {
                let detail = error.takeRetainedValue()
                let domain = CFErrorGetDomain(detail) as String? ?? "Unknown error domain"
                queryError = "\(domain) (\(CFErrorGetCode(detail)))"
            } else if let value {
                sandbox = value as? Bool
                if sandbox == nil { queryError = "Unexpected entitlement value" }
            } else {
                sandbox = false
            }
        } else {
            queryError = "SecTaskCreateFromSelf failed"
        }

        return Self(bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
                    appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    configuration: bundle.object(forInfoDictionaryKey: "CrashPulseVariant") as? String ?? "Unknown",
                    sandboxEntitlement: sandbox, sandboxQueryError: queryError, pid: getpid(),
                    effectiveUID: geteuid(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

struct DiagnosticReport: Encodable {
    let schemaVersion = 2
    let run: RunInfo
    let intervalSeconds: Int
    let timebase: MachTimebase
    let snapshots: [Snapshot]
    var capturePerformance: CapturePerformance? = nil
    var exitProbePID: Int32? = nil
    var exitProbeWasEnumerated: Bool? = nil
    var knownPIDSnapshots: [Snapshot]? = nil
    var historyError: String? = nil

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct CapturePerformance: Codable {
    let elapsedSeconds: Double
    let cpuPercent: Double
    let peakResidentBytes: Int
}

enum DiagnosticCapture {
    static let intervals = [1, 2, 5, 10]

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 || (4...12).contains(arguments.count),
              let interval = Int(arguments[0]), intervals.contains(interval),
              let count = Int(arguments[1]), (2...12).contains(count) else {
            return usage()
        }
        var probePID: Int32?
        var delay = 0.0
        var knownPIDs: [Int32] = []
        if arguments.count >= 4 {
            guard let pid = Int32(arguments[2]), pid > 0,
                  let seconds = Double(arguments[3]), (0.1...20).contains(seconds) else { return usage() }
            probePID = pid
            delay = seconds
            for value in arguments.dropFirst(4) {
                guard let knownPID = Int32(value), knownPID > 0 else { return usage() }
                knownPIDs.append(knownPID)
            }
        }

        let run = RunInfo.current()
        knownPIDs.append(run.pid)
        var collector = ProcessCollector()
        // Direct reads have their own baselines and never enter enumeration counts.
        var knownCollector = ProcessCollector()
        var snapshots: [Snapshot] = []
        var knownSnapshots: [Snapshot] = []
        var probeWasEnumerated: Bool?
        snapshots.append(collector.collect(afterEnumeration: probePID.map { target in
            return { pids in
                let wasEnumerated = pids.contains(target)
                probeWasEnumerated = wasEnumerated
                if wasEnumerated { Thread.sleep(forTimeInterval: delay) }
            }
        }))
        knownSnapshots.append(knownCollector.collectKnownPIDs(knownPIDs))
        let start = performancePoint()
        let clock = SuspendingClock()
        var deadline = clock.now
        for _ in 1..<count {
            deadline += .seconds(interval)
            let remaining = clock.now.duration(to: deadline)
            if remaining > .zero {
                let (seconds, attoseconds) = remaining.components
                Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
            }
            snapshots.append(collector.collect())
            knownSnapshots.append(knownCollector.collectKnownPIDs(knownPIDs))
        }
        let performance = start.flatMap { first -> CapturePerformance? in
            guard let end = performancePoint(), end.ticks > first.ticks, end.cpuSeconds >= first.cpuSeconds,
                  collector.timebase.isValid else { return nil }
            let elapsed = collector.timebase.nanoseconds(end.ticks - first.ticks) / 1e9
            return CapturePerformance(elapsedSeconds: elapsed, cpuPercent: (end.cpuSeconds - first.cpuSeconds)
                                      * 100 / elapsed, peakResidentBytes: end.peakResidentBytes)
        }
        let report = DiagnosticReport(run: run, intervalSeconds: interval, timebase: collector.timebase,
                                      snapshots: snapshots, capturePerformance: performance,
                                      exitProbePID: probePID, exitProbeWasEnumerated: probeWasEnumerated ?? probePID.map { _ in false },
                                      knownPIDSnapshots: knownSnapshots)
        do {
            try FileHandle.standardOutput.write(contentsOf: report.encoded())
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data("CrashPulse capture: \(error)\n".utf8))
            return EXIT_FAILURE
        }
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("Usage: CrashPulse --capture {1|2|5|10} {2...12} [exit-pid delay-seconds [known-pid ...]]\n".utf8))
        return EX_USAGE
    }

    private static func performancePoint() -> (ticks: UInt64, cpuSeconds: Double, peakResidentBytes: Int)? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let seconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
        let subseconds = (Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)) / 1e6
        return (mach_absolute_time(), seconds + subseconds, usage.ru_maxrss)
    }
}
