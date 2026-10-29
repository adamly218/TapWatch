import SwiftUI
import AppKit
import ServiceManagement

extension Signer {
    var color: Color {
        switch self {
        case .apple: return .gray
        case .appStore: return .blue
        case .developerID: return .green
        case .otherCertificate, .adHoc: return .orange
        case .unsigned, .invalid, .unknown: return .red
        }
    }
}

/// Actions the window and alert share; implemented by the app delegate.
struct TapActions {
    var reveal: (TapOwner) -> Void
    var terminate: (TapOwner) -> Void
}

// MARK: - Building blocks

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct InfoLine: View {
    var symbol: String
    var text: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(text)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
    }
}

struct OwnerSummary: View {
    var owner: TapOwner
    var trusted: Bool
    var iconSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: owner.icon).resizable().frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(owner.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Badge(text: owner.signature.signer.label, color: owner.signature.signer.color)
                    if trusted { Badge(text: "Allowed", color: .accentColor) }
                }
                Text(owner.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                InfoLine(symbol: owner.isActiveFilter ? "exclamationmark.triangle" : "eye",
                         text: owner.accessLabel,
                         color: owner.isActiveFilter ? .orange : .secondary)
                InfoLine(symbol: owner.isGlobal ? "globe" : "app", text: "Keystrokes from: \(owner.scopeLabel)")
                InfoLine(symbol: "checkmark.seal", text: signerLine, color: owner.signature.signer.isRisky ? .red : .secondary)
                InfoLine(symbol: "number", text: "PID \(owner.pid) · \(owner.taps.count) tap\(owner.taps.count == 1 ? "" : "s")")
            }
        }
    }

    private var signerLine: String {
        let signature = owner.signature
        if let authority = signature.authority, signature.signer != .apple { return authority }
        return signature.signer.explanation
    }
}

// MARK: - Main window

struct TapListView: View {
    @ObservedObject var watcher: Watcher
    @ObservedObject var preferences: Preferences
    var actions: TapActions

    private var visible: [TapOwner] {
        watcher.owners.filter { !(preferences.ignoreApple && $0.signature.signer == .apple) }
    }

    private var hiddenCount: Int { watcher.owners.count - visible.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { owner in
                            row(owner)
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 460)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: visible.contains(where: preferences.needsReview) ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(visible.contains(where: preferences.needsReview) ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("A keyboard tap lets a program see every key you press.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { watcher.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
        }
        .padding(16)
    }

    private var title: String {
        switch visible.count {
        case 0: return "No programs are reading your keyboard"
        case 1: return "1 program is reading your keyboard"
        default: return "\(visible.count) programs are reading your keyboard"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "keyboard").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Nothing to review").font(.system(size: 13, weight: .medium))
            Text("TapWatch will alert you when a program starts reading your keystrokes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ owner: TapOwner) -> some View {
        HStack(alignment: .top) {
            OwnerSummary(owner: owner, trusted: preferences.isTrusted(owner))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if preferences.isTrusted(owner) {
                    Button("Remove Allow") { preferences.untrust(owner.path) }
                } else {
                    Button("Allow") { preferences.trust(owner) }
                }
                HStack(spacing: 4) {
                    Button { actions.reveal(owner) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    Button { actions.terminate(owner) } label: { Image(systemName: "xmark.octagon") }
                        .help("Quit this program")
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Toggle("Hide Apple programs", isOn: $preferences.ignoreApple)
                .toggleStyle(.checkbox)
            if preferences.ignoreApple, hiddenCount > 0 {
                Text("(\(hiddenCount) hidden)").foregroundStyle(.secondary)
            }
            Spacer()
            if let lastScan = watcher.lastScan {
                Text("Updated \(lastScan.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Alert

struct AlertView: View {
    var owner: TapOwner
    var actions: TapActions
    var allow: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.eye")
                    .font(.system(size: 22))
                    .foregroundStyle(owner.signature.signer.isRisky ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New keyboard tap").font(.system(size: 15, weight: .semibold))
                    Text("\(owner.name) can now see the keys you type.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            OwnerSummary(owner: owner, trusted: false, iconSize: 44)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Text("If you didn't expect this, quit the program and check where it came from. Apps such as launchers, text expanders and window managers use keyboard taps for their shortcuts.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Quit Program", role: .destructive) {
                    actions.terminate(owner)
                }
                Button("Show in Finder") { actions.reveal(owner) }
                Spacer()
                Button("Later", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Allow", action: allow).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

// MARK: - Settings

final class LoginItem: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        self.enabled = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section("Watching") {
                Toggle("Alert me when a program starts reading the keyboard",
                       isOn: Binding(get: { !preferences.paused }, set: { preferences.paused = !$0 }))
                Toggle("Ignore programs signed by Apple", isOn: $preferences.ignoreApple)
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: login.set))
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Allowed programs") {
                if preferences.trusted.isEmpty {
                    Text("None yet. Programs you allow appear here.").foregroundStyle(.secondary)
                }
                ForEach(preferences.trusted, id: \.self) { path in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                        Text(path).font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { preferences.untrust(path) }.controlSize(.small)
                    }
                }
            }
            Section {
                HStack {
                    Text("TapWatch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Button("Quit TapWatch") { NSApp.terminate(nil) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
