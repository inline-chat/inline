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

  /// Seeds the database once. Safe to call again.
  public static func seed(_ database: AppDatabase = .shared) {
    do {
      try database.dbWriter.write { db in
        guard try User.fetchOne(db, id: me) == nil else { return }
        try seed(db)
      }
    } catch {
      Log.scoped("PerfHarnessFixture").error("Perf harness seed failed", error: error)
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
      dialog.readOutboxMaxId = Int64(spec.messages)
      try dialog.save(db)
    }
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
