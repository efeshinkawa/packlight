import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
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
            Windows.render(SettingsView().environmentObject(state).frame(width: 480, height: 900),
                           to: dir.appending(path: "settings.png"))
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

    static func render(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@main
struct PacklightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var insights = Insights.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .environmentObject(insights)
        } label: {
            Image(nsImage: MenuBarIcon.image(mode: state.mode, busy: state.busy, pending: state.pendingAway != nil))
        }
        .menuBarExtraStyle(.window)
    }
}
