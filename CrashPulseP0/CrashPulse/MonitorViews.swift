import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design tokens

/// One place for the panel's type scale and colors. Priority is carried by size and weight first,
/// then by color: the severity color marks only what needs attention.
enum Pulse {
    static let width: CGFloat = 360
    static let gutter: CGFloat = 16

    static var severe: Color { Color(nsColor: .systemRed) }
    static var signal: Color { Color(nsColor: .systemOrange) }
    static var watching: Color { Color(nsColor: .systemGreen) }

    static let title = Font.system(size: 24, weight: .semibold)
    static let figure = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
}

enum PulseFormat {
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func precisePercent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    static func power(_ watts: Double) -> String {
        if watts >= 1 { return watts.formatted(.number.precision(.fractionLength(2))) + " W" }
        if watts > 0 && watts < 0.001 { return "<1 mW" }
        return (watts * 1_000).formatted(.number.precision(.fractionLength(0))) + " mW"
    }

    static func energy(_ wattHours: Double) -> String {
        if wattHours >= 1 { return wattHours.formatted(.number.precision(.fractionLength(0...2))) + " Wh" }
        let milli = wattHours * 1_000
        if milli > 0 && milli < 0.1 { return "<0.1 mWh" }
        return milli.formatted(.number.precision(.fractionLength(milli < 10 ? 1 : 0))) + " mWh"
    }
}

// MARK: - Event wording

enum EventSeverity {
    case now, background, review, inUse, unknown, ignored

    init(_ event: HighCPUEvent) {
        if event.ignoredAt != nil {
            self = .ignored
        } else if event.endReason == nil {
            self = .now
        } else {
            switch event.forensics?.impact {
            case .sustained: self = .background
            case .review: self = .review
            case .activity: self = .inUse
            case nil: self = .unknown
            }
        }
    }

    var label: String {
        switch self {
        case .now: "Happening now"
        case .background: "Busy in the background"
        case .review: "Worth a look"
        case .inUse: "Busy while in use"
        case .unknown: "Earlier recording"
        case .ignored: "Ignored"
        }
    }

    var color: Color {
        switch self {
        case .now, .background: Pulse.severe
        case .review: Pulse.signal
        case .inUse, .unknown, .ignored: Color.secondary
        }
    }

    /// Neutral events still need a visible trace line.
    var traceColor: Color {
        switch self {
        case .inUse, .unknown, .ignored: Color.accentColor
        default: color
        }
    }
}

/// Plain-language text derived from one recorded event.
struct EventStory {
    let event: HighCPUEvent

    var severity: EventSeverity { EventSeverity(event) }
    var triggerName: String { event.cpuTrigger.name }

    var appName: String {
        event.forensics?.suspectedApp?.name ?? triggerName
    }

    var energy: Double? {
        if let evidence = event.forensics, evidence.suspectedApp != nil { return evidence.suspectedAppCPUWattHours }
        return event.observedCPUEnergyWattHours
    }

    private var wasInBackground: Bool? {
        guard let evidence = event.forensics, evidence.foregroundSamples + evidence.backgroundSamples > 0 else { return nil }
        return evidence.backgroundSamples > evidence.foregroundSamples
    }

    var summary: String {
        let peak = PulseFormat.percent(event.peakCPUPercent)
        let span = event.endReason == nil
            ? "for \(PulseFormat.duration(event.observedDurationSeconds)) so far"
            : "for \(PulseFormat.duration(event.observedDurationSeconds))"
        if event.hasSeparateContributor {
            return "\(triggerName) triggered the event, using up to \(peak) CPU \(span)."
        }
        let load = "Kept the CPU at up to \(peak)"
        switch wasInBackground {
        case true?: return "\(load) \(span) while you were using other apps."
        case false?: return "\(load) \(span) while you were using it."
        case nil: return "\(load) \(span)."
        }
    }

    var advice: String {
        switch severity {
        case .now:
            "\(triggerName) is still busy. Open Live to check its current CPU use."
        case .background:
            "\(appName) keeps working hard in the background. If you don’t need it running, quit it or turn off its background sync or indexing."
        case .review:
            "\(appName) was busy while you weren’t using it. If you didn’t expect that, watch it in Live next time."
        case .inUse:
            "This is usually expected: \(appName) was busy while you were using it."
        case .unknown:
            "This event was recorded before CrashPulse kept timelines."
        case .ignored:
            "You ignored this event. It no longer counts toward patterns."
        }
    }

    var timeStatus: String {
        let duration = PulseFormat.duration(event.observedDurationSeconds)
        switch event.endReason {
        case nil: return "Ongoing for \(duration)"
        case .belowThreshold, .processExited: return "Ended after \(duration)"
        default: return "Recorded for \(duration)"
        }
    }

    var timeNote: String {
        let start = event.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
        guard let reason = event.endReason else { return "Started \(start)." }
        let sameDay = Calendar.current.isDate(event.startedAt, inSameDayAs: event.lastObservedAt)
        let end = event.lastObservedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .standard)
        return "\(start) to \(end). Ended \(Self.ending(reason))."
    }

    private static func ending(_ reason: HighCPUEvent.EndReason) -> String {
        switch reason {
        case .belowThreshold: "when CPU use dropped"
        case .processExited: "when the process quit"
        case .processMissing: "when it was no longer observed"
        case .processChanged: "when the process restarted"
        case .sampleUnavailable, .samplingGap: "when readings stopped"
        case .clockChanged: "after a clock change"
        case .monitorStopped: "when monitoring paused"
        case .monitorInterrupted: "when CrashPulse quit unexpectedly"
        }
    }

    var listSubtitle: String {
        let time = event.startedAt.formatted(date: .omitted, time: .shortened)
        if event.endReason == nil { return "Since \(time), still busy" }
        return "\(time) for \(PulseFormat.duration(event.observedDurationSeconds))"
    }

    var triggerNote: String? {
        event.hasSeparateContributor ? "Triggered by \(triggerName)" : nil
    }

    var sparkline: [Double?] {
        guard let evidence = event.forensics else { return [] }
        return (evidence.before + evidence.during + evidence.after).map(\.triggerCPUPercent)
    }
}

// MARK: - Panel chrome

struct PanelStatus {
    let text: String
    let color: Color
}

struct PanelChrome<Content: View>: View {
    let status: PanelStatus
    let monitoring: Bool
    let showsTabs: Bool
    @Binding var tab: MenuMonitorView.Tab
    var historyError: String?
    let onToggleMonitoring: () -> Void
    let openSettings: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
            if let historyError {
                Label("History can’t be saved. Recording continues in memory.", systemImage: "exclamationmark.triangle.fill")
                    .font(Pulse.caption)
                    .foregroundStyle(Pulse.signal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Pulse.gutter)
                    .padding(.bottom, 10)
                    .help(historyError)
            }
            if showsTabs {
                Picker("View", selection: $tab) {
                    ForEach(MenuMonitorView.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Pulse.gutter)
                .padding(.bottom, 12)
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Pulse.width)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("CrashPulse").font(Pulse.bodyStrong)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.text).font(Pulse.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Button(action: onToggleMonitoring) {
                Image(systemName: monitoring ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(monitoring ? "Pause monitoring" : "Resume monitoring")
            .accessibilityLabel(monitoring ? "Pause monitoring" : "Resume monitoring")
        }
        .padding(.horizontal, Pulse.gutter)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(Pulse.detail)
        .padding(.horizontal, Pulse.gutter)
        .padding(.vertical, 9)
    }
}

// MARK: - Root

struct MenuMonitorView: View {
    @ObservedObject var model: MonitorModel
    let openSettings: () -> Void

    enum Tab: String, CaseIterable {
        case events = "Events"
        case live = "Live"
    }

    @State private var tab: Tab
    @State private var selectedEvent: UUID?
    @State private var showIgnored = false
    @State private var report: CPUHistoryReport?
    @State private var historyReadError: String?
    @State private var eventActionError: String?

    init(model: MonitorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        _tab = State(initialValue: model.run.canRecordHistory ? .events : .live)
    }

    var body: some View {
        PanelChrome(status: status, monitoring: model.monitoringEnabled, showsTabs: model.run.canRecordHistory,
                    tab: $tab, historyError: model.historyError,
                    onToggleMonitoring: { model.setMonitoring(!model.monitoringEnabled) },
                    openSettings: openSettings) {
            switch tab {
            case .events: events
            case .live:
                LiveView(snapshot: model.panelVisible ? model.snapshot : nil,
                         activity: model.panelVisible ? model.activity : [],
                         monitoring: model.monitoringEnabled, isVisible: model.panelVisible,
                         onResume: { model.setMonitoring(true) })
            }
        }
        .task(id: historyScan) {
            if showsHistory { await refreshHistory() }
        }
    }

    private var showsHistory: Bool { model.panelVisible && tab == .events }

    private var historyScan: Date? {
        showsHistory ? (model.snapshot?.sampledAt ?? .distantPast) : nil
    }

    private var status: PanelStatus {
        if !model.monitoringEnabled { return PanelStatus(text: "Paused", color: .secondary) }
        guard let snapshot = model.snapshot else { return PanelStatus(text: "Starting", color: .secondary) }
        if snapshot.enumerationIssue != nil { return PanelStatus(text: "No process access", color: Pulse.signal) }
        switch snapshot.powerSupply {
        case .battery: return PanelStatus(text: "Watching, on battery", color: Pulse.watching)
        case .adapter: return PanelStatus(text: "Watching, plugged in", color: Pulse.watching)
        case .ups: return PanelStatus(text: "Watching, on UPS", color: Pulse.watching)
        case nil: return PanelStatus(text: "Watching", color: Pulse.watching)
        }
    }

    @ViewBuilder
    private var events: some View {
        if let report {
            if let selectedEvent, let event = report.events.first(where: { $0.id == selectedEvent }) {
                EventDetailView(event: event, actionError: eventActionError,
                                onBack: { self.selectedEvent = nil },
                                onOpenLive: { tab = .live },
                                onToggleIgnored: { Task { await toggleIgnored(event) } })
            } else {
                EventListView(report: report, showIgnored: $showIgnored,
                              notice: historyReadError ?? eventActionError,
                              onSelect: { selectedEvent = $0.id },
                              onToggleIgnored: { event in Task { await toggleIgnored(event) } })
            }
        } else if let historyReadError {
            PanelMessage(symbol: "exclamationmark.triangle", title: "Events can’t be read", message: historyReadError)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func toggleIgnored(_ event: HighCPUEvent) async {
        do {
            try await model.setEventIgnored(event.id, ignored: event.ignoredAt == nil)
            eventActionError = nil
            if event.ignoredAt == nil, selectedEvent == event.id, !showIgnored { selectedEvent = nil }
            await refreshHistory()
        } catch {
            eventActionError = error.localizedDescription
        }
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
}

// MARK: - Event list

struct EventListView: View {
    let report: CPUHistoryReport
    @Binding var showIgnored: Bool
    var notice: String?
    let onSelect: (HighCPUEvent) -> Void
    let onToggleIgnored: (HighCPUEvent) -> Void

    private struct Day: Identifiable {
        let id: Date
        let events: [HighCPUEvent]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let visible = report.events
            .filter { showIgnored || $0.ignoredAt == nil }
            .sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { Day(id: $0, events: grouped[$0] ?? []) }
    }

    var body: some View {
        let days = days
        VStack(alignment: .leading, spacing: 0) {
            if let pattern = report.recurringBackgroundActivity.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(Pulse.captionStrong)
                        .foregroundStyle(Pulse.severe)
                    Text("\(pattern.app.name) spiked in the background on \(pattern.days) separate days.")
                        .font(Pulse.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Pulse.severe.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, Pulse.gutter - 4)
                .padding(.top, 12)
            }
            if let notice {
                Text(notice)
                    .font(Pulse.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Pulse.gutter)
                    .padding(.top, 10)
            }
            if days.isEmpty {
                PanelMessage(symbol: "waveform.path.ecg", title: "No CPU spikes yet",
                             message: "CrashPulse records any app that keeps the CPU busy for 30 seconds or more.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            Text(Self.dayTitle(day.id))
                                .font(Pulse.captionStrong)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Pulse.gutter)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(day.events) { event in
                                EventRow(story: EventStory(event: event), onSelect: { onSelect(event) })
                                    .contextMenu {
                                        Button(event.ignoredAt == nil ? "Ignore This Event" : "Restore This Event") {
                                            onToggleIgnored(event)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, Pulse.gutter - 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
            if report.events.contains(where: { $0.ignoredAt != nil }) {
                Toggle("Show ignored events", isOn: $showIgnored)
                    .toggleStyle(.checkbox)
                    .font(Pulse.caption)
                    .padding(.horizontal, Pulse.gutter)
                    .padding(.bottom, 10)
            }
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct EventRow: View {
    let story: EventStory
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let severity = story.severity
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Circle()
                    .fill(severity.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(story.appName).font(Pulse.bodyStrong).lineLimit(1)
                    if let note = story.triggerNote {
                        Text(note).font(Pulse.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(story.listSubtitle).font(Pulse.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Sparkline(values: story.sparkline)
                    .stroke(severity.traceColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 52, height: 18)
                    .opacity(story.sparkline.isEmpty ? 0 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(PulseFormat.percent(story.event.peakCPUPercent))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                    Text(story.event.hasSeparateContributor ? "trigger peak" : "peak")
                        .font(Pulse.caption).foregroundStyle(.tertiary)
                }
                .frame(minWidth: 40, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(severity == .ignored ? 0.55 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel([story.appName, story.triggerNote, severity.label, story.listSubtitle,
                             "peak \(PulseFormat.percent(story.event.peakCPUPercent))"].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A lightweight line for list rows. Charts would be too heavy for hundreds of rows.
struct Sparkline: Shape {
    let values: [Double?]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let ceiling = max(100, values.compactMap { $0 }.max() ?? 0)
        let step = rect.width / CGFloat(values.count - 1)
        var drawing = false
        for (index, value) in values.enumerated() {
            guard let value else { drawing = false; continue }
            let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                y: rect.maxY - CGFloat(min(value, ceiling) / ceiling) * rect.height)
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
        return path
    }
}

// MARK: - Event detail

struct EventDetailView: View {
    let event: HighCPUEvent
    var actionError: String?
    let onBack: () -> Void
    let onOpenLive: () -> Void
    let onToggleIgnored: () -> Void

    var body: some View {
        let story = EventStory(event: event)
        let severity = story.severity
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    Label("Events", systemImage: "chevron.left").font(Pulse.detail)
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 14)

                // First priority: who, and how serious.
                Text(severity.label)
                    .font(Pulse.captionStrong)
                    .foregroundStyle(severity.color)
                    .padding(.bottom, 3)
                Text(story.appName)
                    .font(Pulse.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if event.hasSeparateContributor {
                    Text("Likely contributor").font(Pulse.caption).foregroundStyle(.secondary)
                }
                Text(story.summary)
                    .font(Pulse.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 16)

                // Second: what happened over time.
                if let evidence = event.forensics, !(evidence.before + evidence.during + evidence.after).isEmpty {
                    PulseTrace(event: event, evidence: evidence, triggerName: story.triggerName, color: severity.traceColor)
                        .padding(.bottom, 16)
                } else {
                    Text("No timeline was recorded. This event is from before CrashPulse kept timelines.")
                        .font(Pulse.detail)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 16)
                }

                figures(story)
                    .padding(.bottom, 18)

                // Third: what to do about it.
                if severity != .unknown {
                    Text("What you can do").font(Pulse.bodyStrong).padding(.bottom, 4)
                    Text(story.advice)
                        .font(Pulse.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if severity == .now {
                    Button("Open Live", action: onOpenLive)
                        .controlSize(.small)
                        .padding(.top, 8)
                }

                // Fourth: supporting detail.
                if let processes = processes(story) {
                    Text("Processes involved")
                        .font(Pulse.captionStrong)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                        .padding(.bottom, 6)
                    VStack(spacing: 6) {
                        ForEach(processes) { process in
                            ProcessShareRow(process: process, color: severity.traceColor)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(story.timeStatus).font(Pulse.bodyStrong)
                    Text(story.timeNote)
                        .font(Pulse.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 18)
                HStack {
                    Button(event.ignoredAt == nil ? "Ignore this event" : "Restore this event",
                           systemImage: event.ignoredAt == nil ? "eye.slash" : "eye",
                           action: onToggleIgnored)
                        .buttonStyle(.borderless)
                        .font(Pulse.caption)
                        .help("Ignored events stay in history but no longer count toward patterns.")
                    if let actionError {
                        Text(actionError).font(Pulse.caption).foregroundStyle(Pulse.signal).lineLimit(2)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Pulse.gutter)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figures(_ story: EventStory) -> some View {
        HStack(alignment: .top, spacing: 0) {
            figure(PulseFormat.duration(event.observedDurationSeconds), event.endReason == nil ? "So far" : "Duration")
            figure(PulseFormat.percent(event.peakCPUPercent), event.hasSeparateContributor ? "Trigger peak CPU" : "Peak CPU")
            if let energy = story.energy {
                figure(PulseFormat.energy(energy), event.hasSeparateContributor ? "Est. contributor energy" : "Est. CPU energy")
                    .help("Estimated CPU energy for \(story.appName) during this event.")
            } else if let share = event.forensics?.suspectedAppCPUShare {
                figure(share.formatted(.percent.precision(.fractionLength(0))),
                       event.hasSeparateContributor ? "Contributor share" : "Share of CPU")
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Pulse.figure).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(Pulse.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Hidden when the only process is the app itself, which the title already says.
    private func processes(_ story: EventStory) -> [ProcessContribution]? {
        guard let top = event.forensics?.topProcesses, !top.isEmpty else { return nil }
        if top.count == 1, top[0].name == story.appName { return nil }
        return top
    }
}

private struct ProcessShareRow: View {
    let process: ProcessContribution
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(Pulse.detail)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(process.path ?? process.name)
            Spacer(minLength: 8)
            ShareBar(fraction: process.cpuShare, color: color.opacity(0.7))
                .frame(width: 56, height: 4)
            Text(process.cpuShare.formatted(.percent.precision(.fractionLength(0))))
                .font(Pulse.detail.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(2, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pulse trace

/// The before, during and after readings as one continuous strip, with the event span tinted.
struct PulseTrace: View {
    let event: HighCPUEvent
    let evidence: EventEvidence
    let triggerName: String
    let color: Color

    private struct Point: Identifiable {
        let id: Int
        let at: Date
        let value: Double
        let segment: Int
    }

    private static func points(_ source: [ActivityPoint], value: (ActivityPoint) -> Double?) -> [Point] {
        var segment = 0
        var result: [Point] = []
        for (index, point) in source.enumerated() {
            guard let reading = value(point) else { segment += 1; continue }
            result.append(Point(id: index, at: point.at, value: reading, segment: segment))
        }
        return result
    }

    var body: some View {
        let source = (evidence.before + evidence.during + evidence.after).sorted { $0.at < $1.at }
        let trigger = Self.points(source) { $0.triggerCPUPercent }
        let all = Self.points(source) { $0.measuredCPUPercent }
        let top = max(100, (trigger + all).map(\.value).max() ?? 0)
        let ceiling = (top / 100).rounded(.up) * 100
        let start = event.startedAt
        let end = max(event.lastObservedAt, start.addingTimeInterval(1))
        let first = min(source.first?.at ?? start, start)
        let last = max(source.last?.at ?? end, end)

        VStack(alignment: .leading, spacing: 6) {
            Chart {
                RectangleMark(xStart: .value("Start", start), xEnd: .value("End", end))
                    .foregroundStyle(color.opacity(0.07))
                ForEach(all) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Measured total", point.value),
                             series: .value("Series", "all-\(point.segment)"))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(trigger) { point in
                    LineMark(x: .value("Time", point.at), y: .value(triggerName, point.value),
                             series: .value("Series", "app-\(point.segment)"))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: first...last)
            .chartYScale(domain: 0...ceiling)
            .chartXAxis {
                AxisMarks(values: [start, end]) { _ in
                    AxisTick(length: 4).foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, ceiling / 2, ceiling]) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(PulseFormat.percent(number)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 96)
            .accessibilityLabel("CPU use before, during and after the event")

            HStack(spacing: 12) {
                if !trigger.isEmpty { legend(triggerName, color: color, lineWidth: 2) }
                if !all.isEmpty { legend("Measured total", color: .secondary.opacity(0.55), lineWidth: 1) }
                Spacer()
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.18)).frame(width: 12, height: 8)
                    Text("Event").font(Pulse.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legend(_ text: String, color: Color, lineWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: lineWidth)
            Text(text).font(Pulse.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(text)
    }
}

// MARK: - Live

struct LiveView: View {
    let snapshot: Snapshot?
    let activity: [ActivityPoint]
    let monitoring: Bool
    let isVisible: Bool
    let onResume: () -> Void

    private enum Order: String, CaseIterable {
        case power = "Power"
        case cpu = "CPU"
    }

    @State private var order = Order.power
    @State private var showingAll = false
    @State private var search = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        if isVisible {
            visibleContent
        }
    }

    @ViewBuilder
    private var visibleContent: some View {
        if !monitoring {
            PanelMessage(symbol: "pause.circle", title: "Monitoring is paused",
                         message: "Resume to see which apps are using the CPU now.",
                         action: ("Resume", onResume))
        } else if let snapshot, let issue = snapshot.enumerationIssue {
            PanelMessage(symbol: "lock", title: "Can’t read the process list",
                         message: issue.category == .permissionDenied
                            ? "macOS denied access to other processes." : "CrashPulse will try again on the next scan.")
        } else if let snapshot, snapshot.coverage.cpu > 0 {
            content(snapshot)
        } else {
            PanelMessage(symbol: "waveform", title: "Taking the first readings",
                         message: "CPU use appears after two samples.")
        }
    }

    private struct AppUsage: Identifiable {
        var id: String { app.id }
        let app: ProcessGroup
        let rows: [ProcessRow]
        let cpu: Double?
        let watts: Double?

        init(app: ProcessGroup, rows: [ProcessRow]) {
            self.app = app
            self.rows = rows.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
            let percentages = rows.compactMap(\.cpuPercent)
            let measuredWatts = rows.compactMap { $0.cpuPower?.watts }
            cpu = percentages.isEmpty ? nil : percentages.reduce(0, +)
            watts = measuredWatts.isEmpty ? nil : measuredWatts.reduce(0, +)
        }
    }

    private func content(_ snapshot: Snapshot) -> some View {
        let hasPower = snapshot.rows.contains { $0.cpuPower != nil }
        let effective: Order = hasPower ? order : .cpu
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Dictionary(grouping: snapshot.rows, by: { ProcessGroup(row: $0).id }).values
            .compactMap { rows -> AppUsage? in
                guard let first = rows.first else { return nil }
                let app = ProcessGroup(row: first)
                if showingAll, !query.isEmpty {
                    guard app.name.localizedStandardContains(query) || rows.contains(where: {
                        ($0.name ?? "").localizedStandardContains(query) || String($0.pid).contains(query)
                    }) else { return nil }
                }
                let group = AppUsage(app: app, rows: rows)
                return showingAll || (effective == .power ? group.watts != nil : group.cpu != nil) ? group : nil
            }
            .sorted {
                let left = (effective == .power ? $0.watts : $0.cpu) ?? -1
                let right = (effective == .power ? $1.watts : $1.cpu) ?? -1
                return left == right ? $0.id < $1.id : left > right
            }
        let shown = showingAll ? groups : Array(groups.prefix(7))
        let scale = shown.compactMap { effective == .power ? $0.watts : $0.cpu }.max() ?? 1

        return VStack(alignment: .leading, spacing: 0) {
            if !showingAll { trend.padding(.bottom, 14) }
            HStack {
                if showingAll {
                    Button {
                        showingAll = false
                        search = ""
                        expanded.removeAll()
                    } label: { Label("Top apps", systemImage: "chevron.left").font(Pulse.detail) }
                    .buttonStyle(.borderless)
                } else {
                    Text("Top apps now").font(Pulse.bodyStrong)
                }
                Spacer()
                Picker("Sort by", selection: Binding(get: { effective }, set: { order = $0 })) {
                    ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(!hasPower)
                .help(hasPower ? "Rank apps by CPU power or CPU use" : "CPU power isn’t available on this Mac")
            }
            .padding(.bottom, 8)
            if showingAll {
                TextField("Search apps, processes or PIDs", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.bottom, 8)
            }
            if shown.isEmpty {
                Text("No matching apps").font(Pulse.detail).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { group in
                            row(group, order: effective, scale: scale)
                        }
                    }
                }
                .frame(maxHeight: showingAll ? 300 : 236)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !showingAll {
                Button("All apps and processes") { showingAll = true }
                    .buttonStyle(.borderless)
                    .font(Pulse.detail)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, Pulse.gutter)
        .padding(.vertical, 14)
    }

    private var trend: some View {
        let points = activity.compactMap { point in point.measuredCPUPercent.map { (at: point.at, cpu: $0) } }
        let ceiling = max(100, ((points.map(\.cpu).max() ?? 0) / 100).rounded(.up) * 100)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(points.last.map { PulseFormat.percent($0.cpu) } ?? "—").font(Pulse.figure)
                    Text("All apps, last 3 minutes").font(Pulse.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if points.count > 1 {
                Chart(points, id: \.at) { point in
                    AreaMark(x: .value("Time", point.at), y: .value("CPU", point.cpu))
                        .foregroundStyle(Color.accentColor.opacity(0.14))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.at), y: .value("CPU", point.cpu))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, ceiling]) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(PulseFormat.percent(number)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 54)
            }
        }
    }

    private func row(_ group: AppUsage, order: Order, scale: Double) -> some View {
        let value = order == .power ? group.watts : group.cpu
        let isOpen = expanded.contains(group.id)
        return VStack(spacing: 0) {
            Button {
                if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Text(group.app.name).font(Pulse.body).lineLimit(1)
                    Spacer(minLength: 6)
                    ShareBar(fraction: (value ?? 0) / max(scale, 0.0001), color: Color.accentColor.opacity(0.75))
                        .frame(width: 44, height: 4)
                    Text(group.cpu.map(PulseFormat.precisePercent) ?? "—")
                        .font(Pulse.detail.monospacedDigit())
                        .foregroundStyle(order == .cpu ? .primary : .secondary)
                        .frame(width: 50, alignment: .trailing)
                    Text(group.watts.map(PulseFormat.power) ?? "—")
                        .font(Pulse.detail.monospacedDigit())
                        .foregroundStyle(order == .power ? .primary : .secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 4) {
                    ForEach(group.rows) { process in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(process.name ?? process.path.map { ($0 as NSString).lastPathComponent } ?? "PID \(process.pid)")
                                    .font(Pulse.detail).lineLimit(1).truncationMode(.middle)
                                Text("PID \(process.pid)").font(Pulse.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(process.cpuPercent.map(PulseFormat.precisePercent) ?? "—")
                                .frame(width: 50, alignment: .trailing)
                            Text(process.cpuPower.map { PulseFormat.power($0.watts) } ?? "—")
                                .frame(width: 58, alignment: .trailing)
                        }
                        .font(Pulse.detail.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
                .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Welcome

/// Live wrapper used by the app's welcome window.
struct WelcomeContainer: View {
    @ObservedObject var model: MonitorModel
    let onShowPanel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        WelcomeView(activity: model.activity, interval: model.interval, monitoring: model.monitoringEnabled,
                    onShowPanel: onShowPanel, onFinish: onFinish)
            // The window's title bar is transparent; let the layout's own top padding clear it.
            .ignoresSafeArea()
    }
}

/// A short first-launch introduction: what CrashPulse does, what it watches, and where it lives.
struct WelcomeView: View {
    let activity: [ActivityPoint]
    let interval: Int
    let monitoring: Bool
    let onShowPanel: () -> Void
    let onFinish: () -> Void
    @State private var page: Int

    static let size = CGSize(width: 440, height: 480)
    private static let pageCount = 3

    init(activity: [ActivityPoint], interval: Int, monitoring: Bool, startPage: Int = 0,
         onShowPanel: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.activity = activity
        self.interval = interval
        self.monitoring = monitoring
        self.onShowPanel = onShowPanel
        self.onFinish = onFinish
        _page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                switch page {
                case 0: intro.transition(.opacity)
                case 1: watches.transition(.opacity)
                default: menuBar.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.top, 44)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // Page 1: what CrashPulse is for.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.leading, -6)
                .padding(.bottom, 18)
                .accessibilityHidden(true)
            Text("Welcome to CrashPulse")
                .font(Pulse.title)
                .padding(.bottom, 8)
            Text("CrashPulse notices when an app keeps your Mac’s CPU busy for too long, and tells you which app it was.")
                .font(Pulse.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)
            WelcomeTrace()
                .frame(height: 110)
        }
    }

    // Page 2: what it watches, with the Mac's real CPU use as proof that it is already running.
    private var watches: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What CrashPulse watches")
                .font(Pulse.title)
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 16) {
                feature("gauge.with.dots.needle.50percent", "Checks every \(interval) seconds",
                        "It samples CPU use of the apps running under your account. Readings stay on this Mac.")
                feature("waveform.path.ecg", "Records sustained spikes",
                        "When an app keeps the CPU busy for 30 seconds or more, it becomes an event.")
                feature("text.magnifyingglass", "Explains each one",
                        "See which app it was, how long it lasted and what you can do.")
            }
            Spacer(minLength: 16)
            Divider().padding(.bottom, 12)
            liveReading
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Pulse.bodyStrong)
                Text(detail)
                    .font(Pulse.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var liveReading: some View {
        let points = activity.compactMap(\.measuredCPUPercent)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Mac right now").font(Pulse.caption).foregroundStyle(.secondary)
                if let latest = points.last {
                    Text("\(PulseFormat.percent(latest)) CPU").font(Pulse.figure)
                } else {
                    Text(monitoring ? "Taking the first readings…" : "Monitoring is paused")
                        .font(Pulse.bodyStrong)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if points.count > 1 {
                Sparkline(values: points.suffix(36).map { Optional($0) })
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 120, height: 30)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    // Page 3: where to find it, and that an empty list is normal.
    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Find it in the menu bar")
                .font(Pulse.title)
                .padding(.bottom, 22)
            MenuBarSketch()
                .padding(.bottom, 22)
            Text("Click the pulse icon any time to see recent events and what is using the CPU now. CrashPulse keeps watching while the panel is closed.")
                .font(Pulse.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text("Your event list may be empty for a while. Events appear only when an app stays busy.")
                .font(Pulse.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(Self.pageCount)")
            Spacer()
            if page > 0 {
                Button("Back") { go(page - 1) }
                    .keyboardShortcut(.cancelAction)
            }
            if page < Self.pageCount - 1 {
                Button("Continue") { go(page + 1) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done", action: onFinish)
                Button("Show Me", action: onShowPanel)
                    .keyboardShortcut(.defaultAction)
                    .help("Close this window and open the CrashPulse panel from the menu bar")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func go(_ target: Int) {
        withAnimation(.easeInOut(duration: 0.18)) { page = min(max(target, 0), Self.pageCount - 1) }
    }
}

/// The app's signature trace in miniature: a calm line, a sustained spike inside a tinted span, then calm again.
private struct WelcomeTrace: View {
    private static let values: [Double?] = [14, 11, 16, 12, 15, 13, 150, 228, 214, 236, 219, 232, 222, 238, 226, 18, 13, 16, 12, 14]
    private static let span = (start: 5.5, end: 14.5)

    var body: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(Self.values.count - 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Pulse.severe.opacity(0.08))
                    .frame(width: CGFloat(Self.span.end - Self.span.start) * step)
                    .offset(x: CGFloat(Self.span.start) * step)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height - 0.5))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height - 0.5))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                Sparkline(values: Self.values)
                    .stroke(Pulse.severe, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .padding(.vertical, 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A simplified menu bar with the CrashPulse item highlighted and its panel hanging below.
private struct MenuBarSketch: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            bar
            panel
                .padding(.trailing, 12)
                .padding(.top, 6)
        }
        .accessibilityElement()
        .accessibilityLabel("The CrashPulse pulse icon in the menu bar opens a panel with Events and Live")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 14, height: 7)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 0) {
                    Capsule().fill(Color.primary.opacity(0.16)).frame(width: 36, height: 10)
                    Capsule().fill(Color.clear).frame(width: 36, height: 10)
                }
                .padding(2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .frame(maxWidth: .infinity)
                sketchRow(dot: Pulse.severe, width: 64)
                sketchRow(dot: Pulse.signal, width: 48)
                sketchRow(dot: Color.secondary, width: 72)
            }
            .padding(12)
            .frame(width: 168)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sketchRow(dot: Color, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Capsule().fill(Color.primary.opacity(0.18)).frame(width: width, height: 5)
            Spacer(minLength: 0)
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 22, height: 5)
        }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 24)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Messages

struct PanelMessage: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(title).font(Pulse.bodyStrong)
            if let message {
                Text(message)
                    .font(Pulse.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0, action: action.1).controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: MonitorModel
    var showWelcome: (() -> Void)? = nil
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
                if let showWelcome, model.run.canRecordHistory {
                    Button("Show Welcome…", action: showWelcome)
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

#if DEBUG
// MARK: - Debug preview renderer

/// `CrashPulseOff --render-ui OUTPUT_DIR [HISTORY_DIR]` writes PNGs of each panel state in light and dark
/// appearance, using sample events and a live process scan. Debug builds only.
enum UIPreviewRenderer {
    @MainActor
    static func run(_ arguments: [String]) -> Int32 {
        guard let output = arguments.first else {
            FileHandle.standardError.write(Data("Usage: --render-ui OUTPUT_DIR [HISTORY_DIR]\n".utf8))
            return EX_USAGE
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let fixtures = PreviewData.events(now: now)
        var events = fixtures
        if arguments.count > 1,
           let real = try? CPUHistoryStore(directory: URL(fileURLWithPath: arguments[1], isDirectory: true),
                                           policy: HighCPUPolicy()).report(now: now) {
            events += real.events
        }
        let browser = ProcessGroup(path: "/Applications/Arc.app/Contents/MacOS/Arc")!
        let report = CPUHistoryReport(generatedAt: now, policy: HighCPUPolicy(), events: events, batteryToday: nil,
                                      recurringBackgroundActivity: [RecurringActivity(app: PreviewData.indexer, events: 3, days: 3)])
        _ = browser

        var collector = ProcessCollector()
        _ = collector.collect()
        Thread.sleep(forTimeInterval: 1.5)
        let snapshot = collector.collect()
        let activity = PreviewData.activity(now: now)

        let watching = PanelStatus(text: "Watching, plugged in", color: Pulse.watching)
        func panel<V: View>(_ tab: MenuMonitorView.Tab, @ViewBuilder _ content: () -> V) -> some View {
            PanelChrome(status: watching, monitoring: true, showsTabs: true, tab: .constant(tab),
                        onToggleMonitoring: {}, openSettings: {}, content: content)
        }

        var scenes: [(String, AnyView)] = [
            ("1-events", AnyView(panel(.events) {
                EventListView(report: report, showIgnored: .constant(false), onSelect: { _ in }, onToggleIgnored: { _ in })
            })),
            ("6-live", AnyView(panel(.live) {
                LiveView(snapshot: snapshot, activity: activity, monitoring: true, isVisible: true, onResume: {})
            })),
            ("7-empty", AnyView(panel(.events) {
                EventListView(report: CPUHistoryReport(generatedAt: now, policy: HighCPUPolicy(), events: [],
                                                       batteryToday: nil, recurringBackgroundActivity: []),
                              showIgnored: .constant(false), onSelect: { _ in }, onToggleIgnored: { _ in })
            })),
        ]
        for page in 0..<3 {
            scenes.append(("8-welcome-\(page + 1)", AnyView(
                WelcomeView(activity: activity, interval: 5, monitoring: true, startPage: page,
                            onShowPanel: {}, onFinish: {})
            )))
        }
        for (index, event) in fixtures.enumerated() {
            scenes.append(("\(index + 2)-detail", AnyView(panel(.events) {
                EventDetailView(event: event, onBack: {}, onOpenLive: {}, onToggleIgnored: {})
            })))
        }

        for (name, view) in scenes {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                if !render(view, appearance: appearance, to: url) {
                    FileHandle.standardError.write(Data("Could not render \(url.lastPathComponent)\n".utf8))
                    return EXIT_FAILURE
                }
            }
        }
        print(directory.path)
        return EXIT_SUCCESS
    }

    @MainActor
    private static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

private enum PreviewData {
    static let indexer = ProcessGroup(path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores")!

    static func activity(now: Date) -> [ActivityPoint] {
        (0..<36).map { index in
            let wave = 40 + 25 * sin(Double(index) / 4) + (index > 26 ? 90 : 0)
            return ActivityPoint(at: now.addingTimeInterval(Double(index - 35) * 5), measuredCPUPercent: wave,
                                 triggerCPUPercent: nil)
        }
    }

    static func events(now: Date) -> [HighCPUEvent] {
        [
            make(now: now, minutesAgo: 1, seconds: 95, ended: false, impact: .review, fg: 0, bg: 12,
                 path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", base: 6, level: 160,
                 energy: nil, processes: [("com.docker.backend", 0.71), ("qemu-system-aarch64", 0.22), ("vpnkit", 0.03)]),
            make(now: now, minutesAgo: 42, seconds: 250, ended: true, impact: .sustained, fg: 2, bg: 40,
                 path: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)",
                 base: 12, level: 240, energy: 0.0182,
                 processes: [("Browser Helper (Renderer)", 0.58), ("Browser Helper (GPU)", 0.19), ("Arc", 0.11)]),
            make(now: now, minutesAgo: 190, seconds: 64, ended: true, impact: .activity, fg: 11, bg: 1,
                 path: "/Applications/Xcode.app/Contents/MacOS/Xcode", base: 20, level: 310, energy: 0.0061,
                 processes: [("swift-frontend", 0.64), ("Xcode", 0.21), ("clang", 0.08)]),
            make(now: now, minutesAgo: 60 * 26, seconds: 41, ended: true, impact: nil, fg: 0, bg: 0,
                 path: indexer.id, base: 0, level: 95, energy: nil, processes: []),
            make(now: now, minutesAgo: 75, seconds: 105, ended: true, impact: .sustained, fg: 0, bg: 20,
                 path: "/Applications/Browser.app/Contents/MacOS/Browser", base: 12, level: 180,
                 energy: 0.034, processes: [("Browser Helper", 0.60)],
                 triggerPath: "/Applications/Indexer.app/Contents/MacOS/Indexer"),
        ]
    }

    private static func make(now: Date, minutesAgo: Double, seconds: Double, ended: Bool,
                             impact: EventEvidence.Impact?, fg: Int, bg: Int, path: String,
                             base: Double, level: Double, energy: Double?,
                             processes: [(String, Double)], triggerPath: String? = nil) -> HighCPUEvent {
        let start = now.addingTimeInterval(-minutesAgo * 60)
        let end = start.addingTimeInterval(seconds)
        let identity = ProcessIdentity(pid: Int32(400 + Int(minutesAgo)), startSeconds: 1_800_000_000, startMicroseconds: 0)
        let app = ProcessGroup(path: path)!
        let trigger = triggerPath ?? path
        var event = HighCPUEvent(id: UUID(), identity: identity, processStartTicks: 1,
                                 name: (trigger as NSString).lastPathComponent, path: trigger,
                                 startedAt: start, lastObservedAt: end, observedDurationSeconds: seconds,
                                 peakCPUPercent: level * 1.06, endReason: ended ? .processExited : nil)
        event.triggerApp = ProcessGroup.bundle(for: trigger)
        event.observedCPUEnergyWattHours = triggerPath == nil ? energy : nil
        guard let impact else { return event }
        func point(_ offset: Double, _ value: Double) -> ActivityPoint {
            ActivityPoint(at: start.addingTimeInterval(offset), measuredCPUPercent: value + 35 + Double(Int(offset) % 3) * 6,
                          triggerCPUPercent: value)
        }
        let before = stride(from: -30.0, to: 0, by: 5).map { point($0, base + Double(Int($0) % 2) * 3) }
        let during = stride(from: 5.0, through: seconds, by: 5).map { offset -> ActivityPoint in
            let ramp = min(1, offset / 15)
            return point(offset, base + (level - base) * ramp * (0.9 + 0.1 * sin(offset / 7)))
        }
        let after = ended ? stride(from: 5.0, through: 15, by: 5).map { point(seconds + $0, base * 1.2) } : []
        let contributions = processes.enumerated().map { index, item in
            ProcessContribution(identity: ProcessIdentity(pid: Int32(900 + index), startSeconds: 1, startMicroseconds: 0),
                                processStartTicks: UInt64(index), name: item.0, path: path, app: app,
                                firstObservedAt: start, lastObservedAt: end, observedSeconds: seconds,
                                cpuCoreSeconds: seconds * item.1, cpuShare: item.1,
                                cpuEnergyWattHours: nil, energyObservedSeconds: 0)
        }
        event.forensics = EventEvidence(suspectedApp: app, basis: .aboveBaseline, impact: impact,
                                        topProcesses: contributions, suspectedAppCPUShare: processes.first.map { _ in 0.86 },
                                        suspectedAppCPUWattHours: energy, measuredCPUCoreSeconds: seconds * level / 100,
                                        measuredCPUWattHours: energy, estimatedExtraCPUWattHours: energy,
                                        foregroundSamples: fg, backgroundSamples: bg,
                                        before: before, during: during, after: after, afterComplete: ended)
        return event
    }
}
#endif
