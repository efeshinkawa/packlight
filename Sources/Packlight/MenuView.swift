import SwiftUI

/// Compact menu bar panel. Kept short on purpose so it never needs to scroll;
/// settings and insights open in their own windows.
struct MenuView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var insights: Insights
    @AppStorage(Key.language) private var language = Lang.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            vitals
            if !state.privilegedInstalled { privilegeBanner }
            modePicker
            if let deadline = state.pendingAway { pendingBanner(deadline) }
            if let tip = insights.recommendations.first { tipRow(tip) }
            if !state.report.isEmpty { reportView }
            Divider()
            procList
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.layoutDirection, Lang.current.isRTL ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.image(mode: state.mode, busy: false, pending: false))
                .renderingMode(.template)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundStyle(state.mode == .home ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.mode == .home ? T("Home mode") : T("Away mode")).font(.headline)
                Text(state.mode == .home ? T("Full power, builds welcome")
                                         : T("Light and quiet"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Label("\(state.power.percent)%", systemImage: state.power.onAC ? "bolt.fill" : "battery.75percent")
                    .font(.callout.monospacedDigit())
                    .fixedSize()
                if state.lowPowerOn {
                    Text(T("Low Power")).font(.caption2).foregroundStyle(.yellow)
                }
            }
        }
    }

    /// CPU · RAM · draw · time left, all at a glance.
    private var vitals: some View {
        HStack(spacing: 8) {
            if let s = insights.stats {
                vital("CPU", "\(Int(s.cpu * 100))%", progress: s.cpu)
                vital("RAM", String(format: "%.1f/%.0f GB", s.memUsedGB, s.memTotalGB),
                      progress: s.memUsedGB / max(1, s.memTotalGB))
            }
            if let w = insights.averageWatts {
                vital(T("Draw"), String(format: "%.1f W", w), progress: min(1, w / 20))
            }
            if let m = insights.minutesLeft {
                vital(T("Left"), Self.duration(m), progress: Double(state.power.percent) / 100, invert: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `invert`: high is good (battery left), so colors run the other way.
    private func vital(_ title: String, _ value: String, progress: Double?, invert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
                    .tint(Self.tint(invert ? 1 - progress : progress))
                    .controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func tint(_ load: Double) -> Color { load > 0.8 ? .red : load > 0.6 ? .orange : .green }

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? T("%dh %dm", m / 60, m % 60) : T("%dm", m)
    }

    private var privilegeBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(T("Low Power and RAM purge need a one-time permission"), systemImage: "exclamationmark.shield")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button(T("Install password-free helper")) { state.installPrivileged() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            modeButton(.home, title: T("Home"), icon: "house.fill", tint: .orange)
            modeButton(.away, title: T("Away"), icon: "leaf.fill", tint: .green)
        }
        .disabled(state.busy)
        .overlay {
            if state.busy { ProgressView().controlSize(.small) }
        }
    }

    private func modeButton(_ mode: Mode, title: String, icon: String, tint: Color) -> some View {
        let selected = state.mode == mode
        // Drawn by hand: system prominent buttons wash out when the panel isn't key.
        return Button { state.switchTo(mode) } label: {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? tint : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(mode == .away ? T("Close and clean up everything heavy now")
                            : T("Low Power off, services and apps back"))
    }

    private func pendingBanner(_ deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded()))
            VStack(alignment: .leading, spacing: 6) {
                Label(T("Unplugged · Away in %ds", left), systemImage: "powerplug")
                    .font(.callout.monospacedDigit())
                HStack {
                    Button(T("Cancel")) { state.cancelPending() }
                    Button(T("Now")) { state.switchTo(.away) }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tipRow(_ tip: Recommendation) -> some View {
        Button { Windows.show(.insights) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tip.kind == .warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                    .foregroundStyle(tip.kind == .warning ? .orange : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.title).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    if insights.recommendations.count > 1 {
                        Text(T("+%d more tips", insights.recommendations.count - 1))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = state.reportDate {
                Text(T("Last run · ") + date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.report, id: \.self) { line in
                Label {
                    Text(line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
                .font(.caption)
            }
        }
    }

    private var procList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(T("Top CPU right now")).font(.caption).foregroundStyle(.secondary)
            if state.topProcs.isEmpty {
                Text(T("All quiet")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.topProcs.prefix(5)) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "\(Int(p.cpu))% · \(p.rssMB) MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button { state.kill(p) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(T("Quit (SIGTERM)"))
                }
                .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { Windows.show(.insights) } label: {
                Label(T("Insights"), systemImage: "chart.xyaxis.line")
            }
            Button { Windows.show(.settings) } label: {
                Label(T("Settings"), systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Spacer()
            Button(T("Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Key.language) private var language = Lang.system.rawValue
    @AppStorage(Key.autoSwitch) private var autoSwitch = true
    @AppStorage(Key.graceSeconds) private var graceSeconds = 30
    @AppStorage(Key.relaunchApps) private var relaunchApps = ""
    @AppStorage(Key.quitApps) private var quitApps = true
    @AppStorage(Key.appBundleIDs) private var appBundleIDs = ""
    @AppStorage(Key.shutdownSims) private var shutdownSims = true
    @AppStorage(Key.killDev) private var killDev = true
    @AppStorage(Key.extraPatterns) private var extraPatterns = ""
    @AppStorage(Key.stopBrew) private var stopBrew = true
    @AppStorage(Key.clearDerivedData) private var clearDerivedData = true
    @AppStorage(Key.clearSimCaches) private var clearSimCaches = true
    @AppStorage(Key.clearXcodeCaches) private var clearXcodeCaches = true
    @AppStorage(Key.clearNpm) private var clearNpm = false
    @AppStorage(Key.brewCleanup) private var brewCleanup = false
    @AppStorage(Key.purgeRAM) private var purgeRAM = true
    @AppStorage(Key.lowPowerPolicy) private var lowPowerPolicy = LowPowerPolicy.away.rawValue
    @AppStorage(Key.lowPowerThreshold) private var lowPowerThreshold = 30
    @AppStorage(Key.lowPowerOffAtHome) private var lowPowerOffAtHome = true
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section(T("General")) {
                Picker(T("Language"), selection: $language) {
                    Text(Lang.system.nativeName).tag(Lang.system.rawValue)
                    ForEach(Lang.languages) { Text($0.nativeName).tag($0.rawValue) }
                }
                HStack {
                    Image(systemName: state.privilegedInstalled ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(state.privilegedInstalled ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.privilegedInstalled ? T("Password-free helper installed")
                                                       : T("Password-free helper not installed"))
                        Text(T("Used for Low Power Mode and RAM purge (pmset and purge only)."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.privilegedInstalled {
                        Button(T("Remove")) { state.uninstallPrivileged() }
                    } else {
                        Button(T("Install")) { state.installPrivileged() }.buttonStyle(.borderedProminent)
                    }
                }
                Toggle(T("Launch at login"), isOn: Binding(
                    get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
            }

            Section(T("Automatic switching")) {
                Toggle(T("Away when unplugged, Home when plugged in"), isOn: $autoSwitch)
                Picker(T("Wait after unplugging"), selection: $graceSeconds) {
                    ForEach([0, 10, 30, 60, 120, 300], id: \.self) {
                        Text($0 == 0 ? T("Immediately") : T("%d s", $0)).tag($0)
                    }
                }
                .disabled(!autoSwitch)
            }

            Section {
                AppListEditor(ids: $relaunchApps)
            } header: {
                Text(T("Close while away, reopen at home"))
            } footer: {
                Text(T("For apps you only need at your desk, like mouse or keyboard software. They're closed with their helpers and reopened in the background when you're home."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(T("When going Away")) {
                Toggle(T("Quit heavy apps"), isOn: $quitApps)
                AppListEditor(ids: $appBundleIDs, enabled: quitApps)
                Toggle(T("Shut down simulators"), isOn: $shutdownSims)
                Toggle(T("Stop build and dev-server processes"), isOn: $killDev)
                Toggle(T("Stop brew services (restarted at Home)"), isOn: $stopBrew)
            }

            Section {
                Picker(T("Turn on"), selection: $lowPowerPolicy) {
                    Text(T("With Away mode")).tag(LowPowerPolicy.away.rawValue)
                    Text(T("Whenever on battery")).tag(LowPowerPolicy.battery.rawValue)
                    Text(T("When battery is low")).tag(LowPowerPolicy.below.rawValue)
                    Text(T("Never")).tag(LowPowerPolicy.never.rawValue)
                }
                if lowPowerPolicy == LowPowerPolicy.below.rawValue {
                    Picker(T("Battery below"), selection: $lowPowerThreshold) {
                        ForEach([10, 20, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
                Toggle(T("Turn off when plugged in"), isOn: $lowPowerOffAtHome)
                    .disabled(lowPowerPolicy == LowPowerPolicy.never.rawValue)
            } header: {
                Text(T("Low Power Mode"))
            } footer: {
                if !state.privilegedInstalled {
                    Text(T("Needs the password-free helper (General)."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section(T("Cleanup")) {
                Toggle("Xcode DerivedData", isOn: $clearDerivedData)
                Toggle(T("Simulator caches"), isOn: $clearSimCaches)
                Toggle(T("Xcode caches"), isOn: $clearXcodeCaches)
                Toggle("npm cache", isOn: $clearNpm)
                Toggle("brew cleanup", isOn: $brewCleanup)
                Toggle(T("Free inactive RAM (purge)"), isOn: $purgeRAM)
            }

            Section {
                DisclosureGroup(T("Advanced"), isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        listField(T("Close while away, reopen at home"), hint: T("Bundle IDs, comma separated"),
                                  text: $relaunchApps, enabled: true)
                        listField(T("Apps to quit"), hint: T("Bundle IDs, comma separated; a prefix matches a family (com.jetbrains)"),
                                  text: $appBundleIDs, enabled: true)
                        listField(T("Extra process patterns"), hint: T("Regex, comma separated — e.g. python.*manage\\.py"),
                                  text: $extraPatterns, enabled: killDev)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(T("URL scheme"))
                            Text(T("Control Packlight from Shortcuts, scripts or Raycast:"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("packlight://away · home · toggle · cancel · insights · settings\npacklight://set?key=lowPowerPolicy&value=battery")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { state.panelOpened(); state.panelClosed() }
        .environment(\.layoutDirection, Lang.current.isRTL ? .rightToLeft : .leftToRight)
    }

    /// Full-width, left-aligned and wrapping, so long lists are never cut off.
    private func listField(_ title: String, hint: String, text: Binding<String>, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
