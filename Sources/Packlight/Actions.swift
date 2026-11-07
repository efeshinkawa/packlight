import AppKit
import Darwin
import Foundation

struct ProcInfo: Identifiable {
    let pid: Int32
    let cpu: Double
    let rssMB: Int
    let args: String
    /// Every process grouped into this row (an app and its helpers).
    var pids: [Int32] = []
    var id: Int32 { pid }

    var name: String { Self.displayName(forPath: args.split(separator: " ").first.map(String.init) ?? args) }

    /// The outermost .app this process lives in, if any.
    var appPath: String? {
        args.range(of: ".app/").map { String(args[..<$0.lowerBound]) + ".app" }
    }

    /// Prefers the .app name over a deep helper path, and trims Apple's reverse-DNS
    /// daemon names ("com.apple.DriverKit-AppleBCMWLAN" → "AppleBCMWLAN").
    static func displayName(forPath exe: String) -> String {
        if let r = exe.range(of: ".app/") {
            let app = exe[..<r.lowerBound]
            return String(app.split(separator: "/").last ?? Substring(exe))
        }
        var name = (exe as NSString).lastPathComponent
        if name.hasPrefix("com.apple.") {
            name.removeFirst("com.apple.".count)
            if let dash = name.lastIndex(of: "-") { name = String(name[name.index(after: dash)...]) }
        }
        return name
    }

    static func all() -> [ProcInfo] {
        Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,args="]).out
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                      let rss = Int(parts[2]) else { return nil }
                return ProcInfo(pid: pid, cpu: cpu, rssMB: rss / 1024, args: String(parts[3]))
            }
    }

    /// The current user's processes with full command lines, read through libproc and
    /// `KERN_PROCARGS2` instead of spawning `ps`. Other users' processes aren't readable
    /// without root — fine here, since we could not signal them anyway.
    static func mine() -> [ProcInfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, n))).compactMap { pid in
            guard pid > 0, let args = commandLine(pid) else { return nil }
            var info = proc_taskinfo()
            let ok = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
            return ProcInfo(pid: pid, cpu: 0, rssMB: ok ? Int(info.pti_resident_size / 1_048_576) : 0, args: args)
        }
    }

    /// argv joined by spaces. KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argv[0..argc].
    private static func commandLine(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }      // exec path
        while i < size && buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while i < size && args.count < Int(argc) {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    /// Heaviest CPU users, one row per app (helpers summed into their app).
    static func top(_ n: Int) -> [ProcInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        let procs = all().filter { $0.pid != me && !$0.args.hasPrefix("/bin/ps") }
        var groups: [String: ProcInfo] = [:]
        for p in procs {
            let key = p.appPath ?? p.name
            if let g = groups[key] {
                let lead = p.cpu > g.cpu && p.appPath == nil ? p : g
                groups[key] = ProcInfo(pid: lead.pid, cpu: g.cpu + p.cpu, rssMB: g.rssMB + p.rssMB,
                                       args: lead.args, pids: g.pids + [p.pid])
            } else {
                groups[key] = ProcInfo(pid: p.pid, cpu: p.cpu, rssMB: p.rssMB, args: p.args, pids: [p.pid])
            }
        }
        return groups.values.filter { $0.cpu >= 1 }.sorted { $0.cpu > $1.cpu }.prefix(n).map { $0 }
    }
}

/// Everything Away and Home modes do. Runs off the main thread and returns
/// one human-readable line per thing it actually changed.
enum ModeActions {
    /// Matched against full command lines. Targets builds, dev servers and VMs
    /// only, so editors and AI tools keep running.
    static let devPatterns = [
        #"(^|/)xcodebuild\b"#, #"(^|/)swift-(build|frontend|test)\b"#, #"(^|/)clang(\+\+)?\s"#,
        #"(^|/)(cargo|rustc|rust-analyzer)\b"#,
        #"GradleDaemon|GradleWrapperMain|KotlinCompileDaemon"#,
        #"\b(vite|webpack|nodemon|esbuild|turbo|metro|vitest|jest|playwright)\b"#,
        #"\bnext (dev|build|start)\b"#, #"\btsc\b.*--watch"#, #"\bexpo start\b"#,
        #"\breact-native (start|run)"#, #"\b(npm|pnpm|yarn|bun) (run|dev|start|build|watch)\b"#,
        #"(^|/)watchman\b"#, #"(^|/)ollama\b"#, #"qemu-system"#, #"emulator.*-avd"#,
        #"(^|/)caffeinate\b"#,
    ]

    /// Never touched even if a dev pattern matches (MCP servers often run through node/esbuild).
    static let protectedPattern = #"\bmcp\b|-mcp\b|mcp-|Claude\.app|claude-code|/\.claude/|Packlight\.app"#

    static func goAway() async -> [String] {
        let d = UserDefaults.standard
        var report: [String] = []

        let relaunch = await quitForRelaunch(d.list(Key.relaunchApps))
        if !relaunch.isEmpty {
            report.append(T("Closed until you're home: ") + relaunch.joined(separator: ", "))
        }

        if d.bool(forKey: Key.quitApps) {
            let quit = await quitApps(prefixes: d.list(Key.appBundleIDs))
            if !quit.isEmpty { report.append(T("Quit apps: ") + quit.joined(separator: ", ")) }
        }

        if d.bool(forKey: Key.shutdownSims) {
            let booted = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"]).out
                .components(separatedBy: "(Booted)").count - 1
            if booted > 0 {
                Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
                report.append(T("Shut down %d simulator(s)", booted))
            }
        }

        if d.bool(forKey: Key.killDev) {
            let killed = killMatching(devPatterns + d.list(Key.extraPatterns))
            if !killed.isEmpty {
                let names = Array(Set(killed)).sorted().prefix(6).joined(separator: ", ")
                report.append(T("Stopped %d build/dev process(es) (%@)", killed.count, names))
            }
        }

        if d.bool(forKey: Key.stopBrew), let brew = Shell.brew {
            let running = brewServices(brew).filter { $0.status == "started" }.map(\.name)
            for name in running { Shell.run(brew, ["services", "stop", name]) }
            if !running.isEmpty {
                // Remember them so Home can bring exactly these back.
                let previous = Set(d.stringArray(forKey: Key.stoppedBrewServices) ?? [])
                d.set(Array(previous.union(running)), forKey: Key.stoppedBrewServices)
                report.append(T("Stopped brew services: ") + running.joined(separator: ", "))
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var cleared: Int64 = 0
        if d.bool(forKey: Key.clearDerivedData) { cleared += empty(home.appending(path: "Library/Developer/Xcode/DerivedData")) }
        if d.bool(forKey: Key.clearSimCaches) { cleared += empty(home.appending(path: "Library/Developer/CoreSimulator/Caches")) }
        if d.bool(forKey: Key.clearXcodeCaches) { cleared += empty(home.appending(path: "Library/Caches/com.apple.dt.Xcode")) }
        if d.bool(forKey: Key.clearNpm) { cleared += empty(home.appending(path: ".npm/_cacache")) }
        if d.bool(forKey: Key.brewCleanup), let brew = Shell.brew {
            let cache = home.appending(path: "Library/Caches/Homebrew")
            let before = size(of: cache)
            Shell.run(brew, ["cleanup", "-s", "--prune=all"])
            cleared += max(0, before - size(of: cache))
        }
        if cleared > 0 {
            let size = ByteCountFormatter.string(fromByteCount: cleared, countStyle: .file)
            report.append(T("Cleared %@ of caches", size))
        }

        if d.bool(forKey: Key.purgeRAM), Privileged.sudo("/usr/sbin/purge") {
            report.append(T("Freed inactive RAM"))
        }
        let policy = LowPowerPolicy.current
        if policy == .away || policy == .battery, Privileged.sudo("/usr/bin/pmset -a lowpowermode 1") {
            report.append(T("Low Power Mode on"))
        }
        if !Privileged.isInstalled && (d.bool(forKey: Key.purgeRAM) || policy != .never) {
            report.append(T("Skipped RAM / Low Power: install the password-free helper in Settings"))
        }

        if report.isEmpty { report.append(T("Already lean, nothing to close")) }
        return report
    }

    static func goHome() async -> [String] {
        let d = UserDefaults.standard
        var report: [String] = []

        if d.bool(forKey: Key.lowPowerOffAtHome), Privileged.lowPowerEnabled,
           Privileged.sudo("/usr/bin/pmset -a lowpowermode 0") { report.append(T("Low Power Mode off")) }

        if let brew = Shell.brew, let services = d.stringArray(forKey: Key.stoppedBrewServices), !services.isEmpty {
            for name in services { Shell.run(brew, ["services", "start", name]) }
            d.removeObject(forKey: Key.stoppedBrewServices)
            report.append(T("Restarted brew services: ") + services.joined(separator: ", "))
        }

        let reopened = await relaunchPending()
        if !reopened.isEmpty { report.append(T("Reopened: ") + reopened.joined(separator: ", ")) }

        if report.isEmpty { report.append(T("Home mode — full power")) }
        return report
    }

    // MARK: - Quit at Away, reopen at Home

    /// Quits each app and every helper process living inside its bundle (G HUB runs
    /// three of them), remembering which ones were running so Home can reopen them.
    private static func quitForRelaunch(_ ids: [String]) async -> [String] {
        let d = UserDefaults.standard
        var pending = Set(d.stringArray(forKey: Key.relaunchPending) ?? [])
        var names: [String] = []
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let prefix = url.path + "/"
            let procs = ProcInfo.mine().filter { $0.args.hasPrefix(prefix) }
            let apps = await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: id) }
            guard !procs.isEmpty || !apps.isEmpty else { continue }
            await MainActor.run { apps.forEach { $0.terminate() } }
            procs.forEach { kill($0.pid, SIGTERM) }
            try? await Task.sleep(for: .seconds(2))
            procs.filter { kill($0.pid, 0) == 0 }.forEach { kill($0.pid, SIGKILL) }
            pending.insert(id)
            names.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        d.set(Array(pending), forKey: Key.relaunchPending)
        return names
    }

    /// Reopens in the background: through the app's own LaunchAgent when it has one
    /// (no window pops up), otherwise as a hidden app launch.
    private static func relaunchPending() async -> [String] {
        let d = UserDefaults.standard
        let ids = d.stringArray(forKey: Key.relaunchPending) ?? []
        d.removeObject(forKey: Key.relaunchPending)
        var names: [String] = []
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let uid = getuid()
            if let label = launchAgentLabel(inside: url.path),
               Shell.run("/bin/launchctl", ["kickstart", "gui/\(uid)/\(label)"]).status == 0 {
                // started by its agent
            } else {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            names.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        return names
    }

    private static func launchAgentLabel(inside bundlePath: String) -> String? {
        let dirs = [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents"]
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                guard let plist = NSDictionary(contentsOfFile: dir + "/" + file) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
                if program.hasPrefix(bundlePath + "/") { return label }
            }
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    private static func runningApps(_ prefixes: [String]) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return prefixes.contains { id.hasPrefix($0) }
        }
    }

    /// Polite quit only: an app with unsaved work gets to ask, nothing is force-killed.
    private static func quitApps(prefixes: [String]) async -> [String] {
        let apps = await runningApps(prefixes)
        let names = await MainActor.run { apps.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" } }
        await MainActor.run { apps.forEach { $0.terminate() } }
        // Give them a moment so caches aren't deleted under a still-running Xcode.
        for _ in 0..<10 {
            if await MainActor.run(body: { apps.allSatisfy(\.isTerminated) }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return names
    }

    /// SIGTERM, wait, then SIGKILL whatever ignored it. Returns killed process names.
    static func killMatching(_ patterns: [String]) -> [String] {
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        let protected = try? NSRegularExpression(pattern: protectedPattern, options: .caseInsensitive)
        let me = ProcessInfo.processInfo.processIdentifier
        let targets = ProcInfo.mine().filter { p in
            guard p.pid != me, p.pid > 1 else { return false }
            let range = NSRange(p.args.startIndex..., in: p.args)
            if protected?.firstMatch(in: p.args, range: range) != nil { return false }
            return regexes.contains { $0.firstMatch(in: p.args, range: range) != nil }
        }
        guard !targets.isEmpty else { return [] }
        targets.forEach { kill($0.pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 2)
        targets.filter { kill($0.pid, 0) == 0 }.forEach { kill($0.pid, SIGKILL) }
        return targets.map(\.name)
    }

    /// True when Away mode would close this command line (used by the battery insights).
    static func awayWouldClose(path: String) -> Bool {
        let d = UserDefaults.standard
        let ids = d.list(Key.appBundleIDs) + d.list(Key.relaunchApps)
        if let id = bundleID(forPath: path), ids.contains(where: { id.hasPrefix($0) }) { return true }
        let patterns = devPatterns + d.list(Key.extraPatterns)
        let range = NSRange(path.startIndex..., in: path)
        return patterns.contains {
            (try? NSRegularExpression(pattern: $0, options: .caseInsensitive))?.firstMatch(in: path, range: range) != nil
        }
    }

    /// Bundle identifier of the outermost .app containing `path`, if any.
    static func bundleID(forPath path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? path.range(of: ".app", options: .anchored) else { return nil }
        return Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier
    }

    private static func brewServices(_ brew: String) -> [(name: String, status: String)] {
        let json = Shell.run(brew, ["services", "list", "--json"]).out
        guard let start = json.firstIndex(of: "["),
              let arr = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { s in
            guard let n = s["name"] as? String else { return nil }
            return (n, s["status"] as? String ?? "")
        }
    }

    static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Deletes the folder's contents (not the folder) and returns bytes freed.
    private static func empty(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return 0 }
        let before = size(of: url)
        items.forEach { try? fm.removeItem(at: $0) }
        return max(0, before - size(of: url))
    }
}
