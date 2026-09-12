#if os(macOS)
import AppKit
import Foundation
import GRDB
import InlineAvatarCore
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Mac notifications")
struct MacNotificationsTests {
  private let now = Date(timeIntervalSince1970: 1_000)

  private func makeMessage(
    text: String = "Hello",
    date: Int64 = 1_000,
    isDM: Bool = false,
    mentioned: Bool = false,
    isNudge: Bool = false,
    isSilent: Bool = false
  ) -> InlineProtocol.Message {
    InlineProtocol.Message.with {
      $0.id = 10
      $0.chatID = 20
      $0.fromID = 30
      $0.message = text
      $0.date = date
      $0.mentioned = mentioned
      $0.out = false
      if isDM {
        $0.peerID.user.userID = 30
      } else {
        $0.peerID.chat.chatID = 20
      }
      if isNudge {
        $0.media.nudge = .init()
      }
      if isSilent {
        $0.sendMode = .modeSilent
      }
    }
  }

  private func shouldSchedule(
    _ message: InlineProtocol.Message,
    mode: NotificationMode,
    source: MacNotifications.MessageUpdateSource = .newMessage,
    isNewlyInserted: Bool = true,
    isUnread: Bool = true,
    isPersonallyAddressed: Bool = false
  ) -> Bool {
    MacNotifications.shouldScheduleMessageNotification(
      for: message,
      effectiveMode: mode,
      source: source,
      deliveryState: .init(
        isNewlyInserted: isNewlyInserted,
        isUnread: isUnread,
        isPersonallyAddressed: isPersonallyAddressed
      ),
      now: now
    )
  }

  @Test("posts only from an app bundle")
  func postsOnlyFromAppBundle() {
    #expect(MacNotifications.canPostSystemNotifications(
      bundleURL: URL(fileURLWithPath: "/Applications/Inline.app")
    ))
    #expect(!MacNotifications.canPostSystemNotifications(
      bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/swift/pm")
    ))
  }

  @Test("renders named and generic fallback avatars at the requested size")
  func rendersFallbackAvatars() throws {
    let namedPresentation = InlineAvatarPresentation.user(identity: .init(
      firstName: "Ada",
      lastName: "Lovelace",
      displayName: nil,
      email: "ada@example.com",
      username: nil,
      stableIdentifier: "user:1"
    ))
    let genericPresentation = InlineAvatarPresentation.user(identity: .init(
      firstName: nil,
      lastName: nil,
      displayName: nil,
      email: nil,
      username: nil,
      stableIdentifier: "user:2"
    ))

    let namedImage = try #require(MacNotificationAvatarRenderer.makeImage(
      presentation: namedPresentation,
      size: CGSize(width: 44, height: 44)
    ))
    let genericImage = try #require(MacNotificationAvatarRenderer.makeImage(
      presentation: genericPresentation,
      size: CGSize(width: 60, height: 60)
    ))

    #expect(namedImage.width == 44)
    #expect(namedImage.height == 44)
    #expect(genericImage.width == 60)
    #expect(genericImage.height == 60)

    let representation = NSBitmapImageRep(cgImage: namedImage)
    let pngData = try #require(representation.representation(using: .png, properties: [:]))
    #expect(!pngData.isEmpty)
  }

  @Test("only generates initials when no profile photo is configured")
  func initialsFallbackPolicy() {
    let missingPhoto = UserInfo(
      user: User(id: 1, email: nil, firstName: "Ada"),
      profilePhotos: nil
    )
    var unavailablePhotoUser = User(id: 2, email: nil, firstName: "Grace")
    unavailablePhotoUser.profileCdnUrl = "https://example.com/avatar.jpg"
    let unavailablePhoto = UserInfo(user: unavailablePhotoUser, profilePhotos: nil)

    #expect(MacNotificationAvatarPolicy.shouldGenerateInitials(for: missingPhoto))
    #expect(!MacNotificationAvatarPolicy.shouldGenerateInitials(for: unavailablePhoto))
    #expect(!MacNotificationAvatarPolicy.shouldGenerateInitials(for: nil))
  }

  @Test("Document notifications use the file name")
  func documentNotificationsUseFileName() {
    let message = InlineProtocol.Message.with {
      $0.media.document.document.fileName = "Quarterly Report.pdf"
    }

    #expect(message.stringRepresentationWithEmoji == "📄 Quarterly Report.pdf")
    #expect(message.stringRepresentationPlain == "Quarterly Report.pdf")
  }

  @Test("durable newMessage owns every notification mode")
  func durableNewMessageOwnsNotificationRouting() {
    let ordinaryThread = makeMessage()
    let mentionedThread = makeMessage(mentioned: true)
    let ordinaryDM = makeMessage(isDM: true)
    let nudge = makeMessage(text: "👋", isNudge: true)
    let urgent = makeMessage(text: "  🚨\n", isNudge: true)

    #expect(shouldSchedule(ordinaryThread, mode: .all))
    #expect(!shouldSchedule(ordinaryThread, mode: .none))
    #expect(!shouldSchedule(ordinaryThread, mode: .mentions))
    #expect(shouldSchedule(mentionedThread, mode: .mentions))
    #expect(shouldSchedule(ordinaryDM, mode: .mentions))
    #expect(!shouldSchedule(ordinaryDM, mode: .onlyMentions))
    #expect(shouldSchedule(nudge, mode: .onlyMentions))

    for mode in [
      NotificationMode.all,
      .none,
      .mentions,
      .importantOnly,
      .onlyMentions,
    ] {
      #expect(shouldSchedule(urgent, mode: mode))
      #expect(!shouldSchedule(urgent, mode: mode, source: .explicitNotification))
    }
  }

  @Test("reply context counts as a personal address")
  func replyContextCountsAsPersonalAddress() {
    let ordinaryThread = makeMessage()

    #expect(shouldSchedule(
      ordinaryThread,
      mode: .mentions,
      isPersonallyAddressed: true
    ))
    #expect(shouldSchedule(
      ordinaryThread,
      mode: .onlyMentions,
      isPersonallyAddressed: true
    ))
  }

  @Test("freshness, insertion, and unread gates reject replay")
  func replaySafetyGates() {
    let fresh = makeMessage(date: 880)
    let stale = makeMessage(date: 879)
    let invalidDate = makeMessage(date: 0)

    #expect(MacNotifications.maximumMessageAge == 120)
    #expect(shouldSchedule(fresh, mode: .all))
    #expect(!shouldSchedule(stale, mode: .all))
    #expect(!shouldSchedule(invalidDate, mode: .all))
    #expect(!shouldSchedule(fresh, mode: .all, isNewlyInserted: false))
    #expect(!shouldSchedule(fresh, mode: .all, isUnread: false))
  }

  @Test("future server timestamps tolerate client clock skew")
  func futureTimestampTolerance() {
    let future = makeMessage(date: 1_300)
    #expect(shouldSchedule(future, mode: .all))
  }

  @Test("notification attachments are best effort within a bounded delivery budget")
  func notificationAttachmentsAreBestEffort() async {
    let immediateURL = URL(fileURLWithPath: "/tmp/notification-avatar.png")
    let immediate = await MacNotifications.bestEffortAttachment(timeout: .seconds(1)) {
      immediateURL
    }
    #expect(immediate == immediateURL)

    let clock = ContinuousClock()
    let startedAt = clock.now
    let timedOut = await MacNotifications.bestEffortAttachment(timeout: .milliseconds(10)) {
      try? await Task.sleep(for: .seconds(5))
      return immediateURL
    }

    #expect(timedOut == nil)
    #expect(startedAt.duration(to: clock.now) < .seconds(1))
  }

  @Test("silent send mode suppresses even urgent local routing")
  func silentSendModeSuppressesEveryRoute() {
    let silentUrgent = makeMessage(text: "🚨", isNudge: true, isSilent: true)

    #expect(!shouldSchedule(silentUrgent, mode: .none))
    #expect(!shouldSchedule(silentUrgent, mode: .mentions, source: .explicitNotification))
  }

  @Test("message identifiers are stable per chat and message")
  func stableMessageIdentifiers() {
    #expect(MacNotifications.messageNotificationIdentifier(chatID: 12, messageID: 34) == "chat_12_message_34")
    #expect(MacNotifications.notificationThreadIdentifier(chatID: 12) == "chat_12")
  }

#if DEBUG || DEBUG_BUILD
  @Test("playground scenarios project supported notification content")
  func playgroundScenariosProjectSupportedContent() {
    let expectedBodies: [MacNotificationPlaygroundScenario: String] = [
      .customText: "Custom\nbody",
      .multilineText: "First line\nSecond line\n\nA new paragraph",
      .photo: "🖼️ Photo",
      .photoWithCaption: "🖼️ Sprint whiteboard\nFinal layout",
      .video: "🎥 Video",
      .gif: "🎞️ GIF",
      .document: "📄 Quarterly Report.pdf",
      .voice: "🎤 Voice message (1:05)",
      .sticker: "🖼️ Sticker",
      .nudge: "👋 Nudge",
      .urgentNudge: "🚨 Urgent nudge",
      .messageFailed: "A message could not be sent in Design Review.",
    ]

    #expect(expectedBodies.count == MacNotificationPlaygroundScenario.allCases.count)
    for scenario in MacNotificationPlaygroundScenario.allCases {
      let presentation = MacNotifications.playgroundPresentation(
        scenario: scenario,
        customBody: " Custom \n body ",
        chatName: " Design\nReview "
      )
      #expect(presentation.body == expectedBodies[scenario])
      #expect(presentation.forceSound == (scenario == .urgentNudge))
      #expect(presentation.titleOverride == (scenario == .messageFailed ? "Message failed to send" : nil))
      #expect(presentation.includesSenderArtwork == (scenario != .messageFailed))
    }
  }
#endif

  @Test("Grid screen-share notification identifier replaces stale start state")
  func gridScreenShareNotificationIdentifier() {
    #expect(
      MacNotifications.gridScreenShareNotificationIdentifier(
        spaceID: 12,
        participantIdentity: "inline-grid-user-34-membership"
      ) == "grid_12_screen_share_inline-grid-user-34-membership"
    )
  }
}

@Suite("Mac notification database context")
struct MacNotificationDatabaseContextTests {
  @Test("nested replies inherit the nearest explicit preference, including hidden thread and DM parents", arguments: [false, true])
  func inheritsParentNotificationPreferences(rootIsDM: Bool) throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 7, email: nil, firstName: "Peer").insert(db)
      for id in [Int64(100), 600, 601] {
        let chat = Chat(
          id: id, date: Date(timeIntervalSince1970: 1), type: id == 100 && rootIsDM ? .privateChat : .thread,
          title: "Thread", spaceId: nil,
          peerUserId: id == 100 && rootIsDM ? 7 : nil,
          parentChatId: id == 100 ? nil : id == 600 ? 100 : 600,
          parentMessageId: id == 100 ? nil : 1
        )
        try chat.insert(db)
        // No intermediate dialog: inheritance must walk chat ancestry, not dialogs.
        if id != 600 {
          var dialog = Dialog(optimisticForChat: chat)
          if id == 100 {
            dialog.notificationSettings = .with { $0.mode = .mentions }
            dialog.archived = true
            dialog.chatListHidden = true
          }
          try dialog.insert(db)
        }
      }
      func selection() throws -> DialogNotificationSettingSelection {
        let context = try #require(try MacIncomingNotificationContext.fetch(
          db, peerID: .thread(id: 601), chatID: 601, replyToMessageID: nil
        ))
        return context.notificationSelection
      }
      #expect(try selection() == .mentions)
      var parent = try #require(try Dialog.get(peerId: rootIsDM ? .user(id: 7) : .thread(id: 100)).fetchOne(db))
      parent.notificationSettings = .with { $0.mode = .none }
      try parent.update(db)
      #expect(try selection() == .none)

      let middleChat = try #require(try Chat.fetchOne(db, key: 600))
      var middle = Dialog(optimisticForChat: middleChat)
      middle.notificationSettings = .with { $0.mode = .all }
      try middle.insert(db)
      #expect(try selection() == .all)
      var child = try #require(try Dialog.get(peerId: .thread(id: 601)).fetchOne(db))
      child.notificationSettings = .with { $0.mode = .none }
      try child.update(db)
      #expect(try selection() == .none)

      child.notificationSettings = .with { $0.mode = .UNRECOGNIZED(99) }
      try child.update(db)
      middle.notificationSettings = nil
      try middle.update(db)
      #expect(try selection() == .none)
      parent.notificationSettings = nil
      try parent.update(db)
      #expect(try selection() == .global)
    }
  }

  @Test("resolves unread and reply relevance in one context fetch")
  func resolvesUnreadAndReplyRelevance() throws {
    let currentUserID: Int64 = 7
    let senderID: Int64 = 8
    let parentChatID: Int64 = 100
    let replyThreadID: Int64 = 101
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      try User(id: currentUserID, email: nil, firstName: "Current").insert(db)
      try User(id: senderID, email: nil, firstName: "Sender").insert(db)
      try Chat(
        id: parentChatID,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).insert(db)
      try Chat(
        id: replyThreadID,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply",
        spaceId: nil,
        parentChatId: parentChatID,
        parentMessageId: 5
      ).insert(db)
      try Message(
        messageId: 5,
        fromId: currentUserID,
        date: Date(timeIntervalSince1970: 1),
        text: "Anchor",
        peerUserId: nil,
        peerThreadId: parentChatID,
        chatId: parentChatID
      ).insert(db)
      try Message(
        messageId: 6,
        fromId: currentUserID,
        date: Date(timeIntervalSince1970: 2),
        text: "Direct target",
        peerUserId: nil,
        peerThreadId: replyThreadID,
        chatId: replyThreadID
      ).insert(db)
      try Dialog(
        id: Dialog.getDialogId(peerId: .thread(id: replyThreadID)),
        peerUserId: nil,
        peerThreadId: replyThreadID,
        spaceId: nil,
        unreadCount: 1,
        readInboxMaxId: 4,
        readOutboxMaxId: nil,
        pinned: false,
        draftMessage: nil,
        archived: false,
        chatId: replyThreadID,
        unreadMark: false,
        notificationSettings: nil,
        collapsedMaxId: 8
      ).insert(db)

      let context = try #require(try MacIncomingNotificationContext.fetch(
        db,
        peerID: .thread(id: replyThreadID),
        chatID: replyThreadID,
        replyToMessageID: 6
      ))

      #expect(context.directReplySenderID == currentUserID)
      #expect(context.replyThreadAnchorSenderID == currentUserID)
      #expect(context.isUnread(messageID: 10))
      #expect(!context.isUnread(messageID: 4))
      #expect(!context.isUnread(messageID: 7))

      let incoming = InlineProtocol.Message.with { $0.mentioned = false }
      #expect(context.isPersonallyAddressed(
        message: incoming,
        currentUserID: currentUserID
      ))
    }
  }
}
#endif
