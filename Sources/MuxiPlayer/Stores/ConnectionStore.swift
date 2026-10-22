import Foundation
import Observation
import Security
import MuxiCore

enum CredentialStore {
    private static let query: [String: Any] = {
        // Legacy login-keychain items ignore kSecUseAuthenticationUI; fail instead of blocking startup.
        SecKeychainSetUserInteractionAllowed(false)
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.hectorgao.muxi-player", kSecAttrAccount as String: "emby-connection"]
    }()

    static func load() throws -> Connection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError() }
        return try JSONDecoder().decode(Connection.self, from: data)
    }

    static func save(_ connection: Connection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError() }
        } else if status != errSecSuccess { throw KeychainError() }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError() }
    }

    struct KeychainError: LocalizedError {
        var errorDescription: String? { "无法访问 macOS 钥匙串。请解锁钥匙串并允许幕汐播放器访问。" }
    }
}

@MainActor @Observable final class ConnectionStore {
    var connection: Connection?
    var client: EmbyClient?
    var error: String?
    var connecting = false
    let deviceID: String

    init() {
        let stored = UserDefaults.standard.string(forKey: "deviceID") ?? UUID().uuidString
        deviceID = stored
        UserDefaults.standard.set(stored, forKey: "deviceID")
        do {
            if let saved = try CredentialStore.load() { install(saved) }
        } catch { self.error = "已保存的连接暂时无法读取。请检查钥匙串，或重新登录。" }
    }

    private func install(_ connection: Connection) {
        self.connection = connection
        client = EmbyClient(baseURL: connection.baseURL, deviceID: deviceID, connection: connection)
    }

    func connect(address: String, username: String, password: String, clientIdentity: EmbyClientIdentity = .senPlayer, serverKind: MediaServerKind = .emby) async {
        connecting = true
        error = nil
        defer { connecting = false }
        do {
            let url = try ServerAddress.normalize(address)
            let client = EmbyClient(baseURL: url, deviceID: deviceID, clientIdentity: clientIdentity, serverKind: serverKind)
            let connection = try await client.authenticate(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            do { try CredentialStore.save(connection) }
            catch { self.error = "已连接，但钥匙串暂不可用。本次登录仅在内存中保留，退出后需重新登录。" }
            install(connection)
        } catch let error as CredentialStore.KeychainError { self.error = error.localizedDescription }
        catch { self.error = EmbyError.message(error) }
    }

    func disconnect() async {
        error = nil
        do { try CredentialStore.remove() }
        catch { self.error = "本次连接已断开，但无法移除旧钥匙串记录。请在钥匙串访问中移除幕汐的登录记录。" }
        let previous = client
        connection = nil
        client = nil
        do { try await previous?.logout() }
        catch { self.error = "本机连接已移除，但服务器未确认注销。可在服务器的设备管理中撤销此次登录。" }
    }
}
