import Foundation
import InlineNotificationFence
@testable import InlineSharedSnapshot
import Testing

private final class FenceStub: NotificationAccountFenceStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var state: NotificationAccountFenceRead

  init(_ state: NotificationAccountFenceRead) {
    self.state = state
  }

  func set(_ state: NotificationAccountFenceRead) { lock.withLock { self.state = state } }
  func read() -> NotificationAccountFenceRead { lock.withLock { state } }
  func write(_ fence: NotificationAccountFence) -> Bool { set(.present(fence)); return true }
  func delete() -> Bool { set(.missing); return true }
}

private struct OtherVersion: SharedSnapshotPayload {
  static let kind = WidgetChatsSnapshot.kind
  static let schemaVersion = WidgetChatsSnapshot.schemaVersion + 1
  var chats: [WidgetChat]
  var unreadChatCount: Int
}

@Suite("Shared snapshot store")
struct SharedSnapshotStoreTests {
  private let container: URL
  private let fence = FenceStub(.present(NotificationAccountFence(userID: 7, generation: 3)))

  init() throws {
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
  }

  private func store(scope: String = "") -> SharedSnapshotStore {
    SharedSnapshotStore(containerURL: container, scope: scope, fence: fence)
  }

  private func payload(title: String = "Design") -> WidgetChatsSnapshot {
    WidgetChatsSnapshot(
      chats: [WidgetChat(
        id: 1, kind: .thread, title: title, preview: "Ship it", date: Date(timeIntervalSince1970: 100),
        unreadCount: 2, isUnread: true, isPinned: false, emoji: nil,
        initials: WidgetChat.initials(for: title), avatarPath: nil, deepLink: "inline://chat/1"
      )],
      unreadChatCount: 1
    )
  }

  @Test func roundTripsForTheSignedInAccount() throws {
    #expect(try store().write(payload()) == .written)
    let read = store().read(WidgetChatsSnapshot.self)
    #expect(read.current?.payload == payload())
    #expect(read.current?.owner == SharedSnapshotOwner(userID: 7, fenceGeneration: 3))
  }

  @Test func skipsWritingUnchangedContent() throws {
    try store().write(payload())
    #expect(try store().write(payload()) == .unchanged)
    #expect(try store().write(payload(title: "Infra")) == .written)
  }

  @Test func rewritesUnchangedContentForANewSignIn() throws {
    try store().write(payload())
    fence.set(.present(NotificationAccountFence(userID: 7, generation: 5)))
    #expect(try store().write(payload()) == .written)
  }

  @Test func rejectsAnotherAccountsSnapshot() throws {
    try store().write(payload())
    fence.set(.present(NotificationAccountFence(userID: 8, generation: 4)))
    guard case .otherOwner = store().read(WidgetChatsSnapshot.self) else {
      Issue.record("expected otherOwner")
      return
    }
  }

  @Test func signedOutHidesTheSnapshot() throws {
    try store().write(payload())
    fence.set(.present(NotificationAccountFence(userID: nil, generation: 4)))
    guard case .signedOut = store().read(WidgetChatsSnapshot.self) else {
      Issue.record("expected signedOut")
      return
    }
    #expect(throws: SharedSnapshotError.signedOut) { try store().write(payload()) }
  }

  @Test func lockedKeychainReadsUnverified() throws {
    try store().write(payload())
    fence.set(.unavailable)
    guard case let .unverified(snapshot) = store().read(WidgetChatsSnapshot.self) else {
      Issue.record("expected unverified")
      return
    }
    #expect(snapshot.payload == payload())
    #expect(throws: SharedSnapshotError.fenceUnavailable) { try store().write(payload()) }
  }

  @Test func otherSchemaVersionIsIncompatible() throws {
    try store().write(payload())
    guard case .incompatible = store().read(OtherVersion.self) else {
      Issue.record("expected incompatible")
      return
    }
  }

  @Test func scopesKeepInstallsApart() throws {
    try store(scope: ".debug").write(payload())
    guard case .missing = store().read(WidgetChatsSnapshot.self) else {
      Issue.record("expected missing")
      return
    }
    #expect(SharedSnapshotStore.scope(namespace: "debug", userProfile: "alice") == ".debug.alice")
    #expect(SharedSnapshotStore.scope(namespace: "", userProfile: nil) == "")
  }

  @Test func removeDeletesTheFile() throws {
    try store().write(payload())
    try store().remove(WidgetChatsSnapshot.self)
    guard case .missing = store().read(WidgetChatsSnapshot.self) else {
      Issue.record("expected missing")
      return
    }
  }

  @Test func appGroupPathsCannotEscapeTheContainer() {
    #expect(SharedSnapshotStore.appGroupFileURL(relativePath: "IntentAvatars/user-1.jpg", containerURL: container) != nil)
    #expect(SharedSnapshotStore.appGroupFileURL(relativePath: "../secret", containerURL: container) == nil)
    #expect(SharedSnapshotStore.appGroupFileURL(relativePath: "/etc/hosts", containerURL: container) == nil)
    #expect(SharedSnapshotStore.appGroupFileURL(relativePath: " ", containerURL: container) == nil)
  }

  @Test func initialsUseTheFirstTwoWords() {
    #expect(WidgetChat.initials(for: "Mo Rajabi") == "MR")
    #expect(WidgetChat.initials(for: "design") == "D")
    #expect(WidgetChat.initials(for: "🚀") == "#")
  }
}
