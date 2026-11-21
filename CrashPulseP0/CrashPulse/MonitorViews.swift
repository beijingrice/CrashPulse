import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct MenuMonitorView: View {
    @ObservedObject var model: MonitorModel
    let openSettings: () -> Void

    private enum Section: String {
        case battery = "Overview"
        case live = "Live"
        case history = "Events"
    }

    private struct HistoryRefresh: Equatable {
        let section: Section
        let latestScan: Date?
    }

    private enum Order: String, CaseIterable {
        case power = "Power"
        case cpu = "CPU"
    }

    @State private var section: Section
    @State private var order = Order.power
    @State private var showingAll = false
    @State private var search = ""
    @State private var expandedGroups: Set<String> = []
    @State private var selectedEvent: UUID?
    @State private var showIgnored = false
    @State private var eventActionError: String?
    @State private var report: CPUHistoryReport?
    @State private var historyReadError: String?
    private let memoryStyle = ByteCountFormatStyle(style: .memory)

    init(model: MonitorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        _section = State(initialValue: model.run.canRecordHistory ? .history : .live)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            if model.run.canRecordHistory {
                Picker("View", selection: $section) {
                    Text(Section.history.rawValue).tag(Section.history)
                    Text(Section.battery.rawValue).tag(Section.battery)
                    Text(Section.live.rawValue).tag(Section.live)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            switch section {
            case .battery: overview
            case .live: live
            case .history: history
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .task(id: historyRefresh) {
            if historyRefresh != nil { await refreshHistory() }
        }
    }

    private var historyRefresh: HistoryRefresh? {
        guard model.panelVisible, section != .live else { return nil }
        return HistoryRefresh(section: section, latestScan: model.snapshot?.sampledAt)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("CrashPulse")
                    .font(.system(size: 17, weight: .semibold))
                Label(status, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button {
                model.setMonitoring(!model.monitoringEnabled)
            } label: {
                Image(systemName: model.monitoringEnabled ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 23)
            }
            .buttonStyle(.borderless)
            .help(model.monitoringEnabled ? "Pause monitoring" : "Resume monitoring")
            .accessibilityLabel(model.monitoringEnabled ? "Pause monitoring" : "Resume monitoring")
        }
    }

    private var status: String {
        if !model.monitoringEnabled { return "Paused" }
        guard let snapshot = model.snapshot else { return "Starting" }
        if snapshot.enumerationIssue != nil { return "Process access unavailable" }
        switch snapshot.powerSupply {
        case .adapter: return "Plugged in"
        case .battery: return "On battery"
        case .ups: return "On UPS"
        case nil: return "Monitoring"
        }
    }

    private var statusSymbol: String {
        if !model.monitoringEnabled { return "pause.circle" }
        switch model.snapshot?.powerSupply {
        case .adapter: return "powerplug"
        case .battery: return "battery.75percent"
        case .ups: return "bolt.fill"
        case nil: return "circle.dotted"
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            HStack {
                if let sampled = model.activity.last?.measuredCPUPercent {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Measured CPU now").font(.caption).foregroundStyle(.secondary)
                        Text(percent(sampled)).font(.headline).monospacedDigit()
                    }
                }
                Spacer()
                if let report {
                    let today = report.events.filter {
                        $0.ignoredAt == nil && Calendar.current.isDate($0.startedAt, inSameDayAs: report.generatedAt)
                    }.count
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("CPU events today").font(.caption).foregroundStyle(.secondary)
                        Text(today.formatted()).font(.headline).monospacedDigit()
                    }
                }
            }
            .padding(16)
            Divider()
            if let report {
                if let latest = report.events.first(where: { $0.ignoredAt == nil }) {
                    Button {
                        selectedEvent = latest.id
                        section = .history
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest CPU event").font(.caption).foregroundStyle(.secondary)
                                Text(eventName(latest)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    Divider()
                }
            }
            batteryToday
        }
    }

    private var batteryToday: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let historyReadError {
                notice("Battery history unavailable", icon: "exclamationmark.circle", message: historyReadError)
            } else if let report {
                if let day = report.batteryToday, let leader = day.apps.first {
                    batterySummary(day, leader: leader)
                } else if report.batteryToday != nil {
                    notice("No app energy readings yet", icon: "battery.50percent",
                           message: "CrashPulse saw battery activity and is waiting for usable CPU energy readings.")
                } else {
                    notice("No battery use recorded today", icon: "battery.75percent",
                           message: "Leave monitoring on while unplugged. App usage will appear after two battery samples.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .padding(16)
    }

    private func batterySummary(_ day: BatteryUsageReport, leader: BatteryAppUsage) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top CPU drain on battery").font(.caption).foregroundStyle(.secondary)
                    Text(leader.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text("\(batteryShare(leader, of: day)) of measured CPU energy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(energy(leader.wattHours))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(11)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            ForEach(Array(day.apps.dropFirst().prefix(5))) { app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(batteryShare(app, of: day))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(energy(app.wattHours))
                        .frame(width: 88, alignment: .trailing)
                }
                .font(.callout)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }

            Divider()
            Text("\(energy(day.measuredCPUWattHours)) measured · \(batteryDuration(day.observedSeconds)) on battery")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The ranking covers measured process CPU energy during sampled battery use.")
        }
    }

    private func batteryShare(_ app: BatteryAppUsage, of day: BatteryUsageReport) -> String {
        guard day.measuredCPUWattHours > 0 else { return "—" }
        return (app.wattHours / day.measuredCPUWattHours).formatted(.percent.precision(.fractionLength(0)))
    }

    private func batteryDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) sec" }
        let minutes = Int(seconds) / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    @ViewBuilder
    private var live: some View {
        if !model.monitoringEnabled {
            VStack(spacing: 8) {
                notice("Monitoring is paused", icon: "pause.circle",
                       message: "Resume to see current CPU and power.")
                Button("Resume monitoring") { model.setMonitoring(true) }
                    .padding(.bottom, 18)
            }
        } else if let snapshot = model.snapshot, let issue = snapshot.enumerationIssue {
            notice("Process list unavailable", icon: "lock",
                   message: issue.category == .permissionDenied
                    ? "macOS denied access to the process list." : "CrashPulse will try again on the next scan.")
        } else if let snapshot = model.snapshot, snapshot.coverage.cpu > 0 {
            processList(snapshot)
        } else {
            notice("Collecting readings…", icon: "waveform",
                   message: "CPU and power appear after two samples.")
        }
    }


    private struct LiveGroup: Identifiable {
        var id: String { app.id }
        let app: ProcessGroup
        let rows: [ProcessRow]
        let cpu: Double?
        let watts: Double?

        init(app: ProcessGroup, rows: [ProcessRow]) {
            self.app = app
            self.rows = rows
            let percentages = rows.compactMap(\.cpuPercent)
            let measuredWatts = rows.compactMap { $0.cpuPower?.watts }
            cpu = percentages.isEmpty ? nil : percentages.reduce(0, +)
            watts = measuredWatts.isEmpty ? nil : measuredWatts.reduce(0, +)
        }
    }

    private func processList(_ snapshot: Snapshot) -> some View {
        let hasPower = snapshot.rows.contains { $0.cpuPower != nil }
        let effectiveOrder: Order = hasPower ? order : .cpu
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Dictionary(grouping: snapshot.rows, by: { ProcessGroup(row: $0).id }).values.compactMap { rows -> LiveGroup? in
            guard let first = rows.first else { return nil }
            let app = ProcessGroup(row: first)
            if showingAll {
                guard query.isEmpty || app.name.localizedStandardContains(query) || rows.contains(where: {
                    processName($0).localizedStandardContains(query) || String($0.pid).contains(query)
                }) else { return nil }
            }
            let group = LiveGroup(app: app, rows: rows)
            return showingAll || (effectiveOrder == .power ? group.watts != nil : group.cpu != nil) ? group : nil
        }.sorted {
            let left = (effectiveOrder == .power ? $0.watts : $0.cpu) ?? -1
            let right = (effectiveOrder == .power ? $1.watts : $1.cpu) ?? -1
            return left == right ? $0.id < $1.id : left > right
        }

        return VStack(alignment: .leading, spacing: 8) {
            if model.activity.contains(where: { $0.measuredCPUPercent != nil }) {
                Text("Measured CPU · last 3 min").font(.caption).foregroundStyle(.secondary)
                activityChart(model.activity, ceiling: max(100, model.activity.compactMap(\.measuredCPUPercent).max() ?? 0),
                              color: .accentColor)
            }
            HStack {
                if showingAll {
                    Button {
                        showingAll = false
                        search = ""
                        expandedGroups.removeAll()
                    } label: { Label("Top apps", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                } else {
                    Text("Top apps").font(.subheadline.weight(.semibold))
                }
                Spacer()
                Picker("Sort by", selection: Binding(get: { effectiveOrder }, set: { order = $0 })) {
                    ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!hasPower)
                .accessibilityLabel("Sort by")
            }
            if showingAll { TextField("Search app, process or PID", text: $search).textFieldStyle(.roundedBorder) }
            HStack(spacing: 10) {
                Text("App")
                Spacer()
                Text("CPU").frame(width: 55, alignment: .trailing)
                Text("CPU power").frame(width: 80, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            if groups.isEmpty {
                notice("No matching apps", icon: "magnifyingglass", message: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(showingAll ? groups : Array(groups.prefix(6))) { liveGroupRow($0) }
                    }
                }
                .frame(height: showingAll ? 242 : 199)
            }
            if !showingAll {
                Button("All apps and processes", systemImage: "list.bullet") { showingAll = true }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
    }

    private func liveGroupRow(_ group: LiveGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedGroups.contains(group.id) }, set: { expanded in
            if expanded { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) }
        })) {
            VStack(spacing: 2) {
                ForEach(group.rows) { processRow($0, showPID: true) }
            }
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 10) {
                Text(group.app.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 2)
                Text(group.cpu.map(percent) ?? "—").frame(width: 55, alignment: .trailing)
                Text(group.watts.map(power) ?? "—").frame(width: 80, alignment: .trailing)
            }
            .font(.callout)
            .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func processRow(_ row: ProcessRow, showPID: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(processName(row))
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                if showPID {
                    Text(processDetails(row))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Text(row.cpuPercent.map(percent) ?? "—")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
            Text(row.cpuPower.map { power($0.watts) } ?? "—")
                .font(.callout.weight(.medium))
                .frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .help(row.cpuPower.map { "PID \(row.pid) · \(energy($0.intervalWattHours)) of CPU energy in the last sample" }
              ?? "PID \(row.pid) · CPU power unavailable")
        .accessibilityElement(children: .combine)
    }


    private var history: some View {
        Group {
            if let report {
                if let selectedEvent, let event = report.events.first(where: { $0.id == selectedEvent }) {
                    incident(event)
                } else {
                    eventList(report)
                }
            } else if let historyReadError {
                notice("Events unavailable", icon: "exclamationmark.circle", message: historyReadError)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .padding(16)
    }

    private func eventList(_ report: CPUHistoryReport) -> some View {
        let visible = report.events.filter { showIgnored || $0.ignoredAt == nil }
        let recent = visible.filter { (0...86_400).contains(report.generatedAt.timeIntervalSince($0.startedAt)) }.count
        let sorted = visible.sorted {
            let lhs = impactRank($0)
            let rhs = impactRank($1)
            if lhs != rhs { return lhs > rhs }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(recent) in last 24 hours").font(.subheadline.weight(.semibold))
                Spacer()
                if report.events.contains(where: { $0.ignoredAt != nil }) {
                    Toggle("Show ignored", isOn: $showIgnored).toggleStyle(.checkbox).font(.caption)
                }
            }
            if let pattern = report.recurringBackgroundActivity.first {
                Text("\(pattern.app.name) · \(pattern.events) background events across \(pattern.days) days")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let historyReadError {
                Text(historyReadError).font(.caption).foregroundStyle(.secondary)
            }
            if sorted.isEmpty {
                notice("No CPU events yet", icon: "waveform.path.ecg",
                       message: "CrashPulse keeps context around sustained CPU activity while it runs.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(sorted) { event in
                            Button { selectedEvent = event.id } label: { historyRow(event) }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func historyRow(_ event: HighCPUEvent) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(eventName(event)).fontWeight(.semibold).lineLimit(1)
                Text(event.startedAt.formatted(date: .abbreviated, time: .shortened)
                     + " · " + impactLabel(event))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(percent(event.peakCPUPercent)) peak").fontWeight(.medium)
                if let amount = eventEnergy(event) {
                    Text(energy(amount)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption2)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(8)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private func incident(_ event: HighCPUEvent) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { selectedEvent = nil } label: { Label("Events", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.forensics?.suspectedApp == nil ? "Recorded process" : "Likely contributor")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(eventName(event)).font(.title2.weight(.semibold)).lineLimit(2)
                        Text(impactLabel(event)).font(.caption).foregroundStyle(.secondary)
                        let summary = incidentSummary(event)
                        if !summary.isEmpty { Text(summary).fontWeight(.medium) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.startedAt.formatted(date: .abbreviated, time: .standard))
                        Text(event.endReason == nil ? "Ongoing" :
                            "Last high reading \(event.lastObservedAt.formatted(date: endDateStyle(event), time: .standard))")
                        Text("\(event.observedDurationSeconds.formatted(.number.precision(.fractionLength(0)))) s · \(percent(event.peakCPUPercent)) trigger peak")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let evidence = event.forensics {
                        Text(evidence.basis == .aboveBaseline
                             ? "Ranked by CPU increases or processes that appeared near the start."
                             : "Ranked by measured CPU during the event. The earlier baseline is limited.")
                            .font(.caption).foregroundStyle(.secondary)
                        timeline(evidence)
                        Text("CPU contributors").font(.subheadline.weight(.semibold))
                        ForEach(evidence.topProcesses) { process in
                            contributorRow(process)
                        }
                        if evidence.topProcesses.isEmpty {
                            Text("No comparable process samples.").foregroundStyle(.secondary)
                        }
                        if let extra = evidence.suspectedAppExtraCPUWattHours {
                            Text("\(energy(extra)) estimated above the likely contributor’s baseline")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if evidence.foregroundSamples + evidence.backgroundSamples > 0 {
                            Text("\(evidence.backgroundSamples) of \(evidence.foregroundSamples + evidence.backgroundSamples) context samples outside the active app")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let battery = evidence.batterySamples, let adapter = evidence.pluggedInSamples,
                           battery + adapter > 0 {
                            Text("\(battery) samples on battery · \(adapter) plugged in")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This recording has no comparative timeline.").foregroundStyle(.secondary)
                        if let path = event.path { Text(path).textSelection(.enabled).foregroundStyle(.secondary) }
                    }
                    Text("Trigger PID \(event.identity.pid) · \(event.name ?? eventName(event))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = endLabel(event.endReason) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if let baseline = event.baselineCPUPercent, let threshold = event.triggerThresholdCPUPercent {
                        Text("Usual CPU \(percent(baseline)) · detection threshold \(percent(threshold))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("What to do").font(.subheadline.weight(.semibold))
                    Text(advice(event)).foregroundStyle(.secondary)
                    if let eventActionError { Text(eventActionError).foregroundStyle(.secondary) }
                    Button(event.ignoredAt == nil ? "Ignore this event" : "Restore this event") {
                        Task {
                            do {
                                try await model.setEventIgnored(event.id, ignored: event.ignoredAt == nil)
                                eventActionError = nil
                                if event.ignoredAt == nil { selectedEvent = nil }
                                await refreshHistory()
                            } catch {
                                eventActionError = error.localizedDescription
                            }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 445)
        }
    }

    private func contributorRow(_ item: ProcessContribution) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.name).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(item.cpuShare.formatted(.percent.precision(.fractionLength(0))) + " of measured CPU")
                    .font(.caption)
            }
            Text("PID \(item.identity.pid) · \(item.cpuEnergyWattHours.map(energy) ?? "CPU energy unavailable")")
                .font(.caption).foregroundStyle(.secondary)
            if let path = item.path {
                Text(path).font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).help(path)
            }
        }
        .padding(6)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func timeline(_ evidence: EventEvidence) -> some View {
        let phases = [("Before", evidence.before), ("During", evidence.during), ("After", evidence.after)]
        let maximum = max(100, phases.flatMap { $0.1 }.compactMap(\.measuredCPUPercent).max() ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Measured CPU timeline").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 7) {
                ForEach(phases, id: \.0) { phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phase.0).font(.caption)
                        activityChart(phase.1, ceiling: maximum, color: phase.0 == "During" ? .orange : .accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !evidence.afterComplete {
                Text("Follow-up coverage is incomplete.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activityChart(_ points: [ActivityPoint], ceiling: Double, color: Color) -> some View {
        let observed = chartPoints(points)
        return Group {
            if observed.isEmpty {
                Text("No samples").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                Chart {
                    ForEach(observed, id: \.at) { point in
                        LineMark(x: .value("Time", point.at), y: .value("Measured CPU %", point.cpu),
                                 series: .value("Continuous samples", point.segment))
                            .foregroundStyle(color)
                        PointMark(x: .value("Time", point.at), y: .value("Measured CPU %", point.cpu))
                            .foregroundStyle(color).symbolSize(7)
                    }
                }
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
            }
        }
    }

    private func chartPoints(_ points: [ActivityPoint]) -> [(at: Date, cpu: Double, segment: Int)] {
        var segment = 0
        return points.compactMap { point in
            guard let cpu = point.measuredCPUPercent else {
                segment += 1
                return nil
            }
            return (point.at, cpu, segment)
        }
    }

    private func eventName(_ event: HighCPUEvent) -> String {
        event.forensics?.suspectedApp?.name ?? ProcessGroup(path: event.path)?.name ?? event.name
            ?? "PID \(event.identity.pid)"
    }

    private func eventEnergy(_ event: HighCPUEvent) -> Double? {
        if let evidence = event.forensics, evidence.suspectedApp != nil {
            return evidence.suspectedAppCPUWattHours
        }
        return event.observedCPUEnergyWattHours
    }

    private func endDateStyle(_ event: HighCPUEvent) -> Date.FormatStyle.DateStyle {
        Calendar.current.isDate(event.startedAt, inSameDayAs: event.lastObservedAt) ? .omitted : .abbreviated
    }

    private func incidentSummary(_ event: HighCPUEvent) -> String {
        var parts: [String] = []
        if let share = event.forensics?.suspectedAppCPUShare {
            parts.append(share.formatted(.percent.precision(.fractionLength(0))) + " of measured CPU")
        }
        if let amount = eventEnergy(event) { parts.append(energy(amount) + " CPU") }
        return parts.joined(separator: " · ")
    }

    private func impactRank(_ event: HighCPUEvent) -> Int {
        switch event.forensics?.impact {
        case .sustained: 3
        case .review: 2
        case .activity: 1
        case nil: 0
        }
    }

    private func impactLabel(_ event: HighCPUEvent) -> String {
        if event.ignoredAt != nil { return "Ignored" }
        switch event.forensics?.impact {
        case .sustained: return "Sustained background activity"
        case .review: return "Worth a look"
        case .activity: return "Elevated activity"
        case nil: return "Earlier recording"
        }
    }

    private func endLabel(_ reason: HighCPUEvent.EndReason?) -> String? {
        switch reason {
        case .belowThreshold: "CPU fell below the detection threshold"
        case .processExited, .processMissing: "Process stopped appearing in samples"
        case .processChanged: "PID now belongs to a different process"
        case .sampleUnavailable, .samplingGap, .clockChanged: "Monitoring lost continuous readings"
        case .monitorStopped, .monitorInterrupted: "Recording stopped"
        case nil: nil
        }
    }

    private func advice(_ event: HighCPUEvent) -> String {
        if event.forensics?.impact == .sustained {
            return "Check whether the app is still busy in Live. If its work is unexpected, save your work and quit it normally."
        }
        return "If you expected this workload, ignore the event. If it recurs, use the process name and path to investigate."
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit CrashPulse") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func notice(_ title: String, icon: String, message: String?) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(14)
    }

    private func refreshHistory() async {
        do {
            let updated = try await model.historyReport()
            guard !Task.isCancelled else { return }
            report = updated
            historyReadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            historyReadError = error.localizedDescription
        }
    }

    private func processName(_ row: ProcessRow) -> String {
        row.name ?? row.path.map { ($0 as NSString).lastPathComponent } ?? "PID \(row.pid)"
    }

    private func processDetails(_ row: ProcessRow) -> String {
        let detail = row.footprintBytes.map { memoryStyle.format(Int64(clamping: $0)) } ?? row.state.label
        return "PID \(row.pid) · \(detail)"
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func power(_ watts: Double) -> String {
        if watts >= 1 { return watts.formatted(.number.precision(.fractionLength(2))) + " W" }
        if watts > 0 && watts < 0.001 { return "<1 mW" }
        return (watts * 1_000).formatted(.number.precision(.fractionLength(0))) + " mW"
    }

    private func energy(_ wattHours: Double) -> String {
        if wattHours > 0 && wattHours < 0.001 { return "<0.001 Wh" }
        return wattHours.formatted(.number.precision(.fractionLength(0...3))) + " Wh"
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: MonitorModel
    @State private var document: JSONDocument?
    @State private var filename = "CrashPulse-diagnostics"
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Monitor while CrashPulse is open",
                       isOn: Binding(get: { model.monitoringEnabled }, set: { model.setMonitoring($0) }))
                Picker("Sample interval", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                    ForEach(DiagnosticCapture.intervals, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
            }

            Section("Power readings") {
                Text("CPU power is estimated over each sample, on battery or plugged in. It covers CPU activity attributed to the process.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Data and support") {
                if let version = model.run.appVersion {
                    LabeledContent("Version", value: version)
                }
                if model.historyError != nil {
                    Label("History can’t be saved right now.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Export diagnostics to include the error details.")
                }
                Button("Export diagnostics…") {
                    do {
                        if let data = try model.report() { showExport(data, name: "CrashPulse-diagnostics") }
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
                .disabled(model.snapshot == nil)
                if model.run.canRecordHistory {
                    Button("Export battery usage and events…") {
                        Task {
                            do {
                                let report = try await model.historyReport()
                                showExport(try report.encoded(), name: "CrashPulse-history")
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: filename) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func showExport(_ data: Data, name: String) {
        document = JSONDocument(data: data)
        filename = name
        exporting = true
    }
}

private struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
