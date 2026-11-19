import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Peer info presentation")
struct PeerInfoPresentationTests {
  private let me: Int64 = 1

  private func thread(
    id: Int64 = 50,
    spaceId: Int64? = 9,
    isPublic: Bool = false,
    parentChatId: Int64? = nil,
    parentMessageId: Int64? = nil
  ) -> InlineKit.Chat {
    InlineKit.Chat(
      id: id,
      date: Date(timeIntervalSince1970: 0),
      type: .thread,
      title: "design",
      spaceId: spaceId,
      isPublic: isPublic,
      parentChatId: parentChatId,
      parentMessageId: parentMessageId
    )
  }

  private func user(_ id: Int64, bot: Bool = false) -> InlineKit.User {
    var user = InlineKit.User(id: id, email: nil, firstName: "Sam")
    user.bot = bot
    return user
  }

  // MARK: Subject

  @Test("own DM is Saved Messages, other DMs split by bot flag")
  func directSubjects() {
    #expect(PeerInfoSubject.resolve(peer: .user(id: me), chat: nil, user: user(me), currentUserId: me).kind == .selfChat)
    #expect(PeerInfoSubject.resolve(peer: .user(id: 2), chat: nil, user: user(2), currentUserId: me).kind == .person)
    #expect(PeerInfoSubject.resolve(peer: .user(id: 3), chat: nil, user: user(3, bot: true), currentUserId: me).kind == .bot)
  }

  @Test("threads with a parent are subthreads; Home threads have no space")
  func threadSubjects() {
    let top = PeerInfoSubject.resolve(peer: .thread(id: 50), chat: thread(), user: nil, currentUserId: me)
    #expect(top.kind == .thread)
    #expect(top.isHomeThread == false)

    let home = PeerInfoSubject.resolve(peer: .thread(id: 50), chat: thread(spaceId: nil), user: nil, currentUserId: me)
    #expect(home.isHomeThread)

    let reply = PeerInfoSubject.resolve(
      peer: .thread(id: 51),
      chat: thread(id: 51, parentChatId: 50, parentMessageId: 7),
      user: nil,
      currentUserId: me
    )
    #expect(reply.kind == .subthread)
    #expect(reply.parentChatId == 50)
    #expect(reply.parentMessageId == 7)
  }

  // MARK: Tabs

  @Test("tabs keep a fixed shape per subject")
  func tabs() {
    let person = PeerInfoSubject(kind: .person, peer: .user(id: 2))
    #expect(PeerInfoTab.tabs(for: person) == [.threads, .media, .files, .voice, .links])

    let saved = PeerInfoSubject(kind: .selfChat, peer: .user(id: me))
    #expect(PeerInfoTab.tabs(for: saved) == [.media, .files, .voice, .links])

    let thread = PeerInfoSubject(kind: .thread, peer: .thread(id: 50), spaceId: 9)
    #expect(PeerInfoTab.tabs(for: thread).first == .members)
    #expect(PeerInfoTab.tabs(for: thread).contains(.threads))

    let reply = PeerInfoSubject(kind: .subthread, peer: .thread(id: 51), parentChatId: 50)
    #expect(PeerInfoTab.tabs(for: reply).contains(.threads) == false)
  }

  // MARK: Actions

  @Test("Open leads away from the chat; Search leads over it where supported")
  func leadingAction() {
    let person = PeerInfoSubject(kind: .person, peer: .user(id: 2))
    let away = PeerInfoActionContext(isOverOwnChat: false, supportsInChatSearch: true)
    #expect(PeerInfoAction.actions(for: person, context: away) == [.open, .notifications])

    let over = PeerInfoActionContext(isOverOwnChat: true, supportsInChatSearch: true)
    #expect(PeerInfoAction.actions(for: person, context: over) == [.search, .notifications])

    let overWithoutSearch = PeerInfoActionContext(isOverOwnChat: true, supportsInChatSearch: false)
    #expect(PeerInfoAction.actions(for: person, context: overWithoutSearch) == [.notifications])
  }

  @Test("owned bridge bots get Output and Share; threads get Follow and Add")
  func subjectActions() {
    let bot = PeerInfoSubject(kind: .bot, peer: .user(id: 3))
    let owned = PeerInfoActionContext(
      isOverOwnChat: true,
      supportsInChatSearch: true,
      canShareBot: true,
      offersOutputMode: true
    )
    #expect(PeerInfoAction.actions(for: bot, context: owned) == [.search, .notifications, .output, .share])

    let thread = PeerInfoSubject(kind: .thread, peer: .thread(id: 50), spaceId: 9)
    let canAdd = PeerInfoActionContext(isOverOwnChat: false, supportsInChatSearch: true, canAddMembers: true)
    #expect(PeerInfoAction.actions(for: thread, context: canAdd) == [.open, .notifications, .follow, .addMembers])
  }

  @Test("Your own chat has no row over its own chat on a platform without search")
  func selfChatActions() {
    let saved = PeerInfoSubject(kind: .selfChat, peer: .user(id: me))
    let context = PeerInfoActionContext(isOverOwnChat: true, supportsInChatSearch: false)
    #expect(PeerInfoAction.actions(for: saved, context: context).isEmpty)
  }

  // MARK: Notifications

  @Test("the button names the mode in effect, not just the stored choice")
  func notificationTitles() {
    let inheritedMute = PeerInfoNotificationsPresentation(selection: .global, globalMode: .none)
    #expect(inheritedMute.isMuted)
    #expect(inheritedMute.title == "Muted")
    #expect(inheritedMute.detail == "Default")

    let mentions = PeerInfoNotificationsPresentation(selection: .mentions, globalMode: .all)
    #expect(mentions.title == "Mentions")
    #expect(mentions.detail == nil)

    let all = PeerInfoNotificationsPresentation(selection: .global, globalMode: .all)
    #expect(all.isMuted == false)
    #expect(all.systemImage == "bell")
  }

  @Test("quick toggle mutes, and unmutes to Default unless Default is muted too")
  func quickToggle() {
    #expect(PeerInfoNotificationsPresentation(selection: .global, globalMode: .all).quickToggleSelection == .none)
    #expect(PeerInfoNotificationsPresentation(selection: .none, globalMode: .all).quickToggleSelection == .global)
    #expect(PeerInfoNotificationsPresentation(selection: .none, globalMode: .none).quickToggleSelection == .all)
    #expect(PeerInfoNotificationsPresentation(selection: .global, globalMode: .none).quickToggleSelection == .all)
  }

  // MARK: Subtitles and fields

  @Test("person subtitle mirrors the DM header and never shows presence")
  func personSubtitle() {
    #expect(PeerInfoSubtitle.person(focusActive: false, localTime: nil) == nil)
    #expect(PeerInfoSubtitle.person(focusActive: false, localTime: "4:12 PM (-3 hr)") == "4:12 PM (-3 hr)")
    #expect(PeerInfoSubtitle.person(focusActive: true, localTime: nil) == "Notifications silenced")
    #expect(PeerInfoSubtitle.person(focusActive: true, localTime: "4:12 PM") == "Notifications silenced · 4:12 PM")
  }

  @Test("thread subtitle names the kind and counts members except for public threads")
  func threadSubtitle() {
    let privateThread = PeerInfoSubject(kind: .thread, peer: .thread(id: 50), spaceId: 9)
    #expect(PeerInfoSubtitle.thread(subject: privateThread, memberCount: 4) == "Private thread · 4 members")
    #expect(PeerInfoSubtitle.thread(subject: privateThread, memberCount: 1) == "Private thread · 1 member")

    let publicThread = PeerInfoSubject(kind: .thread, peer: .thread(id: 50), spaceId: 9, isPublic: true)
    #expect(PeerInfoSubtitle.thread(subject: publicThread, memberCount: 40) == "Public thread")

    let home = PeerInfoSubject(kind: .thread, peer: .thread(id: 50))
    #expect(PeerInfoSubtitle.thread(subject: home, memberCount: nil) == "Home thread")

    let reply = PeerInfoSubject(kind: .subthread, peer: .thread(id: 51), parentChatId: 50, parentMessageId: 7)
    #expect(PeerInfoSubtitle.thread(subject: reply, memberCount: 3) == "Reply thread · 3 members")
  }

  @Test("About fields are trimmed and empty ones dropped")
  func personFields() {
    var person = user(2)
    person.bio = "  Design  "
    person.username = ""
    person.email = "sam@example.com"
    person.timeZone = "Europe/Paris"
    let fields = PeerInfoPersonFields(user: person, localTime: { _ in "5 PM" })
    #expect(fields.bio == "Design")
    #expect(fields.username == nil)
    #expect(fields.email == "sam@example.com")
    #expect(fields.localTime == "5 PM")
    #expect(fields.isEmpty == false)

    #expect(PeerInfoPersonFields(user: user(3), localTime: { _ in nil }).isEmpty)
  }

  // MARK: Sidecar chats

  @Test("a sidecar chat that points at rows this device lacks still saves")
  func sidecarChatSave() throws {
    let database = AppDatabase.empty()
    var incoming = InlineProtocol.Chat()
    incoming.id = 77
    incoming.title = "release train"
    incoming.spaceID = 404
    incoming.createdBy = 999
    incoming.lastMsgID = 5
    try database.dbWriter.write { db in
      try InlineKit.Chat.saveSidecar(incoming, in: db)
    }
    let saved = try database.reader.read { db in try InlineKit.Chat.fetchOne(db, id: 77) }
    #expect(saved?.title == "release train")
    #expect(saved?.spaceId == nil)
    #expect(saved?.createdBy == nil)
    #expect(saved?.lastMsgId == nil)
  }
}

