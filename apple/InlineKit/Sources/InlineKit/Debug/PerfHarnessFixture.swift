#if DEBUG
import Foundation
import GRDB
import InlineProtocol
import Logger

/// Debug builds only: long synthetic chats for the macOS perf journeys (switch, scroll, resize),
/// seeded into the in-memory database `--perf-harness` selects. The app runs signed in as a fixture
/// user, so the real window, sidebar, chat route, message list and composer render this history
/// without a sign-in. Build the harness app against an unreachable dev host
/// (`USE_PRODUCTION_API=NO DEV_HOST=perf-harness.invalid`) so nothing reaches a server.
///
/// The history is deterministic: the same seed gives the same messages, senders, replies,
/// reactions and entities, so runs compare.
public enum PerfHarnessFixture {
  public static var isRequested: Bool { CommandLine.arguments.contains("--perf-harness") }

  public static let me: Int64 = 1
  static let spaceId: Int64 = 950

  struct ChatSpec {
    let id: Int64
    let peerUserId: Int64?
    let title: String?
    let emoji: String?
    let participants: [Int64]
    let messages: Int
  }

  /// Sidebar names the driver clicks: "Ava Stone" (the long scroll chat), "Ben Ortiz", "Cleo Park",
  /// "Design Review" and "Release Notes".
  static let chats: [ChatSpec] = [
    ChatSpec(id: 701, peerUserId: 2, title: nil, emoji: nil, participants: [me, 2], messages: 2_500),
    ChatSpec(id: 702, peerUserId: 3, title: nil, emoji: nil, participants: [me, 3], messages: 400),
    ChatSpec(id: 703, peerUserId: 4, title: nil, emoji: nil, participants: [me, 4], messages: 300),
    ChatSpec(id: 801, peerUserId: nil, title: "Design Review", emoji: "🎨", participants: [me, 2, 3, 4, 5, 6],
             messages: 700),
    ChatSpec(id: 802, peerUserId: nil, title: "Release Notes", emoji: "🚀", participants: [me, 3, 5, 6],
             messages: 300),
  ]

  /// Seeds the database once. Safe to call again: later launches take away what journeys added since.
  public static func seed(_ database: AppDatabase = .shared) {
    do {
      try database.dbWriter.write { db in
        guard try User.fetchOne(db, id: me) == nil else {
          try pruneJourneyAdditions(db)
          return
        }
        try seed(db)
      }
    } catch {
      Log.scoped("PerfHarnessFixture").error("Perf harness seed failed", error: error)
    }
  }

  /// Messages journeys added (received, sent, streamed: ids past each chat's seeded ones, and pending sends' negative
  /// ids) go at the next launch, so every run starts from the seed. Left there, they piled up at the chats' newest
  /// ends and changed what later runs measured (`rich-select` picked other blocks: 1 pass in 5, 2026-11-27).
  private static func pruneJourneyAdditions(_ db: Database) throws {
    // The seeded count of each chat: `chats`, Agent Notes (`seedRichChat`, 160) and Media Lab (`seedMediaChat`, 24).
    let seeded = chats.map { ($0.id, Int64($0.messages)) } + [(richChatId, Int64(160)), (mediaChatId, Int64(24))]
    for (chatId, count) in seeded {
      _ = try Message
        .filter(Column("chatId") == chatId && (Column("messageId") > count || Column("messageId") < 0))
        .deleteAll(db)
      _ = try Chat.filter(Column("id") == chatId).updateAll(db, Column("lastMsgId").set(to: count))
    }
  }

  /// A fixed "now", so every launch seeds the same timestamps and day separators.
  static let referenceDate = Date(timeIntervalSince1970: 1_794_000_000)

  private static func seed(_ db: Database) throws {
    let now = referenceDate
    let people: [(Int64, String, String, String)] = [
      (me, "Mo", "Rajabi", "mo"),
      (2, "Ava", "Stone", "ava"),
      (3, "Ben", "Ortiz", "ben"),
      (4, "Cleo", "Park", "cleo"),
      (5, "Dev", "Iyer", "dev"),
      (6, "Eli", "Novak", "eli"),
    ]
    for (id, first, last, username) in people {
      try User(id: id, email: "\(username)@example.com", firstName: first, lastName: last, username: username)
        .save(db)
    }
    try Space(id: spaceId, name: "Perf Lab", date: now).save(db)
    for (index, person) in people.enumerated() {
      try Member(id: Int64(2_000 + index), date: now, userId: person.0, spaceId: spaceId,
                 role: person.0 == me ? .owner : .member).save(db)
    }

    var rng = SplitMix64(seed: 0x1F2E_3D4C)
    var reactionId: Int64 = 50_000
    for (chatIndex, spec) in chats.enumerated() {
      var chat = Chat(
        id: spec.id,
        date: now.addingTimeInterval(-Double(chatIndex) * 60),
        type: spec.peerUserId == nil ? .thread : .privateChat,
        title: spec.title,
        spaceId: spec.peerUserId == nil ? spaceId : nil,
        peerUserId: spec.peerUserId,
        emoji: spec.emoji
      )
      try chat.save(db)
      for userId in spec.participants {
        try ChatParticipant(chatId: spec.id, userId: userId, date: now).save(db)
      }

      // Oldest first, a few messages a session, sessions spread over the last months so day
      // separators show up regularly.
      var date = now.addingTimeInterval(-Double(spec.messages) * 900 - Double(chatIndex) * 600)
      var sender = spec.participants[rng.next(spec.participants.count)]
      var runLeft = 0
      for messageId in Int64(1) ... Int64(spec.messages) {
        if runLeft == 0 {
          let others = spec.participants.filter { $0 != sender }
          sender = others[rng.next(others.count)]
          runLeft = 1 + rng.next(5)
        }
        runLeft -= 1
        date = date.addingTimeInterval(rng.chance(0.06) ? Double(4 + rng.next(30)) * 3_600 : Double(20 + rng.next(400)))
        let built = makeText(&rng)
        var message = Message(
          messageId: messageId,
          fromId: sender,
          date: date,
          text: built.text,
          peerUserId: spec.peerUserId,
          peerThreadId: spec.peerUserId == nil ? spec.id : nil,
          chatId: spec.id,
          out: sender == me,
          editDate: rng.chance(0.03) ? date.addingTimeInterval(120) : nil,
          repliedToMessageId: messageId > 10 && rng.chance(0.08)
            ? messageId - Int64(1 + rng.next(min(40, Int(messageId) - 1))) : nil,
          forwardFromUserId: rng.chance(0.02) ? 5 : nil,
          entities: built.entities.isEmpty ? nil : MessageEntities.with { $0.entities = built.entities }
        )
        if message.forwardFromUserId != nil {
          message.forwardFromPeerUserId = 5
          message.forwardFromMessageId = 1
        }
        try message.insert(db)

        if rng.chance(0.12) {
          let emojis = ["👍", "❤️", "😂", "🎉", "👀", "🔥"]
          for _ in 0 ..< 1 + rng.next(3) {
            reactionId += 1
            try Reaction(
              id: reactionId,
              messageId: messageId,
              userId: spec.participants[rng.next(spec.participants.count)],
              emoji: emojis[rng.next(emojis.count)],
              date: date.addingTimeInterval(60),
              chatId: spec.id
            ).insert(db, onConflict: .ignore)
          }
        }
      }

      chat.lastMsgId = Int64(spec.messages)
      try chat.save(db)
      var dialog = Dialog(optimisticForChat: chat)
      dialog.open = true
      dialog.unreadCount = 0
      dialog.readInboxMaxId = Int64(spec.messages)
      // Seeded as the server's read state, so the read sync has nothing to push.
      dialog.serverReadInboxMaxId = Int64(spec.messages)
      dialog.readOutboxMaxId = Int64(spec.messages)
      try dialog.save(db)
    }
    try seedBridgeChat(db, now: now)
    if CommandLine.arguments.contains("--timeline-journey") { try seedRichChat(db, now: now) }
    if mediaRequested { try seedMediaChat(db, now: now) }
  }

  // MARK: - Media, cards and service rows (timeline journey `media` only)

  /// `--perf-harness-media`: "Media Lab", the row kinds the other chats lack (photos, videos, documents with and
  /// without a thumbnail, link previews and a task in the attachments stack, reply-thread cards, service messages),
  /// each sent once by others and once by the fixture user. Local drawn files only; nothing loads from a network.
  public static var mediaRequested: Bool { CommandLine.arguments.contains("--perf-harness-media") }
  public static let mediaChatId: Int64 = 804

  private static func seedMediaChat(_ db: Database, now: Date) throws {
    var chat = Chat(
      id: mediaChatId, date: now, type: .thread, title: "Media Lab", spaceId: spaceId, peerUserId: nil, emoji: "🖼️"
    )
    try chat.save(db)
    for userId in [me, 2, 3] {
      try ChatParticipant(chatId: mediaChatId, userId: userId, date: now).save(db)
    }
    let kinds = 12
    let count = Int64(kinds * 2)
    for messageId in Int64(1) ... count {
      let index = Int(messageId - 1)
      let kind = index % kinds
      // First round from others (Ava and Ben in turns), second from the fixture user.
      let out = index >= kinds
      let from: Int64 = out ? me : (kind % 2 == 0 ? 2 : 3)
      let id = 10_000 + messageId
      var text: String?
      var photoId: Int64?
      var videoId: Int64?
      var documentId: Int64?
      var payload: Client_MessageContentPayload?
      var preview: UrlPreview?
      var task: ExternalTask?

      func photo(tall: Bool, number: Int64) throws -> Photo {
        let photo = try Photo(photoId: number, date: now, format: .jpeg).insertAndFetch(db)
        var size = PhotoSize(photoId: photo.id ?? 0, type: "f", width: 1_200, height: tall ? 1_600 : 800)
        size.localPath = DebugChatFixture.photoFile(tall: tall)
        try size.insert(db)
        return photo
      }

      switch kind {
        case 0:
          text = "Media Lab: photos, videos, files, links, tasks, thread cards and service rows, once each way."
        case 1:
          photoId = try photo(tall: false, number: 9_400_000 + id).photoId
        case 2:
          photoId = try photo(tall: true, number: 9_400_000 + id).photoId
          text = "From the offsite"
        case 3, 10:
          let thumbnail = try photo(tall: false, number: 9_500_000 + id)
          let video = Video(
            videoId: 7_400_000 + id, date: now, width: 1_280, height: 720, duration: kind == 3 ? 12 : 95, size: 1_000,
            thumbnailPhotoId: thumbnail.id, cdnUrl: nil, localPath: DebugChatFixture.videoFile()
          )
          try video.insert(db)
          videoId = video.videoId
          text = kind == 10 ? "Screen recording of the fling" : nil
        case 4, 5:
          let thumbnail = kind == 5 ? try photo(tall: false, number: 9_600_000 + id) : nil
          let document = Document(
            id: 6_400_000 + id, documentId: 6_400_000 + id, date: now,
            fileName: kind == 5 ? "row-cost-mockups.png" : "timeline-notes.pdf",
            mimeType: kind == 5 ? "image/png" : "application/pdf", size: kind == 5 ? 1_480_000 : 248_000,
            cdnUrl: nil, localPath: nil, thumbnailPhotoId: thumbnail?.id
          )
          try document.insert(db)
          documentId = document.documentId
          text = kind == 5 ? "Mockups attached" : nil
        case 6, 7:
          let withPhoto = kind == 6
          text = "Write-up: https://example.com/notes/row-cost-\(messageId)"
          preview = UrlPreview(
            id: 8_400_000 + id, url: "https://example.com/notes/row-cost-\(messageId)", siteName: "Example Notes",
            title: "How we cut the row cost in half",
            description: "Frame layout, pooled parts and fewer rebuilds: what moved the numbers and what didn't.",
            photoId: withPhoto ? try photo(tall: false, number: 9_700_000 + id).photoId : nil, duration: nil
          )
        case 8:
          text = "Thread for the scroll regressions"
          payload = .with {
            $0.replies = .with {
              $0.chatID = 9_800 + messageId
              $0.replyCount = out ? 2 : 7
              $0.recentReplierUserIds = out ? [2] : [2, 3, 1]
            }
          }
        case 9:
          text = "Pinned a message"
          payload = .with { $0.serviceMessage = .with { $0.pinnedMessage = .with { $0.messageID = messageId - 2 } } }
        default:
          text = "Tracking it here"
          task = try ExternalTask(
            application: "linear", taskId: "INL-\(700 + messageId)", status: out ? .inProgress : .todo,
            assignedUserId: 2, url: "https://linear.app/inline/issue/INL-\(700 + messageId)",
            title: "Measure the cell build on media rows", date: now, number: "INL-\(700 + messageId)"
          ).insertAndFetch(db)
      }

      let message = try Message(
        messageId: messageId, fromId: from, date: now.addingTimeInterval(Double(messageId - count) * 600), text: text,
        peerUserId: nil, peerThreadId: mediaChatId, chatId: mediaChatId, out: out, status: out ? .sent : nil,
        photoId: photoId, videoId: videoId, documentId: documentId, contentPayload: payload
      ).insertAndFetch(db)
      if let preview {
        try preview.insert(db)
      }
      if preview != nil || task != nil {
        try Attachment(
          messageId: message.globalId, externalTaskId: task?.id, urlPreviewId: preview?.id, attachmentId: 8_500_000 + id
        ).insert(db)
      }
    }
    chat.lastMsgId = count
    try chat.save(db)
    var dialog = Dialog(optimisticForChat: chat)
    dialog.open = true
    dialog.unreadCount = 0
    dialog.readInboxMaxId = count
    dialog.serverReadInboxMaxId = count
    dialog.readOutboxMaxId = count
    try dialog.save(db)
  }

  // MARK: - Rich blocks (timeline journey only)

  /// "Agent Notes": 160 messages, every other one rich (heading, lists, code, a quote, a table), the rest plain,
  /// with message 40 pinned. Seeded only with `--timeline-journey`, so the perf journeys' sidebar is unchanged.
  public static let richChatId: Int64 = 803

  private static func seedRichChat(_ db: Database, now: Date) throws {
    var chat = Chat(
      id: richChatId, date: now, type: .thread, title: "Agent Notes", spaceId: spaceId, peerUserId: nil, emoji: "🤖"
    )
    try chat.save(db)
    for userId in [me, 2, 5] {
      try ChatParticipant(chatId: richChatId, userId: userId, date: now).save(db)
    }
    var rng = SplitMix64(seed: 0x5EED_0803)
    let count: Int64 = 160
    for messageId in Int64(1) ... count {
      let date = now.addingTimeInterval(Double(messageId - count) * 240)
      let rich = messageId % 2 == 0
      let built = rich ? richText(&rng, index: Int(messageId)) : (makeText(&rng).text, nil)
      let message = Message(
        messageId: messageId, fromId: rich ? 5 : [me, 2][rng.next(2)], date: date, text: built.0,
        peerUserId: nil, peerThreadId: richChatId, chatId: richChatId, out: !rich && messageId % 3 == 0,
        blockContentPayload: built.1
      )
      try message.insert(db)
    }
    try PinnedMessage(chatId: richChatId, messageId: 40, position: 0).insert(db)
    chat.lastMsgId = count
    try chat.save(db)
    var dialog = Dialog(optimisticForChat: chat)
    dialog.open = true
    dialog.unreadCount = 0
    dialog.readInboxMaxId = count
    dialog.serverReadInboxMaxId = count
    dialog.readOutboxMaxId = count
    try dialog.save(db)
  }

  /// A rich agent reply: the blocks are ranges into the text, as the server sends them.
  private static func richText(_ rng: inout SplitMix64, index: Int) -> (String, BlockContentPayload?) {
    var text = ""
    func span(_ part: String) -> InlineProtocol.BlockText {
      if !text.isEmpty { text += "\n" }
      let offset = text.utf16.count
      text += part
      return .with {
        $0.offset = Int64(offset)
        $0.length = Int64(part.utf16.count)
      }
    }
    func paragraph(_ part: String) -> InlineProtocol.Block { .with { $0.paragraph = span(part) } }
    var blocks: [InlineProtocol.Block] = []
    blocks.append(.with { $0.heading = .with { $0.text = span("Step \(index / 2): \(words[rng.next(words.count)]) review"); $0.level = 2 } })
    blocks.append(paragraph(sentences[rng.next(sentences.count)] + " " + sentences[rng.next(sentences.count)]))
    let kind = index / 2 % 4
    if kind == 0 || kind == 2 {
      blocks.append(.with {
        $0.list = .with {
          $0.kind = kind == 0 ? .unordered : .ordered
          $0.items = (0 ..< 3).map { _ in .with { $0.children = [paragraph(sentences[rng.next(sentences.count)])] } }
        }
      })
    }
    if kind == 1 || kind == 2 {
      blocks.append(.with {
        $0.code = .with {
          $0.text = span("func measure(width: CGFloat) -> CGSize {\n  let plan = cache[width] ?? layout(width)\n  return plan.size\n}")
          $0.language = "swift"
        }
      })
    }
    if kind == 3 {
      blocks.append(.with { $0.quote = .with { $0.children = [paragraph(sentences[rng.next(sentences.count)])] } })
      blocks.append(.with {
        $0.table = .with {
          $0.alignments = [.left, .right, .center]
          $0.rows = [["Case", "Before", "After"], ["open", "212 ms", "48 ms"], ["fling", "9 ms", "4 ms"]].map { row in
            .with { $0.cells = row.map(span) }
          }
        }
      })
    }
    blocks.append(paragraph(sentences[rng.next(sentences.count)]))
    return (text, BlockContentPayload(.with { $0.blocks = blocks }))
  }

  // MARK: - Streaming a rich reply

  private static let richStreamParagraphWords = "Rolling the cache change out in three passes so each one can be checked against the numbers before the next one starts".split(separator: " ").map(String.init)
  private static let richStreamItems = [
    "Measure the open path on the seeded chats",
    "Turn the cache on for the main list and compare",
    "Watch the resize journey for dropped frames",
    "Remove the old path once both lists match",
  ]
  private static let richStreamClosingWords = "If any pass regresses the open time it goes back and the next one waits for a fix".split(separator: " ").map(String.init)
  private static let richStreamCodeLines = [
    "func rollOut(_ pass: Pass) async throws {",
    "  let before = try await measure(pass.journey)",
    "  try await pass.enable()",
    "  let after = try await measure(pass.journey)",
    "  guard after.openTime <= before.openTime * 1.02 else {",
    "    try await pass.disable()",
    "    throw RolloutError.regressed(pass, before: before, after: after)",
    "  }",
    "}",
  ]
  private static let richStreamTableRows = [
    ["Pass", "Open time", "Hitches", "Status"],
    ["1 · open path", "212 ms", "0", "done"],
    ["2 · main list", "198 ms", "1", "done"],
    ["3 · resize", "201 ms", "0", "running"],
    ["4 · cleanup", "—", "—", "waiting"],
  ]

  /// Code lines and table rows arrive a few at a time, as an agent's edits bring them: these many per snapshot.
  private static let richStreamCodeChunk = 3
  private static let richStreamTableChunks = [2, 2, 1]

  /// The steps of `richStreamSnapshot` that add code lines and table rows, for captures mid-way.
  public static var richStreamCodeAndTableSteps: (code: Range<Int>, table: Range<Int>) {
    let codeStart = richStreamParagraphWords.count + richStreamItems.count + richStreamClosingWords.count
    let codeSteps = (richStreamCodeLines.count + richStreamCodeChunk - 1) / richStreamCodeChunk
    let tableStart = codeStart + codeSteps
    return (codeStart ..< tableStart, tableStart ..< tableStart + richStreamTableChunks.count)
  }

  /// A rich agent reply as it streams, at `step`: a heading, a paragraph growing word by word, a list growing item by
  /// item, a closing paragraph growing, then a code block growing three lines at a time and a table two rows, two rows
  /// and one (the reveal still shows them a line and a row at a time). Each
  /// snapshot's text extends the last one's (an agent streams by editing its message with ever-longer snapshots), and
  /// the blocks are ranges into it, as the server sends them.
  public static func richStreamSnapshot(step: Int) -> (text: String, blocks: BlockContentPayload?, steps: Int) {
    let paragraphWords = richStreamParagraphWords
    let items = richStreamItems
    let closingWords = richStreamClosingWords
    let codeLines = richStreamCodeLines
    let tableRows = richStreamTableRows
    let parts = richStreamCodeAndTableSteps
    let steps = parts.table.upperBound
    let step = max(0, min(step, steps - 1))
    var text = ""
    func span(_ part: String) -> InlineProtocol.BlockText {
      if !text.isEmpty { text += "\n" }
      let offset = text.utf16.count
      text += part
      return .with {
        $0.offset = Int64(offset)
        $0.length = Int64(part.utf16.count)
      }
    }
    func paragraph(_ part: String) -> InlineProtocol.Block { .with { $0.paragraph = span(part) } }
    var blocks: [InlineProtocol.Block] = []
    blocks.append(.with { $0.heading = .with { $0.text = span("Rollout plan"); $0.level = 2 } })
    let shownWords = min(paragraphWords.count, step + 1)
    blocks.append(paragraph(paragraphWords.prefix(shownWords).joined(separator: " ")))
    let shownItems = max(0, min(items.count, step + 1 - paragraphWords.count))
    if shownItems > 0 {
      blocks.append(.with {
        $0.list = .with {
          $0.kind = .unordered
          $0.items = items.prefix(shownItems).map { item in .with { $0.children = [paragraph(item)] } }
        }
      })
    }
    let shownClosing = max(0, min(closingWords.count, step + 1 - paragraphWords.count - items.count))
    if shownClosing > 0 { blocks.append(paragraph(closingWords.prefix(shownClosing).joined(separator: " "))) }
    let shownCode = step < parts.code.lowerBound
      ? 0 : min(codeLines.count, (min(step, parts.code.upperBound - 1) - parts.code.lowerBound + 1) * richStreamCodeChunk)
    if shownCode > 0 {
      blocks.append(.with {
        $0.code = .with {
          $0.text = span(codeLines.prefix(shownCode).joined(separator: "\n"))
          $0.language = "swift"
        }
      })
    }
    let shownRows = step < parts.table.lowerBound
      ? 0 : richStreamTableChunks.prefix(step - parts.table.lowerBound + 1).reduce(0, +)
    if shownRows > 0 {
      let rows = tableRows.prefix(shownRows).map { row in row.map(span) }
      blocks.append(.with { $0.table = .with { table in table.rows = rows.map { cells in .with { $0.cells = cells } } } })
    }
    return (text, BlockContentPayload(.with { $0.blocks = blocks }), steps)
  }

  /// A long rich agent reply (for reading mid-way through a resize): a heading every eight paragraphs, each paragraph
  /// two to four sentences, `paragraphs` in all.
  public static func richLongSnapshot(paragraphs: Int = 48) -> (text: String, blocks: BlockContentPayload?) {
    let sentences = [
      "The open path reads the window from the database before the first frame.",
      "Rows are planned at the column's width and cached by message.",
      "A fling bakes its path once at the lift and runs on the render server.",
      "Streaming edits reveal at the rate they arrive, a line at a time.",
      "Pins follow every motion on the same clock as the content.",
      "Live resize keeps the reading row, and inside a tall message the passage.",
      "Reactions keep the row's cell, and the bar fades in as the bubble grows.",
    ]
    var text = ""
    func span(_ part: String) -> InlineProtocol.BlockText {
      if !text.isEmpty { text += "\n" }
      let offset = text.utf16.count
      text += part
      return .with {
        $0.offset = Int64(offset)
        $0.length = Int64(part.utf16.count)
      }
    }
    var blocks: [InlineProtocol.Block] = []
    for index in 0 ..< paragraphs {
      if index % 8 == 0 {
        blocks.append(.with { $0.heading = .with { $0.text = span("Part \(index / 8 + 1)"); $0.level = 2 } })
      }
      let count = 2 + index % 3
      let body = (0 ..< count).map { sentences[(index * 3 + $0) % sentences.count] }.joined(separator: " ")
      blocks.append(.with { $0.paragraph = span("\(index + 1). " + body) })
    }
    return (text, BlockContentPayload(.with { $0.blocks = blocks }))
  }

  /// Edits a message's text and blocks as the server's edit update does.
  public static func editRichMessage(
    peer: Peer, messageId: Int64, text: String, blocks: BlockContentPayload?, database: AppDatabase = .shared
  ) throws -> Bool {
    try database.dbWriter.write { db -> Bool in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer),
            var message = try Message.fetchOne(db, key: ["messageId": messageId, "chatId": chat.id])
      else { return false }
      message.text = text
      message.entities = nil
      message.blockContentPayload = blocks
      message.editDate = Date()
      message.rev += 1
      try message.saveMessage(db, publishChanges: true)
      return true
    }
  }

  // MARK: - Read journey

  /// What the chat list, the app icon and the Dock show for a chat.
  public struct ReadState: Sendable, Equatable {
    public let unreadCount: Int
    public let readInboxMaxId: Int64
    public let unreadMark: Bool
  }

  /// Certifies a chat's whole history, as a latest page from the server would, so the list's
  /// bottom is the chat's live end and reads the chat whole. The seed leaves every chat unknown.
  public static func certifyHistory(peer: Peer, database: AppDatabase = .shared) throws {
    try database.dbWriter.write { db in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return }
      try MessageHistoryCoverageStore.subtractAll(
        db, chatId: chat.id, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
  }

  /// A message from `fromId` landing as `UpdateNewMessage` lands one: the row, the chat's last
  /// message and one more unread in one write, published once it commits. Nil without the chat.
  public static func receiveMessage(peer: Peer, from fromId: Int64, database: AppDatabase = .shared) throws -> Int64? {
    try database.dbWriter.write { db -> Int64? in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return nil }
      let messageId = (chat.lastMsgId ?? 0) + 1
      var message = Message(
        messageId: messageId, fromId: fromId, date: Date(), text: "Arrived during the read journey",
        peerUserId: peer.asUserId(), peerThreadId: peer.asThreadId(), chatId: chat.id, out: false
      )
      try message.saveMessage(db, publishChanges: true)
      try Chat.updateLastMsgId(db, chatId: chat.id, lastMsgId: messageId, date: message.date)
      if var dialog = try Dialog.get(peerId: peer).fetchOne(db) {
        dialog.unreadCount = (dialog.unreadCount ?? 0) + 1
        try dialog.update(db)
      }
      return messageId
    }
  }

  public static func readState(peer: Peer, database: AppDatabase = .shared) throws -> ReadState? {
    try database.reader.read { db in
      try Dialog.get(peerId: peer).fetchOne(db).map {
        ReadState(
          unreadCount: $0.unreadCount ?? 0,
          readInboxMaxId: $0.readInboxMaxId ?? 0,
          unreadMark: $0.unreadMark == true
        )
      }
    }
  }

  // MARK: - Timeline journey (`--timeline-journey`)

  /// A chat message's stable row id (`FullMessage.id`: its global id) and text.
  public struct MessageRef: Sendable, Equatable {
    public let messageId: Int64
    public let globalId: Int64
    public let text: String
  }

  /// The chat's messages with ids in `ids` (all of them when nil), oldest first.
  public static func messages(peer: Peer, ids: [Int64]? = nil, database: AppDatabase = .shared) throws -> [MessageRef] {
    try database.reader.read { db in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return [] }
      var request = Message.filter(Column("chatId") == chat.id)
      if let ids { request = request.filter(ids.contains(Column("messageId"))) }
      return try request.order(Column("date").asc, Column("messageId").asc).fetchAll(db).compactMap { message in
        message.globalId.map { MessageRef(messageId: message.messageId, globalId: $0, text: message.text ?? "") }
      }
    }
  }

  /// The newest message, by date.
  public static func newestMessage(peer: Peer, database: AppDatabase = .shared) throws -> MessageRef? {
    try database.reader.read { db in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer),
            let message = try Message.filter(Column("chatId") == chat.id)
            .order(Column("date").desc, Column("messageId").desc).fetchOne(db),
            let globalId = message.globalId
      else { return nil }
      return MessageRef(messageId: message.messageId, globalId: globalId, text: message.text ?? "")
    }
  }

  /// An edit landing as `UpdateEditMessage` lands one: the text replaced, saved, and published
  /// (`messageUpdated`, not animated) once the write commits. Streaming agent messages arrive as a
  /// run of these. False without the message.
  @discardableResult
  public static func editMessage(peer: Peer, messageId: Int64, text: String, database: AppDatabase = .shared) throws -> Bool {
    try database.dbWriter.write { db -> Bool in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer),
            var message = try Message.fetchOne(db, key: ["messageId": messageId, "chatId": chat.id])
      else { return false }
      message.text = text
      message.entities = nil
      message.editDate = Date()
      message.rev += 1
      try message.saveMessage(db, publishChanges: true)
      return true
    }
  }

  /// Adds `userId`'s reaction to a message, or takes it off when it's there, as the app's reaction transaction does:
  /// saved, then the message published as updated (animated) on the main actor.
  public static func toggleReaction(
    peer: Peer, messageId: Int64, emoji: String, userId: Int64, database: AppDatabase = .shared
  ) throws {
    let chatId: Int64? = try database.dbWriter.write { db -> Int64? in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return nil }
      let existing = Reaction.filter(Column("chatId") == chat.id && Column("messageId") == messageId)
        .filter(Column("userId") == userId && Column("emoji") == emoji)
      if try existing.fetchCount(db) > 0 {
        _ = try existing.deleteAll(db)
      } else {
        _ = try Reaction.save(
          db, reaction: Reaction(messageId: messageId, userId: userId, emoji: emoji, date: Date(), chatId: chat.id)
        )
      }
      return chat.id
    }
    guard let chatId else { return }
    Task { @MainActor in
      MessagesPublisher.shared.messageUpdatedWithId(messageId: messageId, chatId: chatId, peer: peer, animated: true)
    }
  }

  /// Deletes as the server's delete update does: the rows go, then `messagesDeleted` on the main actor.
  public static func deleteMessages(peer: Peer, messageIds: [Int64], database: AppDatabase = .shared) throws {
    try database.dbWriter.write { db in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return }
      try Message.deleteMessages(db, messageIds: messageIds, chatId: chat.id)
      db.afterNextTransaction { _ in
        Task { @MainActor in MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peer) }
      }
    }
  }

  /// The optimistic half of a send, as `SendMessageTransaction.optimistic()` does it: a row with a
  /// temporary negative id, sending, from the fixture user, then `messageAddedSync` on the main actor.
  /// Returns the send's random id and the row's stable id.
  public static func insertPendingSend(
    peer: Peer, text: String, database: AppDatabase = .shared
  ) async throws -> (randomId: Int64, globalId: Int64)? {
    let randomId = Int64.random(in: 1 ... Int64.max / 2)
    let full = try await database.dbWriter.write { db -> FullMessage? in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return nil }
      let message = Message(
        messageId: -randomId, randomId: randomId, fromId: me, date: Date(), text: text,
        peerUserId: peer.asUserId(), peerThreadId: peer.asThreadId(), chatId: chat.id, out: true, status: .sending
      )
      try message.save(db)
      try Chat.updateLastMsgId(db, chatId: chat.id, lastMsgId: message.messageId, date: message.date)
      return try FullMessage.queryRequest()
        .filter(Column("messageId") == message.messageId).filter(Column("chatId") == chat.id).fetchOne(db)
    }
    guard let full, let globalId = full.message.globalId else { return nil }
    await MessagesPublisher.shared.messageAddedSync(fullMessage: full, peer: peer)
    return (randomId, globalId)
  }

  /// The server's acknowledgement of a send, as `UpdateMessageId.apply` lands it: the pending row takes
  /// the next real id and `sent`, published once it commits. Returns the real id.
  public static func confirmSend(peer: Peer, randomId: Int64, database: AppDatabase = .shared) throws -> Int64? {
    try database.dbWriter.write { db -> Int64? in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peer),
            var message = try Message.fetchOne(db, key: ["fromId": me, "randomId": randomId])
      else { return nil }
      let newest = try Message.filter(Column("chatId") == chat.id && Column("messageId") > 0)
        .order(Column("messageId").desc).fetchOne(db)?.messageId ?? 0
      message.status = .sent
      message.messageId = newest + 1
      message.randomId = nil
      try message.saveMessage(db, onConflict: .replace, publishChanges: true)
      try Chat.updateLastMsgId(db, chatId: chat.id, lastMsgId: message.messageId, date: message.date)
      return message.messageId
    }
  }

  // MARK: - Bridge output

  /// `--perf-harness-bridge <file>`: a DM with an agent whose messages are exactly what the CLI
  /// bridge rendered (see `BridgeManifest`), opened at launch.
  public static let bridgeAgentId: Int64 = 9
  public static var bridgeRequested: Bool { CommandLine.arguments.contains("--perf-harness-bridge") }

  private static func seedBridgeChat(_ db: Database, now: Date) throws {
    guard let manifest = BridgeManifest.fromArguments(flag: "--perf-harness-bridge") else { return }
    try User(id: bridgeAgentId, email: nil, firstName: manifest.agent, lastName: nil, username: "agent").save(db)
    let chatId: Int64 = 901
    var chat = Chat(
      id: chatId, date: now, type: .privateChat, title: nil, spaceId: nil, peerUserId: bridgeAgentId, emoji: nil
    )
    try chat.save(db)
    for userId in [me, bridgeAgentId] {
      try ChatParticipant(chatId: chatId, userId: userId, date: now).save(db)
    }
    let count = Int64(manifest.messages.count)
    for (index, item) in manifest.messages.enumerated() {
      let messageId = Int64(index + 1)
      var message = Message(
        messageId: messageId, fromId: bridgeAgentId,
        date: now.addingTimeInterval(Double(index - manifest.messages.count) * 30),
        text: item.text, peerUserId: bridgeAgentId, peerThreadId: nil, chatId: chatId, out: false,
        blockContentPayload: item.blocks, entities: item.entities
      )
      try message.insert(db)
    }
    chat.lastMsgId = count
    try chat.save(db)
    var dialog = Dialog(optimisticForChat: chat)
    dialog.open = true
    dialog.unreadCount = 0
    dialog.readInboxMaxId = count
    dialog.serverReadInboxMaxId = count
    dialog.readOutboxMaxId = count
    try dialog.save(db)
  }

  // MARK: - Text

  private static let sentences = [
    "Pushed the fix for the sidebar flicker, can you take a look when you get a minute?",
    "I think we should keep the old behavior for now and revisit after the release.",
    "The build is green again.",
    "Can we move the sync to tomorrow morning? I have a conflict at 10.",
    "Looks good to me, ship it.",
    "I left a few comments on the PR, mostly naming.",
    "Does anyone know why the cache is cold after a restart?",
    "We measured it twice and the numbers are consistent: about 40 percent faster on scroll.",
    "Not sure this is worth the complexity, the simple version covers most cases.",
    "Thanks!",
    "On it.",
    "Here is the summary from yesterday's call with the customer.",
    "They mostly care about search and notifications, less about themes.",
    "The migration ran fine on staging, rolling it out to everyone next.",
    "Let's pair on this after lunch.",
    "I'll write up the plan and share it in the thread.",
    "Heads up: the API returns a 429 when we page too fast.",
    "Good catch, I missed that edge case.",
    "Can you double check the copy on the empty state?",
    "We should probably add a test for this before we forget.",
    "Morning! Anything blocking you today?",
    "The new icon looks great on the dark background.",
    "I'm seeing the same crash on 27.2, attaching the log.",
    "Maybe we cache the layout per width bucket instead of per exact width.",
    "Agreed.",
    "That makes sense, thanks for explaining.",
    "Let me know if you need anything from me.",
    "Release candidate is up, please give it a spin.",
    "The draft got lost when I switched chats, can't reproduce it now though.",
    "Who owns the onboarding flow these days?",
  ]

  private static let words = [
    "layout", "cache", "scroll", "thread", "message", "release", "server", "client", "review", "draft",
    "window", "sidebar", "measure", "render", "frame", "budget", "profile", "trace", "fix", "test",
  ]

  private static func makeText(_ rng: inout SplitMix64) -> (text: String, entities: [MessageEntity]) {
    var text = ""
    var entities: [MessageEntity] = []

    func append(_ part: String, entity: MessageEntity.TypeEnum? = nil) {
      if !text.isEmpty, !text.hasSuffix("\n") { text += " " }
      let offset = text.utf16.count
      text += part
      if let entity {
        entities.append(.with {
          $0.type = entity
          $0.offset = Int64(offset)
          $0.length = Int64(part.utf16.count)
        })
      }
    }

    let roll = rng.next(100)
    let sentenceCount = roll < 50 ? 1 : roll < 85 ? 2 + rng.next(3) : 6 + rng.next(10)
    for index in 0 ..< sentenceCount {
      if sentenceCount > 5, index > 0, index % 4 == 0 { text += "\n\n" }
      append(sentences[rng.next(sentences.count)])
      if rng.chance(0.08) { append("https://example.com/\(words[rng.next(words.count)])/\(rng.next(9_000))", entity: .url) }
      if rng.chance(0.07) { append("\(words[rng.next(words.count)])Store.update()", entity: .code) }
      if rng.chance(0.05) { append("@\(["ava", "ben", "cleo", "dev"][rng.next(4)])", entity: .usernameMention) }
      if rng.chance(0.05) { append("really important", entity: .bold) }
    }
    if rng.chance(0.04) {
      text += "\n"
      append("func measure(width: CGFloat) -> CGSize {\n  layout.size(for: width)\n}", entity: .pre)
    }
    return (text, entities)
  }
}

/// Small deterministic generator so every harness launch seeds the same history.
struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextRaw() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A number in `0 ..< bound`.
  mutating func next(_ bound: Int) -> Int {
    Int(nextRaw() % UInt64(max(bound, 1)))
  }

  mutating func chance(_ probability: Double) -> Bool {
    Double(nextRaw() % 10_000) / 10_000 < probability
  }
}
#endif
