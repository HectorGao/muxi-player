import Foundation

public struct SavedMediaSource: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public let connection: Connection

    public init(id: UUID = UUID(), name: String = "", connection: Connection) {
        self.id = id
        self.connection = connection
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? (connection.baseURL.host ?? (connection.serverKind ?? .emby).label) : trimmed
    }

    public func matches(_ other: Connection) -> Bool {
        connection.baseURL == other.baseURL && connection.user.Id == other.user.Id &&
        (connection.serverKind ?? .emby) == (other.serverKind ?? .emby)
    }
}
