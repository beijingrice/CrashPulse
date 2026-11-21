import Foundation

struct BatteryAppUsage: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    var wattHours: Double

    init(row: ProcessRow, wattHours: Double) {
        if let group = ProcessGroup(path: row.path) {
            id = group.id
            name = group.name
        } else {
            id = "unidentified"
            name = "Unidentified processes"
        }
        self.wattHours = wattHours
    }
}

struct BatteryUsageReport: Encodable {
    let startOfDay: Date
    let observedSeconds: Double
    let measuredCPUWattHours: Double
    let apps: [BatteryAppUsage]
}

struct BatteryUsageDay: Codable, Equatable {
    let startOfDay: Date
    var observedSeconds = 0.0
    var measuredCPUWattHours = 0.0
    var apps: [String: BatteryAppUsage] = [:]

    var report: BatteryUsageReport {
        BatteryUsageReport(startOfDay: startOfDay, observedSeconds: observedSeconds,
                           measuredCPUWattHours: measuredCPUWattHours, apps: apps.values.sorted {
            if $0.wattHours != $1.wattHours { return $0.wattHours > $1.wattHours }
            return $0.id < $1.id
        })
    }

    static func current(_ day: Self?, at date: Date, calendar: Calendar) -> Self? {
        guard let day, day.startOfDay == calendar.startOfDay(for: date) else { return nil }
        return day
    }
}

struct BatteryUsageTracker {
    private static let maximumGroups = 2_048
    private let calendar: Calendar
    private let maximumElapsed: Double
    private var previousBatteryScan: Date?
    private(set) var day: BatteryUsageDay?

    init(day: BatteryUsageDay?, intervalSeconds: Int, calendar: Calendar) {
        self.day = day
        self.calendar = calendar
        maximumElapsed = Double(intervalSeconds) * 2
    }

    // Use two complete battery scans and only per-PID intervals that fit between
    // them. Discontinuities are dropped, including the interval over midnight.
    mutating func ingest(_ scan: Snapshot) -> Bool {
        guard let dayInterval = calendar.dateInterval(of: .day, for: scan.sampledAt) else { return false }
        let today = dayInterval.start
        let rolledOver = day.map { $0.startOfDay != today } ?? false
        if rolledOver { day = nil }

        let previous = previousBatteryScan
        let stable = scan.batterySupplyConfirmed == true && scan.powerSupply == .battery && scan.enumerationIssue == nil
        previousBatteryScan = stable ? scan.sampledAt : nil
        guard stable, let previous, previous >= today else { return rolledOver }
        let elapsed = scan.sampledAt.timeIntervalSince(previous)
        guard elapsed > 0, elapsed <= maximumElapsed else { return rolledOver }

        var foundUsableInterval = false
        for row in scan.rows {
            guard let window = row.cpuWindow, window.startedAt >= previous, row.sampledAt >= scan.sampledAt,
                  row.sampledAt < dayInterval.end,
                  window.elapsedSeconds > 0, window.elapsedSeconds <= maximumElapsed,
                  abs(row.sampledAt.timeIntervalSince(window.startedAt) - window.elapsedSeconds) <= 2 else { continue }
            foundUsableInterval = true
            guard let wattHours = row.cpuPower?.intervalWattHours, wattHours > 0 else { continue }
            if day == nil { day = BatteryUsageDay(startOfDay: today) }
            day?.measuredCPUWattHours += wattHours
            let app = BatteryAppUsage(row: row, wattHours: wattHours)
            if let existing = day?.apps[app.id] {
                day?.apps[app.id]?.wattHours = existing.wattHours + wattHours
            } else if (day?.apps.count ?? 0) < Self.maximumGroups {
                day?.apps[app.id] = app
            }
        }

        if foundUsableInterval {
            if day == nil { day = BatteryUsageDay(startOfDay: today) }
            day?.observedSeconds += elapsed
        }
        return rolledOver || foundUsableInterval
    }
}
