import SwiftUI
import ExtendPadCore

struct MenuView: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let help = helpText { HelpBanner(text: help) }
            if let err = app.status.lastError { ErrorBanner(text: err) { app.engine.clearError() } }
            statusGrid
            modePicker
            actions
            if let t = app.toast {
                Text(t).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { app.refreshPermissions() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(phaseColor.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(phaseColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ExtendPad").font(.headline)
                Text(phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Circle().fill(phaseColor).frame(width: 8, height: 8)
        }
    }

    private var phaseText: String {
        switch app.status.phase {
        case .stopped: return L("status.stopped")
        case .adbMissing: return L("status.adbMissing")
        case .waitingForDevice: return L("status.waitingForDevice")
        case .networkOnly: return L("status.networkOnly")
        case .unauthorized: return L("status.unauthorized")
        case .deviceOffline: return L("status.deviceOffline")
        case .tunnelFailed(let e): return L("status.tunnelFailed") + (e.isEmpty ? "" : ": \(e.prefix(80))")
        case .appMissing: return L("status.appMissing")
        case .waitingForTabletApp: return L("status.waitingForTabletApp")
        case .starting: return L("status.starting")
        case .streaming: return app.settings.mode == .extend ? L("status.streaming") : L("mode.mirror")
        case .error: return L("status.error")
        }
    }

    private var phaseColor: Color {
        switch app.status.phase {
        case .streaming: return .green
        case .starting, .waitingForTabletApp: return .blue
        case .error, .adbMissing, .tunnelFailed: return .red
        case .unauthorized, .appMissing, .networkOnly, .deviceOffline: return .orange
        default: return .secondary
        }
    }

    private var helpText: String? {
        if !app.status.virtualDisplaySupported { return L("diag.unsupported") }
        if !app.status.screenRecordingGranted, app.engine.isRunning { return L("help.permission") }
        switch app.status.phase {
        case .adbMissing: return L("help.adb")
        case .unauthorized: return L("help.unauthorized")
        case .waitingForDevice: return L("help.noDevice")
        default: return nil
        }
    }

    // MARK: Status

    private var statusGrid: some View {
        let st = app.status
        let streaming = st.phase == .streaming
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row(L("label.tablet"), st.tabletName ?? (st.device.model.isEmpty ? "—" : st.device.model))
            row(L("label.usb"), usbText)
            row(L("label.display"), displayText)
            if streaming {
                row(L("label.resolution"), resolutionText)
                row(L("label.fps"), String(format: "%.0f / %d fps", st.stats.renderedFps, st.targetFps))
                row(L("label.bitrate"), String(format: "%.1f Mbps", st.stats.bitrateKbps / 1000))
                row(L("label.latency"), st.stats.latencyMs > 0 ? String(format: "%.0f ms", st.stats.latencyMs) : "—")
                row(L("label.duration"), durationText)
                row(L("label.encoder"), "H.264 · " + (st.encoderHardware ? L("value.hardware") : L("value.software")))
            }
        }
        .font(.system(size: 12))
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).lineLimit(1).truncationMode(.middle)
        }
    }

    private var usbText: String {
        let d = app.status.device
        guard let serial = d.serial else { return L("value.notConnected") }
        let tunnel = d.reverseActive ? " · adb reverse ✓" : ""
        return (d.usbPort != nil ? "USB \(d.usbPort!)" : serial) + tunnel
    }

    private var displayText: String {
        let st = app.status
        if st.displayActive { return st.displayRemovalPending ? L("value.removing") : "\(L("value.active")) · ExtendPad Display" }
        return L("value.inactive")
    }

    private var resolutionText: String {
        guard let p = app.status.plan else { return "—" }
        if app.settings.mode == .mirror { return "\(p.streamWidth)×\(p.streamHeight)" }
        return "\(p.logicalWidth)×\(p.logicalHeight)\(p.hiDPI ? " HiDPI" : "") → \(p.streamWidth)×\(p.streamHeight)"
    }

    private var durationText: String {
        guard let start = app.status.sessionStartedAt else { return "—" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: Controls

    private var modePicker: some View {
        Picker(L("mode.title"), selection: Binding(get: { app.settings.mode }, set: { app.setMode($0) })) {
            Text(L("mode.extend")).tag(DisplayMode.extend)
            Text(L("mode.mirror")).tag(DisplayMode.mirror)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack {
                if app.engine.isRunning {
                    Button(role: .destructive) { app.disconnect() } label: {
                        Label(L("action.disconnect"), systemImage: "bolt.slash").frame(maxWidth: .infinity)
                    }
                } else {
                    Button { app.connect() } label: {
                        Label(L("action.connect"), systemImage: "bolt.horizontal").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button { app.openDisplaySettings() } label: {
                    Label(L("action.arrangement"), systemImage: "display.2").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            if showADBInstaller { ADBInstallView() }
            if case .appMissing = app.status.phase, app.hasBundledAPK {
                Button { app.installTabletApp() } label: { Label(L("action.installApp"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
            }
            if case .waitingForTabletApp = app.status.phase {
                Button { app.openTabletApp() } label: { Label(L("action.openTabletApp"), systemImage: "ipad.landscape").frame(maxWidth: .infinity) }
            }
            if !app.status.screenRecordingGranted {
                Button { app.openScreenRecordingSettings() } label: { Label(L("perm.screen") + " — " + L("action.grant"), systemImage: "lock.shield").frame(maxWidth: .infinity) }
            }
            if app.status.displayActive {
                Button { app.gatherWindows() } label: { Label(L("action.gatherWindows"), systemImage: "macwindow.on.rectangle").frame(maxWidth: .infinity) }
            }
        }
    }

    private var showADBInstaller: Bool {
        if case .adbMissing = app.status.phase { return true }
        switch app.status.adbInstall {
        case .downloading, .installing, .failed: return true
        default: return false
        }
    }

    private var footer: some View {
        HStack {
            Button(L("action.settings")) { SettingsWindow.show() }
            Spacer()
            Button(L("action.quit")) { app.quit() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}

/// "Install adb" button with progress, used in the menu and in Settings.
struct ADBInstallView: View {
    @EnvironmentObject var app: AppController
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch app.status.adbInstall {
            case .downloading(let pct):
                ProgressView(value: Double(pct), total: 100) { Text(L("adb.downloading")).font(.caption) }
            case .installing:
                ProgressView { Text(L("adb.installing")).font(.caption) }
            case .installed(let v):
                Label(L("adb.installed") + " · " + v.replacingOccurrences(of: "Android Debug Bridge ", with: ""), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let e):
                Text(L("adb.failed") + ": " + e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                installButton
            case .idle:
                installButton
            }
            if !compact {
                HStack(spacing: 4) {
                    Text(L("adb.note")).font(.caption2).foregroundStyle(.secondary)
                    Button(L("adb.terms")) { app.openADBTerms() }.buttonStyle(.link).font(.caption2)
                }
            }
        }
    }

    private var installButton: some View {
        Button { app.installADB() } label: {
            Label(L("adb.install"), systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

struct HelpBanner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }
}
