import CoreGraphics
import Foundation
import InlineAvatarRendering
import Intents

public enum InlineMessageIntentDonation {
  public static let preferredAvatarPixelSize: CGFloat = 360

  public static func userConversationIdentifier(_ userID: String) -> String {
    "inline:user:\(userID)"
  }

  public static func threadConversationIdentifier(_ threadID: String) -> String {
    "inline:thread:\(threadID)"
  }

  public static func chatConversationIdentifier(_ chatID: String) -> String {
    "inline:chat:\(chatID)"
  }

  public enum Direction: Sendable, Equatable {
    case incoming
    case outgoing
  }

  public enum PersonHandleType: Sendable, Equatable {
    case emailAddress
    case unknown
  }

  public struct UserAvatar: Sendable, Equatable {
    public let imageData: Data?
    public let firstName: String?
    public let lastName: String?
    public let displayName: String?
    public let email: String?
    public let username: String?
    public let stableIdentifier: String

    public init(
      imageData: Data? = nil,
      firstName: String?,
      lastName: String?,
      displayName: String?,
      email: String?,
      username: String?,
      stableIdentifier: String
    ) {
      self.imageData = imageData
      self.firstName = firstName
      self.lastName = lastName
      self.displayName = displayName
      self.email = email
      self.username = username
      self.stableIdentifier = stableIdentifier
    }
  }

  public struct ThreadAvatar: Sendable, Equatable {
    public let emoji: String?
    public let title: String
    public let isReplyThread: Bool
    public let stableIdentifier: String

    public init(
      emoji: String?,
      title: String,
      isReplyThread: Bool,
      stableIdentifier: String
    ) {
      self.emoji = emoji
      self.title = title
      self.isReplyThread = isReplyThread
      self.stableIdentifier = stableIdentifier
    }
  }

  public enum Avatar: Sendable, Equatable {
    case thread(ThreadAvatar)
    case user(UserAvatar)
  }

  public struct Person: Sendable, Equatable {
    public let identifier: String
    public let handle: String
    public let handleType: PersonHandleType
    public let isCurrentUser: Bool
    public let firstName: String?
    public let lastName: String?
    public let displayName: String?
    public let avatar: Avatar?

    public init(
      identifier: String,
      handle: String,
      handleType: PersonHandleType = .unknown,
      isCurrentUser: Bool = false,
      firstName: String? = nil,
      lastName: String? = nil,
      displayName: String? = nil,
      avatar: Avatar? = nil
    ) {
      self.identifier = identifier
      self.handle = handle
      self.handleType = handleType
      self.isCurrentUser = isCurrentUser
      self.firstName = firstName
      self.lastName = lastName
      self.displayName = displayName
      self.avatar = avatar
    }
  }

  public struct Conversation: Sendable, Equatable {
    public let identifier: String
    public let displayName: String?
    public let avatar: Avatar?
    public let recipientCount: Int?

    public init(
      identifier: String,
      displayName: String?,
      avatar: Avatar? = nil,
      recipientCount: Int? = nil
    ) {
      self.identifier = identifier
      self.displayName = displayName
      self.avatar = avatar
      self.recipientCount = recipientCount
    }
  }

  public struct Request: Sendable, Equatable {
    public let conversation: Conversation
    public let direction: Direction
    public let sender: Person?
    public let recipients: [Person]
    public let content: String?

    public init(
      conversation: Conversation,
      direction: Direction,
      sender: Person? = nil,
      recipients: [Person] = [],
      content: String? = nil
    ) {
      self.conversation = conversation
      self.direction = direction
      self.sender = sender
      self.recipients = recipients
      self.content = content
    }
  }

  @discardableResult
  public static func donate(_ request: Request) async throws -> INSendMessageIntent {
    let intent = makeIntent(for: request)
    let interaction = makeInteraction(intent: intent, request: request)
    try await interaction.donate()
    return intent
  }

  public static func deleteAll() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      INInteraction.deleteAll { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

extension InlineMessageIntentDonation {
  static func makeInteraction(for request: Request) -> INInteraction {
    makeInteraction(intent: makeIntent(for: request), request: request)
  }

  private static func makeInteraction(
    intent: INSendMessageIntent,
    request: Request
  ) -> INInteraction {
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = switch request.direction {
    case .incoming: .incoming
    case .outgoing: .outgoing
    }
    interaction.groupIdentifier = request.conversation.identifier
    return interaction
  }

  static func makeIntent(for request: Request) -> INSendMessageIntent {
    let intent = INSendMessageIntent(
      recipients: request.recipients.isEmpty ? nil : request.recipients.map(makePerson),
      outgoingMessageType: .outgoingMessageText,
      content: request.content,
      speakableGroupName: normalized(request.conversation.displayName)
        .map(INSpeakableString.init(spokenPhrase:)),
      conversationIdentifier: request.conversation.identifier,
      serviceName: "Inline",
      sender: request.sender.map(makePerson),
      attachments: nil
    )

    #if os(iOS)
    if let conversationImage = makeImage(request.conversation.avatar) {
      intent.setImage(conversationImage, forParameterNamed: \.speakableGroupName)
    }
    if let senderImage = makeImage(request.sender?.avatar) {
      intent.setImage(senderImage, forParameterNamed: \.sender)
    }
    #endif

    let recipientCount = request.conversation.recipientCount ?? request.recipients.count
    if recipientCount > 0 {
      let metadata = INSendMessageIntentDonationMetadata()
      metadata.recipientCount = recipientCount
      intent.donationMetadata = metadata
    }

    return intent
  }

  private static func makePerson(_ person: Person) -> INPerson {
    let handleType: INPersonHandleType = switch person.handleType {
    case .emailAddress: .emailAddress
    case .unknown: .unknown
    }
    let handle = INPersonHandle(
      value: person.handle,
      type: handleType
    )
    var nameComponents = PersonNameComponents()
    nameComponents.givenName = normalized(person.firstName)
    nameComponents.familyName = normalized(person.lastName)
    let resolvedNameComponents = nameComponents.givenName == nil && nameComponents.familyName == nil
      ? nil
      : nameComponents

    return INPerson(
      personHandle: handle,
      nameComponents: resolvedNameComponents,
      displayName: normalized(person.displayName),
      image: makeImage(person.avatar),
      contactIdentifier: nil,
      customIdentifier: person.isCurrentUser ? nil : person.identifier,
      isMe: person.isCurrentUser,
      suggestionType: .none
    )
  }

  private static func makeImage(_ avatar: Avatar?) -> INImage? {
    guard let data = avatarData(avatar), !data.isEmpty else { return nil }
    return INImage(imageData: data)
  }

  static func avatarData(_ avatar: Avatar?) -> Data? {
    guard let avatar else { return nil }
    switch avatar {
    case let .thread(thread):
      return InlineAvatarBitmapRenderer.threadImageData(
        identity: InlineThreadAvatarRenderIdentity(
          emoji: thread.emoji,
          title: thread.title,
          isReplyThread: thread.isReplyThread,
          stableIdentifier: thread.stableIdentifier
        ),
        size: CGSize(width: preferredAvatarPixelSize, height: preferredAvatarPixelSize),
        scale: 1
      )
    case let .user(user):
      if let imageData = user.imageData, !imageData.isEmpty {
        return imageData
      }
      return InlineAvatarBitmapRenderer.userInitialsImageData(
        identity: InlineUserAvatarRenderIdentity(
          firstName: user.firstName,
          lastName: user.lastName,
          displayName: user.displayName,
          email: user.email,
          username: user.username,
          stableIdentifier: user.stableIdentifier
        ),
        size: CGSize(width: preferredAvatarPixelSize, height: preferredAvatarPixelSize),
        scale: 1
      )
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
