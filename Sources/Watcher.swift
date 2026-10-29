import Foundation
import Combine
import Darwin
import notify

/// Keeps the list of keyboard taps current and reports taps that appear while it runs.
final class Watcher: ObservableObject {
    @Published private(set) var owners: [TapOwner] = []
    @Published private(set) var lastScan: Date?

    /// Called on the main thread with the owners of taps that appeared and stayed for at least a second.
    var onNewTaps: (([TapOwner]) -> Void)?

    private let queue = DispatchQueue(label: "TapWatch.scanner", qos: .userInitiated)
    private var known: Set<UInt32> = []
    private var tokens: [Int32] = []
    private var timer: Timer?

    func start() {
        queue.async { [self] in
            let taps = TapScanner.keyboardTaps()
            known = Set(taps.map(\.id))
            publish(taps)
        }

        // The window server posts these whenever any process adds or removes an event tap.
        for name in ["com.apple.coregraphics.eventTapAdded", "com.apple.coregraphics.eventTapRemoved"] {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, queue) { [weak self] _ in self?.check() }
            tokens.append(token)
        }

        // Catches taps that were enabled or disabled, which posts no notification.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.queue.async { self?.check() }
        }
    }

    func rescan() {
        queue.async { [self] in check() }
    }

    /// Runs on `queue`.
    private func check() {
        let taps = TapScanner.keyboardTaps()
        let fresh = taps.filter { !known.contains($0.id) }
        known = Set(taps.map(\.id))
        publish(taps)
        guard !fresh.isEmpty else { return }

        // Some apps (virtual machines, screen sharing) create a tap for a split second. Only report lasting ones.
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            let current = TapScanner.keyboardTaps()
            let lasting = fresh.filter { tap in current.contains { $0.id == tap.id } }
            guard !lasting.isEmpty else { return }
            let owners = TapScanner.owners(of: lasting)
            DispatchQueue.main.async { [self] in onNewTaps?(owners) }
        }
    }

    private func publish(_ taps: [EventTap]) {
        let owners = TapScanner.owners(of: taps)
        DispatchQueue.main.async { [self] in
            if owners != self.owners { self.owners = owners }
            lastScan = Date()
        }
    }

    deinit {
        tokens.forEach { notify_cancel($0) }
    }
}

// MARK: - Preferences

final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Programs (by path) the user has allowed. They are still listed but never alert.
    @Published var trusted: [String] {
        didSet { defaults.set(trusted, forKey: "trusted") }
    }
    @Published var ignoreApple: Bool {
        didSet { defaults.set(ignoreApple, forKey: "ignoreApple") }
    }
    @Published var paused: Bool {
        didSet { defaults.set(paused, forKey: "paused") }
    }
    @Published var hasLaunchedBefore: Bool {
        didSet { defaults.set(hasLaunchedBefore, forKey: "hasLaunchedBefore") }
    }

    init() {
        defaults.register(defaults: ["ignoreApple": true])
        trusted = defaults.stringArray(forKey: "trusted") ?? []
        ignoreApple = defaults.bool(forKey: "ignoreApple")
        paused = defaults.bool(forKey: "paused")
        hasLaunchedBefore = defaults.bool(forKey: "hasLaunchedBefore")
    }

    func isTrusted(_ owner: TapOwner) -> Bool { trusted.contains(owner.path) }

    func trust(_ owner: TapOwner) {
        if !isTrusted(owner) { trusted.append(owner.path) }
    }

    func untrust(_ path: String) {
        trusted.removeAll { $0 == path }
    }

    /// Whether a tap owner deserves the user's attention.
    func needsReview(_ owner: TapOwner) -> Bool {
        !isTrusted(owner) && !(ignoreApple && owner.signature.signer == .apple)
    }
}
