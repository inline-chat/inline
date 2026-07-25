import Intents
@testable import InlineIntents
import Testing

@Suite("Inline message intent donation")
struct InlineMessageIntentDonationTests {
  @Test("conversation identifiers are stable across callers")
  func conversationIdentifiers() {
    #expect(InlineMessageIntentDonation.userConversationIdentifier("42") == "inline:user:42")
    #expect(InlineMessageIntentDonation.threadConversationIdentifier("84") == "inline:thread:84")
    #expect(InlineMessageIntentDonation.chatConversationIdentifier("21") == "inline:chat:21")
  }

  @Test("outgoing DM preserves identity and recipient")
  func outgoingDirectMessage() {
    let recipient = InlineMessageIntentDonation.Person(
      identifier: "inline:user:42",
      handle: "person@example.com",
      handleType: .emailAddress,
      firstName: "Taylor",
      lastName: "Example",
      displayName: "Taylor Example"
    )
    let request = InlineMessageIntentDonation.Request(
      conversation: .init(
        identifier: "inline:user:42",
        displayName: "Taylor Example",
        recipientCount: 1
      ),
      direction: .outgoing,
      recipients: [recipient]
    )

    let interaction = InlineMessageIntentDonation.makeInteraction(for: request)
    let intent = interaction.intent as? INSendMessageIntent

    #expect(interaction.direction == .outgoing)
    #expect(interaction.groupIdentifier == "inline:user:42")
    #expect(intent?.conversationIdentifier == "inline:user:42")
    #expect(intent?.recipients?.first?.customIdentifier == "inline:user:42")
    #expect(intent?.recipients?.first?.personHandle?.type == .emailAddress)
    #expect(intent?.content == nil)
    #expect((intent?.donationMetadata as? INSendMessageIntentDonationMetadata)?.recipientCount == 1)
  }

  @Test("thread donation preserves its conversation avatar identity")
  func threadAvatar() {
    let request = InlineMessageIntentDonation.Request(
      conversation: .init(
        identifier: "inline:thread:84",
        displayName: "Design",
        avatar: .thread(.init(
          emoji: "🎨",
          title: "Design",
          isReplyThread: false,
          stableIdentifier: "inline:thread:84"
        )),
        recipientCount: 6
      ),
      direction: .outgoing
    )

    let intent = InlineMessageIntentDonation.makeIntent(for: request)

    #expect(intent.speakableGroupName?.spokenPhrase == "Design")
    #expect(request.conversation.avatar == .thread(.init(
      emoji: "🎨",
      title: "Design",
      isReplyThread: false,
      stableIdentifier: "inline:thread:84"
    )))
    #expect((intent.donationMetadata as? INSendMessageIntentDonationMetadata)?.recipientCount == 6)
  }

  @Test("person metadata does not claim a Contacts match")
  func personWithoutContactIdentifier() {
    let recipient = InlineMessageIntentDonation.Person(
      identifier: "inline:user:9",
      handle: "nine",
      displayName: "Nine"
    )
    let intent = InlineMessageIntentDonation.makeIntent(for: .init(
      conversation: .init(identifier: "inline:user:9", displayName: "Nine"),
      direction: .outgoing,
      recipients: [recipient]
    ))

    #expect(intent.recipients?.first?.contactIdentifier == nil)
    #expect(intent.recipients?.first?.customIdentifier == "inline:user:9")
    #expect(intent.recipients?.first?.suggestionType == INPersonSuggestionType.none)
  }

  @Test("group notification can preserve chat-as-sender presentation")
  func groupNotificationPresentation() {
    let conversationAvatar = InlineMessageIntentDonation.Avatar.thread(.init(
      emoji: "🎨",
      title: "Design",
      isReplyThread: false,
      stableIdentifier: "inline:thread:84"
    ))
    let request = InlineMessageIntentDonation.Request(
      conversation: .init(
        identifier: "inline:thread:84",
        displayName: "Design",
        avatar: conversationAvatar
      ),
      direction: .incoming,
      sender: .init(
        identifier: "inline:thread:84",
        handle: "inline:thread:84",
        displayName: "Design",
        avatar: conversationAvatar
      ),
      recipients: [.init(
        identifier: "inline:current-user",
        handle: "0",
        isCurrentUser: true
      )],
      content: "Hello"
    )

    let intent = InlineMessageIntentDonation.makeIntent(for: request)

    #expect(intent.sender?.displayName == "Design")
    #expect(intent.sender?.isMe == false)
    #expect(intent.sender?.contactIdentifier == nil)
    #expect(intent.recipients?.first?.isMe == true)
    #expect(intent.recipients?.first?.customIdentifier == nil)
    #expect(intent.speakableGroupName?.spokenPhrase == "Design")
  }

  @Test("avatar generation follows Apple's preferred matching size")
  func preferredAvatarSize() {
    #expect(InlineMessageIntentDonation.preferredAvatarPixelSize == 360)
  }
}
