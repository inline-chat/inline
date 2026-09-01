import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Home chat-list presentation")
struct HomeChatListPresentationTests {
  @Test("Narrow snapshot query executes against the current schema")
  func queryMatchesSchema() throws {
    let database = AppDatabase.empty()
    let snapshots = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }

    #expect(snapshots.isEmpty)
  }

  @Test("Live snapshot observation refreshes every visible row field")
  @MainActor
  func liveSnapshotObservationRefreshesVisibleRowFields() async throws {
    let database = AppDatabase.empty()
    let recorder = ChatListSnapshotRecorder()
    let userID: Int64 = 820
    let chatID: Int64 = 821
    let firstMessageID: Int64 = 822
    let secondMessageID: Int64 = 823
    let folderID: Int64 = 824

    try await database.dbWriter.write { db in
      try DialogFolder(id: folderID, title: "Teammates", order: "a").insert(db)
      var user = User(id: userID, email: nil, firstName: "Amy")
      user.profileFileUniqueId = "avatar-v1"
      try user.insert(db)
      try Chat(
        id: chatID,
        date: date(day: 1),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: userID,
        lastMsgId: firstMessageID
      ).insert(db)
      try Message(
        messageId: firstMessageID,
        fromId: userID,
        date: date(day: 1),
        text: "First preview",
        peerUserId: userID,
        peerThreadId: nil,
        chatId: chatID,
        rev: 1
      ).insert(db)

      var dialog = Dialog.previewDm
      dialog.id = Dialog.getDialogId(peerUserId: userID)
      dialog.peerUserId = userID
      dialog.chatId = chatID
      dialog.open = true
      dialog.order = "a"
      dialog.folderId = folderID
      try dialog.insert(db)
    }

    let observation = ValueObservation.tracking { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }
    let cancellable = observation.start(
      in: database.reader,
      scheduling: .immediate,
      onError: recorder.record(error:),
      onChange: recorder.record
    )
    defer { cancellable.cancel() }

    let initial = try #require(await waitForSnapshot(
      recorder,
      messageID: firstMessageID
    )?.first)
    #expect(initial.title == "Amy")
    #expect(initial.previewText == "First preview")
    #expect(initial.unreadCount == 0)
    #expect(initial.order == "a")
    #expect(initial.folderID == folderID)
    #expect(initial.identity?.userDescriptor?.stableAvatarIdentity == "unique:avatar-v1")

    try await database.dbWriter.write { db in
      var user = try #require(try User.fetchOne(db, id: userID))
      user.firstName = "Amy Updated"
      user.profileFileUniqueId = "avatar-v2"
      try user.update(db)

      var dialog = try #require(try Dialog.fetchOne(db, id: Dialog.getDialogId(peerUserId: userID)))
      dialog.unreadCount = 4
      dialog.unreadMark = true
      dialog.order = "b"
      dialog.pinned = true
      dialog.pinnedOrder = "p"
      try dialog.update(db)

      try Message(
        messageId: secondMessageID,
        fromId: userID,
        date: date(day: 2),
        text: "Second preview",
        peerUserId: userID,
        peerThreadId: nil,
        chatId: chatID,
        rev: 2
      ).insert(db)
      try Translation(
        messageId: secondMessageID,
        chatId: chatID,
        translation: "Translated preview",
        entities: nil,
        language: "en",
        date: date(day: 2),
        msgRev: 2
      ).insert(db)
      try Chat.updateLastMsgId(
        db,
        chatId: chatID,
        lastMsgId: secondMessageID,
        date: date(day: 2)
      )
    }

    let updated = try #require(await waitForSnapshot(
      recorder,
      messageID: secondMessageID
    )?.first)
    #expect(updated.title == "Amy Updated")
    #expect(updated.previewText == "Second preview")
    #expect(updated.translatedPreviewText == "Translated preview")
    #expect(updated.lastUpdatedAt == date(day: 2))
    #expect(updated.unreadCount == 4)
    #expect(updated.unreadMark)
    #expect(updated.isPinned)
    #expect(updated.order == "b")
    #expect(updated.pinnedOrder == "p")
    #expect(updated.folderID == folderID)
    #expect(updated.identity?.userDescriptor?.stableAvatarIdentity == "unique:avatar-v2")
    #expect(recorder.errorDescription == nil)
  }

  @Test("Native rich projection accepts nullable legacy file sizes")
  func richProjectionAcceptsNullableLegacyFileSizes() throws {
    let database = AppDatabase.empty()
    let userID: Int64 = 801
    let chatID: Int64 = 802

    try database.dbWriter.write { db in
      try User(id: userID, email: nil, firstName: "Mo").insert(db)
      try Chat(
        id: chatID,
        date: date(day: 1),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: userID
      ).insert(db)

      var dialog = Dialog.previewDm
      dialog.id = Dialog.getDialogId(peerUserId: userID)
      dialog.peerUserId = userID
      dialog.chatId = chatID
      dialog.open = true
      try dialog.insert(db)

      // `fileSize` has always been nullable in SQLite. Missing size metadata is
      // valid cache state and must match the Swift record model.
      try db.execute(
        sql: """
        INSERT INTO "file" (
          "id", "fileType", "fileSize", "uploading", "profileForUserId"
        ) VALUES (?, ?, NULL, 0, ?)
        """,
        arguments: ["malformed-avatar", MessageFileType.photo.rawValue, userID]
      )
    }

    let richItems = try database.reader.read { db in
      try HomeChatItem.all().fetchAll(db)
    }
    #expect(richItems.map(\.peerId) == [.user(id: userID)])
    #expect(richItems.first?.user?.profilePhoto?.first?.fileSize == nil)

    let destinations = try database.reader.read { db in
      try ChatDestinationCatalogSnapshotQuery.fetchAll(db)
    }
    #expect(destinations.map(\.peerId) == [.user(id: userID)])

    let snapshots = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }

    #expect(snapshots.map(\.peer) == [.user(id: userID)])
    #expect(snapshots.first?.title == "Mo")
  }

  @Test("Destination catalog ignores invalid cached presence and user decoders reject milliseconds")
  func destinationCatalogIgnoresInvalidCachedPresence() async throws {
    let database = AppDatabase.empty()
    let userID: Int64 = 803
    let chatID: Int64 = 804

    try await database.dbWriter.write { db in
      try User(id: userID, email: nil, firstName: "Mo").insert(db)
      try Chat(
        id: chatID,
        date: date(day: 1),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: userID
      ).insert(db)

      var dialog = Dialog.previewDm
      dialog.id = Dialog.getDialogId(peerUserId: userID)
      dialog.peerUserId = userID
      dialog.chatId = chatID
      dialog.open = true
      try dialog.insert(db)

      // Reproduce the old contract: milliseconds were stored as Unix seconds.
      try User.filter(id: userID).updateAll(
        db,
        [Column("lastOnline").set(to: Int64(1_723_000_000_000))]
      )
      let user = try #require(try User.fetchOne(db, id: userID))
      try user.save(db) // Re-encodes the far-future Date as an unsupported five-digit-year string.
    }

    let destinations = try await database.reader.read { db in
      try ChatDestinationCatalogSnapshotQuery.fetchAll(db)
    }
    #expect(destinations.map(\.peerId) == [.user(id: userID)])
    #expect(destinations.first?.item.user?.user.lastOnline == nil)

    let commandBarSnapshot = try await database.fetchCommandBarCatalogSnapshot()
    #expect(commandBarSnapshot.knownUsers.map(\.id) == [userID])
    #expect(commandBarSnapshot.knownUsers.first?.lastOnline == nil)

    let apiUser = ApiUser(
      id: userID,
      email: nil,
      firstName: "Mo",
      lastName: nil,
      lastOnline: 1_723_000_000_000,
      date: 1_723_000_000,
      username: nil
    )
    #expect(User(from: apiUser).lastOnline == nil)

    var lastOnline = LastOnline()
    lastOnline.date = 1_723_000_000_000
    var status = UserStatus()
    status.lastOnline = lastOnline
    var protocolUser = InlineProtocol.User()
    protocolUser.id = userID
    protocolUser.status = status
    #expect(User(from: protocolUser).lastOnline == nil)
  }

  @Test("Snapshot projection carries All Chats rendering and action metadata")
  func allChatsMetadataProjection() throws {
    let database = AppDatabase.empty()
    let spaceID: Int64 = 810
    let chatID: Int64 = 811
    let senderID: Int64 = 812
    let messageID: Int64 = 813

    try database.dbWriter.write { db in
      try Space(
        id: spaceID,
        name: "🧪 Lab",
        date: date(day: 1)
      ).insert(db)

      var sender = User(id: senderID, email: nil, firstName: "Dena")
      sender.profileFileUniqueId = "avatar-unique-id"
      try sender.insert(db)

      try Chat(
        id: chatID,
        date: date(day: 1),
        type: .thread,
        title: "Experiments",
        spaceId: spaceID,
        lastMsgId: messageID,
        isPublic: false,
        createdBy: senderID
      ).insert(db)
      try Message(
        messageId: messageID,
        fromId: senderID,
        date: date(day: 2),
        text: "Ready",
        peerUserId: nil,
        peerThreadId: chatID,
        chatId: chatID
      ).insert(db)

      var dialog = Dialog.previewThread
      dialog.id = Dialog.getDialogId(peerThreadId: chatID)
      dialog.peerThreadId = chatID
      dialog.chatId = chatID
      dialog.spaceId = spaceID
      dialog.open = true
      try dialog.insert(db)
    }

    let snapshot = try #require(database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en",
        includePreviewSenderIdentity: true
      ).first
    })

    #expect(snapshot.spaceName == "Lab")
    #expect(snapshot.previewSenderName == "Dena")
    #expect(snapshot.previewSenderIdentity?.userID == senderID)
    #expect(snapshot.previewSenderIdentity?.stableAvatarIdentity == "unique:avatar-unique-id")
    #expect(snapshot.chatType == .thread)
    #expect(snapshot.chatCreatedBy == senderID)
    #expect(snapshot.chatIsPublic == false)
  }

  @Test("Reply-thread anchor preview keeps the document file name")
  func replyThreadDocumentAnchorPreview() throws {
    let database = AppDatabase.empty()
    let parentChatID: Int64 = 710
    let replyChatID: Int64 = 711
    let anchorMessageID: Int64 = 12
    let documentID: Int64 = 91

    try database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Mo").insert(db)
      try Chat(
        id: parentChatID,
        date: date(day: 1),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).insert(db)
      try Document(
        id: nil,
        documentId: documentID,
        date: date(day: 1),
        fileName: "Anchor Report.pdf",
        mimeType: "application/pdf",
        size: 42,
        cdnUrl: nil,
        localPath: nil,
        thumbnailPhotoId: nil
      ).insert(db)
      try Message(
        messageId: anchorMessageID,
        fromId: 1,
        date: date(day: 1),
        text: nil,
        peerUserId: nil,
        peerThreadId: parentChatID,
        chatId: parentChatID,
        documentId: documentID
      ).insert(db)
      try Chat(
        id: replyChatID,
        date: date(day: 2),
        type: .thread,
        title: nil,
        spaceId: nil,
        parentChatId: parentChatID,
        parentMessageId: anchorMessageID
      ).insert(db)

      var dialog = Dialog.previewThread
      dialog.id = Dialog.getDialogId(peerThreadId: replyChatID)
      dialog.peerThreadId = replyChatID
      dialog.chatId = replyChatID
      dialog.open = true
      try dialog.insert(db)
    }

    let snapshots = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }

    #expect(snapshots.first?.title == "📄 Anchor Report.pdf")
    #expect(snapshots.first?.parentChatID == parentChatID)
    #expect(snapshots.first?.parentTitle == "Parent")
    let fallback = try database.reader.read { db in
      try ReplyThreadTitleFallback.title(
        for: try #require(try Chat.fetchOne(db, id: replyChatID)),
        db: db
      )
    }
    #expect(fallback == "📄 Anchor Report.pdf")
  }

  @Test("Space chat adapter carries its document into embedded previews")
  func spaceChatItemCarriesDocumentPreview() {
    let document = Document(
      id: nil,
      documentId: 92,
      date: date(day: 1),
      fileName: "Space Notes.md",
      mimeType: "text/markdown",
      size: 42,
      cdnUrl: nil,
      localPath: nil,
      thumbnailPhotoId: nil
    )
    let message = Message(
      messageId: 13,
      fromId: 1,
      date: date(day: 1),
      text: nil,
      peerUserId: nil,
      peerThreadId: 712,
      chatId: 712,
      documentId: document.documentId
    )
    let item = SpaceChatItem(
      dialog: .previewThread,
      message: message,
      document: document
    )

    #expect(item.embeddedMessage?.document?.fileName == "Space Notes.md")
  }

  @Test("Last-message translations match the selected language and message revision")
  func translatedLastMessagePreview() throws {
    let database = AppDatabase.empty()
    let chatID: Int64 = 700
    let messageID: Int64 = 10

    try database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Mo").insert(db)
      try Chat(
        id: chatID,
        date: date(day: 1),
        type: .thread,
        title: "Translated chat",
        spaceId: nil,
        lastMsgId: messageID
      ).insert(db)
      try Message(
        messageId: messageID,
        fromId: 1,
        date: date(day: 2),
        text: "Bonjour",
        peerUserId: nil,
        peerThreadId: chatID,
        chatId: chatID,
        rev: 1
      ).insert(db)

      var dialog = Dialog.previewThread
      dialog.id = Dialog.getDialogId(peerThreadId: chatID)
      dialog.peerThreadId = chatID
      dialog.chatId = chatID
      dialog.open = true
      try dialog.insert(db)

      try Translation(
        messageId: messageID,
        chatId: chatID,
        translation: "Hello",
        entities: nil,
        language: "en",
        date: date(day: 2),
        msgRev: 1
      ).insert(db)
    }

    let translated = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }
    #expect(translated.first?.translatedPreviewText == "Hello")

    let wrongLanguage = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "de"
      )
    }
    #expect(wrongLanguage.first?.translatedPreviewText == nil)

    try database.dbWriter.write { db in
      guard var message = try Message.fetchOne(
        db,
        key: ["chatId": chatID, "messageId": messageID]
      ) else {
        Issue.record("Expected seeded last message")
        return
      }
      message.rev = 2
      try message.update(db)
    }
    let staleRevision = try database.reader.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en"
      )
    }
    #expect(staleRevision.first?.translatedPreviewText == nil)
  }

  @Test("Inbox contains open chats only and keeps pinned chats first")
  func inboxMembershipAndOrdering() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, pinned: false, activity: date(day: 3)),
      item(2, open: false, pinned: true, activity: date(day: 4)),
      item(3, open: true, pinned: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 3), .thread(id: 1)])
    #expect(presentation.inboxPinned.map(\.peer) == [.thread(id: 3)])
    #expect(presentation.inboxUnpinned.map(\.peer) == [.thread(id: 1)])
    #expect(presentation.allChats.map(\.peer).contains(.thread(id: 2)))
  }

  @Test("All Chats extracts open and closed pins without duplicating them")
  func allChatsMembership() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, pinned: false, activity: date(day: 3)),
      item(2, open: false, pinned: true, pinnedOrder: "b", activity: date(day: 4)),
      item(3, open: false, pinned: false, activity: date(day: 2)),
      item(4, open: true, pinned: true, pinnedOrder: "a", activity: date(day: 1)),
    ], inboxSort: .lastUpdated, now: date(day: 4), calendar: calendar)

    #expect(Set(presentation.allChats.map(\.peer)) == Set([
      .thread(id: 1), .thread(id: 2), .thread(id: 3), .thread(id: 4),
    ]))
    #expect(presentation.allChatsPinned.map(\.peer) == [.thread(id: 4), .thread(id: 2)])
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 1), .thread(id: 3),
    ])
  }

  @Test("Archived and hidden chats do not leak into active surfaces")
  func archivedVisibility() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, archived: true, activity: date(day: 3)),
      item(2, open: true, hidden: true, activity: date(day: 2)),
      item(3, open: true, activity: date(day: 1)),
      item(4, open: false, archived: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 3)])
    #expect(presentation.allChats.map(\.peer) == [.thread(id: 3)])
    #expect(presentation.archived.map(\.peer) == [.thread(id: 1), .thread(id: 4)])
    #expect(presentation.archivedSections.map(\.id) == [date(day: 3), date(day: 1)])
    #expect(presentation.archivedSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 1), .thread(id: 4),
    ])
  }

  @Test("Opened-time sorting applies to Inbox while All Chats stays activity ordered")
  func openedTimeIsInboxOnly() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4), opened: date(day: 1)),
      item(2, open: true, activity: date(day: 2), opened: date(day: 3)),
    ], inboxSort: .recentlyOpened, now: date(day: 4), calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 2), .thread(id: 1)])
    #expect(presentation.allChatSections.map(\.id) == [
      .day(date(day: 4)), .day(date(day: 2)),
    ])
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 1), .thread(id: 2),
    ])
  }

  @Test("Unread filter only affects All Chats")
  func unreadAllChatsFilter() {
    let presentation = ChatListPresentation.make(
      from: [
        item(1, open: true, activity: date(day: 3)),
        item(2, open: true, unreadCount: 2, activity: date(day: 2)),
        item(3, open: false, unreadMark: true, activity: date(day: 1)),
      ],
      inboxSort: .lastUpdated,
      allChatsFilter: .unread,
      calendar: calendar
    )

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 1), .thread(id: 2)])
    #expect(presentation.allChats.map(\.peer) == [.thread(id: 2), .thread(id: 3)])
  }

  @Test("All Chats uses recent days, then current-year months, then years")
  func hybridTimelineSections() {
    let now = date(year: 2026, month: 8, day: 14)
    let presentation = ChatListPresentation.make(
      from: [
        item(1, activity: date(year: 2026, month: 8, day: 14)),
        item(2, activity: date(year: 2026, month: 8, day: 13)),
        item(3, activity: date(year: 2026, month: 8, day: 8)),
        item(4, activity: date(year: 2026, month: 8, day: 7)),
        item(5, activity: date(year: 2026, month: 2, day: 20)),
        item(6, activity: date(year: 2025, month: 12, day: 31)),
        item(7, activity: date(year: 2025, month: 1, day: 1)),
      ],
      inboxSort: .lastUpdated,
      now: now,
      calendar: calendar
    )

    #expect(presentation.allChatSections.map(\.id) == [
      .day(date(year: 2026, month: 8, day: 14)),
      .day(date(year: 2026, month: 8, day: 13)),
      .day(date(year: 2026, month: 8, day: 8)),
      .month(year: 2026, month: 8),
      .month(year: 2026, month: 2),
      .year(2025),
    ])
    #expect(presentation.allChatSections.last?.items.map(\.peer) == [
      .thread(id: 6), .thread(id: 7),
    ])
  }

  @Test("Timeline boundaries use local calendar days across daylight saving time")
  func timelineCalendarBoundaries() {
    var localCalendar = Calendar(identifier: .gregorian)
    localCalendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = localCalendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    let sixDaysAgo = localCalendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
    let sevenDaysAgo = localCalendar.date(from: DateComponents(year: 2026, month: 3, day: 3))!
    let eightDaysAgo = localCalendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!

    #expect(
      ChatListTimelinePeriod.classify(
        sixDaysAgo,
        relativeTo: now,
        calendar: localCalendar
      ) == .day(sixDaysAgo)
    )
    #expect(
      ChatListTimelinePeriod.classify(
        sevenDaysAgo,
        relativeTo: now,
        calendar: localCalendar
      ) == .month(year: 2026, month: 3)
    )
    #expect(
      ChatListTimelinePeriod.classify(
        eightDaysAgo,
        relativeTo: now,
        calendar: localCalendar
      ) == .month(year: 2026, month: 3)
    )
  }

  @Test("Inbox unread badge excludes closed chats")
  func inboxUnreadCount() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, unreadCount: 2),
      item(2, open: false, unreadCount: 5),
      item(3, open: true, unreadMark: true),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(presentation.inboxUnreadCount == 2)
  }

  @Test("Row timestamps use compact absolute time and date labels")
  func absoluteRowTimestamps() {
    let now = calendar.date(from: DateComponents(
      year: 2026,
      month: 8,
      day: 4,
      hour: 14,
      minute: 30
    ))!
    let justNow = now.addingTimeInterval(-30)
    let earlierToday = now.addingTimeInterval(-3_600)
    let yesterday = now.addingTimeInterval(-86_400)
    let earlierThisYear = calendar.date(byAdding: .day, value: -14, to: now)!
    let previousYear = calendar.date(byAdding: .year, value: -1, to: now)!

    #expect(
      ChatListDateFormatter.rowTitle(for: justNow, now: now, calendar: calendar)
        == justNow.formatted(date: .omitted, time: .shortened)
    )
    #expect(
      ChatListDateFormatter.rowTitle(for: earlierToday, now: now, calendar: calendar)
        == earlierToday.formatted(date: .omitted, time: .shortened)
    )
    #expect(
      ChatListDateFormatter.rowTitle(for: yesterday, now: now, calendar: calendar)
        == yesterday.formatted(.dateTime.weekday(.abbreviated))
    )
    #expect(
      ChatListDateFormatter.rowTitle(for: earlierThisYear, now: now, calendar: calendar)
        == earlierThisYear.formatted(.dateTime.month(.abbreviated).day())
    )
    #expect(
      ChatListDateFormatter.rowTitle(for: previousYear, now: now, calendar: calendar)
        == previousYear.formatted(.dateTime.month(.abbreviated).day().year())
    )
  }

  @Test("Last-message previews cover every persisted message content kind")
  func lastMessagePreviewCoverage() throws {
    let servicePayload = Client_MessageContentPayload.with {
      $0.serviceMessage = MessageService.with {
        $0.pinnedMessage = MessageServicePinnedMessage()
      }
    }
    let voicePayload = Client_MessageContentPayload.with {
      $0.voice = Client_MessageVoiceContent.with { $0.voiceID = 42 }
    }

    #expect(preview(text: " Hello\nworld ") == "Hello world")
    #expect(preview(isSticker: true) == "Sticker")
    #expect(preview(fileID: "file") == "File")
    #expect(preview(photoID: 1) == "Photo")
    #expect(preview(videoID: 1) == "Video")
    #expect(preview(documentID: 1, documentFileName: "Report.pdf") == "📄 Report.pdf")
    #expect(preview(documentID: 1, documentFileName: "Artist - Song.mp3") == "🎵 Artist - Song.mp3")
    #expect(preview(documentID: 1) == "📄 Document")
    #expect(preview(contentPayload: try voicePayload.serializedData()) == "Voice message")
    #expect(preview(contentPayload: try servicePayload.serializedData()) == "Pinned a message")
    #expect(preview() == "Message")
    #expect(preview(messageID: nil) == nil)
  }

  @Test("Structural diff ignores content-only changes and detects membership moves")
  func structuralDiff() {
    let original = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3)),
      item(2, open: false, activity: date(day: 2)),
    ], inboxSort: .lastUpdated, calendar: calendar)
    let contentOnly = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3), title: "Renamed"),
      item(2, open: false, activity: date(day: 2)),
    ], inboxSort: .lastUpdated, calendar: calendar)
    let moved = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 3)),
      item(2, open: true, activity: date(day: 2)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(contentOnly.structuralLocationChangeCount(from: original) == 0)
    #expect(moved.structuralLocationChangeCount(from: original) == 1)
  }

  @Test("Pinning one Inbox chat remains a small animated reorder")
  func pinnedReorderDiff() {
    let original = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4)),
      item(2, open: true, activity: date(day: 3)),
      item(3, open: true, activity: date(day: 2)),
      item(4, open: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)
    let pinned = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 4)),
      item(2, open: true, activity: date(day: 3)),
      item(3, open: true, pinned: true, activity: date(day: 2)),
      item(4, open: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(pinned.inbox.map(\.peer) == [
      .thread(id: 3), .thread(id: 1), .thread(id: 2), .thread(id: 4),
    ])
    #expect(pinned.inboxPinned.map(\.peer) == [.thread(id: 3)])
    #expect(pinned.inboxUnpinned.map(\.peer) == [
      .thread(id: 1), .thread(id: 2), .thread(id: 4),
    ])
    #expect(pinned.structuralLocationChangeCount(from: original) == 2)
  }

  @Test("Inbox section changes remain structural when flat order is unchanged")
  func pinnedSectionIdentityDiff() {
    let original = ChatListPresentation.make(from: [
      item(1, open: true, activity: date(day: 2)),
      item(2, open: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)
    let pinned = ChatListPresentation.make(from: [
      item(1, open: true, pinned: true, activity: date(day: 2)),
      item(2, open: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(pinned.inbox.map(\.peer) == original.inbox.map(\.peer))
    #expect(pinned.inboxPinned.map(\.peer) == [.thread(id: 1)])
    #expect(pinned.inboxUnpinned.map(\.peer) == [.thread(id: 2)])
    #expect(pinned.structuralLocationChangeCount(from: original) == 2)
  }

  @Test("Production-scale projection keeps stable identity and surface membership")
  func productionScaleProjection() {
    let itemCount = 5_000
    let snapshots = (1 ... itemCount).map { index in
      item(
        Int64(index),
        open: index.isMultiple(of: 3),
        pinned: index.isMultiple(of: 97),
        archived: index.isMultiple(of: 31),
        hidden: index.isMultiple(of: 47),
        unreadCount: index.isMultiple(of: 11) ? 1 : 0,
        activity: Date(timeIntervalSince1970: TimeInterval(itemCount - index))
      )
    }

    let presentation = ChatListPresentation.make(
      from: snapshots,
      inboxSort: .lastUpdated,
      calendar: calendar
    )
    let expectedVisible = snapshots.filter(\.isVisibleInHome)
    let expectedInbox = expectedVisible.filter(\.isOpen)
    let allPeers = presentation.allChats.map(\.peer)
    let pinnedPrefixIsValid = presentation.inbox
      .prefix { $0.isPinned }
      .allSatisfy { $0.isPinned }
    let unpinnedSuffixIsValid = presentation.inbox
      .drop { $0.isPinned }
      .allSatisfy { !$0.isPinned }
    let allChatsTimeline = presentation.allChatSections.flatMap(\.items)
    let allChatsTimelineIsActivityOrdered = allChatsTimeline.elementsEqual(
      allChatsTimeline.sorted {
        ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
      }
    )

    #expect(presentation.allChatCount == expectedVisible.count)
    #expect(presentation.inbox.count == expectedInbox.count)
    #expect(presentation.inboxPinned.allSatisfy { $0.isPinned })
    #expect(presentation.inboxUnpinned.allSatisfy { !$0.isPinned })
    #expect(presentation.allChatsPinned.allSatisfy { $0.isPinned })
    #expect(allChatsTimeline.allSatisfy { !$0.isPinned })
    #expect(Set(allPeers).count == allPeers.count)
    #expect(pinnedPrefixIsValid)
    #expect(unpinnedSuffixIsValid)
    #expect(allChatsTimelineIsActivityOrdered)
    #expect(presentation.structuralLocationChangeCount(from: presentation) == 0)
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(day: Int) -> Date {
    date(year: 2026, month: 8, day: day)
  }

  private func date(year: Int, month: Int, day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func preview(
    messageID: Int64? = 1,
    text: String? = nil,
    isSticker: Bool? = nil,
    fileID: String? = nil,
    photoID: Int64? = nil,
    videoID: Int64? = nil,
    documentID: Int64? = nil,
    documentFileName: String? = nil,
    contentPayload: Data? = nil
  ) -> String? {
    ChatListDatabaseQuery.messagePreview(ChatListMessagePreviewInput(
      messageID: messageID,
      text: text,
      isSticker: isSticker,
      fileID: fileID,
      photoID: photoID,
      videoID: videoID,
      documentID: documentID,
      documentFileName: documentFileName,
      contentPayloadData: contentPayload
    ))
  }

  private func item(
    _ id: Int64,
    open: Bool = false,
    pinned: Bool = false,
    pinnedOrder: String? = nil,
    archived: Bool = false,
    hidden: Bool = false,
    unreadCount: Int = 0,
    unreadMark: Bool = false,
    activity: Date? = nil,
    opened: Date? = nil,
    title: String? = nil
  ) -> ChatListItemSnapshot {
    ChatListItemSnapshot(
      peer: .thread(id: id),
      chatID: id,
      title: title ?? "Chat \(id)",
      unreadCount: unreadCount,
      unreadMark: unreadMark,
      isOpen: open,
      isPinned: pinned,
      isChatListHidden: hidden,
      isArchived: archived,
      lastUpdatedAt: activity,
      openedDate: opened,
      pinnedOrder: pinnedOrder
    )
  }

  private func waitForSnapshot(
    _ recorder: ChatListSnapshotRecorder,
    messageID: Int64
  ) async -> [ChatListItemSnapshot]? {
    for _ in 0 ..< 100 {
      if let snapshots = recorder.latest,
         snapshots.first?.contentSignature.messageID == messageID {
        return snapshots
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return recorder.latest
  }
}

private final class ChatListSnapshotRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedLatest: [ChatListItemSnapshot]?
  private var recordedErrorDescription: String?

  var latest: [ChatListItemSnapshot]? {
    lock.withLock { recordedLatest }
  }

  var errorDescription: String? {
    lock.withLock { recordedErrorDescription }
  }

  func record(_ snapshots: [ChatListItemSnapshot]) {
    lock.withLock {
      recordedLatest = snapshots
    }
  }

  func record(error: Error) {
    lock.withLock {
      recordedErrorDescription = String(reflecting: error)
    }
  }
}

private extension ChatListIdentityDescriptor {
  var userDescriptor: ChatListUserAvatarDescriptor? {
    guard case let .user(descriptor) = self else { return nil }
    return descriptor
  }
}
