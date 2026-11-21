import Darwin
import XCTest

final class CPUHistoryTests: XCTestCase {
    private let policy = HighCPUPolicy()
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func sample(from start: Int, to end: Int, cpu: Double = 80, pid: Int32 = 30,
                        birth: UInt64 = 42, machStart: UInt64 = 123, clockAdjustment: Double = 0,
                        energyNanojoules: UInt64? = nil, path: String? = "/tmp/fixture") -> ProcessRow {
        ProcessRow(pid: pid, name: "fixture", path: path,
                   identity: ProcessIdentity(pid: pid, startSeconds: birth, startMicroseconds: 0),
                   effectiveUID: 501, parentPID: nil, sampledAt: at(Double(end) + clockAdjustment),
                   cpuPercent: cpu, residentBytes: 1, footprintBytes: 1, state: .sampled, issues: [],
                   cpuWindow: CPUWindow(processStartTicks: machStart, startTicks: UInt64(start), endTicks: UInt64(end),
                                        startedAt: at(Double(start)), elapsedSeconds: Double(end - start)),
                   cpuPower: ProcessCPUPower(before: 0, after: energyNanojoules, elapsedSeconds: Double(end - start)))
    }

    private func emptyRow(at second: Int, state: SamplingState, issue: ReadIssue? = nil) -> ProcessRow {
        ProcessRow(pid: 30, name: nil, path: nil, identity: nil, effectiveUID: nil, parentPID: nil,
                   sampledAt: at(Double(second)), cpuPercent: nil, residentBytes: nil, footprintBytes: nil,
                   state: state, issues: issue.map { [$0] } ?? [])
    }

    private func snapshot(_ second: Int, rows: [ProcessRow], issue: ReadIssue? = nil,
                          supply: PowerSupply? = nil, confirmedBattery: Bool? = nil) -> Snapshot {
        Snapshot(sampledAt: at(Double(second)), scanMilliseconds: nil, coverage: Coverage(),
                 enumerationIssue: issue, rows: rows, powerSupply: supply,
                 batterySupplyConfirmed: confirmedBattery ?? (supply == .battery))
    }

    private func at(_ seconds: Double) -> Date {
        origin.addingTimeInterval(seconds)
    }

    private func streak() -> (HighCPUTracker, HighCPUEvent?) {
        var tracker = HighCPUTracker(policy: policy, intervalSeconds: 5)
        var event: HighCPUEvent?
        for end in stride(from: 5, through: 30, by: 5) {
            event = tracker.ingest(snapshot(end, rows: [sample(from: end - 5, to: end)])).first
        }
        return (tracker, event)
    }

    private func fixtureStore() throws -> CPUHistoryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return CPUHistoryStore(directory: directory, policy: policy, calendar: calendar)
    }

    private func qualify(_ recorder: CPUHistoryRecorder) throws {
        for end in stride(from: 5, through: 30, by: 5) {
            try recorder.ingest(snapshot(end, rows: [sample(from: end - 5, to: end)]))
        }
    }

    func testThresholdRequiresThirtyActualSecondsAndRecordsPeak() throws {
        var tracker = HighCPUTracker(policy: policy, intervalSeconds: 5)
        for end in [4, 8, 12, 16, 20, 24, 28] {
            let row = sample(from: end - 4, to: end, cpu: end == 20 ? 195 : 80)
            XCTAssertTrue(tracker.ingest(snapshot(end, rows: [row])).isEmpty)
        }
        let event = try XCTUnwrap(tracker.ingest(snapshot(32, rows: [sample(from: 28, to: 32)])).first)
        XCTAssertEqual(event.startedAt, at(0))
        XCTAssertEqual(event.lastObservedAt, at(32))
        XCTAssertEqual(event.observedDurationSeconds, 32)
        XCTAssertEqual(event.peakCPUPercent, 195)
        XCTAssertNil(event.endReason)
    }

    func testBriefSpikeAndDropDoNotCreateEvent() {
        var tracker = HighCPUTracker(policy: policy, intervalSeconds: 5)
        for end in stride(from: 5, through: 50, by: 5) {
            let row = sample(from: end - 5, to: end, cpu: end == 25 ? 79 : 160)
            XCTAssertTrue(tracker.ingest(snapshot(end, rows: [row])).isEmpty)
        }
    }

    func testHistoryDistinguishesObservedEnergyFromMissingSamples() throws {
        var tracker = HighCPUTracker(policy: policy, intervalSeconds: 5)
        var update: HighCPUEvent?
        for end in stride(from: 5, through: 30, by: 5) {
            let row = sample(from: end - 5, to: end,
                             energyNanojoules: end <= 20 ? 10_000_000_000 : nil)
            update = tracker.ingest(snapshot(end, rows: [row])).first
        }
        let event = try XCTUnwrap(update)
        XCTAssertEqual(event.observedDurationSeconds, 30)
        XCTAssertEqual(event.observedCPUEnergyWattHours ?? -1, 40.0 / 3_600, accuracy: 1e-9)
        XCTAssertEqual(event.energyObservedDurationSeconds, 20)
    }

    func testOngoingStreakUpdatesTheSameEventAndClosesOnDrop() throws {
        var (tracker, event) = streak()
        let original = try XCTUnwrap(event)
        event = tracker.ingest(snapshot(35, rows: [sample(from: 30, to: 35, cpu: 190)])).first
        XCTAssertEqual(event?.id, original.id)
        XCTAssertEqual(event?.peakCPUPercent, 190)
        let done = tracker.ingest(snapshot(40, rows: [sample(from: 35, to: 40, cpu: 79)])).first
        XCTAssertEqual(done?.id, original.id)
        XCTAssertEqual(done?.endReason, .belowThreshold)
        XCTAssertEqual(done?.lastObservedAt, at(35))
        XCTAssertEqual(done?.observedDurationSeconds, 35)
        XCTAssertTrue(tracker.ingest(snapshot(45, rows: [])).isEmpty)
    }

    func testProcessReusedPIDCannotExtendExistingEvent() throws {
        for (birth, machStart): (UInt64, UInt64) in [(43, 123), (42, 124)] {
            var (tracker, event) = streak()
            let original = try XCTUnwrap(event)
            let changed = sample(from: 30, to: 35, birth: birth, machStart: machStart)
            let old = tracker.ingest(snapshot(35, rows: [changed])).first
            XCTAssertEqual(old?.endReason, .processChanged)
            XCTAssertEqual(old?.id, original.id)
            for end in stride(from: 40, through: 60, by: 5) {
                let next = sample(from: end - 5, to: end, birth: birth, machStart: machStart)
                event = tracker.ingest(snapshot(end, rows: [next])).first
            }
            let replacement = try XCTUnwrap(event)
            XCTAssertNotEqual(replacement.id, original.id)
            XCTAssertEqual(replacement.startedAt, at(30))
            XCTAssertEqual(replacement.identity.startSeconds, birth)
            XCTAssertEqual(replacement.processStartTicks, machStart)
        }
    }

    func testProcessExitAndDisappearanceKeepLastVerifiedTime() {
        for listed: Bool in [true, false] {
            var (tracker, event) = streak()
            let rows = listed ? [emptyRow(at: 35, state: .exited)] : []
            let ended = tracker.ingest(snapshot(35, rows: rows)).first
            XCTAssertEqual(ended?.id, event?.id)
            XCTAssertEqual(ended?.endReason, listed ? .processExited : .processMissing)
            XCTAssertEqual(ended?.lastObservedAt, at(30))
        }
    }

    func testPermissionFailureSleepAndEnumerationFailureCloseTheEvent() {
        let denied = ReadIssue.system(.resources, -1, EPERM)
        let wake = ReadIssue(stage: .cpu, category: .sleepWake)
        let input: [(Snapshot, HighCPUEvent.EndReason)] = [
            (snapshot(35, rows: [emptyRow(at: 35, state: .inaccessible, issue: denied)]), .sampleUnavailable),
            (snapshot(35, rows: [emptyRow(at: 35, state: .baseline, issue: wake)]), .samplingGap),
            (snapshot(35, rows: [], issue: .system(.enumeration, 0, EIO)), .samplingGap)
        ]
        for (scan, reason) in input {
            var (tracker, event) = streak()
            let result = tracker.ingest(scan)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.id, event?.id)
            XCTAssertEqual(result.first?.endReason, reason)
        }
    }

    func testLongOrNonAdjacentWindowsAndWallClockChangesBreakContinuity() {
        let inputs: [(ProcessRow, HighCPUEvent.EndReason)] = [
            (sample(from: 30, to: 42), .samplingGap),
            (sample(from: 32, to: 37), .samplingGap),
            (sample(from: 30, to: 35, clockAdjustment: -60), .clockChanged)
        ]
        for (row, reason) in inputs {
            var (tracker, event) = streak()
            let result = tracker.ingest(snapshot(42, rows: [row]))
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.id, event?.id)
            XCTAssertEqual(result.first?.endReason, reason)
            XCTAssertEqual(result.first?.lastObservedAt, at(30))
        }
    }

    func testStoreAllowsLiveReadersAndExcludesSecondWriter() throws {
        let store = try fixtureStore()
        XCTAssertTrue(try store.report(now: at(0)).events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        XCTAssertThrowsError(try store.startRecording(intervalSeconds: 5, now: at(0))) {
            XCTAssertEqual($0 as? CPUHistoryStore.StoreError, .alreadyMonitoring)
        }
        try qualify(recorder)
        XCTAssertNil(try XCTUnwrap(store.report(now: at(30)).events.first).endReason)
        try recorder.stop(now: at(31))
        let reopened = CPUHistoryStore(directory: store.directory, policy: policy)
        let records = try reopened.report(now: at(31)).events
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.endReason, .monitorStopped)
        XCTAssertEqual(records.first?.lastObservedAt, at(30))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRecoveryAndRetentionAfterUnexpectedStop() throws {
        let store = try fixtureStore()
        var recorder: CPUHistoryRecorder? = try store.startRecording(intervalSeconds: 5, now: at(0))
        try qualify(XCTUnwrap(recorder))
        recorder = nil

        let recovered = try XCTUnwrap(store.report(now: at(40)).events.first)
        XCTAssertEqual(recovered.endReason, .monitorInterrupted)
        XCTAssertEqual(recovered.lastObservedAt, at(30))
        XCTAssertEqual(try store.report(now: at(30 + Double(policy.retentionSeconds) - 1)).events.count, 1)
        XCTAssertTrue(try store.report(now: at(30 + Double(policy.retentionSeconds))).events.isEmpty)
        XCTAssertTrue(try store.report(now: at(40)).events.isEmpty)
    }

    func testDiskFailureLeavesPendingEventsForRetry() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        for end in stride(from: 5, to: 30, by: 5) {
            try recorder.ingest(snapshot(end, rows: [sample(from: end - 5, to: end)]))
        }
        // A directory in the destination slot makes atomic replacement fail
        // without changing the writer lock or requiring elevated permissions.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try recorder.ingest(snapshot(30, rows: [sample(from: 25, to: 30)])))
        try FileManager.default.removeItem(at: store.fileURL)
        try recorder.ingest(snapshot(35, rows: []))
        let event = try XCTUnwrap(store.report(now: at(35)).events.first)
        XCTAssertEqual(event.endReason, .processMissing)
        XCTAssertEqual(event.observedDurationSeconds, 30)
        try recorder.stop(now: at(35))
    }

    func testUnsupportedHistoryIsNeverOverwritten() throws {
        let store = try fixtureStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: false)
        let original = Data(#"{"schemaVersion":4,"events":[]}"#.utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.startRecording(intervalSeconds: 5, now: at(0))) {
            XCTAssertEqual($0 as? CPUHistoryStore.StoreError, .unsupportedVersion(4))
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    private func damagedCopies(in store: CPUHistoryStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("cpu-history.damaged-") }
    }

    func testCorruptHistoryIsSetAsideAndRecordingResumes() throws {
        let store = try fixtureStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: false)
        let original = Data(#"{"schemaVersion":3,"events":["#.utf8)
        try original.write(to: store.fileURL)

        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        let copies = try damagedCopies(in: store)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)
        try qualify(recorder)
        try recorder.stop(now: at(31))
        XCTAssertEqual(try store.report(now: at(31)).events.count, 1)
        XCTAssertEqual(try damagedCopies(in: store).count, 1)
    }

    func testUnreadableRecordIsSkippedWithoutLosingOthers() throws {
        let store = try fixtureStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: false)
        var recorded = try XCTUnwrap(streak().1)
        recorded.endReason = .monitorStopped
        let event = String(decoding: try JSONEncoder().encode(recorded), as: UTF8.self)
        let original = Data(#"{"schemaVersion":3,"events":[{"unexpected":true},\#(event)],"batteryDay":7}"#.utf8)
        try original.write(to: store.fileURL)

        let report = try store.report(now: at(31))
        XCTAssertEqual(report.events.map(\.id), [recorded.id])
        XCTAssertNil(report.batteryToday)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(damagedCopies(in: store).first)), original)
        // The repaired journal no longer needs to be set aside.
        XCTAssertEqual(try store.report(now: at(31)).events.map(\.id), [recorded.id])
        XCTAssertEqual(try damagedCopies(in: store).count, 1)
    }

    func testLiveReaderSeesReadableRecordsWithoutRepairing() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        var recorded = try XCTUnwrap(streak().1)
        recorded.endReason = .monitorStopped
        let event = String(decoding: try JSONEncoder().encode(recorded), as: UTF8.self)
        try Data(#"{"schemaVersion":3,"events":[\#(event),{"unexpected":true}]}"#.utf8).write(to: store.fileURL)

        XCTAssertEqual(try store.report(now: at(31)).events.map(\.id), [recorded.id])
        XCTAssertTrue(try damagedCopies(in: store).isEmpty)
        try recorder.stop(now: at(31))
    }

    func testBatteryRankingMergesNestedHelpersAndRanksByWattHours() throws {
        var tracker = BatteryUsageTracker(day: nil, intervalSeconds: 5, calendar: calendar)
        XCTAssertFalse(tracker.ingest(snapshot(0, rows: [], supply: .battery)))
        let energy: UInt64 = 36_000_000_000 // 0.01 Wh
        let apps = [
            sample(from: 0, to: 5, pid: 1, energyNanojoules: energy,
                   path: "/Applications/Browser.app/Contents/MacOS/Browser"),
            sample(from: 0, to: 5, pid: 2, energyNanojoules: energy * 2,
                   path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            sample(from: 0, to: 5, pid: 3, energyNanojoules: energy,
                   path: "/Applications/Editor.app/Contents/MacOS/Editor"),
            sample(from: 0, to: 5, pid: 4, energyNanojoules: energy, path: nil)
        ]
        XCTAssertTrue(tracker.ingest(snapshot(5, rows: apps, supply: .battery)))
        let day = try XCTUnwrap(tracker.day?.report)
        XCTAssertEqual(day.observedSeconds, 5)
        XCTAssertEqual(day.measuredCPUWattHours, 0.05, accuracy: 1e-9)
        XCTAssertEqual(day.apps.first?.name, "Browser")
        XCTAssertEqual(day.apps.first?.wattHours ?? -1, 0.03, accuracy: 1e-9)
        XCTAssertTrue(day.apps.contains { $0.name == "Unidentified processes" })
    }

    func testPowerChangesAndSamplingGapsDoNotCountAsBatteryEnergy() throws {
        var tracker = BatteryUsageTracker(day: nil, intervalSeconds: 5, calendar: calendar)
        let sequence: [(Int, Int, PowerSupply?, Bool?)] = [
            (0, 5, .adapter, nil), (5, 10, .battery, nil),
            (10, 15, .battery, false), (15, 20, .battery, nil),
            (20, 25, .ups, nil), (25, 30, nil, nil), (30, 35, .battery, nil),
            (35, 55, .battery, nil)
        ]
        for (start, end, supply, confirmed) in sequence {
            let row = sample(from: start, to: end, energyNanojoules: 36_000_000_000)
            XCTAssertFalse(tracker.ingest(snapshot(end, rows: [row], supply: supply, confirmedBattery: confirmed)))
        }
        XCTAssertNil(tracker.day)
        let row = sample(from: 55, to: 60, energyNanojoules: 36_000_000_000)
        XCTAssertTrue(tracker.ingest(snapshot(60, rows: [row], supply: .battery)))
        XCTAssertEqual(tracker.day?.observedSeconds, 5)
    }

    func testBatteryDayRollsOverWithoutCountingAcrossMidnight() throws {
        let midnight = try XCTUnwrap(calendar.dateInterval(of: .day, for: origin)?.end)
        let end = Int(midnight.timeIntervalSince(origin))
        var tracker = BatteryUsageTracker(day: nil, intervalSeconds: 5, calendar: calendar)
        _ = tracker.ingest(snapshot(end - 10, rows: [], supply: .battery))
        let before = sample(from: end - 10, to: end - 5, energyNanojoules: 36_000_000_000)
        _ = tracker.ingest(snapshot(end - 5, rows: [before], supply: .battery))
        XCTAssertNotNil(tracker.day)
        let crossing = sample(from: end - 5, to: end, energyNanojoules: 72_000_000_000)
        _ = tracker.ingest(snapshot(end, rows: [crossing], supply: .battery))
        XCTAssertNil(tracker.day)
        let today = sample(from: end, to: end + 5, energyNanojoules: 36_000_000_000)
        _ = tracker.ingest(snapshot(end + 5, rows: [today], supply: .battery))
        XCTAssertEqual(tracker.day?.startOfDay, midnight)
        XCTAssertEqual(tracker.day?.measuredCPUWattHours ?? -1, 0.01, accuracy: 1e-9)
    }

    func testBatteryUsageFlushesAtStopAndAccumulatesAcrossRestart() throws {
        let store = try fixtureStore()
        let first = try store.startRecording(intervalSeconds: 5, now: at(0))
        try first.ingest(snapshot(0, rows: [], supply: .battery))
        for end in [5, 10] {
            let row = sample(from: end - 5, to: end, energyNanojoules: 36_000_000_000)
            try first.ingest(snapshot(end, rows: [row], supply: .battery))
        }
        XCTAssertEqual(first.report(now: at(10)).batteryToday?.observedSeconds, 10)
        XCTAssertEqual(try store.report(now: at(10)).batteryToday?.observedSeconds, 5)
        try first.stop(now: at(11))

        let second = try store.startRecording(intervalSeconds: 5, now: at(15))
        let invisible = sample(from: 10, to: 15, energyNanojoules: 360_000_000_000)
        try second.ingest(snapshot(15, rows: [invisible], supply: .battery))
        let visible = sample(from: 15, to: 20, energyNanojoules: 36_000_000_000)
        try second.ingest(snapshot(20, rows: [visible], supply: .battery))
        try second.stop(now: at(21))

        let day = try XCTUnwrap(store.report(now: at(21)).batteryToday)
        XCTAssertEqual(day.observedSeconds, 15)
        XCTAssertEqual(day.measuredCPUWattHours, 0.03, accuracy: 1e-9)
        XCTAssertNil(try store.report(now: at(86_421)).batteryToday)
    }

    func testLegacyJouleHistoryMigratesWithoutLosingExistingEvents() throws {
        struct LegacyFile: Encodable {
            let schemaVersion = 1
            let events: [HighCPUEvent]
        }
        let store = try fixtureStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: false)
        var recorded = try XCTUnwrap(streak().1)
        recorded.observedCPUEnergyJoules = 90
        recorded.energyObservedDurationSeconds = 30
        recorded.endReason = .monitorStopped
        try JSONEncoder().encode(LegacyFile(events: [recorded])).write(to: store.fileURL)
        let report = try store.report(now: at(31))
        XCTAssertEqual(report.events.first?.id, recorded.id)
        XCTAssertEqual(report.events.first?.observedCPUEnergyWattHours ?? -1, 0.025, accuracy: 1e-9)
        let json = try report.encoded()
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("Joules"))
        XCTAssertFalse(try String(contentsOf: store.fileURL, encoding: .utf8).contains("Joules"))
    }

    func testWarmBaselineAvoidsStableWorkloadAndDetectsRelativeChange() throws {
        var steady = HighCPUTracker(policy: policy, intervalSeconds: 5)
        for end in stride(from: 5, through: 60, by: 5) {
            let cpu: Double = end <= 15 ? 70 : 90
            let row = sample(from: end - 5, to: end, cpu: cpu)
            XCTAssertTrue(steady.ingest(snapshot(end, rows: [row])).isEmpty)
        }

        var relative = HighCPUTracker(policy: policy, intervalSeconds: 5)
        var event: HighCPUEvent?
        for end in stride(from: 5, through: 45, by: 5) {
            let cpu: Double = end <= 15 ? 20 : 60
            let row = sample(from: end - 5, to: end, cpu: cpu)
            event = relative.ingest(snapshot(end, rows: [row])).first
        }
        let detected = try XCTUnwrap(event)
        XCTAssertEqual(detected.startedAt, at(15))
        XCTAssertEqual(detected.baselineCPUPercent, 20)
        XCTAssertEqual(detected.triggerThresholdCPUPercent, 55)
    }

    private func comparativeScan(_ end: Int, since start: Int = 0, foregroundPID: Int32 = 31) -> Snapshot {
        let relative = end - start
        let stable = sample(from: end - 5, to: end, cpu: 190, pid: 31, energyNanojoules: 90_000_000_000,
                            path: "/Applications/Editor.app/Contents/MacOS/Editor")
        var rows = [stable]
        if relative <= 60 {
            let app = "/Applications/Browser.app/Contents/"
            rows.append(sample(from: end - 5, to: end, cpu: relative <= 30 ? 5 : 150,
                               energyNanojoules: relative <= 30 ? 1_000_000_000 : 27_000_000_000,
                               path: app + "MacOS/Browser"))
            rows.append(sample(from: end - 5, to: end, cpu: relative <= 30 ? 2 : 35, pid: 32,
                               energyNanojoules: relative <= 30 ? 500_000_000 : 3_000_000_000,
                               path: app + "Frameworks/Renderer.app/Contents/MacOS/Renderer"))
        }
        var observation = snapshot(end, rows: rows, supply: relative <= 45 ? .battery : .adapter)
        observation.foregroundPID = foregroundPID
        return observation
    }

    func testAttributionRanksIncreaseSeparatelyFromTotalAndSurvivesExit() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        for end in stride(from: 5, through: 60, by: 5) {
            try recorder.ingest(comparativeScan(end))
        }
        let active = try XCTUnwrap(recorder.report(now: at(60)).events.first { $0.identity.pid == 30 })
        try recorder.setIgnored(true, id: active.id, now: at(61))
        for end in [65, 70, 75, 80] { try recorder.ingest(comparativeScan(end)) }
        try recorder.stop(now: at(82))

        let report = try store.report(now: at(82))
        let event = try XCTUnwrap(report.events.first { $0.id == active.id })
        let evidence = try XCTUnwrap(event.forensics)
        XCTAssertEqual(event.endReason, .processMissing)
        XCTAssertEqual(event.ignoredAt, at(61))
        XCTAssertEqual(evidence.suspectedApp?.name, "Browser")
        XCTAssertEqual(evidence.basis, .aboveBaseline)
        XCTAssertEqual(evidence.impact, .review)
        XCTAssertEqual(evidence.topProcesses.map { $0.identity.pid }, [31, 30, 32])
        XCTAssertEqual(evidence.topProcesses[2].app.id, evidence.topProcesses[1].app.id)
        XCTAssertEqual(evidence.topProcesses[1].cpuShare, 150.0 / 375, accuracy: 1e-9)
        XCTAssertEqual(evidence.topProcesses[1].firstObservedAt, at(30))
        XCTAssertEqual(evidence.topProcesses[1].lastObservedAt, at(60))
        XCTAssertEqual(evidence.topProcesses[1].cpuEnergyWattHours ?? -1, 0.045, accuracy: 1e-9)
        XCTAssertEqual(evidence.suspectedAppCPUWattHours ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertGreaterThan(evidence.suspectedAppExtraCPUWattHours ?? 0, 0.047)
        XCTAssertEqual(evidence.batterySamples, 3)
        XCTAssertEqual(evidence.pluggedInSamples, 3)
        XCTAssertTrue(evidence.afterComplete)
        XCTAssertTrue(evidence.before.contains { $0.at <= event.startedAt && $0.measuredCPUPercent != nil })
        XCTAssertTrue(evidence.during.contains { $0.triggerCPUPercent == 150 })
        XCTAssertTrue(evidence.after.contains { $0.at > event.lastObservedAt && $0.measuredCPUPercent != nil })
        try store.setIgnored(false, id: event.id, now: at(83))
        XCTAssertNil(try store.report(now: at(83)).events.first { $0.id == active.id }?.ignoredAt)
    }

    func testForegroundWorkIsActivityAndStoppingEarlyPreservesPartialContext() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        for end in stride(from: 5, through: 60, by: 5) {
            try recorder.ingest(comparativeScan(end, foregroundPID: 30))
        }
        try recorder.stop(now: at(61))
        let event = try XCTUnwrap(store.report(now: at(61)).events.first { $0.identity.pid == 30 })
        XCTAssertEqual(event.endReason, .monitorStopped)
        XCTAssertEqual(event.forensics?.impact, .activity)
        XCTAssertEqual(event.forensics?.afterComplete, false)
        XCTAssertGreaterThan(event.forensics?.foregroundSamples ?? 0, 0)
    }

    func testReportsRecurringBackgroundActivityAcrossDays() throws {
        let store = try fixtureStore()
        for offset in [0, 86_400] {
            let recorder = try store.startRecording(intervalSeconds: 5, now: at(Double(offset)))
            for elapsed in stride(from: 5, through: 80, by: 5) {
                try recorder.ingest(comparativeScan(offset + elapsed, since: offset))
            }
            try recorder.stop(now: at(Double(offset + 81)))
        }
        let report = try store.report(now: at(86_482))
        let recurring = try XCTUnwrap(report.recurringBackgroundActivity.first { $0.app.name == "Browser" })
        XCTAssertEqual(recurring.events, 2)
        XCTAssertEqual(recurring.days, 2)
    }

    func testLongEventPreservesCumulativeAttributionAfterRollingFramesExpire() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        for end in stride(from: 5, through: 230, by: 5) {
            let cpu: Double = end <= 30 ? 10 : 120
            try recorder.ingest(snapshot(end, rows: [sample(from: end - 5, to: end, cpu: cpu)]))
        }
        let event = try XCTUnwrap(recorder.report(now: at(230)).events.first)
        let evidence = try XCTUnwrap(event.forensics)
        XCTAssertEqual(event.observedDurationSeconds, 200)
        XCTAssertEqual(evidence.topProcesses.first?.cpuCoreSeconds ?? -1, 240, accuracy: 1e-9)
        XCTAssertNotNil(evidence.before.first { $0.at < event.startedAt })
        XCTAssertFalse(recorder.activity.contains { $0.at < at(50) })
        try recorder.stop(now: at(231))
    }

    func testAComparableEnergyIncreaseCanRaiseReviewPriority() throws {
        let store = try fixtureStore()
        let recorder = try store.startRecording(intervalSeconds: 5, now: at(0))
        for end in stride(from: 5, through: 60, by: 5) {
            let row = sample(from: end - 5, to: end, cpu: end <= 30 ? 20 : 60,
                             energyNanojoules: end <= 30 ? 1_000_000_000 : 30_000_000_000)
            try recorder.ingest(snapshot(end, rows: [row]))
        }
        let evidence = try XCTUnwrap(recorder.report(now: at(60)).events.first?.forensics)
        XCTAssertEqual(evidence.impact, .review)
        XCTAssertEqual(evidence.basis, .aboveBaseline)
        XCTAssertGreaterThan(evidence.estimatedExtraCPUWattHours ?? 0, 0.04)
        try recorder.stop(now: at(61))
    }

}
