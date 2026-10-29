import Foundation
import Security

/// Turns a face crop into an identity embedding. Step 4 adds the Core ML implementation.
protocol FaceRecognizer: Sendable {
    func embedding(of frame: FaceCaptureService.Frame, face: FaceSample) throws -> [Float]
}

/// Login-keychain items for Face Unlock, never synced. The item's ACL trusts only the app that
/// created it; the login keychain stays unlocked while the screen is locked.
// ponytail: login keychain, not the data-protection keychain: that needs a keychain-access-groups
// entitlement, which needs a provisioning profile, and a free account's profile expires in 7 days.
// Move back (kSecUseDataProtectionKeychain + access group) once signed with a paid team.
enum FaceUnlockKeychain {
    private static func query(_ service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "default"]
    }

    static func set(_ data: Data, service: String) throws {
        delete(service: service)
        var add = query(service)
        add[kSecValueData] = data
        add[kSecAttrSynchronizable] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func get(service: String) throws -> Data? {
        var q = query(service)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return out as? Data
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        let status = SecItemDelete(query(service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Enrolled face embeddings, stored only in the keychain. No photos.
struct TemplateStore {
    var service = "com.notchdeck.faceunlock.templates"

    func load() throws -> [[Float]] {
        guard let data = try FaceUnlockKeychain.get(service: service) else { return [] }
        return try JSONDecoder().decode([[Float]].self, from: data)
    }

    func save(_ templates: [[Float]]) throws {
        try FaceUnlockKeychain.set(JSONEncoder().encode(templates), service: service)
    }

    @discardableResult
    func wipe() -> Bool { FaceUnlockKeychain.delete(service: service) }
}
