import AppKit
import CoreGraphics
import Security
import Darwin

// MARK: - Models

/// Who signed a program, from strongest to weakest trust.
enum Signer: Equatable {
    case apple
    case appStore
    case developerID
    case otherCertificate
    case adHoc
    case unsigned
    case invalid
    case unknown

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .appStore: return "App Store"
        case .developerID: return "Developer ID"
        case .otherCertificate: return "Signed"
        case .adHoc: return "Ad hoc"
        case .unsigned: return "Unsigned"
        case .invalid: return "Invalid signature"
        case .unknown: return "Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .apple: return "Part of macOS, signed by Apple."
        case .appStore: return "Distributed through the Mac App Store."
        case .developerID: return "Signed by an identified developer."
        case .otherCertificate: return "Signed with a certificate that isn't from Apple."
        case .adHoc: return "Signed without an identity. Common for apps you built yourself."
        case .unsigned: return "Not signed at all. Be careful."
        case .invalid: return "The signature doesn't match the file. It may have been modified."
        case .unknown: return "The signature couldn't be checked."
        }
    }

    var isRisky: Bool { [.unsigned, .invalid, .unknown].contains(self) }
}

struct Signature: Equatable {
    var signer: Signer
    var identifier: String?
    var teamID: String?
    var authority: String?
}

struct EventTap: Identifiable, Equatable {
    let id: UInt32
    let pid: pid_t
    let targetPID: pid_t
    let isActiveFilter: Bool
}

/// Every keyboard tap owned by one process.
struct TapOwner: Identifiable, Equatable {
    let pid: pid_t
    let path: String
    let name: String
    let bundlePath: String?
    let signature: Signature
    var taps: [EventTap]
    var targetName: String?

    var id: pid_t { pid }
    var isActiveFilter: Bool { taps.contains(where: \.isActiveFilter) }
    var isGlobal: Bool { taps.contains { $0.targetPID == 0 } }

    var icon: NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(forFile: bundlePath ?? path)
    }

    var accessLabel: String {
        isActiveFilter ? "Active filter: can read, change or block keystrokes"
                       : "Listener: can read keystrokes"
    }

    var scopeLabel: String {
        isGlobal ? "All apps" : "Only \(targetName ?? "one app")"
    }
}

// MARK: - Scanning

enum TapScanner {
    private static let keyboardMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

    /// The enabled event taps that receive key presses, as reported by the window server.
    static func keyboardTaps() -> [EventTap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }

        return list.prefix(Int(count))
            .filter { $0.enabled && $0.eventsOfInterest & keyboardMask != 0 }
            .map { EventTap(id: $0.eventTapID, pid: $0.tappingProcess, targetPID: $0.processBeingTapped,
                            isActiveFilter: $0.options == .defaultTap) }
    }

    /// Groups taps by the process that owns them and looks up who that process is.
    static func owners(of taps: [EventTap]) -> [TapOwner] {
        Dictionary(grouping: taps, by: \.pid).compactMap { pid, taps in
            guard let path = processPath(pid) else { return nil }
            let bundle = enclosingBundle(of: path)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? bundle.flatMap(displayName)
                ?? (path as NSString).lastPathComponent
            let target = taps.first { $0.targetPID != 0 }.flatMap { tap in
                NSRunningApplication(processIdentifier: tap.targetPID)?.localizedName
                    ?? processPath(tap.targetPID).map { ($0 as NSString).lastPathComponent }
            }
            return TapOwner(pid: pid, path: path, name: name, bundlePath: bundle,
                            signature: SignatureChecker.signature(of: path),
                            taps: taps.sorted { $0.id < $1.id }, targetName: target)
        }
        .sorted { ($0.signature.signer == .apple ? 1 : 0, $0.name.lowercased())
                < ($1.signature.signer == .apple ? 1 : 0, $1.name.lowercased()) }
    }

    static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func enclosingBundle(of path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if ["app", "xpc", "appex"].contains(url.pathExtension) { return url.path }
        }
        return nil
    }

    private static func displayName(_ bundlePath: String) -> String? {
        let bundle = Bundle(path: bundlePath)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName")) as? String
    }
}

// MARK: - Code signing

enum SignatureChecker {
    private static var cache: [String: Signature] = [:]
    private static let lock = NSLock()

    private static let requirements: [(Signer, String)] = [
        (.apple, "anchor apple"),
        (.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"),
        (.developerID, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
    ]

    static func signature(of path: String) -> Signature {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let result = check(path)
        cache[path] = result
        return result
    }

    private static func check(_ path: String) -> Signature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return Signature(signer: .unknown) }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
        switch SecStaticCodeCheckValidity(code, flags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return Signature(signer: .unsigned)
        default: return Signature(signer: .invalid)
        }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        var signature = Signature(
            signer: .otherCertificate,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            authority: certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? })

        if let match = requirements.first(where: { satisfies(code, $0.1, flags) }) {
            signature.signer = match.0
        } else if certificates.isEmpty {
            signature.signer = .adHoc
        }
        return signature
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String, _ flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
