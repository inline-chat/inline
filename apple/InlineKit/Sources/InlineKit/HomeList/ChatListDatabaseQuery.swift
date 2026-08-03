import Foundation
import GRDB
import InlineProtocol
import Logger

public enum ChatListDatabaseQuery {
  public static func fetchSnapshots(
    _ db: Database,
    spaceID: Int64?,
    includeSpaceChatsInHome: Bool,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> [ChatListItemSnapshot] {
    let scope = scopePredicate(
      spaceID: spaceID,
      includeSpaceChatsInHome: includeSpaceChatsInHome
    )
    let request = SQLRequest<Row>(
      sql: """
      SELECT
        "dialog"."peerUserId" AS "peerUserID",
        "dialog"."peerThreadId" AS "peerThreadID",
        "chat"."id" AS "chatID",
        COALESCE("dialog"."spaceId", "chat"."spaceId") AS "spaceID",
        "dialog"."unreadCount" AS "unreadCount",
        "dialog"."unreadMark" AS "unreadMark",
        "dialog"."archived" AS "isArchived",
        "dialog"."pinned" AS "isPinned",
        "dialog"."open" AS "isOpen",
        "dialog"."openedDate" AS "openedDate",
        "dialog"."order" AS "normalOrder",
        "dialog"."pinnedOrder" AS "pinnedOrder",
        "dialog"."followMode" AS "followMode",

        "chat"."date" AS "chatDate",
        "chat"."type" AS "chatType",
        "chat"."title" AS "chatTitle",
        "chat"."emoji" AS "chatEmoji",
        "chat"."parentMessageId" AS "parentMessageID",

        "peerUser"."firstName" AS "peerFirstName",
        "peerUser"."lastName" AS "peerLastName",
        "peerUser"."email" AS "peerEmail",
        "peerUser"."username" AS "peerUsername",
        "peerUser"."phoneNumber" AS "peerPhoneNumber",
        "peerUser"."profileFileId" AS "profileFileID",
        "peerUser"."profileFileUniqueId" AS "profileFileUniqueID",
        "peerUser"."profileCdnUrl" AS "profileCDNURL",
        "peerUser"."profileLocalPath" AS "profileLocalPath",

        "lastMessage"."messageId" AS "lastMessageID",
        "lastMessage"."date" AS "lastMessageDate",
        "lastMessage"."text" AS "lastMessageText",
        "lastMessage"."rev" AS "lastMessageRevision",
        "lastMessage"."isSticker" AS "lastMessageIsSticker",
        "lastMessage"."fileId" AS "lastMessageFileID",
        "lastMessage"."photoId" AS "lastMessagePhotoID",
        "lastMessage"."videoId" AS "lastMessageVideoID",
        "lastMessage"."documentId" AS "lastMessageDocumentID",
        "lastMessage"."contentPayload" AS "lastMessageContentPayload",
        "lastDocument"."fileName" AS "lastDocumentFileName",
        "lastSender"."firstName" AS "senderFirstName",
        "lastSender"."lastName" AS "senderLastName",
        "lastSender"."email" AS "senderEmail",
        "lastSender"."username" AS "senderUsername",
        "lastSender"."phoneNumber" AS "senderPhoneNumber",

        "draft2"."text" AS "draftText",
        "draft2"."revision" AS "draftRevision",
        CASE WHEN "draft2"."attachments" IS NULL THEN 0 ELSE 1 END AS "draftHasAttachments",
        "dialog"."draftMessage" AS "legacyDraftMessage",

        "anchorMessage"."text" AS "anchorMessageText",
        "anchorMessage"."messageId" AS "anchorMessageID",
        "anchorMessage"."isSticker" AS "anchorMessageIsSticker",
        "anchorMessage"."fileId" AS "anchorMessageFileID",
        "anchorMessage"."photoId" AS "anchorMessagePhotoID",
        "anchorMessage"."videoId" AS "anchorMessageVideoID",
        "anchorMessage"."documentId" AS "anchorMessageDocumentID",
        "anchorMessage"."contentPayload" AS "anchorMessageContentPayload"
      FROM "dialog"
      JOIN "chat"
        ON "chat"."id" = COALESCE("dialog"."chatId", "dialog"."peerThreadId")
      LEFT JOIN "user" AS "peerUser"
        ON "peerUser"."id" = "dialog"."peerUserId"
      LEFT JOIN "message" AS "lastMessage"
        ON "lastMessage"."chatId" = "chat"."id"
        AND "lastMessage"."messageId" = "chat"."lastMsgId"
      LEFT JOIN "user" AS "lastSender"
        ON "lastSender"."id" = "lastMessage"."fromId"
      LEFT JOIN "document" AS "lastDocument"
        ON "lastDocument"."documentId" = "lastMessage"."documentId"
      LEFT JOIN "draft2"
        ON "draft2"."peerKey" = CASE
          WHEN "dialog"."peerUserId" IS NOT NULL
            THEN 'user_' || CAST("dialog"."peerUserId" AS TEXT)
          ELSE 'thread_' || CAST("dialog"."peerThreadId" AS TEXT)
        END
      LEFT JOIN "message" AS "anchorMessage"
        ON "anchorMessage"."chatId" = "chat"."parentChatId"
        AND "anchorMessage"."messageId" = "chat"."parentMessageId"
      WHERE \(Dialog.chatListVisibilitySQL)
        AND \(scope.sql)
      ORDER BY "dialog"."id"
      """,
      arguments: scope.arguments
    )

    let rows = try request.fetchAll(db)
    guard rows.isEmpty == false else { return [] }
    #if DEBUG
    ChatListDatabaseRow.validateLayout(of: rows[0])
    #endif
    let hasLocalAvatarPath = rows.contains { rawRow in
      let row = ChatListDatabaseRow(rawRow)
      let path: String? = row[.profileLocalPath]
      return path?.isEmpty == false
    }
    let profileCacheDirectory = hasLocalAvatarPath
      ? FileHelpers.getLocalCacheDirectory(for: .photos)
      : nil
    return rows.compactMap { rawRow in
      makeSnapshot(
        from: ChatListDatabaseRow(rawRow),
        now: now,
        calendar: calendar,
        profileCacheDirectory: profileCacheDirectory
      )
    }
  }

  private static func makeSnapshot(
    from row: ChatListDatabaseRow,
    now: Date,
    calendar: Calendar,
    profileCacheDirectory: URL?
  ) -> ChatListItemSnapshot? {
    let peerUserID: Int64? = row[.peerUserID]
    let peerThreadID: Int64? = row[.peerThreadID]
    let peer: InlineKit.Peer
    if let peerUserID {
      peer = .user(id: peerUserID)
    } else if let peerThreadID {
      peer = .thread(id: peerThreadID)
    } else {
      return nil
    }

    let chatID: Int64 = row[.chatID]
    let chatType: String = row[.chatType]
    let isPrivateChat = chatType == ChatType.privateChat.rawValue
    let parentMessageID: Int64? = row[.parentMessageID]
    let isReplyThread = parentMessageID != nil
    let title: String
    let identity: ChatListIdentityDescriptor

    if let peerUserID {
      let profileCDNURL: String? = row[.profileCDNURL]
      let profileLocalPath: String? = row[.profileLocalPath]
      let descriptor = ChatListUserAvatarDescriptor(
        userID: peerUserID,
        firstName: row[.peerFirstName],
        lastName: row[.peerLastName],
        email: row[.peerEmail],
        username: row[.peerUsername],
        profileFileID: row[.profileFileID],
        profileFileUniqueID: row[.profileFileUniqueID],
        profileLocalPath: profileLocalPath,
        remoteURL: profileCDNURL.flatMap(URL.init(string:)),
        localURL: preparedAvatarLocalURL(
          path: profileLocalPath,
          directory: profileCacheDirectory
        )
      )
      title = userDisplayName(
        firstName: descriptor.firstName,
        lastName: descriptor.lastName,
        username: descriptor.username,
        email: descriptor.email,
        phoneNumber: row[.peerPhoneNumber]
      ) ?? "Loading..."
      identity = .user(descriptor)
    } else {
      title = threadTitle(
        rawTitle: row[.chatTitle],
        isReplyThread: isReplyThread,
        anchorPreview: messagePreview(MessagePreviewInput(
          messageID: row[.anchorMessageID],
          text: row[.anchorMessageText],
          isSticker: row[.anchorMessageIsSticker],
          fileID: row[.anchorMessageFileID],
          photoID: row[.anchorMessagePhotoID],
          videoID: row[.anchorMessageVideoID],
          documentID: row[.anchorMessageDocumentID],
          documentFileName: nil,
          contentPayloadData: row[.anchorMessageContentPayload]
        ))
      )
      identity = .thread(
        ChatListThreadIconDescriptor(
          emoji: normalizedEmoji(row[.chatEmoji]),
          title: title,
          isReplyThread: isReplyThread
        )
      )
    }

    let followMode: String? = row[.followMode]
    let isFollowed = followMode == "following"
    let draftPreview = makeDraftPreview(
      text: row[.draftText],
      hasAttachments: row[.draftHasAttachments],
      legacyDraftData: row[.legacyDraftMessage]
    )
    let lastMessagePreview = makeLastMessagePreview(row: row, chatType: chatType)
    let lastMessageDate: Date? = row[.lastMessageDate]
    let chatDate: Date? = row[.chatDate]
    let lastUpdatedAt = lastMessageDate ?? chatDate

    return ChatListItemSnapshot(
      peer: peer,
      chatID: chatID,
      spaceID: row[.spaceID],
      title: title,
      previewSenderName: draftPreview == nil ? lastMessagePreview?.senderName : nil,
      previewText: draftPreview ?? lastMessagePreview?.text,
      timestampText: ChatListDateFormatter.rowTitle(
        for: lastUpdatedAt,
        now: now,
        calendar: calendar
      ),
      identity: identity,
      unreadCount: max(row[.unreadCount] ?? 0, 0),
      unreadMark: row[.unreadMark] ?? false,
      prominence: peerUserID != nil || isPrivateChat || isFollowed ? .prominent : .standard,
      isOpen: row[.isOpen] ?? false,
      isPinned: row[.isPinned] ?? false,
      isFollowed: isFollowed,
      isChatListHidden: false,
      isArchived: row[.isArchived] ?? false,
      lastUpdatedAt: lastUpdatedAt,
      openedDate: row[.openedDate],
      order: row[.normalOrder],
      pinnedOrder: row[.pinnedOrder],
      contentSignature: ChatListContentSignature(
        messageID: row[.lastMessageID],
        messageRevision: row[.lastMessageRevision],
        draftRevision: row[.draftRevision]
      )
    )
  }

  private static func preparedAvatarLocalURL(path: String?, directory: URL?) -> URL? {
    guard let path, path.isEmpty == false, let directory else { return nil }
    let url = directory.appending(path: path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private static func makeLastMessagePreview(
    row: ChatListDatabaseRow,
    chatType: String
  ) -> LastMessagePreview? {
    guard let preview = messagePreview(MessagePreviewInput(
      messageID: row[.lastMessageID],
      text: row[.lastMessageText],
      isSticker: row[.lastMessageIsSticker],
      fileID: row[.lastMessageFileID],
      photoID: row[.lastMessagePhotoID],
      videoID: row[.lastMessageVideoID],
      documentID: row[.lastMessageDocumentID],
      documentFileName: row[.lastDocumentFileName],
      contentPayloadData: row[.lastMessageContentPayload]
    )) else {
      return nil
    }

    guard chatType == ChatType.thread.rawValue else {
      return LastMessagePreview(text: preview, senderName: nil)
    }
    guard let sender = userDisplayName(
      firstName: row[.senderFirstName],
      lastName: row[.senderLastName],
      username: row[.senderUsername],
      email: row[.senderEmail],
      phoneNumber: row[.senderPhoneNumber]
    ) else {
      return LastMessagePreview(text: preview, senderName: nil)
    }
    return LastMessagePreview(text: preview, senderName: sender)
  }

  private struct LastMessagePreview {
    let text: String
    let senderName: String?
  }

  private static func makeDraftPreview(
    text: String?,
    hasAttachments: Bool?,
    legacyDraftData: Data?
  ) -> String? {
    let legacyText = legacyDraftData.flatMap { data in
      try? InlineProtocol.DraftMessage(serializedBytes: data).text
    }
    if let text = singleLineText(text) ?? singleLineText(legacyText) {
      return "Draft: \(text)"
    }
    if hasAttachments == true {
      return "Draft: Attachment"
    }
    return nil
  }

  private static func messagePreview(_ input: MessagePreviewInput) -> String? {
    let payload = input.contentPayloadData.flatMap { data in
      try? Client_MessageContentPayload(serializedBytes: data)
    }
    if let payload, payload.hasServiceMessage,
       let fallback = singleLineText(payload.serviceMessage.fallbackText) {
      return fallback
    }
    if let text = singleLineText(input.text) {
      return text
    }
    if input.isSticker == true { return "Sticker" }
    if input.fileID != nil { return "File" }
    if input.photoID != nil { return "Photo" }
    if input.videoID != nil { return "Video" }
    if input.documentID != nil {
      return singleLineText(input.documentFileName) ?? "Document"
    }
    if payload?.hasVoice == true { return "Voice message" }
    return input.messageID == nil ? nil : "Message"
  }

  private static func threadTitle(
    rawTitle: String?,
    isReplyThread: Bool,
    anchorPreview: String?
  ) -> String {
    if let title = singleLineText(rawTitle) {
      return title
    }
    guard isReplyThread else { return "New thread" }
    guard let anchorPreview = singleLineText(anchorPreview) else { return "Re: Message" }
    return "Re: \(String(anchorPreview.prefix(72)))"
  }

  private static func userDisplayName(
    firstName: String?,
    lastName: String?,
    username: String?,
    email: String?,
    phoneNumber: String?
  ) -> String? {
    let directName = [singleLineText(firstName), singleLineText(lastName)]
      .compactMap { $0 }
      .joined(separator: " ")
    return singleLineText(directName)
      ?? singleLineText(username)
      ?? singleLineText(email)
      ?? singleLineText(phoneNumber)
  }

  private static func singleLineText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { $0.isEmpty == false }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji = singleLineText(emoji), let first = emoji.first else { return nil }
    return String(first)
  }

  private static func scopePredicate(
    spaceID: Int64?,
    includeSpaceChatsInHome: Bool
  ) -> (sql: String, arguments: StatementArguments) {
    if let spaceID {
      return (
        """
        (
          COALESCE("dialog"."spaceId", "chat"."spaceId") = ?
          OR "dialog"."peerUserId" IN (
            SELECT "member"."userId"
            FROM "member"
            WHERE "member"."spaceId" = ?
          )
        )
        """,
        StatementArguments([spaceID, spaceID])
      )
    }

    if includeSpaceChatsInHome == false {
      return (
        "COALESCE(\"dialog\".\"spaceId\", \"chat\".\"spaceId\") IS NULL",
        StatementArguments()
      )
    }

    return ("1 = 1", StatementArguments())
  }
}

private struct MessagePreviewInput {
  let messageID: Int64?
  let text: String?
  let isSticker: Bool?
  let fileID: String?
  let photoID: Int64?
  let videoID: Int64?
  let documentID: Int64?
  let documentFileName: String?
  let contentPayloadData: Data?
}
