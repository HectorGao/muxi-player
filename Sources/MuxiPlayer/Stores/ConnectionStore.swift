import Foundation
import Observation
import Security
import MuxiCore

// Keep Keychain calls off the main actor; macOS may need to ask for access after an app update.
actor CredentialStore {
    private let service: String
    init(service: String = "com.hectorgao.muxi-player") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    func load() throws -> [SavedMediaSource] {
        if let data = try read("media-sources-v1") {
            let sources = try JSONDecoder().decode([SavedMediaSource].self, from: data)
            guard Set(sources.map(\.id)).count == sources.count else { throw CocoaError(.coderReadCorrupt) }
            return sources
        }
        if let legacy = try read("emby-connection") {
            let connection = try JSONDecoder().decode(Connection.self, from: legacy)
            let sources = [SavedMediaSource(connection: connection)]
            try save(sources)
            return sources // Preserve the old entry until migration has succeeded; never fall back after a new vault exists.
        }
        return []
    }

    func save(_ sources: [SavedMediaSource]) throws {
        let data = try JSONEncoder().encode(sources)
        let request = query("media-sources-v1")
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "muxi 媒体源"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问媒体源钥匙串。请解锁钥匙串并允许 muxi 访问，然后重试（\(status)）。" }
    }
}

@MainActor @Observable final class ConnectionStore {
    private(set) var sources: [SavedMediaSource] = []
    private(set) var selectedSourceID: UUID?
    private(set) var clients: [UUID: EmbyClient] = [:]
    private(set) var revision = 0
    var error: String?
    private(set) var connecting = false
    private(set) var restoring = true
    private(set) var storageReady = false
    let deviceID: String
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var restoreStarted = false

    var connection: Connection? { sources.first { $0.id == selectedSourceID }?.connection }
    var client: EmbyClient? { selectedSourceID.flatMap { clients[$0] } }
    var selectedSource: SavedMediaSource? { sources.first { $0.id == selectedSourceID } }

    init(credentials: CredentialStore = CredentialStore(), defaults: UserDefaults = .standard) {
        self.credentials = credentials; self.defaults = defaults
        let stored = defaults.string(forKey: "deviceID") ?? UUID().uuidString
        deviceID = stored
        defaults.set(stored, forKey: "deviceID")
        selectedSourceID = defaults.string(forKey: "selectedMediaSource").flatMap(UUID.init(uuidString:))
    }

    func restore() async {
        guard !restoreStarted else { return }
        restoreStarted = true; restoring = true; error = nil
        defer { restoring = false }
        do {
            let saved = try await credentials.load()
            install(saved)
            storageReady = true
        } catch {
            self.error = (error as? CredentialStore.KeychainError)?.localizedDescription ?? "无法读取已保存的媒体源，原记录已保留。请重试。"
            restoreStarted = false
        }
    }

    private func install(_ saved: [SavedMediaSource]) {
        sources = saved
        clients = Dictionary(uniqueKeysWithValues: saved.map { source in
            (source.id, EmbyClient(baseURL: source.connection.baseURL, deviceID: deviceID, connection: source.connection))
        })
        if !sources.contains(where: { $0.id == selectedSourceID }) { selectSource(nil) }
        revision += 1
    }

    func selectSource(_ id: UUID?) {
        selectedSourceID = sources.contains { $0.id == id } ? id : nil
        defaults.set(selectedSourceID?.uuidString, forKey: "selectedMediaSource")
    }

    @discardableResult
    func connect(address: String, username: String, password: String, name: String = "", replacing sourceID: UUID? = nil,
                 clientIdentity: EmbyClientIdentity = .senPlayer, serverKind: MediaServerKind = .emby) async -> Bool {
        guard storageReady, !connecting else { return false }
        connecting = true; error = nil
        defer { connecting = false }
        do {
            let url = try ServerAddress.normalize(address)
            let client = EmbyClient(baseURL: url, deviceID: deviceID, clientIdentity: clientIdentity, serverKind: serverKind)
            let connected = try await client.authenticate(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            var updated = sources
            let existing = updated.firstIndex { $0.id == sourceID } ?? updated.firstIndex { $0.matches(connected) }
            if let existing {
                updated[existing] = SavedMediaSource(id: updated[existing].id, name: name, connection: connected)
            } else { updated.append(SavedMediaSource(name: name, connection: connected)) }
            try await credentials.save(updated)
            install(updated)
            return true
        } catch {
            self.error = (error as? CredentialStore.KeychainError)?.localizedDescription ?? EmbyError.message(error)
            return false
        }
    }

    func remove(_ source: SavedMediaSource) async {
        guard storageReady, !connecting else { return }
        connecting = true; error = nil
        defer { connecting = false }
        do {
            let remaining = sources.filter { $0.id != source.id }
            try await credentials.save(remaining)
            let previous = clients[source.id]
            install(remaining)
            do { try await previous?.logout() }
            catch { self.error = "已移除本机媒体源；服务器暂未确认注销，可在服务器设备管理中撤销此登录。" }
        } catch { self.error = "未能保存修改，媒体源已保留。" }
    }
}
