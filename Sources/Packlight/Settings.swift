import Foundation

/// UserDefaults keys; the same strings are used by @AppStorage in the UI.
enum Key {
    static let mode = "mode"
    static let autoSwitch = "autoSwitch"
    static let graceSeconds = "graceSeconds"
    static let quitApps = "quitApps"
    static let appBundleIDs = "appBundleIDs"
    static let shutdownSims = "shutdownSims"
    static let killDev = "killDev"
    static let extraPatterns = "extraPatterns"
    static let stopBrew = "stopBrew"
    static let stoppedBrewServices = "stoppedBrewServices"
    static let clearDerivedData = "clearDerivedData"
    static let clearSimCaches = "clearSimCaches"
    static let clearXcodeCaches = "clearXcodeCaches"
    static let clearNpm = "clearNpm"
    static let brewCleanup = "brewCleanup"
    static let purgeRAM = "purgeRAM"
    static let lowPower = "lowPower"            // pre-1.1: replaced by lowPowerPolicy
    static let lowPowerPolicy = "lowPowerPolicy"
    static let lowPowerThreshold = "lowPowerThreshold"
    static let lowPowerOffAtHome = "lowPowerOffAtHome"
    static let language = "language"
    static let relaunchApps = "relaunchApps"
    static let relaunchPending = "relaunchPending"
    static let estimate = "estimate"
    static let lastReport = "lastReport"
    static let lastReportDate = "lastReportDate"

    /// Keys the packlight://set URL may change.
    static let settable: Set<String> = [
        language, relaunchApps,
        autoSwitch, graceSeconds, quitApps, appBundleIDs, shutdownSims, killDev, extraPatterns,
        stopBrew, clearDerivedData, clearSimCaches, clearXcodeCaches, clearNpm, brewCleanup,
        purgeRAM, lowPowerPolicy, lowPowerThreshold, lowPowerOffAtHome,
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            mode: Mode.home.rawValue,
            language: Lang.system.rawValue,
            // Quit when going out, reopened (in the background) when back home.
            relaunchApps: "",
            autoSwitch: true,
            graceSeconds: 30,
            quitApps: true,
            appBundleIDs: "com.apple.dt.Xcode, com.apple.iphonesimulator, com.google.android.studio, com.docker.docker, dev.kdrag0n.MacVirt",
            shutdownSims: true,
            killDev: true,
            extraPatterns: "",
            stopBrew: true,
            clearDerivedData: true,
            clearSimCaches: true,
            clearXcodeCaches: true,
            clearNpm: false,
            brewCleanup: false,
            purgeRAM: true,
            lowPowerPolicy: LowPowerPolicy.away.rawValue,
            lowPowerThreshold: 30,
            lowPowerOffAtHome: true,
        ])
        // Registered defaults aren't visible to `defaults read`; write them out once
        // so the Raycast extension sees real values.
        let d = UserDefaults.standard
        let stored = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        // Someone who had switched the old Low Power toggle off keeps it off.
        if stored[lowPowerPolicy] == nil, stored[lowPower] as? Bool == false {
            d.set(LowPowerPolicy.never.rawValue, forKey: lowPowerPolicy)
        }
        for key in settable where stored[key] == nil {
            d.set(d.object(forKey: key), forKey: key)
        }
    }
}

/// When Packlight turns on macOS Low Power Mode.
enum LowPowerPolicy: String, CaseIterable, Identifiable {
    case away       // with Away mode
    case battery    // whenever unplugged
    case below      // on battery below a chosen percentage
    case never
    var id: String { rawValue }

    static var current: LowPowerPolicy {
        LowPowerPolicy(rawValue: UserDefaults.standard.string(forKey: Key.lowPowerPolicy) ?? "") ?? .away
    }
}

enum Mode: String {
    case home, away
}

extension UserDefaults {
    func list(_ key: String) -> [String] {
        (string(forKey: key) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
