import AppKit
import Combine
import UserNotifications

@MainActor
final class BackgroundNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "backgroundCPUAlertsEnabled")
    @Published private(set) var permission: BackgroundAlertPermission = .unavailable
    @Published private(set) var requesting = false

    private let center = UNUserNotificationCenter.current()
    private let preferenceKey = "backgroundCPUAlertsEnabled"
    private var presentation: UNNotificationPresentationOptions = []
    private var refreshGeneration = 0
    var onOpenEvent: ((UUID) -> Void)?

    var canEvaluate: Bool { enabled && permission.allowsDelivery }

    func installDelegate() {
        center.delegate = self
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: preferenceKey)
        guard value else { return }
        requesting = true
        Task {
            defer { requesting = false }
            if await center.notificationSettings().authorizationStatus == .notDetermined, enabled {
                do {
                    _ = try await center.requestAuthorization(options: [.alert])
                } catch {
                    HistoryCommand.log("Notification authorization failed: \(error.localizedDescription)")
                }
            }
            await refreshPermission()
        }
    }

    func refreshPermission() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let settings = await center.notificationSettings()
        guard generation == refreshGeneration else { return }
        presentation = []
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notRequested
        case .denied: permission = .denied
        case .authorized:
            if settings.notificationCenterSetting == .enabled { presentation.insert(.list) }
            if settings.alertSetting == .enabled, settings.alertStyle != .none { presentation.insert(.banner) }
            permission = presentation.contains(.banner) ? .allowed : (presentation.isEmpty ? .denied : .quiet)
        case .provisional:
            permission = .quiet
            presentation = [.list]
        @unknown default: permission = .unavailable
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func deliver(_ alerts: [BackgroundCPUAlert]) async {
        guard enabled, !alerts.isEmpty else { return }
        await refreshPermission()
        for alert in alerts where canEvaluate {
            let content = UNMutableNotificationContent()
            let cpu = alert.averageCPU.formatted(.number.precision(.fractionLength(0)))
            switch alert.level {
            case .sustained:
                content.title = "Background CPU activity"
                content.body = "\(alert.name) averaged \(cpu)% CPU for \(alert.seconds) seconds while not in the foreground."
            case .severe:
                content.title = "High background CPU activity"
                content.body = "\(alert.name) averaged \(cpu)% CPU for \(alert.seconds) seconds while not in the foreground."
            }
            do {
                try await post(content, eventID: alert.eventID)
            } catch {
                HistoryCommand.log("Background CPU notification failed: \(error.localizedDescription)")
            }
        }
    }

    #if DEBUG
    func deliverTest(eventID: UUID) async throws {
        let content = UNMutableNotificationContent()
        content.title = "CrashPulse test notification"
        content.body = "Open the sample event to test navigation."
        try await post(content, eventID: eventID)
    }
    #endif

    private func post(_ content: UNMutableNotificationContent, eventID: UUID) async throws {
        content.userInfo = [BackgroundCPUAlert.eventIDKey: eventID.uuidString]
        let request = UNNotificationRequest(identifier: eventID.uuidString, content: content, trigger: nil)
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard BackgroundCPUAlert.eventID(in: notification.request.content.userInfo) != nil else { return [] }
        return await foregroundPresentation()
    }

    private func foregroundPresentation() -> UNNotificationPresentationOptions {
        canEvaluate ? presentation : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = BackgroundCPUAlert.eventID(in: response.notification.request.content.userInfo)
        else { return }
        await openEvent(id)
    }

    private func openEvent(_ id: UUID) {
        onOpenEvent?(id)
    }
}
