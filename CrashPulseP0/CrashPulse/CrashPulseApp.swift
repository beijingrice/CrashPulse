import AppKit
import SwiftUI

enum CrashPulseApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = CrashPulseDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class CrashPulseDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MonitorModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.woke() }
        }
        model.startIfEnabled()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsWindow?.isVisible == true {
            sender.activate()
            settingsWindow?.makeKeyAndOrderFront(nil)
        } else {
            showPopover()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasSamplingTask else { return .terminateNow }
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "CrashPulse"
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "CrashPulse")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("CrashPulse")
        item.button?.toolTip = "CrashPulse"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let host = NSHostingController(rootView: MenuMonitorView(model: model, openSettings: { [weak self] in
            self?.showSettings()
        }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        model.panelVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelVisible = false
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: MonitorSettingsView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "CrashPulse Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private actor SamplingWorker {
    struct Reading: Sendable {
        let snapshot: Snapshot
        let historyError: String?
        let activity: [ActivityPoint]
    }

    private var collector = ProcessCollector()
    private var history: CPUHistoryRecorder?
    private var historyStore: CPUHistoryStore?
    private var historyError: String?
    private var interval = 5

    func reset(interval: Int, recordHistory: Bool) -> MachTimebase {
        collector = ProcessCollector()
        historyError = nil
        self.interval = interval
        if recordHistory {
            do {
                historyStore = try Self.defaultStore()
            } catch {
                reportHistoryError(error)
            }
        }
        return collector.timebase
    }

    func collect(resetForWake: Bool, foregroundPID: Int32?) -> Reading {
        var snapshot = collector.collect(resetForWake: resetForWake)
        snapshot.foregroundPID = foregroundPID
        if let historyStore {
            do {
                if history == nil { history = try historyStore.startRecording(intervalSeconds: interval) }
                try history?.ingest(snapshot)
                historyError = nil
            } catch {
                reportHistoryError(error)
            }
        }
        return Reading(snapshot: snapshot, historyError: historyError, activity: history?.activity ?? [])
    }

    func stop() -> String? {
        defer {
            history = nil
            historyStore = nil
        }
        guard let history else { return historyError }
        do {
            try history.stop()
            historyError = nil
        } catch {
            reportHistoryError(error)
        }
        return historyError
    }

    func historyReport() throws -> CPUHistoryReport {
        if let history { return history.report() }
        return try Self.defaultStore().report()
    }

    func setEventIgnored(_ id: UUID, ignored: Bool) throws {
        if let history {
            try history.setIgnored(ignored, id: id)
        } else {
            try Self.defaultStore().setIgnored(ignored, id: id)
        }
    }

    private static func defaultStore() throws -> CPUHistoryStore {
        try CPUHistoryStore(directory: CPUHistoryStore.defaultDirectory(), policy: HighCPUPolicy())
    }

    private func reportHistoryError(_ error: Error) {
        let message = error.localizedDescription
        if historyError != message {
            HistoryCommand.log(message)
            historyError = message
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var interval: Int
    @Published private(set) var monitoringEnabled: Bool
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var historyError: String?
    @Published private(set) var activity: [ActivityPoint] = []
    @Published var panelVisible = false
    let run = RunInfo.current()

    private let worker = SamplingWorker()
    private var task: Task<Void, Never>?
    private var wakeGeneration = 0
    private var snapshotInterval = 5
    private var snapshotTimebase: MachTimebase?
    private var quitting = false
    private let defaults = UserDefaults.standard
    private let intervalKey = "monitoringInterval"
    private let enabledKey = "monitoringEnabled"

    init() {
        let saved = defaults.integer(forKey: intervalKey)
        interval = DiagnosticCapture.intervals.contains(saved) ? saved : 5
        monitoringEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    var hasSamplingTask: Bool { task != nil }

    func setMonitoring(_ enabled: Bool) {
        guard monitoringEnabled != enabled else { return }
        monitoringEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            startIfEnabled()
        } else {
            task?.cancel()
        }
    }

    func setInterval(_ seconds: Int) {
        guard seconds != interval, DiagnosticCapture.intervals.contains(seconds) else { return }
        interval = seconds
        defaults.set(seconds, forKey: intervalKey)
        if monitoringEnabled {
            task?.cancel()
            startIfEnabled()
        }
    }

    func startIfEnabled() {
        guard monitoringEnabled, task == nil, !quitting else { return }
        snapshot = nil
        historyError = nil
        activity = []
        let interval = interval
        let recordHistory = run.canRecordHistory
        task = Task { [weak self, worker] in
            defer {
                self?.task = nil
                self?.startIfEnabled()
            }
            let timebase = await worker.reset(interval: interval, recordHistory: recordHistory)
            let clock = SuspendingClock()
            var deadline = clock.now
            var previousWake = self?.wakeGeneration
            while !Task.isCancelled, let self {
                let currentWake = wakeGeneration
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let result = await worker.collect(resetForWake: currentWake != previousWake,
                                                  foregroundPID: foreground)
                guard !Task.isCancelled else { break }
                if currentWake != wakeGeneration {
                    deadline = clock.now
                    continue
                }
                snapshot = result.snapshot
                historyError = result.historyError
                activity = result.activity
                snapshotInterval = interval
                snapshotTimebase = timebase
                previousWake = currentWake
                deadline += .seconds(interval)
                if deadline <= clock.now {
                    deadline = clock.now + .seconds(interval)
                }
                do {
                    try await clock.sleep(until: deadline, tolerance: .milliseconds(50))
                } catch {
                    break
                }
            }
            let finalHistoryError = await worker.stop()
            self?.historyError = finalHistoryError
        }
    }

    func woke() {
        wakeGeneration += 1
    }

    func prepareToQuit() async {
        quitting = true
        task?.cancel()
        await task?.value
    }

    func report() throws -> Data? {
        guard let snapshot, let snapshotTimebase else { return nil }
        return try DiagnosticReport(run: run, intervalSeconds: snapshotInterval,
                                    timebase: snapshotTimebase, snapshots: [snapshot],
                                    historyError: historyError).encoded()
    }

    func historyReport() async throws -> CPUHistoryReport {
        try await worker.historyReport()
    }

    func setEventIgnored(_ id: UUID, ignored: Bool) async throws {
        try await worker.setEventIgnored(id, ignored: ignored)
    }
}
