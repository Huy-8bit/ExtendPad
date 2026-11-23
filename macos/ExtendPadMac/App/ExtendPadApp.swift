import SwiftUI
import AppKit
import ExtendPadCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        _ = AppController.shared
    }

    /// Re-opening the app from Finder shows Settings (useful when the menu bar icon is hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in SettingsWindow.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppController.shared.engine.stop()
        return .terminateNow
    }
}

/// Holds only the menu-bar visibility, so status updates never re-render the App scene.
@MainActor
final class MenuIconState: ObservableObject {
    static let shared = MenuIconState()
    @Published var visible: Bool = UserDefaults.standard.object(forKey: "showMenuIcon") as? Bool ?? true
}

struct ExtendPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var iconState = MenuIconState.shared

    var body: some Scene {
        // MenuBarExtra writes `isInserted` back even when nothing changed; ignoring same-value
        // writes avoids a SwiftUI update loop that would otherwise pin the main thread.
        MenuBarExtra(isInserted: Binding(
            get: { iconState.visible },
            set: { v in if iconState.visible != v { iconState.visible = v; AppController.shared.showMenuIcon = v } }
        )) {
            MenuView().environmentObject(AppController.shared)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status-bar symbol; observes the controller on its own so only this view updates.
struct MenuBarIcon: View {
    @ObservedObject private var controller = AppController.shared
    var body: some View { Image(systemName: symbol) }
    private var symbol: String {
        switch controller.status.phase {
        case .streaming: return "rectangle.on.rectangle.angled.fill"
        case .error, .adbMissing, .tunnelFailed: return "exclamationmark.triangle"
        default: return "rectangle.on.rectangle.angled"
        }
    }
}

/// AppKit-hosted settings window (reliable from an accessory app on macOS 13+).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(AppController.shared))
            let w = NSWindow(contentViewController: host)
            w.title = L("settings.title")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 620, height: 520))
            w.center()
            window = w
        }
        window?.title = L("settings.title")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
