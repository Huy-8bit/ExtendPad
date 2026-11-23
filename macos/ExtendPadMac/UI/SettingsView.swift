import SwiftUI
import ExtendPadCore

struct SettingsView: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        TabView {
            DisplayTab().tabItem { Label(L("tab.display"), systemImage: "display") }
            StreamingTab().tabItem { Label(L("tab.streaming"), systemImage: "dot.radiowaves.left.and.right") }
            ConnectionTab().tabItem { Label(L("tab.connection"), systemImage: "cable.connector") }
            GeneralTab().tabItem { Label(L("tab.general"), systemImage: "gearshape") }
            PermissionsTab().tabItem { Label(L("tab.permissions"), systemImage: "lock.shield") }
            DiagnosticsTab().tabItem { Label(L("tab.diagnostics"), systemImage: "stethoscope") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 480)
        .environmentObject(app)
    }
}

private struct DisplayTab: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        Form {
            Picker(L("mode.title"), selection: $app.settings.mode) {
                Text(L("mode.extend")).tag(DisplayMode.extend)
                Text(L("mode.mirror")).tag(DisplayMode.mirror)
            }
            .pickerStyle(.segmented)
            Picker(L("display.preset"), selection: $app.settings.preset) {
                ForEach(DisplayPreset.allCases, id: \.self) { Text(L("preset.\($0.rawValue)")).tag($0) }
            }
            if app.settings.preset == .custom {
                Picker(L("display.custom"), selection: Binding(
                    get: { "\(app.settings.customWidth)x\(app.settings.customHeight)" },
                    set: { v in
                        let p = v.split(separator: "x").compactMap { Int($0) }
                        if p.count == 2 { app.settings.customWidth = p[0]; app.settings.customHeight = p[1] }
                    })) {
                    ForEach(customOptions, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                }
            }
            Picker(L("display.refresh"), selection: $app.settings.fpsLimit) {
                Text(L("display.refresh.auto")).tag(0)
                Text("30 fps").tag(30)
                Text("45 fps").tag(45)
                Text("60 fps").tag(60)
            }
            Picker(L("display.arrangement"), selection: $app.settings.arrangement) {
                ForEach(Arrangement.allCases, id: \.self) { Text(L("arr.\($0.rawValue)")).tag($0) }
            }
            Toggle(L("display.cursor"), isOn: $app.settings.showCursor)
            Toggle(L("display.localCursor"), isOn: $app.settings.localCursor).disabled(!app.settings.showCursor)
            Picker(L("display.grace"), selection: $app.settings.displayGraceSeconds) {
                Text("0 s").tag(0); Text("10 s").tag(10); Text("20 s").tag(20); Text("60 s").tag(60); Text("5 min").tag(300)
            }
            Text(L("display.grace.help")).font(.caption).foregroundStyle(.secondary)
            Text(L("display.hint")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("action.arrangement")) { app.openDisplaySettings() }
                Button(L("action.gatherWindows")) { app.gatherWindows() }.disabled(!app.status.displayActive)
            }
        }
        .formStyle(.grouped)
    }

    private var customOptions: [String] {
        let s = app.status
        var list = DisplayPlanner.standardResolutions.map { "\($0.width)x\($0.height)" }
        if s.plan == nil { return list }
        let cur = "\(app.settings.customWidth)x\(app.settings.customHeight)"
        if !list.contains(cur) { list.append(cur) }
        return list
    }
}

private struct StreamingTab: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        Form {
            Picker(L("streaming.quality"), selection: $app.settings.quality) {
                ForEach(StreamQuality.allCases, id: \.self) { Text(L("quality.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Picker(L("streaming.bitrate"), selection: $app.settings.customBitrateKbps) {
                Text(L("streaming.bitrate.auto")).tag(0)
                ForEach([4000, 8000, 12000, 20000, 30000], id: \.self) { Text("\($0 / 1000) Mbps").tag($0) }
            }
            Text(L("streaming.help")).font(.caption).foregroundStyle(.secondary)
            if app.status.phase == .streaming {
                let st = app.status.stats
                Section {
                    LabeledContent(L("label.fps"), value: String(format: "capture %.0f · encoded %.0f · shown %.0f", st.captureFps, st.encodedFps, st.renderedFps))
                    LabeledContent(L("label.bitrate"), value: String(format: "%.1f Mbps (target %.1f)", st.bitrateKbps / 1000, Double(st.targetBitrateKbps) / 1000))
                    LabeledContent(L("label.latency"), value: String(format: "%.0f ms (encode %.1f ms, tablet decode %.1f ms, RTT %.1f ms)", st.latencyMs, st.encodeMs, st.tabletDecodeMs, st.rttMs))
                    LabeledContent(L("label.dropped"), value: "\(st.droppedFrames)")
                    LabeledContent(L("label.decoder"), value: app.status.tabletDecoder ?? "—")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionTab: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        Form {
            Toggle(L("conn.autoConnect"), isOn: $app.settings.autoConnectOnLaunch)
            Toggle(L("conn.autoLaunch"), isOn: $app.settings.autoLaunchTabletApp)
            Toggle(L("conn.autoReconnect"), isOn: $app.settings.autoReconnect)
            TextField(L("conn.adbPath"), text: $app.settings.adbPath, prompt: Text(app.status.device.adbPath ?? L("conn.adbPath.auto")))
            LabeledContent("adb") {
                Text(app.status.device.adbPath == nil ? L("adb.missing")
                     : (app.engine.adbIsManagedCopy ? L("adb.source.managed") : L("adb.source.system")))
                    .foregroundStyle(.secondary)
            }
            if app.status.device.adbPath == nil || app.engine.adbIsManagedCopy {
                ADBInstallView().environmentObject(app)
            }
            Section(L("conn.status")) {
                LabeledContent("adb", value: app.status.device.adbVersion ?? "—")
                LabeledContent(L("label.tablet"), value: app.status.device.serial.map { "\(app.status.device.model) (\($0))" } ?? L("value.notConnected"))
                LabeledContent("adb reverse tcp:27183", value: app.status.device.reverseActive ? "✓" : "—")
                if let panel = app.status.tabletPanel { LabeledContent("Panel", value: panel) }
                if let dec = app.status.tabletDecoder { LabeledContent(L("label.decoder"), value: dec) }
                if app.hasBundledAPK { Button(L("action.installApp")) { app.installTabletApp() }.disabled(app.status.device.serial == nil) }
            }
            Section {
                Toggle(L("conn.touch"), isOn: $app.settings.allowTouchInput)
                Text(L("conn.touch.help")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("conn.emulator"), isOn: $app.settings.allowEmulator)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        Form {
            Toggle(L("general.launchAtLogin"), isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Toggle(L("general.menuIcon"), isOn: $app.showMenuIcon)
            Text(L("general.menuIcon.help")).font(.caption).foregroundStyle(.secondary)
            Picker(L("general.language"), selection: $app.language) {
                ForEach(AppLanguage.allCases) { Text(L("lang.\($0.rawValue)")).tag($0) }
            }
            LabeledContent("Version", value: ExtendPadEngine.appVersion)
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsTab: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        Form {
            permission(L("perm.screen"), L("perm.screen.help"), app.status.screenRecordingGranted) { app.openScreenRecordingSettings() }
            permission(L("perm.ax"), L("perm.ax.help"), app.status.accessibilityGranted) { app.openAccessibilitySettings() }
            Text(L("perm.adhoc")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { app.refreshPermissions() }
    }

    private func permission(_ title: String, _ help: String, _ ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(ok ? L("perm.granted") : L("perm.missing"), systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            if !ok { Button(L("action.grant"), action: action) }
        }
    }
}

private struct DiagnosticsTab: View {
    @EnvironmentObject var app: AppController
    @State private var report = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("diag.help")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(report).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Button(L("action.copyDiagnostics")) { app.copyDiagnostics() }
                Button(L("action.revealLogs")) { app.revealLogs() }
                Spacer()
                Button { report = app.engine.diagnosticsReport() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { report = app.engine.diagnosticsReport() }
    }
}
