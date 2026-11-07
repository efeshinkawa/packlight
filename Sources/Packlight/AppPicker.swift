import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An installed or running app, as shown in the pickers.
struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    var isRunning = false
    var isBackground = false      // menu bar / agent app (no Dock icon)
    var memoryMB = 0
    var id: String { bundleID }

    var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    private static let developerDir = Shell.run("/usr/bin/xcode-select", ["-p"]).out
        .trimmingCharacters(in: .whitespacesAndNewlines)

    /// Finds an app by bundle ID, including Simulator, which lives inside Xcode where
    /// Launch Services doesn't always index it.
    static func locate(_ id: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        if id == "com.apple.iphonesimulator" {
            let path = developerDir + "/Applications/Simulator.app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Resolves a stored bundle ID into a display entry (even if the app isn't installed).
    static func resolve(_ id: String) -> AppEntry {
        let url = locate(id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        return AppEntry(bundleID: id, name: name, url: url, isRunning: running)
    }
}

enum AppCatalog {
    /// Installed apps (Applications folders) merged with whatever is running, deduplicated by bundle ID.
    static func load() -> [AppEntry] {
        var byID: [String: AppEntry] = [:]
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appending(path: item)
                guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                byID[id] = AppEntry(bundleID: id, name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
            }
        }
        // Memory per app bundle: sum of every process living inside it.
        var memory: [String: Int] = [:]
        for p in ProcInfo.mine() {
            if let path = p.appPath { memory[path, default: 0] += p.rssMB }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  app.activationPolicy != .prohibited || byID[id] != nil,
                  let url = app.bundleURL, !url.path.hasPrefix("/System/") else { continue }
            var entry = byID[id] ?? AppEntry(bundleID: id, name: app.localizedName ?? id, url: url)
            entry.isRunning = true
            entry.isBackground = app.activationPolicy != .regular
            entry.memoryMB = memory[url.path] ?? 0
            byID[id] = entry
        }
        return Array(byID.values)
    }
}

// MARK: - List editor used in Settings

/// A list of apps with icons, backed by the comma-separated bundle-ID string in UserDefaults.
struct AppListEditor: View {
    @Binding var ids: String
    var enabled = true
    @State private var picking = false
    @State private var hovered: String?

    private var list: [String] {
        ids.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if list.isEmpty {
                Text(T("No apps yet")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(list, id: \.self) { id in
                let app = AppEntry.resolve(id)
                HStack(spacing: 8) {
                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).lineLimit(1)
                        if app.url == nil {
                            Text(T("Not installed")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if app.isRunning {
                        Circle().fill(.green).frame(width: 6, height: 6).help(T("Running"))
                    }
                    Spacer()
                    Button { remove(id) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .opacity(hovered == id ? 1 : 0.45)
                        .help(T("Remove"))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? id : nil }
            }
            Button { picking = true } label: { Label(T("Add Apps…"), systemImage: "plus") }
                .padding(.top, 4)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .sheet(isPresented: $picking) {
            AppPickerSheet(existing: Set(list)) { picked in
                ids = (list + picked.filter { !list.contains($0) }).joined(separator: ", ")
            }
        }
    }

    private func remove(_ id: String) {
        ids = list.filter { $0 != id }.joined(separator: ", ")
    }
}

// MARK: - Picker sheet

struct AppPickerSheet: View {
    enum Filter: String, CaseIterable, Identifiable { case all, running, background; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable { case name, memory, runningFirst; var id: String { rawValue } }

    let existing: Set<String>
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppEntry]
    @State private var loading: Bool
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .runningFirst
    @State private var selection: Set<String>

    /// `preset` skips scanning the Mac (used for the README screenshots).
    init(existing: Set<String>, preset: [AppEntry]? = nil, selected: Set<String> = [],
         onAdd: @escaping ([String]) -> Void) {
        self.existing = existing
        self.onAdd = onAdd
        _apps = State(initialValue: preset ?? [])
        _loading = State(initialValue: preset == nil)
        _selection = State(initialValue: selected)
    }

    private var shown: [AppEntry] {
        apps.filter { app in
            guard !existing.contains(app.bundleID) else { return false }
            switch filter {
            case .all: break
            case .running: if !app.isRunning { return false }
            case .background: if !app.isBackground { return false }
            }
            return search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
                || app.bundleID.localizedCaseInsensitiveContains(search)
        }
        .sorted { a, b in
            switch sort {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .memory: return a.memoryMB != b.memoryMB ? a.memoryMB > b.memoryMB
                : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .runningFirst: return a.isRunning != b.isRunning ? a.isRunning
                : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(T("Search apps"), text: $search).textFieldStyle(.plain)
                }
                .padding(7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                HStack {
                    Picker("", selection: $filter) {
                        Text(T("All")).tag(Filter.all)
                        Text(T("Running")).tag(Filter.running)
                        Text(T("Background")).tag(Filter.background)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Picker(T("Sort by"), selection: $sort) {
                        Text(T("Running first")).tag(Sort.runningFirst)
                        Text(T("Name")).tag(Sort.name)
                        Text(T("Memory use")).tag(Sort.memory)
                    }
                    .fixedSize()
                }
            }
            .padding(14)

            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(T("No matching apps")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { app in
                    row(app)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button(T("Other…")) { chooseFromDisk() }
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selection.isEmpty ? T("Add") : T("Add %d", selection.count)) {
                    onAdd(Array(selection))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 460, height: 520)
        .task {
            guard loading else { return }
            let loaded = await Task.detached(priority: .userInitiated) { AppCatalog.load() }.value
            apps = loaded
            loading = false
        }
    }

    private func row(_ app: AppEntry) -> some View {
        let checked = selection.contains(app.bundleID)
        return HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if app.isRunning {
                if app.memoryMB > 0 {
                    Text(verbatim: "\(app.memoryMB) MB").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Circle().fill(.green).frame(width: 6, height: 6).help(T("Running"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if checked { selection.remove(app.bundleID) } else { selection.insert(app.bundleID) }
        }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !existing.contains($0) }
        if !ids.isEmpty {
            onAdd(ids)
            dismiss()
        }
    }
}

extension AppPickerSheet {
    /// Sample list built from apps that ship with every Mac.
    static var demoApps: [AppEntry] {
        func app(_ name: String, _ id: String, running: Bool = false, background: Bool = false, mb: Int = 0) -> AppEntry {
            let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
            return AppEntry(bundleID: id, name: name, url: url, isRunning: running, isBackground: background, memoryMB: mb)
        }
        return [
            app("Music", "com.apple.Music", running: true, mb: 412),
            app("Photos", "com.apple.Photos", running: true, mb: 288),
            app("Mail", "com.apple.mail", running: true, mb: 196),
            app("Messages", "com.apple.MobileSMS", running: true, mb: 142),
            app("Calendar", "com.apple.iCal"),
            app("Maps", "com.apple.Maps"),
            app("Notes", "com.apple.Notes"),
            app("Podcasts", "com.apple.podcasts"),
            app("Reminders", "com.apple.reminders"),
        ]
    }
}
