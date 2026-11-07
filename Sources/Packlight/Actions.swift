import AppKit
import Foundation

struct ProcInfo: Identifiable {
    let pid: Int32
    let cpu: Double
    let rssMB: Int
    let args: String
    var id: Int32 { pid }

    var name: String { Self.displayName(forPath: args.split(separator: " ").first.map(String.init) ?? args) }

    /// Prefers the .app name over a deep helper path.
    static func displayName(forPath exe: String) -> String {
        if let r = exe.range(of: ".app/") {
            let app = exe[..<r.lowerBound]
            return String(app.split(separator: "/").last ?? Substring(exe))
        }
        return (exe as NSString).lastPathComponent
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

    static func top(_ n: Int) -> [ProcInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        return all()
            .filter { $0.pid != me && $0.cpu >= 1 && !$0.args.hasPrefix("/bin/ps") }
            .sorted { $0.cpu > $1.cpu }
            .prefix(n)
            .map { $0 }
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
        if d.bool(forKey: Key.lowPower), Privileged.sudo("/usr/bin/pmset -a lowpowermode 1") {
            report.append(T("Low Power Mode on"))
        }
        if !Privileged.isInstalled && (d.bool(forKey: Key.purgeRAM) || d.bool(forKey: Key.lowPower)) {
            report.append(T("Skipped RAM / Low Power: install the password-free helper in Settings"))
        }

        if report.isEmpty { report.append(T("Already lean, nothing to close")) }
        return report
    }

    static func goHome() async -> [String] {
        let d = UserDefaults.standard
        var report: [String] = []

        if Privileged.sudo("/usr/bin/pmset -a lowpowermode 0") { report.append(T("Low Power Mode off")) }

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
            let procs = ProcInfo.all().filter { $0.args.hasPrefix(prefix) }
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
        let targets = ProcInfo.all().filter { p in
            guard p.pid != me, p.pid > 1, !p.args.hasPrefix("/bin/ps") else { return false }
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
