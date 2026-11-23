import Foundation
import SwiftUI
import AppKit
import ServiceManagement
import ExtendPadCore

/// Bridges the main-thread engine to SwiftUI and persists user preferences.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var status = EngineStatus()
    @Published var settings: EngineSettings { didSet { settingsChanged(oldValue) } }
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            L10n.language = language.resolved
            defaults.set(language.rawValue, forKey: "language")
        }
    }
    @Published var showMenuIcon: Bool {
        didSet {
            guard showMenuIcon != oldValue else { return }
            defaults.set(showMenuIcon, forKey: "showMenuIcon")
            if MenuIconState.shared.visible != showMenuIcon { MenuIconState.shared.visible = showMenuIcon }
        }
    }
    @Published var toast: String?
    @Published var launchAtLogin: Bool = false

    let engine: ExtendPadEngine
    private let defaults = UserDefaults.standard
    private var applyingRemote = false

    private init() {
        var s = EngineSettings()
        if let data = UserDefaults.standard.data(forKey: "settings.v1"),
           let decoded = try? JSONDecoder().decode(EngineSettings.self, from: data) {
            s = decoded
        }
        settings = s
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
        language = lang
        L10n.language = lang.resolved
        showMenuIcon = UserDefaults.standard.object(forKey: "showMenuIcon") as? Bool ?? true
        engine = ExtendPadEngine(settings: s)
        engine.onStatus = { [weak self] st in
            Task { @MainActor in if self?.status != st { self?.status = st } }
        }
        engine.onSettingsChangedRemotely = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                self.applyingRemote = true
                self.settings = st
                self.applyingRemote = false
                self.persist()
            }
        }
        status = engine.status
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if s.autoConnectOnLaunch { engine.start() }
    }

    private func settingsChanged(_ old: EngineSettings) {
        guard settings != old else { return }
        persist()
        if !applyingRemote { engine.update(settings: settings) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings.v1") }
    }

    // MARK: Actions

    func connect() { engine.clearError(); engine.start(); engine.reconnectTablet() }
    func disconnect() { engine.stop() }
    func setMode(_ m: DisplayMode) { settings.mode = m }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        engine.requestScreenRecording()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        engine.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermissions() { engine.refreshPermissions() }

    func installTabletApp() {
        engine.installTabletApp { [weak self] ok, msg in
            Task { @MainActor in self?.showToast(ok ? L("install.ok") : "\(L("install.fail")): \(msg.suffix(160))") }
        }
    }

    func openTabletApp() { engine.reconnectTablet() }
    func installADB() { engine.installADB() }
    func openADBTerms() { NSWorkspace.shared.open(ADBInstaller.termsURL) }
    func gatherWindows() { engine.gatherWindows() }
    var hasBundledAPK: Bool { engine.hasBundledAPK }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.diagnosticsReport(), forType: .string)
        showToast(L("diag.copied"))
    }

    func revealLogs() { NSWorkspace.shared.activateFileViewerSelecting([Log.logFile]) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showToast(_ s: String) {
        toast = s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.toast == s { self.toast = nil }
        }
    }

    func quit() {
        engine.stop()
        // Give adb a moment to remove the reverse tunnel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
}
