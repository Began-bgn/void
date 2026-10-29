import AppKit
import Carbon.HIToolbox
import OpenDirectory

/// The login password, in the login keychain (`FaceUnlockKeychain`): readable on the lock screen,
/// never synced, readable only by NotchDeck per the item's ACL. The password is only ever held as bytes that are zeroed after use; it is never
/// logged, shown, put on the pasteboard or written anywhere else.
actor CredentialVault {
    static let shared = CredentialVault()
    init() {}
    private(set) var service = "com.notchdeck.faceunlock.password"
    /// Tests use their own item.
    func setService(_ name: String) { service = name }

    enum VaultError: Error, Equatable {
        case wrongPassword, notStored
    }

    /// Checks `password` against this user's local account, then stores it. Zeroes `password`.
    func store(_ password: inout [UInt8]) throws {
        defer { password.resetBytes() }
        guard Self.verify(password) else { throw VaultError.wrongPassword }
        var data = Data(password)
        defer { data.resetBytes(in: 0..<data.count) }
        try FaceUnlockKeychain.set(data, service: service)
    }

    var isStored: Bool { ((try? FaceUnlockKeychain.get(service: service)) ?? nil) != nil }

    @discardableResult
    func wipe() -> Bool { FaceUnlockKeychain.delete(service: service) }

    /// The stored password, verified first. Refuses when it no longer verifies (e.g. after a
    /// password change): typing a stale password would only count toward the macOS lockout.
    /// The caller must `resetBytes()` the result as soon as it has used it.
    func verifiedPassword() throws -> [UInt8] {
        guard var bytes = try FaceUnlockKeychain.get(service: service).map(Array.init) else { throw VaultError.notStored }
        guard Self.verify(bytes) else { bytes.resetBytes(); throw VaultError.wrongPassword }
        return bytes
    }

    /// OpenDirectory check against the local node. The String it needs is unavoidable here; it
    /// lives only for this call.
    // ponytail: Swift Strings can't be zeroed; the bytes are, the transient String is not.
    static func verify(_ password: [UInt8]) -> Bool {
        guard let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(String(decoding: password, as: UTF8.self))) != nil
    }
}

extension Array where Element == UInt8 {
    /// Overwrites the bytes with zeros (not optimised away) and empties the array.
    mutating func resetBytes() {
        withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
        removeAll()
    }
}

/// Puts the password into the lock screen's password field.
protocol LockScreenInput {
    /// Types `password` and presses Return, once. Returns when the screen unlocked (true) or
    /// after a timeout (false). Never retries.
    @MainActor func enterPassword(_ password: [UInt8]) async -> Bool
}

/// Synthesised key events (needs Accessibility). Spike result: the lock screen accepts posted
/// keystrokes even with secure input on. Unicode-string events, so the keyboard layout doesn't
/// matter. Stops typing the moment the screen is no longer locked, so nothing ever reaches a
/// normal app.
struct CGEventLockScreenInput: LockScreenInput {
    var unlockTimeout: Duration = .seconds(4)

    static var isAllowed: Bool { CGPreflightPostEventAccess() }

    @MainActor func enterPassword(_ password: [UInt8]) async -> Bool {
        guard Self.isAllowed, LockStateMonitor.screenIsLocked else { return false }
        var units: [UInt16] = []
        defer { units.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var bytes = password.makeIterator()
        var decoder = UTF8()
        decode: while true {
            switch decoder.decode(&bytes) {
            case .scalarValue(let s): UTF16.encode(s) { units.append($0) }
            case .emptyInput: break decode
            case .error: return false
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for i in units.indices {
            guard LockStateMonitor.screenIsLocked else { return false }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: $0.baseAddress! + i) }
                event?.post(tap: .cghidEventTap)
            }
        }
        guard LockStateMonitor.screenIsLocked else { return false }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down)?.post(tap: .cghidEventTap)
        }
        let deadline = ContinuousClock.now + unlockTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if !LockStateMonitor.screenIsLocked { return true }
        }
        return false
    }
}
