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

  @Test("All Chats includes Inbox and keeps closed pinned chats in activity order")
  func allChatsMembership() {
    let presentation = ChatListPresentation.make(from: [
      item(1, open: true, pinned: false, activity: date(day: 3)),
      item(2, open: false, pinned: true, activity: date(day: 4)),
      item(3, open: false, pinned: false, activity: date(day: 2)),
      item(4, open: true, pinned: true, activity: date(day: 1)),
    ], inboxSort: .lastUpdated, calendar: calendar)

    #expect(Set(presentation.allChats.map(\.peer)) == Set([
      .thread(id: 1), .thread(id: 2), .thread(id: 3), .thread(id: 4),
    ]))
    #expect(presentation.allChatSections.flatMap(\.items).map(\.peer) == [
      .thread(id: 2), .thread(id: 1), .thread(id: 3), .thread(id: 4),
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
    ], inboxSort: .recentlyOpened, calendar: calendar)

    #expect(presentation.inbox.map(\.peer) == [.thread(id: 2), .thread(id: 1)])
    #expect(presentation.allChatSections.map(\.id) == [date(day: 4), date(day: 2)])
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
    let allChatsAreActivityOrdered = presentation.allChats.elementsEqual(
      presentation.allChats.sorted {
        ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
      }
    )

    #expect(presentation.allChatCount == expectedVisible.count)
    #expect(presentation.inbox.count == expectedInbox.count)
    #expect(presentation.inboxPinned.allSatisfy { $0.isPinned })
    #expect(presentation.inboxUnpinned.allSatisfy { !$0.isPinned })
    #expect(Set(allPeers).count == allPeers.count)
    #expect(pinnedPrefixIsValid)
    #expect(unpinnedSuffixIsValid)
    #expect(allChatsAreActivityOrdered)
    #expect(presentation.structuralLocationChangeCount(from: presentation) == 0)
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: day))!
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
      openedDate: opened
    )
  }
}
