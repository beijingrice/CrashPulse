import Darwin
import Dispatch
import Foundation

enum HistoryCommand {
    static func run(_ command: String, arguments: [String]) -> Int32 {
        guard let options = Options(command: command, arguments: arguments) else {
            log("""
            Usage:
              CrashPulseOff --monitor [--interval 1|2|5|10] [--duration seconds] [--history-dir directory]
              CrashPulseOff --history [--history-dir directory]
            """)
            return EX_USAGE
        }

        let run = RunInfo.current()
        guard run.canRecordHistory else {
            log("CPU history requires the Sandbox Off app running as an ordinary user.")
            return EX_NOPERM
        }
        do {
            let directory = try options.directory ?? CPUHistoryStore.defaultDirectory()
            let store = CPUHistoryStore(directory: directory, policy: HighCPUPolicy())
            if command == "--history" {
                var data = try store.report().encoded()
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } else {
                try monitor(store: store, interval: options.interval, duration: options.duration)
            }
            return EXIT_SUCCESS
        } catch {
            log(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private struct Options {
        var interval = 5
        var duration: Int?
        var directory: URL?

        init?(command: String, arguments: [String]) {
            guard arguments.count.isMultiple(of: 2) else { return nil }
            var seen: Set<String> = []
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                let value = arguments[index + 1]
                guard seen.insert(key).inserted else { return nil }
                switch key {
                case "--interval" where command == "--monitor":
                    guard let seconds = Int(value), DiagnosticCapture.intervals.contains(seconds) else { return nil }
                    interval = seconds
                case "--duration" where command == "--monitor":
                    guard let seconds = Int(value), (1...86400).contains(seconds) else { return nil }
                    duration = seconds
                case "--history-dir":
                    guard !value.isEmpty else { return nil }
                    directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
                default:
                    return nil
                }
            }
        }
    }

    private static func monitor(store: CPUHistoryStore, interval: Int, duration: Int?) throws {
        let stopped = DispatchSemaphore(value: 0)
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stopped.signal() }
            source.activate()
            return source
        }
        defer { signals.forEach { $0.cancel() } }

        let recorder = try store.startRecording(intervalSeconds: interval)
        var collector = ProcessCollector()
        let clock = SuspendingClock()
        var deadline = clock.now
        let end = duration.map { deadline + .seconds($0) }
        log("Recording CPU history in \(store.directory.path)")
        do {
            while stopped.wait(timeout: .now()) == .timedOut {
                let snapshot = collector.collect()
                try recorder.ingest(snapshot)
                if let issue = snapshot.enumerationIssue, issue.category == .permissionDenied {
                    throw issue
                }
                deadline += .seconds(interval)
                let now = clock.now
                if deadline <= now { deadline = now + .seconds(interval) }
                let remaining = now.duration(to: min(deadline, end ?? deadline))
                if remaining <= .zero { break }
                let (seconds, attoseconds) = remaining.components
                let wait = Double(seconds) + Double(attoseconds) / 1e18
                if stopped.wait(timeout: .now() + wait) == .success { break }
                if let end, clock.now >= end { break }
            }
        } catch {
            // Preserve the sampling or write error while still attempting a final commit.
            try? recorder.stop()
            throw error
        }
        try recorder.stop()
    }

    static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("CrashPulse: \(message)\n".utf8))
    }
}
