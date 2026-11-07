import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var mode: Mode
    @Published private(set) var power = PowerState.current()
    @Published private(set) var busy = false
    @Published private(set) var report: [String] = []
    @Published private(set) var reportDate: Date?
    /// Set while the "unplugged → going away" grace period is counting down.
    @Published private(set) var pendingAway: Date?
    @Published private(set) var topProcs: [ProcInfo] = []
    @Published private(set) var privilegedInstalled = Privileged.isInstalled
    @Published private(set) var lowPowerOn = Privileged.lowPowerEnabled

    /// Set by `--snapshot --demo`: sample data, no live refresh.
    private var demo = false
    private var lowPowerTriggered = false
    private var monitor: PowerMonitor?
    private var pendingTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private init() {
        Key.registerDefaults()
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .home
        report = d.stringArray(forKey: Key.lastReport) ?? []
        let ts = d.double(forKey: Key.lastReportDate)
        reportDate = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        monitor = PowerMonitor { [weak self] state in
            Task { @MainActor in self?.powerChanged(state) }
        }
    }

    // MARK: Mode switching

    func switchTo(_ target: Mode) {
        cancelPending()
        guard !busy else { return }
        busy = true
        mode = target
        UserDefaults.standard.set(target.rawValue, forKey: Key.mode)
        Task {
            let lines = await Task.detached(priority: .userInitiated) {
                target == .away ? await ModeActions.goAway() : await ModeActions.goHome()
            }.value
            report = lines
            reportDate = Date()
            // Persisted so the Raycast extension can show the last run too.
            UserDefaults.standard.set(lines, forKey: Key.lastReport)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastReportDate)
            busy = false
            lowPowerOn = Privileged.lowPowerEnabled
            refreshProcs()
        }
    }

    private func powerChanged(_ state: PowerState) {
        let was = power.onAC
        power = state
        if state.onAC != was { applyLowPowerPolicy(onAC: state.onAC) }
        guard state.onAC != was, UserDefaults.standard.bool(forKey: Key.autoSwitch) else { return }

        if !state.onAC && mode == .home {
            let grace = max(0, UserDefaults.standard.integer(forKey: Key.graceSeconds))
            pendingAway = Date().addingTimeInterval(TimeInterval(grace))
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
                self?.switchTo(.away)
            }
        } else if state.onAC {
            cancelPending()
            if mode == .away { switchTo(.home) }
        }
    }

    /// "Whenever unplugged" turns Low Power on right away; plugging in turns it off if asked to.
    private func applyLowPowerPolicy(onAC: Bool) {
        let d = UserDefaults.standard
        if !onAC && LowPowerPolicy.current == .battery {
            Task.detached { Privileged.sudo("/usr/bin/pmset -a lowpowermode 1") }
            lowPowerOn = true
        } else if onAC && d.bool(forKey: Key.lowPowerOffAtHome) && Privileged.lowPowerEnabled {
            Task.detached { Privileged.sudo("/usr/bin/pmset -a lowpowermode 0") }
            lowPowerOn = false
        }
    }

    /// Called by Insights on every reading: "below N%" turns Low Power on once per unplugged stretch.
    func batteryReading(percent: Int, onAC: Bool) {
        guard !demo else { return }
        if onAC { lowPowerTriggered = false; return }
        guard LowPowerPolicy.current == .below, !lowPowerTriggered,
              percent <= UserDefaults.standard.integer(forKey: Key.lowPowerThreshold),
              !Privileged.lowPowerEnabled else { return }
        lowPowerTriggered = true
        Task.detached { Privileged.sudo("/usr/bin/pmset -a lowpowermode 1") }
        lowPowerOn = true
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingAway = nil
    }

    // MARK: URL control (used by the Raycast extension)

    /// packlight://away · packlight://home · packlight://toggle · packlight://cancel
    /// packlight://install-privileges
    /// packlight://set?key=lowPower&value=true
    func handle(_ url: URL) {
        guard url.scheme == "packlight" else { return }
        switch url.host ?? "" {
        case "away": switchTo(.away)
        case "home": switchTo(.home)
        case "toggle": switchTo(mode == .home ? .away : .home)
        case "cancel": cancelPending()
        case "install-privileges": installPrivileged()
        case "insights": Windows.show(.insights)
        case "settings": Windows.show(.settings)
        case "set":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let key = items.first(where: { $0.name == "key" })?.value,
                  let value = items.first(where: { $0.name == "value" })?.value,
                  Key.settable.contains(key) else { return }
            let d = UserDefaults.standard
            if let b = Bool(value) { d.set(b, forKey: key) }
            else if let i = Int(value) { d.set(i, forKey: key) }
            else { d.set(value, forKey: key) }
        default: break
        }
    }

    // MARK: Demo data (README screenshots)

    func loadDemo(away: Bool) {
        demo = true
        mode = away ? .away : .home
        power = PowerState(onAC: false, percent: away ? 58 : 64)
        privilegedInstalled = true
        lowPowerOn = away
        topProcs = away ? [
            ProcInfo(pid: 1, cpu: 9, rssMB: 120, args: "/System/Library/WindowServer"),
            ProcInfo(pid: 2, cpu: 6, rssMB: 410, args: "/Applications/Safari.app/Contents/MacOS/Safari"),
            ProcInfo(pid: 3, cpu: 3, rssMB: 95, args: "/Applications/Notes.app/Contents/MacOS/Notes"),
        ] : [
            ProcInfo(pid: 1, cpu: 92, rssMB: 2100, args: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            ProcInfo(pid: 2, cpu: 64, rssMB: 880, args: "/usr/bin/swift-frontend -frontend -c"),
            ProcInfo(pid: 3, cpu: 38, rssMB: 1400, args: "/Simulator.app/Contents/MacOS/Simulator"),
            ProcInfo(pid: 4, cpu: 22, rssMB: 310, args: "/opt/homebrew/bin/node node_modules/.bin/vite"),
            ProcInfo(pid: 5, cpu: 9, rssMB: 120, args: "/System/Library/WindowServer"),
        ]
        report = away ? [
            T("Quit apps: ") + "Xcode, Simulator, Docker",
            T("Shut down %d simulator(s)", 2),
            T("Stopped %d build/dev process(es) (%@)", 4, "node, swift-frontend, watchman"),
            T("Cleared %@ of caches", "3.2 GB"),
            T("Low Power Mode on"),
        ] : []
        reportDate = away ? Date() : nil
    }

    // MARK: Recommendations

    func apply(_ fix: Recommendation.Fix) {
        switch fix {
        case .switchAway: switchTo(.away)
        case .installHelper: installPrivileged()
        case .lowPower:
            Task.detached { Privileged.sudo("/usr/bin/pmset -a lowpowermode 1") }
            lowPowerOn = true
        case .addToAway(let id):
            let d = UserDefaults.standard
            let list = d.list(Key.appBundleIDs)
            if !list.contains(id) { d.set((list + [id]).joined(separator: ", "), forKey: Key.appBundleIDs) }
        }
        Insights.shared.rebuildRecommendations()
    }

    // MARK: Live process list (only while the panel is open)

    func panelOpened() {
        guard !demo else { return }
        privilegedInstalled = Privileged.isInstalled
        lowPowerOn = Privileged.lowPowerEnabled
        power = PowerState.current()
        refreshProcs()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProcs() }
        }
    }

    func panelClosed() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshProcs() {
        Task {
            let procs = await Task.detached { ProcInfo.top(6) }.value
            topProcs = procs
        }
    }

    /// Quits the app politely when the row is an app (so it can ask to save);
    /// otherwise sends SIGTERM to every process in the row.
    func kill(_ p: ProcInfo) {
        if let path = p.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            app.terminate()
        } else {
            (p.pids.isEmpty ? [p.pid] : p.pids).forEach { Darwin.kill($0, SIGTERM) }
        }
        topProcs.removeAll { $0.id == p.id }
    }

    // MARK: Setup

    func installPrivileged() {
        // Bring the agent app forward so the admin prompt isn't hidden behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        privilegedInstalled = Privileged.install()
    }

    func uninstallPrivileged() {
        Task {
            await Task.detached { Privileged.uninstall() }.value
            privilegedInstalled = Privileged.isInstalled
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            objectWillChange.send()
        }
    }
}
