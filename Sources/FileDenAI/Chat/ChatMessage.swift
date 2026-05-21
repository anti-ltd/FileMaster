import Foundation

/// One message in a document chat. User turns carry just text; assistant turns
/// carry the streamed answer plus the sources it drew from.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var text: String
    public var citations: [Citation]
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: Role, text: String = "",
                citations: [Citation] = [], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.isStreaming = isStreaming
    }
}
