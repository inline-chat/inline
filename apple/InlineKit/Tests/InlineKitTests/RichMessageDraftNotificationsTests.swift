import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Rich message draft notifications", .serialized)
struct RichMessageDraftNotificationsTests {
  @Test("change notifications from background posts are delivered on main thread")
  func changeNotificationsFromBackgroundPostsAreDeliveredOnMainThread() async {
    RichMessageDraftStore.shared.removeAllForTesting()

    let probe = DraftNotificationProbe()
    let observer = NotificationCenter.default.addObserver(
      forName: RichMessageDraftNotifications.didChange,
      object: nil,
      queue: nil
    ) { notification in
      guard let change = RichMessageDraftNotifications.change(from: notification) else { return }
      probe.record(
        DraftNotificationObservation(
          isMainThread: Thread.isMainThread,
          change: change
        )
      )
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
      RichMessageDraftStore.shared.removeAllForTesting()
    }

	    let postTask = Task.detached {
	      RichMessageDraftNotifications.post(
	        Self.update(
	          draftId: "chatgpt:test-notification-main-thread",
	          messageId: 18,
	          text: "streaming draft",
	          expiresAt: Int64(Date().timeIntervalSince1970) + 60
	        )
	      )
	    }
    await postTask.value

    let observation = await waitForObservation(probe)

    #expect(observation?.isMainThread == true)
    #expect(observation?.change.key == RichMessageDraftMessageKey(peer: .thread(id: 42), messageId: 18))
    #expect(observation?.change.snapshot?.draftId == "chatgpt:test-notification-main-thread")
    #expect(observation?.change.snapshot?.richText.fallbackText == "streaming draft")
  }

  @Test("expiry notifications from background posts are delivered on main thread")
  func expiryNotificationsFromBackgroundPostsAreDeliveredOnMainThread() async {
    RichMessageDraftStore.shared.removeAllForTesting()
    _ = RichMessageDraftStore.shared.apply(
	      Self.update(
	        draftId: "chatgpt:test-notification-expiry",
	        messageId: 19,
	        text: "expiring draft",
	        expiresAt: 1_782_129_630
	      ),
	      now: Date(timeIntervalSince1970: 1_782_129_600)
	    )

    let probe = DraftNotificationProbe()
    let observer = NotificationCenter.default.addObserver(
      forName: RichMessageDraftNotifications.didChange,
      object: nil,
      queue: nil
    ) { notification in
      guard let change = RichMessageDraftNotifications.change(from: notification) else { return }
      probe.record(
        DraftNotificationObservation(
          isMainThread: Thread.isMainThread,
          change: change
        )
      )
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
      RichMessageDraftStore.shared.removeAllForTesting()
    }

    let postTask = Task.detached {
      RichMessageDraftNotifications.expireNow(now: Date(timeIntervalSince1970: 1_782_129_631))
    }
    await postTask.value

    let observation = await waitForObservation(probe)

    #expect(observation?.isMainThread == true)
    #expect(observation?.change.key == RichMessageDraftMessageKey(peer: .thread(id: 42), messageId: 19))
    #expect(observation?.change.snapshot == nil)
  }

	  private static func update(
	    draftId: String,
	    messageId: Int64,
	    text: String,
	    expiresAt: Int64
	  ) -> UpdateRichMessageDraft {
	    UpdateRichMessageDraft.with {
	      $0.draftID = draftId
	      $0.peerID = protocolPeer
	      $0.senderUserID = 2
	      $0.messageID = messageId
	      $0.richText = richText(text)
	      $0.expiresAt = expiresAt
	    }
	  }

  private static var protocolPeer: InlineProtocol.Peer {
    InlineProtocol.Peer.with {
      $0.type = .chat(.with { chat in
        chat.chatID = 42
      })
    }
  }

  private static func richText(_ text: String) -> RichMessage {
    RichMessage.with {
      $0.version = 1
      $0.direction = .directionAuto
      $0.fallbackText = text
    }
  }
}

private struct DraftNotificationObservation: Sendable {
  let isMainThread: Bool
  let change: RichMessageDraftChange
}

private final class DraftNotificationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var current: DraftNotificationObservation?

  func record(_ observation: DraftNotificationObservation) {
    lock.lock()
    defer { lock.unlock() }

    if current == nil {
      current = observation
    }
  }

  func observation() -> DraftNotificationObservation? {
    lock.lock()
    defer { lock.unlock() }

    return current
  }
}

private func waitForObservation(
  _ probe: DraftNotificationProbe,
  timeout: Duration = .seconds(1)
) async -> DraftNotificationObservation? {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if let observation = probe.observation() {
      return observation
    }
    try? await Task.sleep(for: .milliseconds(10))
  }

  return probe.observation()
}
