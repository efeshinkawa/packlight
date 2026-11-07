import Foundation

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String] = []) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        // Read before waiting so a full pipe can't deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let brew: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Root-only commands (pmset, purge) run through a one-time sudoers rule so
/// switching modes never asks for a password.
enum Privileged {
    static let sudoersPath = "/etc/sudoers.d/packlight"
    /// Written by pre-release builds; removed when the helper is installed.
    static let legacySudoersPath = "/etc/sudoers.d/lapdesktop"
    static let commands = [
        "/usr/bin/pmset -a lowpowermode 0",
        "/usr/bin/pmset -a lowpowermode 1",
        "/usr/sbin/purge",
    ]

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Shows the macOS admin prompt once and installs the rule (validated by visudo).
    static func install() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: " + commands.joined(separator: ", ")
        let sh = "t=$(mktemp) && echo '\(rule)' > $t && /usr/sbin/visudo -cf $t && "
            + "/usr/bin/install -m 0440 -o root -g wheel $t \(sudoersPath); r=$?; rm -f $t \(legacySudoersPath); exit $r"
        let source = "do shell script \"\(sh)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && isInstalled
    }

    static func uninstall() {
        let source = "do shell script \"rm -f \(sudoersPath)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    @discardableResult
    static func sudo(_ command: String) -> Bool {
        guard isInstalled else { return false }
        return Shell.run("/usr/bin/sudo", ["-n"] + command.split(separator: " ").map(String.init)).status == 0
    }

    /// Read from the system directly; no `pmset` process per check.
    static var lowPowerEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
