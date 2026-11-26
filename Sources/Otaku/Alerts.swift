import AppKit
import ServiceManagement
import UserNotifications

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

    static var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { _ = try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}
