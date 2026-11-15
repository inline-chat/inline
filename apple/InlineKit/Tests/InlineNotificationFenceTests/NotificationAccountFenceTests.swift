import Foundation
@testable import InlineNotificationFence
import Testing
@preconcurrency import UserNotifications

final class MemoryFenceStorage: NotificationAccountFenceStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: NotificationAccountFence?
  private var unavailable = false
  private var failsWrites = false
  private(set) var writeCount = 0

  init(_ stored: NotificationAccountFence? = nil) {
    self.stored = stored
  }

  var value: NotificationAccountFence? { lock.withLock { stored } }

  func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }
  func setFailsWrites(_ value: Bool) { lock.withLock { failsWrites = value } }

  func read() -> NotificationAccountFenceRead {
    lock.withLock {
      if unavailable { return .unavailable }
      return stored.map(NotificationAccountFenceRead.present) ?? .missing
    }
  }

  func write(_ fence: NotificationAccountFence) -> Bool {
    lock.withLock {
      writeCount += 1
      guard !failsWrites else { return false }
      stored = fence
      return true
    }
  }

  func delete() -> Bool {
    lock.withLock {
      stored = nil
      return true
    }
  }
}

@Suite("Notification account fence")
struct NotificationAccountFenceTests {
  private func payload(recipient: Any?) -> [AnyHashable: Any] {
    var userInfo: [AnyHashable: Any] = [
      "kind": "send_message_encrypted",
      "threadId": "77",
      "messageId": "9",
      "encryptedContent": ["version": 1],
    ]
    if let recipient { userInfo["recipientUserId"] = recipient }
    return userInfo
  }

  @Test("admits only the signed-in recipient")
  func admitsOnlySignedInRecipient() {
    let fence = NotificationAccountFence(userID: 42, generation: 3)
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: .present(fence))
      == .admitted(fence))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: NSNumber(value: 42)), fence: .present(fence))
      == .admitted(fence))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "43"), fence: .present(fence))
      == .rejected(.otherAccount))
    #expect(NotificationAccountAdmission.evaluate(
      userInfo: payload(recipient: "42"),
      fence: .present(.init(userID: nil, generation: 4))
    ) == .rejected(.signedOut))
  }

  @Test("fails closed without a recipient or a readable fence")
  func failsClosed() {
    let fence = NotificationAccountFenceRead.present(.init(userID: 42, generation: 1))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: nil), fence: fence)
      == .rejected(.missingRecipient))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: true), fence: fence)
      == .rejected(.missingRecipient))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "0"), fence: fence)
      == .rejected(.missingRecipient))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: .missing)
      == .rejected(.missingFence))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: .unavailable)
      == .rejected(.fenceUnavailable))
  }

  @Test("A's queued notification is withheld after A logs out")
  func withheldAfterLogout() {
    let storage = MemoryFenceStorage()
    let publisher = NotificationAccountFencePublisher(storage: storage)
    #expect(publisher.publishSignedIn(userID: 42))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read()).isAdmitted)

    #expect(publisher.publishSignedOut())
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read())
      == .rejected(.signedOut))
  }

  @Test("A's queued notification is withheld after B signs in")
  func withheldAfterAccountSwitch() {
    let storage = MemoryFenceStorage()
    let publisher = NotificationAccountFencePublisher(storage: storage)
    publisher.publishSignedIn(userID: 42)
    publisher.publishSignedOut()
    publisher.publishSignedIn(userID: 7)

    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read())
      == .rejected(.otherAccount))
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "7"), fence: storage.read()).isAdmitted)
  }

  @Test("an admitted notification is revoked by logout during processing, even if A signs back in")
  func admissionRecheckSeesGenerationChange() throws {
    let storage = MemoryFenceStorage()
    let publisher = NotificationAccountFencePublisher(storage: storage)
    publisher.publishSignedIn(userID: 42)
    let admission = NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read())
    #expect(admission.isCurrent(storage.read()))

    let before = try #require(storage.value)
    publisher.publishSignedOut()
    #expect(admission.isCurrent(storage.read()) == false)
    publisher.publishSignedIn(userID: 42)
    let after = try #require(storage.value)

    #expect(after.userID == 42)
    #expect(after.generation != before.generation)
    #expect(admission.isCurrent(storage.read()) == false)
    #expect(admission.isCurrent(.unavailable) == false)
  }

  @Test("publications are idempotent and generations only move forward")
  func publicationsAreIdempotent() throws {
    let storage = MemoryFenceStorage(.init(userID: 42, generation: 10))
    let publisher = NotificationAccountFencePublisher(storage: storage)
    #expect(publisher.publishSignedIn(userID: 42))
    #expect(storage.writeCount == 0)

    publisher.publishSignedOut()
    publisher.publishSignedOut()
    #expect(storage.writeCount == 1)
    #expect(storage.value == .init(userID: nil, generation: 11))

    publisher.publishSignedIn(userID: 42)
    #expect(storage.value == .init(userID: 42, generation: 12))
  }

  @Test("a stale owner never overwrites a newer transition")
  func staleOwnerIsSkipped() {
    let storage = MemoryFenceStorage(.init(userID: nil, generation: 5))
    let publisher = NotificationAccountFencePublisher(storage: storage)
    #expect(publisher.publishSignedIn(userID: 42, isCurrent: { false }) == false)
    #expect(storage.value == .init(userID: nil, generation: 5))
    #expect(storage.writeCount == 0)
  }

  @Test("a failed signed-out write deletes the record, which the extension also rejects")
  func signedOutFailsClosed() {
    let storage = MemoryFenceStorage(.init(userID: 42, generation: 5))
    storage.setFailsWrites(true)
    let publisher = NotificationAccountFencePublisher(storage: storage)
    #expect(publisher.publishSignedOut())
    #expect(storage.value == nil)
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read())
      == .rejected(.missingFence))
    #expect(publisher.publishSignedIn(userID: 42) == false)
  }

  @Test("a recreated record never repeats a generation an extension may hold")
  func recreatedRecordStartsAhead() throws {
    let storage = MemoryFenceStorage()
    let publisher = NotificationAccountFencePublisher(storage: storage)
    publisher.publishSignedIn(userID: 42)
    let first = try #require(storage.value)
    #expect(first.generation > 1_000_000)

    storage.setUnavailable(true)
    #expect(NotificationAccountAdmission.evaluate(userInfo: payload(recipient: "42"), fence: storage.read())
      == .rejected(.fenceUnavailable))
  }

  @Test("redaction keeps routing and presentation, drops private content")
  func redactionDropsPrivateContent() throws {
    let content = UNMutableNotificationContent()
    content.title = "Secret thread"
    content.subtitle = "Alice"
    content.body = "the launch code is 1234"
    content.threadIdentifier = "77"
    content.sound = .default
    content.userInfo = payload(recipient: "42").merging([
      "sender": ["id": 5, "displayName": "Alice"],
      "userId": 5,
      "isThread": true,
    ]) { current, _ in current }

    let redacted = NotificationAccountRedaction.content(from: content)
    #expect(redacted.title == NotificationAccountRedaction.title)
    #expect(redacted.subtitle.isEmpty)
    #expect(redacted.body == NotificationAccountRedaction.body)
    #expect(redacted.attachments.isEmpty)
    #expect(redacted.threadIdentifier == "77")
    #expect(redacted.sound != nil)
    let keys = Set(redacted.userInfo.keys.compactMap { $0 as? String })
    #expect(keys == ["kind", "recipientUserId", "threadId", "messageId"])
  }

  @Test("a push for another account is shown quietly, grouped apart, without routing")
  func anotherAccountIsQuiet() throws {
    let content = UNMutableNotificationContent()
    content.title = "Vlad"
    content.body = "secret"
    content.threadIdentifier = "chat_7"
    content.sound = .default
    content.userInfo = payload(recipient: "42")
      .merging(["threadId": "chat_7", "messageId": "9"]) { current, _ in current }

    for reason in [NotificationAccountAdmission.Rejection.otherAccount, .signedOut, .missingFence] {
      let quiet = NotificationAccountRedaction.content(from: content, rejection: reason)
      #expect(quiet.sound == nil)
      #expect(quiet.interruptionLevel == .passive)
      #expect(quiet.threadIdentifier == NotificationAccountRedaction.withheldThreadIdentifier)
      #expect(!quiet.body.contains("secret"))
      #expect(Set(quiet.userInfo.keys.compactMap { $0 as? String }) == ["recipientUserId"])
    }

    // Own-account failures may hide a real missed message: keep the sound and the chat.
    for reason in [NotificationAccountAdmission.Rejection.fenceUnavailable, .missingRecipient] {
      let audible = NotificationAccountRedaction.content(from: content, rejection: reason)
      #expect(audible.sound != nil)
      #expect(audible.threadIdentifier == "chat_7")
      #expect(audible.body == NotificationAccountRedaction.body)
    }
  }

  @Test("delivered notifications for other accounts are stale once the app opens")
  func staleDeliveredNotifications() {
    let mine = UNMutableNotificationContent()
    mine.userInfo = payload(recipient: "42")
    let theirs = UNMutableNotificationContent()
    theirs.userInfo = payload(recipient: "43")
    let withheld = UNMutableNotificationContent()
    withheld.threadIdentifier = NotificationAccountRedaction.withheldThreadIdentifier
    let local = UNMutableNotificationContent()

    #expect(!NotificationAccountRedaction.isStale(mine, currentUserID: 42))
    #expect(NotificationAccountRedaction.isStale(theirs, currentUserID: 42))
    #expect(NotificationAccountRedaction.isStale(withheld, currentUserID: 42))
    #expect(!NotificationAccountRedaction.isStale(local, currentUserID: 42))
  }
}

@Suite("Install namespace")
struct InstallNamespaceTests {
  @Test("release keeps historical names; other builds get their own")
  func namespaces() {
    #expect(InlineInstallNamespace.resolve(bundleIdentifier: "chat.inline.InlineIOS", isExtension: false) == "")
    #expect(InlineInstallNamespace.resolve(
      bundleIdentifier: "chat.inline.InlineIOS.InlineNotificationExtension", isExtension: true
    ) == "")
    #expect(InlineInstallNamespace.resolve(
      bundleIdentifier: "chat.inline.InlineIOS.debug", isExtension: false
    ) == "debug")
    #expect(InlineInstallNamespace.resolve(
      bundleIdentifier: "chat.inline.InlineIOS.devbuild.InlineNotificationExtension", isExtension: true
    ) == "devbuild")
    #expect(InlineInstallNamespace.resolve(bundleIdentifier: "chat.inline.InlineMac", isExtension: false) == "")
    #expect(InlineInstallNamespace.scoped("fence-v1", namespace: "") == "fence-v1")
    #expect(InlineInstallNamespace.scoped("fence-v1", namespace: "debug") == "fence-v1.debug")
  }
}

