import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = Watcher()
    let preferences = Preferences()
    private var statusItem: NSStatusItem!
    private var listWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var alerts: [pid_t: NSPanel] = [:]
    /// Processes already alerted about this session, keyed by PID and path so a reused PID still alerts.
    private var alerted: Set<String> = []
    private var subscriptions = Set<AnyCancellable>()

    lazy var actions = TapActions(reveal: { [weak self] in self?.reveal($0) },
                                  terminate: { [weak self] in self?.terminate($0) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TapWatch"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onNewTaps = { [weak self] in self?.handle(newOwners: $0) }
        watcher.$owners.combineLatest(preferences.$paused, preferences.$trusted, preferences.$ignoreApple)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &subscriptions)
        watcher.start()

        if !preferences.hasLaunchedBefore {
            preferences.hasLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showList() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showList()
        return true
    }

    // MARK: Menu bar

    private var reviewCount: Int { watcher.owners.filter(preferences.needsReview).count }

    private func updateIcon() {
        let symbol = preferences.paused ? "shield.slash" : reviewCount > 0 ? "exclamationmark.shield" : "checkmark.shield"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TapWatch")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = preferences.paused ? "TapWatch is paused" : "TapWatch: \(summary)"
    }

    private var summary: String {
        switch reviewCount {
        case 0: return "nothing to review"
        case 1: return "1 program can read your keyboard"
        default: return "\(reviewCount) programs can read your keyboard"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: preferences.paused ? "Paused: no alerts" : "Watching the keyboard", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let detail = NSMenuItem(title: summary.prefix(1).uppercased() + summary.dropFirst(), action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())
        menu.addItem(item("Show Keyboard Taps…", #selector(showList), "k"))
        menu.addItem(item(preferences.paused ? "Resume Alerts" : "Pause Alerts", #selector(togglePaused), ""))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(item("Quit TapWatch", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func togglePaused() {
        preferences.paused.toggle()
    }

    // MARK: Windows

    @objc func showList() {
        if listWindow == nil {
            listWindow = makeWindow("Keyboard Taps", TapListView(watcher: watcher, preferences: preferences, actions: actions))
        }
        watcher.rescan()
        present(listWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow("TapWatch Settings", SettingsView(preferences: preferences))
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(_ title: String, _ view: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Alerts

    private func handle(newOwners: [TapOwner]) {
        guard !preferences.paused else { return }
        for owner in newOwners where preferences.needsReview(owner) {
            let key = "\(owner.pid):\(owner.path)"
            guard !alerted.contains(key), alerts[owner.pid] == nil else { continue }
            alerted.insert(key)
            showAlert(owner)
        }
    }

    func showAlert(_ owner: TapOwner) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        let close = { [weak self, weak panel] in
            panel?.close()
            self?.alerts[owner.pid] = nil
        }
        let hosting = NSHostingController(rootView: AlertView(
            owner: owner, actions: actions,
            allow: { [weak self] in self?.preferences.trust(owner); close() },
            dismiss: close))
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()
        alerts[owner.pid] = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    private func reveal(_ owner: TapOwner) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: owner.bundlePath ?? owner.path)])
    }

    private func terminate(_ owner: TapOwner) {
        let alert = NSAlert()
        alert.messageText = "Quit \(owner.name)?"
        alert.informativeText = owner.signature.signer == .apple
            ? "This is part of macOS. Quitting it may affect accessibility or input features until it restarts."
            : "Unsaved work in \(owner.name) may be lost. If it starts again at login, remove it from System Settings → General → Login Items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let app = NSRunningApplication(processIdentifier: owner.pid), app.terminate() {
            // Asked the app to quit normally.
        } else if kill(owner.pid, SIGTERM) != 0 {
            let failure = NSAlert()
            failure.messageText = "Couldn't quit \(owner.name)"
            failure.informativeText = String(cString: strerror(errno))
            failure.runModal()
        }
        alerts[owner.pid]?.close()
        alerts[owner.pid] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watcher.rescan() }
    }
}

// MARK: - Command-line modes

/// `--scan` prints every keyboard tap and exits.
func printScan() {
    let owners = TapScanner.owners(of: TapScanner.keyboardTaps())
    if owners.isEmpty { print("No keyboard event taps.") }
    for owner in owners {
        print("\(owner.name)  [\(owner.signature.signer.label)\(owner.signature.teamID.map { ", team \($0)" } ?? "")]")
        print("  path    \(owner.path)")
        print("  pid     \(owner.pid), \(owner.taps.count) tap(s): \(owner.taps.map { String($0.id) }.joined(separator: ", "))")
        print("  access  \(owner.accessLabel)")
        print("  scope   \(owner.scopeLabel)")
        if let authority = owner.signature.authority { print("  signer  \(authority)") }
    }
}

/// `--snapshot <folder>` renders the window and an alert to PNG files for the README.
func snapshot(to folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let watcher = Watcher()
    watcher.start()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    let preferences = Preferences()
    let ignoredApple = preferences.ignoreApple
    preferences.ignoreApple = false
    defer { preferences.ignoreApple = ignoredApple }
    let actions = TapActions(reveal: { _ in }, terminate: { _ in })

    func save<Content: View>(_ view: Content, _ name: String) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }

    save(TapListView(watcher: watcher, preferences: preferences, actions: actions), "window.png")
    if let owner = watcher.owners.first(where: { $0.signature.signer != .apple }) ?? watcher.owners.first {
        save(AlertView(owner: owner, actions: actions, allow: {}, dismiss: {}), "alert.png")
    }
}

let arguments = CommandLine.arguments
let app = NSApplication.shared

if arguments.contains("--scan") {
    printScan()
} else if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    app.setActivationPolicy(.prohibited)
    snapshot(to: URL(fileURLWithPath: arguments[index + 1]))
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
