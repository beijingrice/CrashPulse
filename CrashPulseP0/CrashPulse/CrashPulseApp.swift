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
final class CrashPulseDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model = MonitorModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// Set once the welcome window has been seen. Launch with `-showWelcome YES` to show it again.
    private static let welcomeCompletedKey = "welcomeCompleted"

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard model.run.canRecordHistory else { return }
        model.notifications.onOpenEvent = { [weak self] id in self?.openEvent(id) }
        model.notifications.installDelegate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.woke() }
        }
        if model.run.canRecordHistory {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let identity = MonitorModel.foregroundIdentity(app)
                MainActor.assumeIsolated {
                    self?.model.foregroundChanged(identity)
                }
            }
            refreshAlertPermission()
        }
        let firstLaunch = shouldShowWelcome()
        model.startIfEnabled()
        if model.eventNavigation != nil { showPopover() }
        else if firstLaunch { showWelcome() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshAlertPermission()
    }

    private func refreshAlertPermission() {
        guard model.run.canRecordHistory else { return }
        Task { await model.notifications.refreshPermission() }
    }

    /// True on a genuine first launch. People who used CrashPulse before the welcome existed already
    /// have a history journal, so they are marked as done instead.
    private func shouldShowWelcome() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "showWelcome") { return true }
        guard model.run.canRecordHistory, !defaults.bool(forKey: Self.welcomeCompletedKey) else { return false }
        if let directory = try? CPUHistoryStore.defaultDirectory(),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("cpu-history.json").path) {
            defaults.set(true, forKey: Self.welcomeCompletedKey)
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if welcomeWindow?.isVisible == true {
            sender.activate()
            welcomeWindow?.makeKeyAndOrderFront(nil)
        } else if settingsWindow?.isVisible == true {
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
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
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

    private func openEvent(_ id: UUID) {
        model.eventNavigation = MonitorModel.EventNavigation(eventID: id)
        guard statusItem != nil else { return }
        NSApp.activate()
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
        } else {
            showPopover()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.panelVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelVisible = false
    }

    private func showSettings() {
        popover.performClose(nil)
        refreshAlertPermission()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: MonitorSettingsView(model: model, showWelcome: { [weak self] in
                self?.settingsWindow?.close()
                self?.showWelcome()
            }))
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

    private func showWelcome() {
        popover.performClose(nil)
        if welcomeWindow == nil {
            let host = NSHostingController(rootView: WelcomeContainer(
                model: model,
                onShowPanel: { [weak self] in self?.finishWelcome(showPanel: true) },
                onFinish: { [weak self] in self?.finishWelcome(showPanel: false) }))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to CrashPulse"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // The content runs under the transparent title bar, so the frame is the design size.
            window.setFrame(NSRect(origin: window.frame.origin, size: WelcomeView.size), display: false)
            window.delegate = self
            window.center()
            welcomeWindow = window
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    private func finishWelcome(showPanel: Bool) {
        welcomeWindow?.close()
        if showPanel {
            // Let the window finish closing so the popover becomes key.
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        // Closing the window any way counts as having seen it.
        UserDefaults.standard.set(true, forKey: Self.welcomeCompletedKey)
        welcomeWindow = nil
    }
}

private actor SamplingWorker {
    struct Reading: Sendable {
        let snapshot: Snapshot
        let historyError: String?
        let activity: [ActivityPoint]
        let alerts: [BackgroundCPUAlert]
    }

    private var collector = ProcessCollector()
    private var history: CPUHistoryRecorder?
    private var historyStore: CPUHistoryStore?
    private var historyError: String?
    private var interval = 5
    private let historyDirectory: URL?

    init(historyDirectory: URL? = nil) {
        self.historyDirectory = historyDirectory
    }

    func reset(interval: Int, recordHistory: Bool) -> MachTimebase {
        collector = ProcessCollector()
        historyError = nil
        self.interval = interval
        if recordHistory {
            do {
                historyStore = try makeStore()
            } catch {
                reportHistoryError(error)
            }
        }
        return collector.timebase
    }

    func collect(resetForWake: Bool, foregroundPID: Int32?) -> Snapshot {
        var snapshot = collector.collect(resetForWake: resetForWake)
        snapshot.foregroundPID = foregroundPID
        return snapshot
    }

    func record(_ snapshot: Snapshot, background: BackgroundForeground?) -> Reading {
        var alerts: [BackgroundCPUAlert] = []
        if let historyStore {
            do {
                if history == nil { history = try historyStore.startRecording(intervalSeconds: interval) }
                alerts = try history?.ingest(snapshot, background: background) ?? []
                historyError = nil
            } catch {
                reportHistoryError(error)
            }
        }
        return Reading(snapshot: snapshot, historyError: historyError, activity: history?.activity ?? [], alerts: alerts)
    }

    func collectAndRecord(resetForWake: Bool, foregroundPID: Int32?) -> Reading {
        record(collect(resetForWake: resetForWake, foregroundPID: foregroundPID), background: nil)
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
        return try makeStore().report()
    }

    func setEventIgnored(_ id: UUID, ignored: Bool) throws {
        if let history {
            try history.setIgnored(ignored, id: id)
        } else {
            try makeStore().setIgnored(ignored, id: id)
        }
    }

    #if DEBUG
    func createNotificationTestEvent() throws -> UUID {
        if let history { return try history.createNotificationTestEvent() }
        let recorder = try makeStore().startRecording(intervalSeconds: interval)
        let id = try recorder.createNotificationTestEvent()
        try recorder.stop()
        return id
    }
    #endif

    private func makeStore() throws -> CPUHistoryStore {
        try CPUHistoryStore(directory: historyDirectory ?? CPUHistoryStore.defaultDirectory(), policy: HighCPUPolicy())
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
    struct EventNavigation: Equatable {
        let id = UUID()
        let eventID: UUID
    }

    @Published private(set) var interval: Int
    @Published private(set) var monitoringEnabled: Bool
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var historyError: String?
    @Published private(set) var activity: [ActivityPoint] = []
    @Published var panelVisible = false
    @Published var eventNavigation: EventNavigation?
    let run = RunInfo.current()
    let notifications = BackgroundNotifications()

    private let worker: SamplingWorker
    private var foreground: BackgroundForeground?
    private var departedApps: [String: UInt64] = [:]
    private var backgroundGraceTicks: UInt64 = 0
    private var task: Task<Void, Never>?
    private var wakeGeneration = 0
    private var snapshotInterval = 5
    private var snapshotTimebase: MachTimebase?
    private var quitting = false
    private let defaults = UserDefaults.standard
    private let intervalKey = "monitoringInterval"
    private let enabledKey = "monitoringEnabled"

    init() {
        #if DEBUG
        worker = SamplingWorker(historyDirectory: Self.debugAlertDirectory)
        #else
        worker = SamplingWorker()
        #endif
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
            if timebase.isValid {
                self?.backgroundGraceTicks = UInt64(10_000_000_000 * Double(timebase.denominator) / Double(timebase.numerator))
            }
            let clock = SuspendingClock()
            var deadline = clock.now
            var previousWake = self?.wakeGeneration
            while !Task.isCancelled, let self {
                let currentWake = wakeGeneration
                let frontmost = NSWorkspace.shared.frontmostApplication
                let result: SamplingWorker.Reading
                if let before = foregroundForAlerts(frontmost) {
                    let collected = await worker.collect(resetForWake: currentWake != previousWake,
                                                         foregroundPID: frontmost?.processIdentifier)
                    guard !Task.isCancelled else { break }
                    if currentWake != wakeGeneration {
                        deadline = clock.now
                        continue
                    }
                    let after = foregroundForAlerts(NSWorkspace.shared.frontmostApplication)
                    result = await worker.record(collected, background: before == after ? after : nil)
                } else {
                    result = await worker.collectAndRecord(resetForWake: currentWake != previousWake,
                                                           foregroundPID: frontmost?.processIdentifier)
                }
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
                if !result.alerts.isEmpty { await notifications.deliver(result.alerts) }
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

    nonisolated static func foregroundIdentity(_ app: NSRunningApplication?) -> (pid: Int32, key: String)? {
        guard let app else { return nil }
        let path = app.bundleURL?.path
        let appKey = path.flatMap { ProcessGroup.bundle(for: $0 + "/Contents/")?.id ?? $0 }
            ?? app.executableURL?.path
        guard let appKey else { return nil }
        return (app.processIdentifier, appKey)
    }

    func foregroundChanged(_ identity: (pid: Int32, key: String)?) {
        guard notifications.canEvaluate else {
            foreground = nil
            departedApps.removeAll(keepingCapacity: true)
            return
        }
        let now = mach_absolute_time()
        if let previous = foreground {
            guard previous.pid != identity?.pid || previous.appKey != identity?.key else { return }
            departedApps = departedApps.filter { $0.value > now }
            departedApps[previous.appKey] = now + backgroundGraceTicks
        }
        foreground = identity.map {
            BackgroundForeground(pid: $0.pid, appKey: $0.key, observedSince: now, graceUntil: departedApps)
        }
    }

    private func foregroundForAlerts(_ app: NSRunningApplication?) -> BackgroundForeground? {
        guard notifications.canEvaluate else {
            foreground = nil
            return nil
        }
        foregroundChanged(Self.foregroundIdentity(app))
        return foreground
    }

    #if DEBUG
    static var debugAlertDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-background-alerts"),
              let path = arguments.dropFirst(index + 1).first, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func sendNotificationTest() async throws {
        guard Self.debugAlertDirectory != nil, notifications.canEvaluate else { return }
        let id = try await worker.createNotificationTestEvent()
        try await notifications.deliverTest(eventID: id)
    }
    #endif

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
