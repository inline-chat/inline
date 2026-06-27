import Foundation
import GRDB
import InlineProtocol
import Logger

extension Client_MessageContentPayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case voice
    case actions
    case replies
    case serviceMessage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let voice = try container.decodeIfPresent(Client_MessageVoiceContent.self, forKey: .voice)
    let actions = try container.decodeIfPresent(MessageActions.self, forKey: .actions)
    let replies = try container.decodeIfPresent(MessageReplies.self, forKey: .replies)
    let serviceMessage = try container.decodeIfPresent(MessageService.self, forKey: .serviceMessage)

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
    if let serviceMessage {
      self.serviceMessage = serviceMessage
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
    if hasServiceMessage {
      try container.encode(serviceMessage, forKey: .serviceMessage)
    }
  }
}

extension MessageService: Codable {
  private enum CodingKeys: String, CodingKey {
    case event
    case threadBacklink
    case pinnedMessage
  }

  private enum Event: String, Codable {
    case threadBacklink
    case pinnedMessage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    guard let event = try? container.decode(Event.self, forKey: .event) else {
      return
    }

    switch event {
      case .threadBacklink:
        if let backlink = try container.decodeIfPresent(MessageServiceThreadBacklink.self, forKey: .threadBacklink) {
          threadBacklink = backlink
        } else {
          threadBacklink = MessageServiceThreadBacklink()
        }
      case .pinnedMessage:
        if let message = try container.decodeIfPresent(MessageServicePinnedMessage.self, forKey: .pinnedMessage) {
          pinnedMessage = message
        }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch event {
      case .threadBacklink:
        try container.encode(Event.threadBacklink, forKey: .event)
        try container.encode(threadBacklink, forKey: .threadBacklink)
      case .pinnedMessage:
        try container.encode(Event.pinnedMessage, forKey: .event)
        try container.encode(pinnedMessage, forKey: .pinnedMessage)
      case nil:
        break
    }
  }
}

extension MessageServiceThreadBacklink: Codable {
  private enum CodingKeys: String, CodingKey {
    case sourceChatID
    case sourceTitle
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let sourceChatID = try container.decodeIfPresent(Int64.self, forKey: .sourceChatID) {
      self.sourceChatID = sourceChatID
    }
    if let sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle) {
      self.sourceTitle = sourceTitle
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if hasSourceChatID {
      try container.encode(sourceChatID, forKey: .sourceChatID)
    }
    if hasSourceTitle {
      try container.encode(sourceTitle, forKey: .sourceTitle)
    }
  }
}

extension MessageServicePinnedMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case messageID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let messageID = try container.decodeIfPresent(Int64.self, forKey: .messageID) {
      self.messageID = messageID
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if hasMessageID {
      try container.encode(messageID, forKey: .messageID)
    }
  }
}

extension MessageReplies: Codable {
  private enum CodingKeys: String, CodingKey {
    case chatID
    case replyCount
    case hasUnread_p
    case recentReplierUserIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    chatID = try container.decodeIfPresent(Int64.self, forKey: .chatID) ?? 0
    replyCount = try container.decodeIfPresent(Int32.self, forKey: .replyCount) ?? 0
    hasUnread_p = try container.decodeIfPresent(Bool.self, forKey: .hasUnread_p) ?? false
    recentReplierUserIds = try container.decodeIfPresent([Int64].self, forKey: .recentReplierUserIds) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chatID, forKey: .chatID)
    try container.encode(replyCount, forKey: .replyCount)
    try container.encode(hasUnread_p, forKey: .hasUnread_p)
    try container.encode(recentReplierUserIds, forKey: .recentReplierUserIds)
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
