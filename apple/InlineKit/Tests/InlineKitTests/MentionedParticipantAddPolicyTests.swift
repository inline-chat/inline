import Testing
@testable import InlineKit

@Suite("Mentioned Participant Add Policy Tests")
struct MentionedParticipantAddPolicyTests {
  @Test("auto-adds in small private threads")
  func autoAddsInSmallPrivateThreads() {
    let action = MentionedParticipantAddPolicy.action(
      for: [2],
      context: context(messageCount: 3)
    )

    #expect(action == .autoAdd([2]))
  }

  @Test("prompts when private thread is past auto-add limit")
  func promptsPastLimit() {
    let action = MentionedParticipantAddPolicy.action(
      for: [2, 3],
      context: context(messageCount: MentionedParticipantAddPolicy.defaultAutoAddMessageLimit)
    )

    #expect(action == .prompt([2, 3]))
  }

  @Test("reply threads always auto-add")
  func replyThreadsAlwaysAutoAdd() {
    let action = MentionedParticipantAddPolicy.action(
      for: [2],
      context: context(isReplyThread: true, messageCount: 100)
    )

    #expect(action == .autoAdd([2]))
  }

  @Test("skips public and non-thread chats")
  func skipsUnsupportedChats() {
    #expect(MentionedParticipantAddPolicy.action(
      for: [2],
      context: context(chatType: .privateChat)
    ) == .none)

    #expect(MentionedParticipantAddPolicy.action(
      for: [2],
      context: context(isPublic: true)
    ) == .none)
  }

  @Test("filters current participants, current user, zero ids, and pending ids")
  func filtersIneligibleUsers() {
    let action = MentionedParticipantAddPolicy.action(
      for: [0, 1, 2, 3, 4],
      context: context(
        participantIds: [2],
        pendingUserIds: [3],
        messageCount: 3
      )
    )

    #expect(action == .autoAdd([4]))
  }

  private func context(
    chatType: ChatType = .thread,
    isPublic: Bool = false,
    isReplyThread: Bool = false,
    currentUserId: Int64? = 1,
    participantIds: Set<Int64> = [],
    pendingUserIds: Set<Int64> = [],
    messageCount: Int = 0
  ) -> MentionedParticipantAddContext {
    MentionedParticipantAddContext(
      chatType: chatType,
      isPublic: isPublic,
      isReplyThread: isReplyThread,
      currentUserId: currentUserId,
      messageCount: messageCount,
      participantIds: participantIds,
      pendingUserIds: pendingUserIds
    )
  }
}
