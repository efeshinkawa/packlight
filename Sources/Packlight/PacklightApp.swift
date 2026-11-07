import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController?

    /// Sample settings for the README screenshot, kept in a throwaway suite so the
    /// user's real settings are neither shown nor changed.
    private static func demoDefaults() -> UserDefaults {
        let suite = "io.github.efeshinkawa.packlight.demo"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set("en", forKey: Key.language)
        d.set("com.logi.ghub", forKey: Key.relaunchApps)
        d.set("com.apple.dt.Xcode, com.google.android.studio", forKey: Key.appBundleIDs)
        return d
    }

    /// A menu bar app never quits because a window closed (snapshot render windows included).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach(AppState.shared.handle) }
    }

    /// `Packlight --snapshot <dir>` renders the panel and both windows to PNGs and exits.
    /// Used to check layouts without clicking the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // `Packlight --make-icon <file.png> <pixels>` writes the app icon (used by build.sh).
        if let i = args.firstIndex(of: "--make-icon"), i + 2 < args.count, let px = Double(args[i + 2]) {
            try? PacklightMark.appIcon(size: px).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else {
            MainActor.assumeIsolated { status = StatusItemController() }
            return
        }
        let dir = URL(fileURLWithPath: args[i + 1])
        NSApp.appearance = NSAppearance(named: .aqua)   // README shots are always light
        Task { @MainActor in
            let state = AppState.shared
            let demo = args.contains("--demo")
            if demo {
                state.loadDemo(away: false)
                Insights.shared.loadDemo(away: false)
            } else {
                state.panelOpened()
                Insights.shared.setFast(true)
                try? await Task.sleep(for: .seconds(4))
            }
            Windows.render(MenuView().environmentObject(state).environmentObject(Insights.shared),
                           to: dir.appending(path: "menu.png"))
            Windows.render(SettingsView().environmentObject(state).frame(width: 480, height: demo ? 1300 : 900)
                .defaultAppStorage(demo ? Self.demoDefaults() : .standard),
                           to: dir.appending(path: "settings.png"))
            if demo {
                Windows.render(AppPickerSheet(existing: [], preset: AppPickerSheet.demoApps,
                                              selected: ["com.apple.Music", "com.apple.Photos"]) { _ in },
                               to: dir.appending(path: "app-picker.png"))
            }
            Windows.render(InsightsView().environmentObject(state).environmentObject(Insights.shared)
                .frame(width: 560, height: demo ? 1180 : 980), to: dir.appending(path: "insights.png"))
            if demo {
                state.loadDemo(away: true)
                Insights.shared.loadDemo(away: true)
                Windows.render(MenuView().environmentObject(state).environmentObject(Insights.shared),
                               to: dir.appending(path: "menu-away.png"))
            }
            NSApp.terminate(nil)
        }
    }
}

/// Settings and Insights are plain AppKit windows so they can be opened from anywhere
/// (menu panel, URL scheme, Raycast) and scroll like normal windows.
@MainActor
enum Windows {
    enum Kind { case settings, insights }
    private static var open: [Kind: NSWindow] = [:]
    private static var renderWindows: [NSWindow] = []

    static func show(_ kind: Kind) {
        if let w = open[kind] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root: AnyView
        let title: String
        let size: NSSize
        switch kind {
        case .settings:
            root = AnyView(SettingsView().environmentObject(AppState.shared))
            title = T("Packlight Settings")
            size = NSSize(width: 480, height: 640)
        case .insights:
            root = AnyView(InsightsView().environmentObject(AppState.shared).environmentObject(Insights.shared))
            title = T("Battery Insights")
            size = NSSize(width: 560, height: 700)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                open[kind] = nil
                if kind == .insights { Insights.shared.setFast(false) }
            }
        }
        open[kind] = window
        if kind == .insights { Insights.shared.setFast(true) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Renders a view to an opaque PNG in light appearance. Opaque matters: a transparent
    /// background makes the dark text unreadable on dark-mode pages (e.g. GitHub's app).
    static func render(_ view: some View, to url: URL) {
        let aqua = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        renderWindows.append(window)   // kept alive until the snapshot run exits
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        host.layoutSubtreeIfNeeded()
        guard let content = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: content)

        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: content.pixelsWide,
                                         pixelsHigh: content.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = content.size   // before creating the context, so it draws at the Retina scale
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(origin: .zero, size: content.size)
        aqua?.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
        rect.fill()
        content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The menu bar icon and its panel. An NSPopover (rather than MenuBarExtra) because it
/// resizes with its content — MenuBarExtra windows keep their first height and leave a gap.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var observers: [AnyCancellable] = []

    override init() {
        super.init()
        let host = NSHostingController(rootView: MenuView()
            .environmentObject(AppState.shared)
            .environmentObject(Insights.shared))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Packlight")
        updateIcon()
        observers.append(AppState.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        })
    }

    private func updateIcon() {
        let s = AppState.shared
        item.button?.image = MenuBarIcon.image(mode: s.mode, busy: s.busy, pending: s.pendingAway != nil)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh first so the panel opens at its final size.
            AppState.shared.panelOpened()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.panelClosed()
    }
}

@main
struct PacklightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item is AppKit (StatusItemController); SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}
