import Darwin
import Foundation
import IOKit.ps

struct ProcessCollector {
    private static let maximumPIDSlots = 1_048_576
    private var pidBuffer: [pid_t] = []
    private var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
    private var pathBuffer = [CChar](repeating: 0, count: Int(CPPathBufferSize))
    private var engine: SamplingEngine

    var timebase: MachTimebase { engine.timebase }

    init() {
        var info = mach_timebase_info_data_t()
        let status = mach_timebase_info(&info)
        engine = SamplingEngine(timebase: MachTimebase(
            numerator: status == KERN_SUCCESS ? info.numer : 0,
            denominator: status == KERN_SUCCESS ? info.denom : 0
        ))
    }

    mutating func collect(resetForWake: Bool = false, afterEnumeration: (([pid_t]) -> Void)? = nil) -> Snapshot {
        let startedOnBattery = Self.powerSupply() == .battery
        let startedAt = Date()
        let start = Self.clock()
        var reads: [ProcessRead] = []
        var error: ReadIssue?
        switch enumeratePIDs() {
        case .success(let count):
            if let afterEnumeration {
                afterEnumeration(Array(pidBuffer.prefix(count)))
            }
            var seen: Set<pid_t> = []
            seen.reserveCapacity(count)
            reads.reserveCapacity(count)
            for index in 0..<count {
                let pid = pidBuffer[index]
                if pid > 0 && seen.insert(pid).inserted {
                    reads.append(readProcess(pid))
                }
            }
        case .failure(let issue):
            error = issue
        }
        return finish(reads, startedAt: startedAt, start: start, issue: error,
                      resetForWake: resetForWake, startedOnBattery: startedOnBattery)
    }

    mutating func collectKnownPIDs(_ pids: [pid_t]) -> Snapshot {
        let startedAt = Date()
        let start = Self.clock()
        let reads = Set(pids).sorted().map { readProcess($0) }
        return finish(reads, startedAt: startedAt, start: start)
    }

    private mutating func finish(_ reads: [ProcessRead], startedAt: Date, start: SampleClock,
                                 issue: ReadIssue? = nil, resetForWake: Bool = false,
                                 startedOnBattery: Bool? = nil) -> Snapshot {
        let end = Self.clock()
        let supply = Self.powerSupply()
        let duration = end.awakeTicks >= start.awakeTicks && timebase.isValid
            ? timebase.nanoseconds(end.awakeTicks - start.awakeTicks) / 1_000_000 : nil
        return engine.sample(SnapshotInput(sampledAt: startedAt, scanMilliseconds: duration, rows: reads,
                                          enumerationIssue: issue,
                                          resetForWake: resetForWake || end.crossedSleep(since: start,
                                                                                       timebase: timebase),
                                          powerSupply: supply,
                                          batterySupplyConfirmed: startedOnBattery.map { $0 && supply == .battery }))
    }

    private mutating func enumeratePIDs() -> Result<Int, ReadIssue> {
        let width = MemoryLayout<pid_t>.stride
        if pidBuffer.isEmpty {
            errno = 0
            let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            let errorNumber = errno
            guard estimate > 0 else { return .failure(.system(.enumeration, estimate, errorNumber)) }
            guard Int(estimate).isMultiple(of: width) else {
                return .failure(ReadIssue(stage: .enumeration, category: .partialRead, returnValue: estimate))
            }
            let capacity = min(Self.maximumPIDSlots, max(256, Int(estimate) / width + 64))
            pidBuffer = [pid_t](repeating: 0, count: capacity)
        }

        while true {
            let byteCapacity = pidBuffer.count * width
            // proc_listallpids wraps this call and divides by sizeof(pid_t).
            // The byte count allows explicit validation before indexing.
            let (bytes, errorNumber) = pidBuffer.withUnsafeMutableBufferPointer { buffer in
                errno = 0
                let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(byteCapacity))
                return (result, errno)
            }
            guard bytes > 0 else { return .failure(.system(.enumeration, bytes, errorNumber)) }
            guard bytes <= byteCapacity else {
                return .failure(ReadIssue(stage: .enumeration, category: .unexpectedResult, returnValue: bytes))
            }
            guard Int(bytes).isMultiple(of: width) else {
                return .failure(ReadIssue(stage: .enumeration, category: .partialRead, returnValue: bytes))
            }
            if bytes < byteCapacity { return .success(Int(bytes) / width) }
            guard pidBuffer.count < Self.maximumPIDSlots else {
                return .failure(ReadIssue(stage: .enumeration, category: .enumerationFull))
            }
            pidBuffer = [pid_t](repeating: 0, count: min(Self.maximumPIDSlots, pidBuffer.count * 2))
        }
    }

    private mutating func readProcess(_ pid: pid_t) -> ProcessRead {
        let before = Self.readIdentity(pid, stage: .identity)
        let name = Self.readText(pid, stage: .name, function: proc_name, buffer: &nameBuffer)
        let path = Self.readText(pid, stage: .path, function: proc_pidpath, buffer: &pathBuffer)
        let resources = Self.readResources(pid)
        let clock = Self.clock()
        let sampledAt = Date()
        var read = ProcessRead(pid: pid, clock: clock, sampledAt: sampledAt)
        switch name {
        case .success(let value): read.name = value
        case .failure(let issue): read.issues.append(issue)
        }
        switch path {
        case .success(let value): read.path = value
        case .failure(let issue): read.issues.append(issue)
        }
        if case .failure(let issue) = resources { read.issues.append(issue) }
        switch before {
        case .failure(let issue):
            read.issues.append(issue)
        case .success(let first):
            switch Self.readIdentity(pid, stage: .identityRecheck) {
            case .failure(let issue):
                read.issues.append(issue)
            case .success(let last):
                if last.pbi_start_tvsec == first.pbi_start_tvsec && last.pbi_start_tvusec == first.pbi_start_tvusec {
                    read.identity = ProcessIdentity(pid: pid, startSeconds: first.pbi_start_tvsec,
                                                   startMicroseconds: first.pbi_start_tvusec)
                    read.effectiveUID = last.pbi_uid
                    read.parentPID = last.pbi_ppid
                    if case .success(let value) = resources { read.resources = value }
                } else {
                    read.name = nil
                    read.path = nil
                    read.issues.append(ReadIssue(stage: .identityRecheck, category: .identityChanged))
                }
            }
        }
        return read
    }

    private static func readIdentity(_ pid: pid_t, stage: ReadStage) -> Result<proc_bsdinfo, ReadIssue> {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let errorNumber = errno
        guard result > 0 else { return .failure(.system(stage, result, errorNumber)) }
        guard result == size else {
            let category: IssueCategory = result < size ? .partialRead : .unexpectedResult
            return .failure(ReadIssue(stage: stage, category: category, returnValue: result))
        }
        guard info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
            return .failure(ReadIssue(stage: stage, category: .missingIdentity, returnValue: result))
        }
        return .success(info)
    }

    private static func readText(_ pid: pid_t, stage: ReadStage,
                                 function: (pid_t, UnsafeMutableRawPointer?, UInt32) -> Int32,
                                 buffer: inout [CChar]) -> Result<String, ReadIssue> {
        buffer.withUnsafeMutableBufferPointer { bytes in
            bytes[0] = 0
            errno = 0
            let result = function(pid, bytes.baseAddress, UInt32(bytes.count))
            let errorNumber = errno
            guard result > 0 else { return .failure(.system(stage, result, errorNumber)) }
            guard result < bytes.count else {
                return .failure(ReadIssue(stage: stage, category: .unexpectedResult, returnValue: result))
            }
            // libproc returns the length of the string excluding the terminator.
            guard bytes[Int(result)] == 0, bytes[0] != 0 else {
                return .failure(ReadIssue(stage: stage, category: .partialRead, returnValue: result))
            }
            let text = UnsafeRawBufferPointer(start: bytes.baseAddress, count: Int(result))
            return .success(String(decoding: text, as: UTF8.self))
        }
    }

    private static func readResources(_ pid: pid_t) -> Result<ProcessResources, ReadIssue> {
        // The status-only API has no byte count. Reject untouched fields on an
        // apparent success. These sentinels are outside usable field values.
        var usage = rusage_info_v0()
        usage.ri_user_time = .max
        usage.ri_system_time = .max
        usage.ri_proc_start_abstime = .max
        usage.ri_proc_exit_abstime = .max
        usage.ri_resident_size = .max
        usage.ri_phys_footprint = .max
        var energy: UInt64 = .max
        errno = 0
        let result = CPReadResources(pid, &usage, &energy)
        let errorNumber = errno
        guard result == 0 else {
            guard result == -1 else {
                return .failure(ReadIssue(stage: .resources, category: .unexpectedResult, returnValue: result))
            }
            return .failure(.system(.resources, result, errorNumber))
        }
        guard usage.ri_user_time != .max, usage.ri_system_time != .max,
              usage.ri_proc_start_abstime != .max, usage.ri_proc_exit_abstime != .max,
              usage.ri_resident_size != .max, usage.ri_phys_footprint != .max else {
            return .failure(ReadIssue(stage: .resources, category: .partialRead))
        }
        guard usage.ri_proc_exit_abstime == 0 else {
            return .failure(ReadIssue(stage: .resources, category: .exited))
        }
        guard usage.ri_proc_start_abstime > 0 else {
            return .failure(ReadIssue(stage: .resources, category: .missingIdentity))
        }
        return .success(ProcessResources(userTicks: usage.ri_user_time, systemTicks: usage.ri_system_time,
                                         startTicks: usage.ri_proc_start_abstime,
                                         residentBytes: usage.ri_resident_size,
                                         footprintBytes: usage.ri_phys_footprint,
                                         cpuEnergyNanojoules: energy == .max ? nil : energy))
    }

    static func clock() -> SampleClock {
        SampleClock(awakeTicks: mach_absolute_time(), continuousTicks: mach_continuous_time())
    }

    private static func powerSupply() -> PowerSupply? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return nil
        }
        switch source {
        case kIOPMACPowerKey: return .adapter
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return nil
        }
    }
}
