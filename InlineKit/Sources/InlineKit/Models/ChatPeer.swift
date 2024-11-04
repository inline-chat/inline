import Foundation
import GRDB

public enum Peer: Codable, Hashable, Sendable {
    case user(id: Int64)
    case thread(id: Int64)
    
    private enum CodingKeys: String, CodingKey {
        case userId
        case threadId
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let userId = try container.decodeIfPresent(Int64.self, forKey: .userId) {
            self = .user(id: userId)
        } else if let threadId = try container.decodeIfPresent(Int64.self, forKey: .threadId) {
            self = .thread(id: threadId)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid peer type - must contain either userId or threadId"
                )
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .user(let id):
            try container.encode(id, forKey: .userId)
        case .thread(let id):
            try container.encode(id, forKey: .threadId)
        }
    }
    
    public var isPrivate: Bool {
        switch self {
        case .user:
            return true
        case .thread:
            return false
        }
    }
}
