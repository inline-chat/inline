import Testing
@preconcurrency import UserNotifications

@testable import InlineKit

@Suite("Notification cleanup matching")
struct NotificationCleanupTests {
  private func makeContent(
    threadIdentifier: String,
    payloadThreadId: Any? = nil,
    messageId: Any? = nil
  ) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.threadIdentifier = threadIdentifier

    var userInfo: [String: Any] = [:]
    if let payloadThreadId {
      userInfo["threadId"] = payloadThreadId
    }
    if let messageId {
      userInfo["messageId"] = messageId
    }
    content.userInfo = userInfo

    return content
  }

  @Test("matches when thread identifier matches and there is no message limit")
  func matchesByThreadIdentifierWithoutLimit() {
    let content = makeContent(threadIdentifier: "thread-1")

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: nil
      )
    )
  }

  @Test("matches payload threadId when threadIdentifier differs")
  func matchesByPayloadThreadId() {
    let content = makeContent(
      threadIdentifier: "other-thread",
      payloadThreadId: "thread-1"
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: nil
      )
    )
  }

  @Test("does not match when both thread identifiers differ")
  func rejectsDifferentThread() {
    let content = makeContent(
      threadIdentifier: "other-thread",
      payloadThreadId: "also-other"
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: nil
      ) == false
    )
  }

  @Test("supports string message IDs when bounded")
  func supportsStringMessageIds() {
    let content = makeContent(
      threadIdentifier: "thread-1",
      messageId: "15"
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: 20
      )
    )
  }

  @Test("supports integer and NSNumber message IDs when bounded")
  func supportsIntegerMessageIds() {
    let intContent = makeContent(
      threadIdentifier: "thread-1",
      messageId: 25
    )
    let numberContent = makeContent(
      threadIdentifier: "thread-1",
      messageId: NSNumber(value: 10)
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: intContent,
        threadId: "thread-1",
        upToMessageId: 20
      ) == false
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: numberContent,
        threadId: "thread-1",
        upToMessageId: 20
      )
    )
  }

  @Test("requires message ID when bounded")
  func rejectsMissingMessageIdForBoundedRemoval() {
    let content = makeContent(threadIdentifier: "thread-1")

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: 20
      ) == false
    )
  }

  @Test("rejects invalid string message IDs when bounded")
  func rejectsInvalidStringMessageId() {
    let content = makeContent(
      threadIdentifier: "thread-1",
      messageId: "not-a-number"
    )

    #expect(
      NotificationCleanup.shouldRemove(
        content: content,
        threadId: "thread-1",
        upToMessageId: 20
      ) == false
    )
  }
}
