import Foundation
import GRDB
import InlineProtocol
import Logger

extension Client_MessageContentPayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case voice
    case actions
    case replies
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let voice = try container.decodeIfPresent(Client_MessageVoiceContent.self, forKey: .voice)
    let actions = try container.decodeIfPresent(InlineProtocol.MessageActions.self, forKey: .actions)
    let replies = try container.decodeIfPresent(InlineProtocol.MessageReplies.self, forKey: .replies)

    self.init()
    if let voice {
      self.voice = voice
    }
    if let actions {
      self.actions = actions
    }
    if let replies {
      self.replies = replies
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if hasVoice {
      try container.encode(voice, forKey: .voice)
    }
    if hasActions {
      try container.encode(actions, forKey: .actions)
    }
    if hasReplies {
      try container.encode(replies, forKey: .replies)
    }
  }
}

extension Client_MessageVoiceContent: Codable {
  private enum CodingKeys: String, CodingKey {
    case voiceID
    case duration
    case waveform
    case mimeType
    case cdnURL
    case localRelativePath
    case size
    case transcription
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    voiceID = try container.decode(Int64.self, forKey: .voiceID)
    duration = try container.decode(Int32.self, forKey: .duration)
    waveform = try container.decode(Data.self, forKey: .waveform)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    cdnURL = try container.decode(String.self, forKey: .cdnURL)
    localRelativePath = try container.decode(String.self, forKey: .localRelativePath)
    size = try container.decode(Int64.self, forKey: .size)
    transcription = try container.decode(String.self, forKey: .transcription)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(voiceID, forKey: .voiceID)
    try container.encode(duration, forKey: .duration)
    try container.encode(waveform, forKey: .waveform)
    try container.encode(mimeType, forKey: .mimeType)
    try container.encode(cdnURL, forKey: .cdnURL)
    try container.encode(localRelativePath, forKey: .localRelativePath)
    try container.encode(size, forKey: .size)
    try container.encode(transcription, forKey: .transcription)
  }
}

extension InlineProtocol.MessageReplies: Codable {
  private enum CodingKeys: String, CodingKey {
    case chatID
    case replyCount
    case hasUnread
    case recentReplierUserIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    chatID = try container.decode(Int64.self, forKey: .chatID)
    replyCount = try container.decode(Int32.self, forKey: .replyCount)
    hasUnread_p = try container.decode(Bool.self, forKey: .hasUnread)
    recentReplierUserIds = try container.decodeIfPresent([Int64].self, forKey: .recentReplierUserIds) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chatID, forKey: .chatID)
    try container.encode(replyCount, forKey: .replyCount)
    try container.encode(hasUnread_p, forKey: .hasUnread)
    try container.encode(recentReplierUserIds, forKey: .recentReplierUserIds)
  }
}

extension Client_MessageContentPayload: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize MessageContentPayload to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Client_MessageContentPayload? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try Client_MessageContentPayload(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize MessageContentPayload from database", error: error)
      return nil
    }
  }
}
