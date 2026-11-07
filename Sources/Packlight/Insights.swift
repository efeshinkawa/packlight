import AppKit
import Darwin
import Foundation
import IOKit

// MARK: - Raw readings

/// Straight from the AppleSmartBattery registry entry (no root needed).
struct BatteryReading {
    var percent: Int
    var onAC: Bool
    var charging: Bool
    var voltage: Double        // V
    var amperage: Double       // A, negative while discharging
    var currentMAh: Double
    var fullMAh: Double
    var designMAh: Double
    var cycles: Int
    var temperatureC: Double?

    var watts: Double { abs(voltage * amperage) }
    var remainingWh: Double { currentMAh * voltage / 1000 }
    var fullWh: Double { fullMAh * voltage / 1000 }
    var health: Double { designMAh > 0 ? fullMAh / designMAh : 1 }

    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        // Values are unsigned in the registry; int64Value turns the two's-complement current negative.
        func num(_ key: String) -> NSNumber? { (d[key] as? NSNumber) ?? (data[key] as? NSNumber) }
        let current = num("AppleRawCurrentCapacity")?.doubleValue ?? 0
        let full = num("AppleRawMaxCapacity")?.doubleValue ?? 0
        let state = PowerState.current()
        return BatteryReading(
            percent: state.percent,
            onAC: (d["ExternalConnected"] as? Bool) ?? state.onAC,
            charging: (d["IsCharging"] as? Bool) ?? false,
            voltage: (num("Voltage")?.doubleValue ?? 0) / 1000,
            amperage: Double(num("InstantAmperage")?.int64Value ?? num("Amperage")?.int64Value ?? 0) / 1000,
            currentMAh: current,
            fullMAh: full,
            designMAh: num("DesignCapacity")?.doubleValue ?? full,
            cycles: num("CycleCount")?.intValue ?? 0,
            temperatureC: num("Temperature").map { $0.doubleValue / 100 }
        )
    }
}

struct SystemStats {
    var cpu: Double            // 0...1, whole machine
    var memUsedGB: Double
    var memTotalGB: Double
    var swapUsedGB: Double
    var pressure: Int          // 1 normal, 2 warning, 4 critical

    private static var lastTicks: (busy: UInt64, total: UInt64)?

    static func read() -> SystemStats {
        // CPU: delta of host-wide ticks since the previous call.
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        let t = load.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        var cpu = 0.0
        if let last = lastTicks, total > last.total {
            cpu = Double(busy - last.busy) / Double(total - last.total)
        }
        lastTicks = (busy, total)

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let page = Double(vm_kernel_page_size)
        // Same idea as Activity Monitor's "Memory Used": app + wired + compressed.
        let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count)
            + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        let gb = 1_073_741_824.0
        return SystemStats(cpu: min(1, max(0, cpu)), memUsedGB: used / gb,
                           memTotalGB: Double(ProcessInfo.processInfo.physicalMemory) / gb,
                           swapUsedGB: Double(swap.xsu_used) / gb, pressure: Int(level))
    }
}

/// One app (helpers grouped under their .app) and its share of recent energy use.
struct EnergyConsumer: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let share: Double          // 0...1 of total measured energy impact
    let awayCloses: Bool
    var isSystem: Bool { path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") }
}

enum EnergySampler {
    /// `top`'s energy-impact column for every process, grouped by app.
    static func sample() -> [String: Double] {
        let out = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "40", "-o", "power", "-stats", "pid,power"]).out
        // The first sample has no deltas; only parse the block after the second header.
        guard let range = out.range(of: "PID", options: .backwards) else { return [:] }
        var totals: [String: Double] = [:]
        for line in out[range.upperBound...].split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let power = Double(parts[1]), power > 0 else { continue }
            // Processes that exited between samples can't be attributed; skip them.
            guard let path = groupPath(pid: pid) else { continue }
            totals[path, default: 0] += power
        }
        return totals
    }

    static func groupPath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path
    }
}

// MARK: - History, prediction, recommendations

struct BatterySample: Codable {
    var t: Date
    var percent: Int
    var watts: Double
    var remainingWh: Double
    var onAC: Bool
}

struct Recommendation: Identifiable {
    enum Kind { case info, warning, action }
    enum Fix: Equatable { case switchAway, lowPower, addToAway(String), installHelper }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    var fix: Fix?
}

@MainActor
final class Insights: ObservableObject {
    static let shared = Insights()

    @Published private(set) var battery: BatteryReading?
    @Published private(set) var stats: SystemStats?
    @Published private(set) var history: [BatterySample] = []
    @Published private(set) var consumers: [EnergyConsumer] = []
    @Published private(set) var averageWatts: Double?
    @Published private(set) var recommendations: [Recommendation] = []

    /// Smoothed energy score per app; decays so the list reflects the last ~15 minutes.
    private var energyScores: [String: Double] = [:]
    private var ewmaWatts: Double?
    private var lastEnergySample = Date.distantPast
    private var timer: Timer?
    private var fastMode = false
    /// Set by `--snapshot --demo`: sample data, no live measurements.
    private var demo = false
    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Packlight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([BatterySample].self, from: data) {
            history = saved.filter { $0.t > Date().addingTimeInterval(-48 * 3600) }
        }
        _ = SystemStats.read()  // prime the CPU delta
        tick()
        schedule()
    }

    /// Faster refresh while a window showing insights is open.
    func setFast(_ fast: Bool) {
        fastMode = fast
        schedule()
        if fast { tick(forceEnergy: true) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fastMode ? 5 : 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Prediction

    /// Minutes until empty at the current (blended) draw.
    var minutesLeft: Double? {
        guard let b = battery, !b.onAC, let w = averageWatts, w > 0.3 else { return nil }
        return b.remainingWh / w * 60
    }

    /// Battery percent lost per hour at the current draw.
    var percentPerHour: Double? {
        guard let b = battery, let w = averageWatts, b.fullWh > 0 else { return nil }
        return w / b.fullWh * 100
    }

    /// How long a full charge would last at the current draw.
    var fullChargeHours: Double? {
        guard let b = battery, let w = averageWatts, w > 0.3 else { return nil }
        return b.fullWh / w
    }

    /// Share of measured energy coming from things Away mode would close.
    var awayShare: Double { consumers.filter(\.awayCloses).reduce(0) { $0 + $1.share } }

    private func tick(forceEnergy: Bool = false) {
        guard !demo, let b = BatteryReading.read() else { return }
        battery = b
        stats = SystemStats.read()
        AppState.shared.batteryReading(percent: b.percent, onAC: b.onAC)

        // Watts: EWMA of instant draw, blended with the real energy drop over the last 30 min,
        // which is steadier than any single reading.
        if b.onAC {
            ewmaWatts = nil
        } else {
            let alpha = fastMode ? 0.08 : 0.3
            ewmaWatts = ewmaWatts.map { alpha * b.watts + (1 - alpha) * $0 } ?? b.watts
        }
        averageWatts = b.onAC ? nil : blend(ewma: ewmaWatts, slope: slopeWatts(now: b))

        if history.last.map({ Date().timeIntervalSince($0.t) >= 55 }) ?? true {
            history.append(BatterySample(t: Date(), percent: b.percent, watts: b.onAC ? 0 : b.watts,
                                         remainingWh: b.remainingWh, onAC: b.onAC))
            history.removeAll { $0.t < Date().addingTimeInterval(-48 * 3600) }
            if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL) }
        }

        let energyEvery: TimeInterval = fastMode ? 10 : (b.onAC ? 600 : 120)
        if forceEnergy || Date().timeIntervalSince(lastEnergySample) >= energyEvery {
            lastEnergySample = Date()
            Task.detached(priority: .utility) {
                let totals = EnergySampler.sample()
                await MainActor.run { Insights.shared.absorb(totals) }
            }
        }

        rebuildRecommendations()
        publishEstimate()
    }

    private func slopeWatts(now b: BatteryReading) -> Double? {
        let window = Date().addingTimeInterval(-30 * 60)
        // Only the current unplugged stretch counts.
        var stretch: [BatterySample] = []
        for s in history.reversed() {
            if s.onAC || s.t < window { break }
            stretch.insert(s, at: 0)
        }
        guard let first = stretch.first else { return nil }
        let hours = Date().timeIntervalSince(first.t) / 3600
        guard hours >= 10.0 / 60 else { return nil }
        let drop = first.remainingWh - b.remainingWh
        return drop > 0 ? drop / hours : nil
    }

    private func blend(ewma: Double?, slope: Double?) -> Double? {
        switch (ewma, slope) {
        case let (e?, s?): return 0.5 * e + 0.5 * s
        case let (e?, nil): return e
        case let (nil, s?): return s
        default: return nil
        }
    }

    func absorb(_ totals: [String: Double]) {
        guard !demo else { return }
        for key in energyScores.keys { energyScores[key]! *= 0.6 }
        for (k, v) in totals { energyScores[k, default: 0] += v }
        energyScores = energyScores.filter { $0.value > 0.5 }
        let sum = energyScores.values.reduce(0, +)
        guard sum > 0 else { consumers = []; return }
        consumers = energyScores.sorted { $0.value > $1.value }.prefix(8).map { path, score in
            EnergyConsumer(path: path, name: ProcInfo.displayName(forPath: path + "/"),
                           bundleID: path.hasSuffix(".app") ? Bundle(path: path)?.bundleIdentifier : nil,
                           share: score / sum, awayCloses: ModeActions.awayWouldClose(path: path))
        }
        rebuildRecommendations()
        publishEstimate()
    }

    private func publishEstimate() {
        guard let b = battery else { return }
        var e: [String: Any] = ["percent": b.percent, "onAC": b.onAC, "health": b.health,
                                "cycles": b.cycles, "updated": Date().timeIntervalSince1970]
        if let w = averageWatts { e["watts"] = w }
        if let m = minutesLeft { e["minutesLeft"] = m }
        if let s = stats { e["cpu"] = s.cpu; e["memUsedGB"] = s.memUsedGB; e["memTotalGB"] = s.memTotalGB }
        e["topConsumers"] = consumers.prefix(5).map { "\($0.name) \(Int($0.share * 100))%" }
        e["tips"] = recommendations.map(\.title)
        UserDefaults.standard.set(e, forKey: Key.estimate)
    }

    // MARK: Demo data (README screenshots)

    func loadDemo(away: Bool) {
        demo = true
        battery = BatteryReading(percent: away ? 58 : 64, onAC: false, charging: false, voltage: 11.9,
                                 amperage: away ? -0.38 : -0.92, currentMAh: away ? 2380 : 2580, fullMAh: 4100,
                                 designMAh: 4560, cycles: 118, temperatureC: 31.2)
        stats = SystemStats(cpu: away ? 0.08 : 0.41, memUsedGB: away ? 6.4 : 11.2, memTotalGB: 16,
                            swapUsedGB: 0.2, pressure: 1)
        averageWatts = away ? 4.6 : 10.6
        func c(_ path: String, _ name: String, _ id: String?, _ share: Double, _ away: Bool) -> EnergyConsumer {
            EnergyConsumer(path: path, name: name, bundleID: id, share: share, awayCloses: away)
        }
        consumers = [
            c("/Applications/Xcode.app", "Xcode", "com.apple.dt.Xcode", 0.31, true),
            c("/Applications/Simulator.app", "Simulator", "com.apple.iphonesimulator", 0.19, true),
            c("/opt/homebrew/bin/node", "node (vite)", nil, 0.14, true),
            c("/Applications/Safari.app", "Safari", "com.apple.Safari", 0.12, false),
            c("/Applications/Docker.app", "Docker", "com.docker.docker", 0.09, true),
            c("/System/Library/WindowServer", "WindowServer", nil, 0.08, false),
            c("/Applications/Notes.app", "Notes", "com.apple.Notes", 0.04, false),
        ]
        // Six hours: two on the charger, then unplugged with a heavy stretch and a light one.
        let now = Date()
        history = (0..<360).map { i in
            let t = now.addingTimeInterval(Double(i - 360) * 60)
            if i < 120 { return BatterySample(t: t, percent: 100, watts: 0, remainingWh: 48.8, onAC: true) }
            let m = Double(i - 120)
            let watts = m < 150 ? 11 + 3 * sin(m / 9) : 4.5 + sin(m / 7)
            let pct = 100 - (m < 150 ? m * 0.2 : 30 + (m - 150) * 0.07)
            return BatterySample(t: t, percent: Int(pct), watts: watts, remainingWh: 48.8 * pct / 100, onAC: false)
        }
        recommendations = []
        let saved = UserDefaults.standard.string(forKey: Key.mode)
        UserDefaults.standard.set((away ? Mode.away : Mode.home).rawValue, forKey: Key.mode)
        rebuildRecommendations()
        if away { recommendations.removeAll { $0.id == "lowpower" } }
        if let saved { UserDefaults.standard.set(saved, forKey: Key.mode) }
    }

    // MARK: Recommendations

    func rebuildRecommendations() {
        guard let b = battery else { return }
        var recs: [Recommendation] = []
        let d = UserDefaults.standard
        let mode = Mode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .home
        func share(_ match: (EnergyConsumer) -> Bool) -> Double { consumers.filter(match).reduce(0) { $0 + $1.share } }
        let pct = { (x: Double) in "\(Int((x * 100).rounded()))%" }

        if let w = averageWatts, !b.onAC, w >= 9 {
            recs.append(.init(id: "drain", kind: .warning,
                title: T("Draining fast: %.1f W", w),
                detail: T("Light use on a MacBook is about 3–6 W. At this rate a full charge lasts %.1f h.", fullChargeHours ?? 0)))
        }

        if mode == .home && !b.onAC && awayShare >= 0.15 {
            recs.append(.init(id: "away", kind: .action,
                title: T("Away mode would cut ~%@ of current energy use", pct(awayShare)),
                detail: T("It closes the dev tools, simulators and apps behind it."),
                fix: .switchAway))
        }

        let browsers = ["brave", "chrome", "safari", "firefox", "arc", "edge", "opera", "vivaldi", "orion"]
        let isBrowser = { (c: EnergyConsumer) in browsers.contains { c.path.lowercased().contains($0) } }
        let browserShare = share(isBrowser)
        if browserShare >= 0.15 {
            recs.append(.init(id: "browser", kind: .info,
                title: T("Browser tabs use %@ of energy", pct(browserShare)),
                detail: T("Close video and heavy web-app tabs, and turn on the browser's Energy / Memory Saver.")))
        }

        let display = share { $0.path.hasSuffix("WindowServer") }
        if display >= 0.2 {
            recs.append(.init(id: "display", kind: .info,
                title: T("Screen work is %@ of energy", pct(display)),
                detail: T("Lower brightness, pause animated or video content, and unplug external displays.")))
        }

        if share({ $0.path.contains("/mds") || $0.path.hasSuffix("mdworker_shared") }) >= 0.1 {
            recs.append(.init(id: "spotlight", kind: .info,
                title: T("Spotlight is indexing"),
                detail: T("Temporary — usually after big builds or downloads. It settles on its own.")))
        }

        if share({ $0.path.hasSuffix("kernel_task") }) >= 0.1 {
            recs.append(.init(id: "thermal", kind: .warning,
                title: T("The Mac is running hot"),
                detail: T("kernel_task is throttling to cool down. Let it breathe and close heavy work.")))
        }

        let ids = d.list(Key.appBundleIDs) + d.list(Key.relaunchApps)
        for c in consumers where c.share >= 0.12 && !c.awayCloses && !c.isSystem && !isBrowser(c) {
            guard let id = c.bundleID, id != Bundle.main.bundleIdentifier,
                  !ids.contains(where: { id.hasPrefix($0) }) else { continue }
            recs.append(.init(id: "add-\(id)", kind: .action,
                title: T("%@ uses %@ of energy", c.name, pct(c.share)),
                detail: T("Add it to the apps Away mode quits?"),
                fix: .addToAway(id)))
        }

        if let s = stats, s.pressure >= 2 || s.swapUsedGB >= 1 {
            recs.append(.init(id: "memory", kind: .warning,
                title: T("Memory is tight (%.1f GB swap)", s.swapUsedGB),
                detail: T("Swapping to disk costs battery. Closing a heavy app or two helps more than anything else.")))
        }

        if !b.onAC && !Privileged.lowPowerEnabled {
            recs.append(.init(id: "lowpower", kind: .action,
                title: T("Low Power Mode is off"),
                detail: T("Usually adds 10–30%% more runtime for everyday work."),
                fix: Privileged.isInstalled ? .lowPower : .installHelper))
        }

        if b.health < 0.8 {
            recs.append(.init(id: "health", kind: .warning,
                title: T("Battery health is %@", pct(b.health)),
                detail: T("Below 80%% Apple considers the battery worn; runtime will be noticeably shorter.")))
        }

        recommendations = recs
    }
}
