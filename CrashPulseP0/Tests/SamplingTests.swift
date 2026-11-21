import Darwin
import XCTest

final class SamplingTests: XCTestCase {
    private let base = MachTimebase(numerator: 125, denominator: 3)

    private func read(pid: Int32 = 42, start: UInt64? = 123, startTicks: UInt64 = 12, ticks: UInt64,
                      continuous: UInt64? = nil, user: UInt64 = 0, system: UInt64 = 0,
                      energy: UInt64? = nil) -> ProcessRead {
        ProcessRead(pid: pid, identity: start.map { ProcessIdentity(pid: pid, startSeconds: $0, startMicroseconds: 5) },
                    resources: ProcessResources(userTicks: user, systemTicks: system, startTicks: startTicks,
                                                residentBytes: 4096, footprintBytes: 2048,
                                                cpuEnergyNanojoules: energy),
                    clock: SampleClock(awakeTicks: ticks, continuousTicks: continuous ?? ticks),
                    sampledAt: Date(timeIntervalSince1970: 100))
    }

    private func scan(_ rows: ProcessRead..., wake: Bool = false) -> SnapshotInput {
        SnapshotInput(sampledAt: Date(timeIntervalSince1970: 100), scanMilliseconds: nil, rows: rows,
                      resetForWake: wake)
    }

    func testFirstSampleHasMemoryAndNoCPU() {
        var engine = SamplingEngine(timebase: base)
        let snapshot = engine.sample(scan(read(ticks: 100, user: 20)))
        XCTAssertNil(snapshot.rows.first?.cpuPercent)
        XCTAssertEqual(snapshot.rows.first?.state, .baseline)
        XCTAssertEqual(snapshot.rows.first?.residentBytes, 4096)
        XCTAssertEqual(snapshot.coverage.baseline, 1)
        XCTAssertEqual(snapshot.coverage.failed, 0)
    }

    func testCPUUsesBothCounterDeltasAndElapsedTime() {
        var engine = SamplingEngine(timebase: base)
        let large = UInt64(1) << 60
        _ = engine.sample(scan(read(ticks: large, user: large, system: large)))
        let row = engine.sample(scan(read(ticks: large + 1000, user: large + 300, system: large + 200))).rows.first
        XCTAssertEqual(row?.cpuPercent ?? -1, 50, accuracy: 0.0001)
        XCTAssertEqual(row?.state, .sampled)
    }

    func testMultithreadedCPUCanExceed100Percent() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(ticks: 1001, user: 1100, system: 400))).rows.first
        XCTAssertEqual(row?.cpuPercent ?? -1, 150, accuracy: 0.0001)
    }

    func testNonIdentityMachTimebaseConversion() {
        XCTAssertEqual(base.nanoseconds(24_000_000), 1_000_000_000, accuracy: 0.0001)
    }

    func testPowerUsesEnergyDeltaAndConvertedElapsedTime() throws {
        var engine = SamplingEngine(timebase: base)
        let first = engine.sample(scan(read(ticks: 24_000_000, energy: 4_000_000_000)))
        XCTAssertNil(first.rows.first?.cpuPower)
        let next = engine.sample(scan(read(ticks: 72_000_000, user: 48_000_000, energy: 9_000_000_000)))
        let power = try XCTUnwrap(next.rows.first?.cpuPower)
        XCTAssertEqual(power.intervalWattHours, 5.0 / 3_600, accuracy: 1e-9)
        XCTAssertEqual(power.watts, 2.5, accuracy: 1e-9)
    }

    func testUnpopulatedOrRegressedEnergyDoesNotHideCPU() {
        let cases: [(UInt64?, UInt64?)] = [(0, 0), (nil, 14), (14, nil), (14, 12)]
        for (first, second) in cases {
            var engine = SamplingEngine(timebase: base)
            _ = engine.sample(scan(read(ticks: 1, energy: first)))
            let snapshot = engine.sample(scan(read(ticks: 11, user: 10, energy: second)))
            XCTAssertNil(snapshot.rows.first?.cpuPower)
            XCTAssertEqual(snapshot.rows.first?.cpuPercent ?? -1, 100, accuracy: 1e-9)
        }
        XCTAssertEqual(ProcessCPUPower(before: 14, after: 14, elapsedSeconds: 1)?.watts, 0)
    }

    func testPowerNeverSpansPIDReuseSleepOrDeniedReads() {
        var denied = read(ticks: 11, energy: 50)
        denied.issues = [.system(.resources, -1, EPERM)]
        let cases: [SnapshotInput] = [
            scan(read(start: 124, ticks: 11, energy: 50)),
            scan(read(ticks: 11, energy: 50), wake: true),
            scan(denied)
        ]
        for input in cases {
            var engine = SamplingEngine(timebase: base)
            _ = engine.sample(scan(read(ticks: 1, energy: 10)))
            XCTAssertNil(engine.sample(input).rows.first?.cpuPower)
        }
    }

    func testTrueIdleWithTwoValidReadsIsZero() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(ticks: 1001))).rows.first
        XCTAssertEqual(row?.cpuPercent, 0)
        XCTAssertEqual(row?.state, .sampled)
    }

    func testCounterRegressionReseedsBaseline() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1, user: 10)))
        let row = engine.sample(scan(read(ticks: 101, user: 9, system: 20))).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertEqual(row?.issues.first?.category, .counterRegression)
        let recovered = engine.sample(scan(read(ticks: 201, user: 19, system: 20))).rows.first
        XCTAssertEqual(recovered?.cpuPercent ?? -1, 10, accuracy: 0.0001)
    }

    func testCounterSumOverflow() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(ticks: 101, user: .max - 1, system: 2))).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertEqual(row?.issues.first?.category, .counterOverflow)
    }

    func testZeroAndBackwardElapsedTime() {
        for secondTime: UInt64 in [100, 99] {
            var engine = SamplingEngine(timebase: base)
            _ = engine.sample(scan(read(ticks: 100)))
            let row = engine.sample(scan(read(ticks: secondTime, user: 10))).rows.first
            XCTAssertNil(row?.cpuPercent)
            XCTAssertEqual(row?.issues.first?.category, .invalidInterval)
        }
    }

    func testPIDReuseWithDifferentBSDStart() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(start: 124, ticks: 101, user: 50))).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertEqual(row?.state, .baseline)
        XCTAssertEqual(row?.issues.first?.category, .identityChanged)
    }

    func testDifferentResourceStartAlsoResetsEvenWithMatchingBSDStart() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(startTicks: 15, ticks: 101, user: 50))).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertEqual(row?.issues.first?.category, .identityChanged)
    }

    func testNewAndDisappearingProcess() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        let next = engine.sample(scan(read(pid: 43, ticks: 101, user: 20)))
        XCTAssertEqual(next.rows.map(\.pid), [43])
        XCTAssertEqual(next.rows.first?.state, .baseline)
        let reappeared = engine.sample(scan(read(ticks: 201, user: 20)))
        XCTAssertEqual(reappeared.rows.first?.state, .baseline)
    }

    func testMissingOrUnrecheckedIdentityRejectsResources() {
        var engine = SamplingEngine(timebase: base)
        let missing = engine.sample(scan(read(start: nil, ticks: 1, user: 20))).rows.first
        XCTAssertNil(missing?.cpuPercent)
        XCTAssertNil(missing?.footprintBytes)
        XCTAssertEqual(missing?.issues.first?.category, .missingIdentity)

        var raced = read(ticks: 101)
        raced.issues = [.init(stage: .identityRecheck, category: .identityChanged)]
        let row = engine.sample(scan(raced)).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertNil(row?.residentBytes)
    }

    func testPermissionFailureBreaksContinuityAndNeverBecomesZero() {
        for number in [EPERM, EACCES] {
            var engine = SamplingEngine(timebase: base)
            _ = engine.sample(scan(read(ticks: 1)))
            var denied = read(ticks: 101)
            denied.resources = nil
            denied.issues = [.system(.resources, -1, number), .system(.path, 0, number)]
            let snapshot = engine.sample(scan(denied))
            XCTAssertEqual(snapshot.rows.first?.state, .inaccessible)
            XCTAssertEqual(snapshot.rows.first?.issues.first?.errorNumber, number)
            XCTAssertNil(snapshot.rows.first?.cpuPercent)
            XCTAssertNil(snapshot.rows.first?.footprintBytes)
            XCTAssertEqual(snapshot.coverage.failed, 1)
            XCTAssertEqual(snapshot.coverage.issueCounts["permissionDenied"], 1)
            XCTAssertEqual(engine.sample(scan(read(ticks: 201))).rows.first?.state, .baseline)
        }
    }

    func testOptionalPathDenialDoesNotDiscardValidResources() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        var next = read(ticks: 101, user: 20)
        next.issues = [.system(.path, 0, EACCES)]
        let row = engine.sample(scan(next)).rows.first
        XCTAssertEqual(row?.cpuPercent ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(row?.state, .sampled)
        XCTAssertNil(row?.path)
    }

    func testFailedAndPartialResourceReadsDiscardMemoryAndCPU() {
        for issue in [ReadIssue(stage: .resources, category: .partialRead), .system(.resources, -1, EIO)] {
            var engine = SamplingEngine(timebase: base)
            _ = engine.sample(scan(read(ticks: 1)))
            var partial = read(ticks: 101, user: 50)
            partial.issues = [issue]
            let snapshot = engine.sample(scan(partial))
            XCTAssertNil(snapshot.rows.first?.cpuPercent)
            XCTAssertNil(snapshot.rows.first?.residentBytes)
            XCTAssertEqual(snapshot.rows.first?.state, .unavailable)
            XCTAssertEqual(snapshot.rows.first?.issues, [issue])
            XCTAssertEqual(snapshot.coverage.identity, 1)
            XCTAssertEqual(snapshot.coverage.resource, 0)
        }
    }

    func testExitedDuringCollection() {
        var engine = SamplingEngine(timebase: base)
        var gone = read(ticks: 100)
        gone.identity = nil
        gone.resources = nil
        gone.issues = [.system(.identity, 0, ESRCH)]
        let snapshot = engine.sample(scan(gone))
        XCTAssertEqual(snapshot.rows.first?.state, .exited)
        XCTAssertNil(snapshot.rows.first?.cpuPercent)
        XCTAssertEqual(snapshot.coverage.enumerated, 1)
    }

    func testWakeNotificationAndClockDiscontinuityResetBaseline() {
        for notified in [true, false] {
            var engine = SamplingEngine(timebase: base)
            let extra: UInt64 = notified ? 0 : 24_000_000
            _ = engine.sample(scan(read(ticks: 100)))
            let wake = engine.sample(scan(read(ticks: 200, continuous: 200 + extra, user: 20), wake: notified))
            XCTAssertNil(wake.rows.first?.cpuPercent)
            XCTAssertEqual(wake.rows.first?.issues.first?.category, .sleepWake)
            let recovered = engine.sample(scan(read(ticks: 300, continuous: 300 + extra, user: 50)))
            XCTAssertEqual(recovered.rows.first?.cpuPercent ?? -1, 30, accuracy: 0.0001)
        }
    }

    func testEnumerationFailureClearsBaseline() {
        var engine = SamplingEngine(timebase: base)
        _ = engine.sample(scan(read(ticks: 1)))
        var failed = scan()
        failed.enumerationIssue = .system(.enumeration, 0, EPERM)
        XCTAssertEqual(engine.sample(failed).coverage.issueCounts["permissionDenied"], 1)
        XCTAssertEqual(engine.sample(scan(read(ticks: 201))).rows.first?.state, .baseline)
    }

    func testInvalidTimebaseDoesNotPublishCPU() {
        var engine = SamplingEngine(timebase: MachTimebase(numerator: 1, denominator: 0))
        _ = engine.sample(scan(read(ticks: 1)))
        let row = engine.sample(scan(read(ticks: 101))).rows.first
        XCTAssertNil(row?.cpuPercent)
        XCTAssertEqual(row?.issues.first?.category, .timebaseUnavailable)
    }
}
