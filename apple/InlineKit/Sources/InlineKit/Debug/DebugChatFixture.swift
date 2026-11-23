#if DEBUG
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import InlineProtocol

/// A signed-out, in-memory chat for list development (debug builds only):
/// hundreds of messages with names, replies, reactions, photos, RTL text,
/// service messages, day boundaries and an unread boundary, plus scripted
/// live updates published through its own `MessagesPublisher`.
@MainActor
public final class DebugChatFixture {
  public enum Opening: String, Sendable {
    case latest, unread, saved
  }

  public let database: AppDatabase
  public let publisher: MessagesPublisher
  public let peer: Peer
  public let chatId: Int64 = 1
  public let currentUserId: Int64 = 1
  /// The last read message id when opening at the unread line.
  public let unreadBoundary: Int64
  /// The saved reading place used by `.saved`.
  public let savedPlace: ChatReadingPlace
  private(set) var nextMessageId: Int64
  private var nextTemporaryId: Int64 = -1

  private static let users: [(Int64, String, String)] = [
    (1, "Me", "Self"), (2, "Alice", "Moreno"), (3, "Bob", "Okafor"), (4, "رنا", "حداد"), (5, "Dana", "Levi"),
  ]

  private nonisolated static let texts = [
    "ok",
    "On my way 🚲",
    "Can you look at the build when you have a minute? CI is red on main again.",
    "I pushed a fix for the keyboard glitch. The list now follows the composer on open and close, and interactive dismissal keeps the content under the finger. Let me know if anything looks off on the iPad.",
    "Three things before Friday:\n1. finish the adapter\n2. measure the first window\n3. write down what is missing compared to the old list",
    "مرحبا، هل يمكنك مراجعة التغييرات قبل الاجتماع؟",
    "שלום, אני אבדוק את זה אחרי הצהריים",
    "👍",
    "😂😂",
    "Here is a longer note with a link https://inline.chat/docs and a mention of the plan. We should keep paging smooth in both directions and never move the reading row when older messages arrive above it.",
    "Lunch?",
    "Agreed. Shipping it behind the debug switch first.",
  ]

  /// Messages below this id exist only "on the server" until `loadRemoteOlder` brings them in.
  private var remoteFloor: Int64
  private let seedStart: Date
  private let seedStep: TimeInterval
  private let seedNow: Date
  /// Messages each sender sends in a row.
  private let seedRun: Int

  /// Seeds `messageCount` messages ending now into `database` (a new
  /// in-memory one by default). With `remoteFloor`, messages below it are
  /// held back as remote history behind a coverage hole. `dense` sends them
  /// 45 s apart in runs of 12 per sender, so long sender groups form.
  public init(
    messageCount: Int = 420, remoteFloor: Int? = nil, dense: Bool = false,
    database: AppDatabase? = nil, publisher: MessagesPublisher? = nil
  ) throws {
    let database = try database ?? AppDatabase(
      DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "debug-fixture"))
    )
    self.database = database
    self.publisher = publisher ?? MessagesPublisher(database: database)
    peer = .thread(id: 1)
    let total = Int64(messageCount)
    unreadBoundary = total - 40
    savedPlace = ChatReadingPlace(messageId: total - min(180, total / 2), offset: 140)
    nextMessageId = total + 1
    let floor = Int64(remoteFloor ?? 1)
    self.remoteFloor = floor
    let chatId = chatId
    let now = Date()
    // Spread over four days so day separators fall inside the window (dense: 45 s apart).
    let start = dense ? now.addingTimeInterval(-45 * Double(messageCount) - 60) : now.addingTimeInterval(-86_400 * 3.2)
    let step = (now.timeIntervalSince(start) - 60) / Double(messageCount)
    let run = dense ? 12 : 3
    seedStart = start
    seedStep = step
    seedNow = now
    seedRun = run
    try database.dbWriter.write { db in
      for (id, first, last) in Self.users {
        try User(id: id, email: nil, firstName: first, lastName: last).insert(db)
      }
      try Chat(id: chatId, date: now.addingTimeInterval(-86_400 * 30), type: .thread, title: "List lab",
               spaceId: nil, lastMsgId: total).insert(db)
      for (id, _, _) in Self.users {
        try ChatParticipant(chatId: chatId, userId: id, date: now).insert(db)
      }
      for index in Int(floor) ... messageCount {
        try Self.seed(db, index: index, chatId: chatId, start: start, step: step, now: now, run: run)
      }
      try MessageHistoryCoverageStore.subtract(
        db, chatId: chatId, lowerId: floor, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      var dialog = Dialog(optimisticForChat: Chat(id: chatId, date: now, type: .thread, title: "List lab", spaceId: nil))
      dialog.unreadCount = 0
      try dialog.insert(db)
    }
    #if os(iOS)
    // On iOS, deletes and reloads reach only chats a screen has activated, as `ChatView` does.
    activeChat = self.publisher.activateChat(peer: peer)
    #endif
  }

  private nonisolated static func seed(
    _ db: Database, index: Int, chatId: Int64, start: Date, step: TimeInterval, now: Date, run runLength: Int = 3
  ) throws {
    let id = Int64(index)
    let run = (index / runLength) % 7
    // Albums: four photos every 41 messages, three every 47, a captioned pair every 61, three files
    // every 43, two photos and two files every 59, one sender each, kept off the messages the
    // other kinds own (service, agent blocks, files).
    let ownedElsewhere = index % 97 == 0 || index % 41 == 0 || index % 61 == 0
    let album: (start: Int, size: Int)? = if ownedElsewhere {
      nil
    } else if (20 ..< 24).contains(index % 41) {
      (index - index % 41 + 20, 4)
    } else if (30 ..< 32).contains(index % 61) {
      (index - index % 61 + 30, 2)
    } else if (10 ..< 13).contains(index % 47) {
      (index - index % 47 + 10, 3)
    } else if (5 ..< 8).contains(index % 43) {
      (index - index % 43 + 5, 3)
    } else if (40 ..< 44).contains(index % 59) {
      (index - index % 59 + 40, 4)
    } else {
      nil
    }
    // Which items are files: all of the 43s, the last two of the 59s.
    let albumFile = album.map { album in
      album.start % 43 == 5 && album.size == 3 || album.start % 59 == 40 && album.size == 4 && index - album.start >= 2
    } ?? false
    let senderRun = album.map { ($0.start / runLength) % 7 } ?? run
    let from: Int64 = [2, 2, 3, 1, 4, 5, 1][senderRun]
    var text: String? = Self.texts[(index * 7 + run) % Self.texts.count]
    var payload: Client_MessageContentPayload?
    var photoId: Int64?
    var groupedId: Int64?
    var documentId: Int64?
    if let album, albumFile {
      groupedId = 50_000 + Int64(album.start)
      let names = ["Roadmap.pdf", "design-assets.zip", "Budget 2027.xlsx", "Meeting notes.docx"]
      let document = Document(
        id: 6_000_000 + id, documentId: 6_000_000 + id, date: now, fileName: names[(index - album.start) % names.count],
        mimeType: "application/octet-stream", size: 120_000 * (index - album.start + 1), cdnUrl: nil,
        localPath: nil, thumbnailPhotoId: nil
      )
      try document.insert(db)
      documentId = document.documentId
      text = index == album.start && album.size == 3 ? "Files for Monday" : nil
    } else if let album {
      groupedId = 50_000 + Int64(album.start)
      photoId = 9_000 + id
      let photo = try Photo(photoId: 9_000 + id, date: now, format: .jpeg).insertAndFetch(db)
      // Four: a portrait or two among landscapes. Three: a portrait first (Telegram's column layout).
      let tall = album.size == 4 ? index % 3 == 1 : album.size == 3 && index == album.start
      var size = PhotoSize(photoId: photo.id ?? 0, type: "f", width: 1_200, height: tall ? 1_600 : 800)
      size.localPath = Self.photoFile(tall: tall)
      try size.insert(db)
      text = index == album.start && album.size == 2 ? "Two from the weekend"
        : index == album.start && album.size == 4 && album.start % 59 == 40 ? "Shots and the specs" : nil
    } else if index % 97 == 0 {
      text = "Pinned a message"
      payload = .with { $0.serviceMessage = .with { $0.pinnedMessage = .with { $0.messageID = id - 3 } } }
    } else if index % 29 == 0 {
      photoId = 9_000_000 + id
      let photo = try Photo(photoId: 9_000_000 + id, date: now, format: .jpeg).insertAndFetch(db)
      // Sizes reference the photo's local row id. A drawn local file, so a tap opens the gallery.
      var size = PhotoSize(photoId: photo.id ?? 0, type: "f", width: 1_200, height: index % 2 == 0 ? 800 : 1_600)
      size.localPath = Self.photoFile(tall: index % 2 != 0)
      try size.insert(db)
      if index % 2 == 0 { text = nil }
    }
    // Alice's even messages are sent for her by an agent: the agent badge and "Sent via Codex".
    // The agents rotate so every badge shows; Claude Code comes without a server name.
    if payload == nil, from == 2, index % 2 == 0, groupedId == nil {
      let agents = ["codex", "claude-code", "chatgpt", "opencode"]
      payload = .with { $0.via = .with { $0.app = agents[(index / 2) % agents.count] } }
    }
    var videoId: Int64?
    if photoId == nil, payload == nil, groupedId == nil, index % 53 == 0 {
      // A video with a drawn thumbnail and a stand-in file, so a tap opens the chat's gallery.
      let thumbnail = try Photo(photoId: 8_000_000 + id, date: now, format: .jpeg).insertAndFetch(db)
      var size = PhotoSize(photoId: thumbnail.id ?? 0, type: "f", width: 1_200, height: 600)
      size.localPath = Self.photoFile(tall: false)
      try size.insert(db)
      let video = Video(
        videoId: 7_000_000 + id, date: now, width: 1_280, height: 720, duration: 12, size: 1_000,
        thumbnailPhotoId: thumbnail.id, cdnUrl: nil, localPath: Self.videoFile()
      )
      try video.insert(db)
      videoId = video.videoId
      text = nil
    }
    // Agent replies with blocks every 41st message: a code block with lines wider than the bubble (it
    // scrolls sideways), a wide table, and a closed disclosure that opens in place.
    var blocks: BlockContentPayload?
    if photoId == nil, videoId == nil, payload == nil, index % 41 == 0 {
      let rich = Self.agentBlocks(variant: (index / 41) % 3)
      text = rich.text
      blocks = rich.payload
    }
    // A file every 61st message.
    if photoId == nil, videoId == nil, payload == nil, blocks == nil, index % 61 == 0 {
      let document = Document(
        id: 6_000_000 + id, documentId: 6_000_000 + id, date: now, fileName: "timeline-notes-\(index).pdf",
        mimeType: "application/pdf", size: 248_000, cdnUrl: nil, localPath: nil, thumbnailPhotoId: nil
      )
      try document.insert(db)
      documentId = document.documentId
      if index % 2 == 0 { text = nil }
    }
    var message = Message(
      messageId: id, fromId: from, date: start.addingTimeInterval(Double(index) * step), text: text,
      peerUserId: nil, peerThreadId: chatId, chatId: chatId, out: from == 1, status: from == 1 ? .sent : nil,
      repliedToMessageId: index % 11 == 0 && index > 5 && groupedId == nil ? id - 5 : nil, photoId: photoId,
      videoId: videoId, documentId: documentId, contentPayload: payload, blockContentPayload: blocks,
      groupedId: groupedId
    )
    try message.saveMessage(db)
    if index % 7 == 0 {
      for (offset, emoji) in ["👍", "❤️", "😂"].prefix(index % 3 + 1).enumerated() {
        try Reaction(id: id * 10 + Int64(offset), messageId: id, userId: Int64(offset + 2), emoji: emoji,
                     date: now, chatId: chatId).insert(db)
      }
    }
  }

  /// Message text and blocks whose ranges point into it, as an agent sends them.
  private nonisolated static func agentBlocks(variant: Int) -> (text: String, payload: BlockContentPayload?) {
    var text = ""
    func add(_ string: String) -> BlockText {
      if !text.isEmpty { text += "\n" }
      let start = (text as NSString).length
      text += string
      return .with {
        $0.offset = Int64(start)
        $0.length = Int64((string as NSString).length)
      }
    }
    var blocks: [Block] = []
    switch variant {
      case 0:
        blocks.append(.with { $0.paragraph = add("The fix keeps the reading row in place when older pages arrive:") })
        let code = add("""
        func apply(_ transaction: TimelineTransaction) {
          let anchor = layout.anchor(nearest: viewport.midY) // the row the reader is looking at, kept where it is
          solver.place(transaction.changed, keeping: anchor, margins: TimelineMargins(span: 900, ahead: 1_200, behind: 600))
        }
        """)
        blocks.append(.with { $0.code = .with { $0.text = code; $0.language = "swift" } })
      case 1:
        blocks.append(.with { $0.paragraph = add("Fling stalls by device and fixture:") })
        let header = ["Device", "Fixture", "Frames", "Stalls", "Longest", "Notes"].map(add)
        let rows = [
          ["iPhone SE", "normal", "2,310", "4", "71 ms", "first page load"],
          ["iPhone 17e", "dense", "2,284", "4", "68 ms", "long sender groups"],
        ].map { $0.map(add) }
        blocks.append(.with {
          $0.table = .with { table in
            table.rows = ([header] + rows).map { cells in .with { $0.cells = cells } }
          }
        })
      default:
        blocks.append(.with { $0.paragraph = add("Done. Three places changed.") })
        let summary = add("Details")
        let children: [Block] = [
          .with { $0.paragraph = add("The keyboard coordinator measures again after a rotation.") },
          .with { $0.paragraph = add("The date pill's tap no longer puts the keyboard away.") },
          .with { $0.paragraph = add("History paging waits for the next drag after a failed page.") },
        ]
        blocks.append(.with {
          $0.disclosure = .with {
            $0.summary = summary
            $0.initiallyOpen = false
            $0.children = children
          }
        })
    }
    return (text, BlockContentPayload(.with { $0.blocks = blocks }))
  }

  /// A stand-in video file in the video cache (not playable); its local path.
  private nonisolated static func videoFile() -> String? {
    let name = "debug-fixture-video.mp4"
    let url = FileHelpers.getLocalCacheDirectory(for: .videos).appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: Data(count: 1_000)) else { return nil }
    }
    return name
  }

  /// A drawn JPEG in the photo cache (a diagonal gradient), written once per shape; its local path.
  private nonisolated static func photoFile(tall: Bool) -> String? {
    let name = tall ? "debug-fixture-tall.jpg" : "debug-fixture-wide.jpg"
    let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { return name }
    let width = 600, height = tall ? 800 : 400
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    let colors = [CGColor(red: 0.98, green: 0.6, blue: 0.3, alpha: 1), CGColor(red: 0.3, green: 0.45, blue: 0.95, alpha: 1)]
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])
    else { return nil }
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? name : nil
  }

  /// Simulates a server page of older history: up to `limit` messages below
  /// the remote floor are written and their range certified. False when none remain.
  public func loadRemoteOlder(limit: Int = 100, latency: Duration = .milliseconds(600)) async throws -> Bool {
    guard remoteFloor > 1 else { return false }
    try await Task.sleep(for: latency)
    let upper = remoteFloor - 1
    let lower = max(1, upper - Int64(limit) + 1)
    let (chatId, start, step, now, run) = (chatId, seedStart, seedStep, seedNow, seedRun)
    try await database.dbWriter.write { db in
      for index in Int(lower) ... Int(upper) {
        try Self.seed(db, index: index, chatId: chatId, start: start, step: step, now: now, run: run)
      }
      try MessageHistoryCoverageStore.subtract(db, chatId: chatId, lowerId: lower, upperId: upper)
    }
    remoteFloor = lower
    return true
  }

  /// Simulates fetching the history around `messageId`: remote pages arrive until it is stored.
  public func loadRemoteAround(messageId: Int64, latency: Duration = .milliseconds(600)) async throws {
    while remoteFloor > max(1, messageId - 20) {
      guard try await loadRemoteOlder(limit: 200, latency: latency) else { return }
    }
  }

  #if os(iOS)
  private var activeChat: MessagesPublisher.ActiveChatToken?
  #endif

  /// The prepared first frame for an opening, as `ChatOpenPreparation` reads it.
  public func initialState(
    for opening: Opening, limit: Int? = nil
  ) async throws -> MessagesProgressiveViewModel.InitialState {
    let unreadCount = opening == .unread ? Int(nextMessageId - 1 - unreadBoundary) : 0
    let boundary: Int64? = opening == .unread ? unreadBoundary : nil
    let chatId = chatId
    try await database.dbWriter.write { db in
      try Dialog.filter(Column("chatId") == chatId).updateAll(
        db,
        Column("unreadCount").set(to: unreadCount),
        Column("readInboxMaxId").set(to: boundary),
        // As the server's read state, so the read sync has nothing to push.
        Column("serverReadInboxMaxId").set(to: boundary)
      )
    }
    return try await MessagesProgressiveViewModel.prepareInitialState(
      peer: peer, chatId: chatId, limit: limit ?? MessagesProgressiveViewModel.defaultInitialLimit(),
      savedPlace: opening == .saved ? savedPlace : nil,
      database: database, publisher: publisher, currentUserId: currentUserId
    )
  }

  // MARK: Scripted updates

  private func fetch(globalId: Int64) throws -> FullMessage? {
    try database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: currentUserId).filter(id: globalId).fetchOne(db)
    }
  }

  private func insert(
    text: String, from: Int64, messageId: Int64, status: MessageSendingStatus? = nil,
    replyToMessageId: Int64? = nil, randomId: Int64? = nil
  ) throws -> FullMessage? {
    let chatId = chatId
    let saved = try database.dbWriter.write { db -> Message in
      var message = Message(
        messageId: messageId, randomId: randomId ?? (messageId < 0 ? Int64.random(in: 1 ... .max) : nil), fromId: from,
        date: Date(), text: text, peerUserId: nil, peerThreadId: chatId, chatId: chatId, out: from == currentUserId,
        status: status, repliedToMessageId: replyToMessageId
      )
      return try message.saveMessage(db)
    }
    return try saved.globalId.flatMap(fetch(globalId:))
  }

  /// The production composer's send, into this chat: a pending row, then the ack.
  /// `randomId` and `temporaryMessageId` are the composer transaction's, so the composer's send
  /// animation finds the pending row as it would a real send.
  public func sendFromComposer(
    text: String, replyToMessageId: Int64?, randomId: Int64? = nil, temporaryMessageId: Int64? = nil
  ) async throws {
    try await sendAndAcknowledge(
      text: text, replyToMessageId: replyToMessageId, randomId: randomId, temporaryMessageId: temporaryMessageId
    )
  }

  /// The production composer's edit of a message (server id).
  public func editFromComposer(messageId: Int64, text: String) throws {
    let chatId = chatId
    guard let message = try database.reader.read({ db in
      try FullMessage.queryRequest(currentUserId: currentUserId)
        .filter(Column("chatId") == chatId && Column("messageId") == messageId).fetchOne(db)
    }) else { return }
    try setText(text, of: message)
  }

  /// Someone else's message arrives.
  public func receive() throws {
    defer { nextMessageId += 1 }
    guard let message = try insert(text: "Incoming \(nextMessageId)", from: 2, messageId: nextMessageId) else { return }
    publisher.publisher.send(.add(.init(messages: [message], peer: peer)))
  }

  /// The current user sends; the server acknowledges after `delay`.
  public func sendAndAcknowledge(
    text: String = "Sent from the harness", replyToMessageId: Int64? = nil,
    after delay: Duration = .milliseconds(700), randomId: Int64? = nil, temporaryMessageId: Int64? = nil
  ) async throws {
    let temporary = temporaryMessageId ?? nextTemporaryId
    if temporaryMessageId == nil { nextTemporaryId -= 1 }
    guard let pending = try insert(text: text, from: currentUserId, messageId: temporary,
                                   status: .sending, replyToMessageId: replyToMessageId, randomId: randomId)
    else { return }
    publisher.publisher.send(.add(.init(messages: [pending], peer: peer)))
    try await Task.sleep(for: delay)
    let serverId = nextMessageId
    nextMessageId += 1
    try await database.dbWriter.write { db in
      try Message.filter(Column("globalId") == pending.id).updateAll(
        db, Column("messageId").set(to: serverId), Column("status").set(to: MessageSendingStatus.sent.rawValue)
      )
    }
    if let acked = try fetch(globalId: pending.id) {
      publisher.publisher.send(.update(.init(message: acked, animated: true, peer: peer)))
    }
  }

  private func newest() throws -> FullMessage? {
    try database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: currentUserId)
        .filter(Column("chatId") == chatId).order(Column("date").desc).fetchOne(db)
    }
  }

  private func setText(_ text: String, of message: FullMessage) throws {
    try database.dbWriter.write { db in
      try Message.filter(Column("globalId") == message.id).updateAll(
        db, Column("text").set(to: text), Column("editDate").set(to: Date())
      )
    }
    if let updated = try fetch(globalId: message.id) {
      publisher.publisher.send(.update(.init(message: updated, animated: true, peer: peer)))
    }
  }

  /// The server id of the current user's newest sent message.
  public func newestOutgoingMessageId() throws -> Int64? {
    let chatId = chatId
    return try database.reader.read { db in
      try Message.filter(Column("chatId") == chatId && Column("out") == true && Column("messageId") > 0)
        .order(Column("messageId").desc).fetchOne(db)?.messageId
    }
  }

  /// The newest message is edited once.
  public func edit() throws {
    guard let message = try newest() else { return }
    try setText((message.message.text ?? "") + " (edited, now a bit longer than before)", of: message)
  }

  /// The newest message grows by a few words `steps` times, like a streaming reply.
  public func stream(steps: Int = 12, every interval: Duration = .milliseconds(120)) async throws {
    guard var message = try newest() else { return }
    var text = message.message.text ?? ""
    for step in 1 ... steps {
      text += step % 4 == 0 ? "\nNext line \(step)." : " more words \(step)"
      try setText(text, of: message)
      message = try fetch(globalId: message.id) ?? message
      try await Task.sleep(for: interval)
    }
  }

  /// The current user's reaction toggled as the app sends one: saved (or removed) and published at once, as
  /// the transaction's optimistic step does, then published again a round trip later, as the server's
  /// `UpdateReaction` is applied (its save finds the reaction already there and publishes all the same).
  public func toggleReaction(emoji: String, messageId: Int64, roundTrip: Duration = .milliseconds(300)) async throws {
    let chatId = chatId
    let userId = currentUserId
    try await database.dbWriter.write { db in
      let mine = Reaction.filter(Column("chatId") == chatId && Column("messageId") == messageId)
        .filter(Column("userId") == userId && Column("emoji") == emoji)
      if try mine.fetchCount(db) > 0 {
        _ = try mine.deleteAll(db)
      } else {
        _ = try Reaction.save(db, reaction: Reaction(id: 90_000_000 + messageId * 100 + Int64(emoji.unicodeScalars.first?.value ?? 0) % 100, messageId: messageId, userId: userId, emoji: emoji, date: Date(), chatId: chatId))
      }
    }
    try publishUpdate(messageId: messageId)
    try await Task.sleep(for: roundTrip)
    try publishUpdate(messageId: messageId)
  }

  private func publishUpdate(messageId: Int64) throws {
    let chatId = chatId
    let currentUserId = currentUserId
    guard let message = try database.reader.read({ db in
      try FullMessage.queryRequest(currentUserId: currentUserId)
        .filter(Column("chatId") == chatId && Column("messageId") == messageId).fetchOne(db)
    }) else { return }
    publisher.publisher.send(.update(.init(message: message, animated: true, peer: peer)))
  }

  /// A message is deleted, wherever it is.
  public func delete(messageId: Int64) throws {
    let chatId = chatId
    _ = try database.dbWriter.write { db in
      try Message.filter(Column("chatId") == chatId && Column("messageId") == messageId).deleteAll(db)
    }
    publisher.messagesDeleted(messageIds: [messageId], peer: peer)
  }

  /// The server id the next received message will get.
  public var upcomingMessageId: Int64 { nextMessageId }

  /// The newest message is deleted.
  public func deleteNewest() throws {
    guard let message = try newest() else { return }
    let (chatId, messageId) = (chatId, message.message.messageId)
    _ = try database.dbWriter.write { db in
      try Message.filter(Column("chatId") == chatId && Column("messageId") == messageId).deleteAll(db)
    }
    publisher.messagesDeleted(messageIds: [message.message.messageId], peer: peer)
  }

  /// Translations of the newest `count` messages arrive, stored and published as `TranslationViewModel`
  /// stores and publishes them. They show once translation is on for the chat.
  public func translateNewest(count: Int = 12, language: String) throws {
    let chatId = chatId
    let ids = try database.dbWriter.write { db -> [Int64] in
      let messages = try Message.filter(Column("chatId") == chatId && Column("messageId") > 0)
        .order(Column("messageId").desc).limit(count).fetchAll(db)
      for message in messages {
        try Translation(
          messageId: message.messageId, chatId: chatId,
          translation: "Translated (\(language)): " + (message.text ?? "") + " — and a few more words.",
          entities: nil, language: language, date: Date(), msgRev: 0
        ).insert(db, onConflict: .replace)
      }
      return messages.compactMap(\.globalId)
    }
    for id in ids {
      if let message = try fetch(globalId: id) {
        publisher.publisher.send(.update(.init(message: message, animated: false, peer: peer)))
      }
    }
  }

  /// A reload whose content is unchanged.
  public func refreshIdentical() {
    publisher.messagesReload(peer: peer, animated: false)
  }

  /// A catch-up that wrote three messages to the database, then a reload.
  public func refreshAddingThree() throws {
    for _ in 0 ..< 3 {
      _ = try insert(text: "Caught up \(nextMessageId)", from: 3, messageId: nextMessageId)
      nextMessageId += 1
    }
    publisher.messagesReload(peer: peer, animated: false)
  }
}
#endif
