import AppKit
import ServiceManagement
import UserNotifications

// Mac notifications for new episodes. Needs a real app bundle: a bare `swift run` binary has none.
enum Alerts {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func ask() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String) {
        guard available else { print("alert:", title, "-", body); return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["anime": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + body, content: c, trigger: nil))
    }

    // Alerts only arrive while Otaku runs, so offer to start it at login.
    static var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { _ = try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}
