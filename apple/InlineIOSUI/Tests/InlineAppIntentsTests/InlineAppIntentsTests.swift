import Auth
import AppIntents
import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineAppIntents

@Suite("Inline App Intents")
struct InlineAppIntentsTests {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  @Test("Siri person identity is account scoped and confirmation disambiguates names")
  func siriPersonIdentity() {
    let person = InlineSiriPersonEntity(userID: Int64.max, accountID: 99, name: "Sam", username: "sam-work")
    #expect(person.userID(for: 99) == Int64.max)
    #expect(person.userID(for: 98) == nil)
    #expect(person.confirmationName == "Sam (@sam-work)")
    let selfPerson = InlineSiriPersonEntity(userID: 99, accountID: 99, name: "Me")
    #expect(selfPerson.person.isMe)
    #expect(selfPerson.confirmationName == "Saved Messages")
    let noUsername = InlineSiriPersonEntity(userID: 50, accountID: 99, name: "Sam")
    #expect(noUsername.confirmationName == "Sam (50)")
  }

  @available(iOS 27.0, macOS 27.0, *)
  @Test("spoken names retain ambiguous recipients and explicit IDs never cross accounts")
  func siriPersonNames() {
    var payload = GetChatsResult()
    payload.users = [
      .with { $0.id = 10; $0.firstName = "Alex"; $0.lastName = "Chen" },
      .with { $0.id = 11; $0.firstName = "Alex"; $0.lastName = "Rivera" },
    ]
    let inbox = InlineIntentInbox(payload, accountID: 99)
    let nameOnly = IntentPerson(identifier: .unknown, name: .displayName("Alex"), handle: nil)
    #expect(InlineSiriPersonQuery.name(of: nameOnly) == "Alex")
    #expect(InlineSiriPersonQuery.people(matchingPersonName: "Alex", in: inbox).map(\.id) == ["p1:99:10", "p1:99:11"])
    var components = PersonNameComponents()
    components.givenName = "Alex"
    components.familyName = "Chen"
    #expect(InlineSiriPersonQuery.name(of: IntentPerson(identifier: .contact("device-contact"), name: .components(components), handle: nil)) == "Alex Chen")
    #expect(InlineSiriPersonQuery.name(of: IntentPerson(identifier: .unknown, name: .unknown, handle: nil)) == nil)
    #expect(InlineSiriPersonQuery.person(forApplicationIdentifier: "p1:98:10", in: inbox) == nil)
  }
  @available(iOS 27.0, macOS 27.0, *)
  @Test("first-DM entity hydration resolves fresh IDs without a conversation or a cached name")
  func firstDMPersonHydration() {
    let inbox = InlineIntentInbox.empty(accountID: 99)
    let fresh = InlineProtocol.User.with { $0.id = 10; $0.firstName = "New Name"; $0.username = "newusername" }
    let people = InlineSiriPersonQuery.rehydratedPeople(
      ["p1:99:10", "p1:99:10", "p1:98:10", "p1:99:11"], in: inbox, fetchedUsers: [fresh]
    )
    #expect(people.map(\.id) == ["p1:99:10"])
    #expect(people.first?.inlineDisplayName == "New Name")
    #expect(people.first?.username == "newusername")
    #expect(inbox.conversations.isEmpty)
    #expect(InlineSiriPersonQuery.rehydratedPeople(["p1:99:10"], in: inbox, fetchedUsers: []).isEmpty)
    let peopleOnly = InlineIntentInbox(.with { $0.users = [fresh] }, accountID: 99)
    #expect(InlineSiriPersonQuery.person(forApplicationIdentifier: "inline:username:NEWUSERNAME", in: peopleOnly)?.id == "p1:99:10")
  }

  @available(iOS 27.0, macOS 27.0, *)
  @Test("a reassigned username cannot replace the stable identity carried by a Siri alias")
  func renamedPersonAlias() throws {
    let transferred = IntentPerson(
      identifier: .unknown, name: .displayName("Original Person"),
      handle: .init(applicationDefined: "inline:username:oldname", label: "Inline"),
      aliases: [.init(applicationDefined: "inline:user:10", label: "Inline")]
    )
    let original = InlineProtocol.User.with { $0.id = 10; $0.firstName = "Original Person"; $0.username = "newname" }
    let newOwner = InlineProtocol.User.with { $0.id = 11; $0.firstName = "Different Person"; $0.username = "oldname" }
    let inbox = InlineIntentInbox(.with { $0.users = [original, newOwner] }, accountID: 99)
    let identifiers = InlineSiriPersonQuery.applicationIdentifiers(of: transferred)
    let resolved = try #require(identifiers.first.flatMap { InlineSiriPersonQuery.person(forApplicationIdentifier: $0, in: inbox) })
    #expect(resolved.id == "p1:99:10")
    #expect(resolved.username == "newname")
    let unavailable = InlineIntentInbox(.with { $0.users = [newOwner] }, accountID: 99)
    #expect(InlineSiriPersonQuery.rehydratedPeople([resolved.id], in: unavailable, fetchedUsers: []).isEmpty)

    let wrongAccount = IntentPerson(
      identifier: .applicationDefined("p1:98:10"), name: .displayName("Original Person"),
      handle: transferred.handle, aliases: transferred.aliases
    )
    let imported = InlineSiriPersonQuery.applicationIdentifiers(of: wrongAccount).compactMap {
      InlineSiriPersonQuery.person(forApplicationIdentifier: $0, in: inbox)
    }
    #expect(imported.isEmpty)
  }
  #endif

  @Test("saved identity keeps account and chat namespaces separate at full Int64 precision")
  func identity() throws {
    let id = InlineIntentChatID(accountID: 123, chatID: Int64.max)
    #expect(InlineIntentChatID(id.rawValue) == id)
    #expect(id.rawValue != InlineIntentChatID(accountID: 124, chatID: Int64.max).rawValue)
    for invalid in ["123", "v2:123:456", "v1:0:1", "v1:1:-1", "v1:1:2:3", "v1::2"] {
      #expect(InlineIntentChatID(invalid) == nil)
    }
  }

  @Test("suggestions omit hidden and archived rows while closed chats remain accessible")
  func eligibility() throws {
    var result = GetChatsResult()
    insertChat(1, title: "Visible", into: &result)
    insertChat(2, title: "Hidden", hidden: true, into: &result)
    insertChat(4, title: "Archived", archived: true, into: &result)
    result.chats.append(.with { $0.id = 5; $0.peerID.chat.chatID = 5 })
    let inbox = InlineIntentInbox(result, accountID: 99)
    #expect(InlineIntentChatStore.fetch(in: inbox).map(\.id.chatID) == [1])
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "Visible").map(\.id.chatID) == [1])
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "Hidden").isEmpty)
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "Archived").isEmpty)
    #expect(try inbox.conversation("v1:99:1").dialog.open == false)
    #expect(InlineIntentChatStore.fetch(in: inbox, chatIDs: [1, 2, 3, 4, 5]).map(\.id.chatID) == [1, 2, 4])
    #expect(InlineIntentChatStore.fetch(in: inbox, chatIDs: []).isEmpty)
  }

  @Test("an authorized explicit hidden or archived chat is projected without changing placement")
  func explicitPresentationStateIsNotAccess() throws {
    var response = GetChatResult.with {
      $0.chat.id = 7
      $0.chat.title = "Hidden Reply"
      $0.chat.peerID.chat.chatID = 7
      $0.dialog.chatID = 7
      $0.dialog.peer.chat.chatID = 7
      $0.dialog.open = false
      $0.dialog.archived = true
      $0.dialog.chatListHidden = true
    }
    let resolved = try InlineIntentInbox.empty(accountID: 99).addingConversation(response)
    let conversation = try resolved.conversation("v1:99:7")
    #expect(conversation.chat.title == "Hidden Reply")
    #expect(conversation.dialog.open == false)
    #expect(conversation.dialog.archived)
    #expect(conversation.dialog.chatListHidden)

    response.dialog.peer.chat.chatID = 8
    #expect(throws: InlineIntentError.self) {
      try InlineIntentInbox.empty(accountID: 99).addingConversation(response)
    }
  }

  @Test("server search matches Unicode names and usernames; percent and underscore remain literal")
  func search() throws {
    var result = GetChatsResult()
    result.users = [.with { $0.id = 88; $0.firstName = "Élodie"; $0.lastName = "Martin"; $0.username = "elodie" }]
    insertChat(10, title: "", userID: 88, into: &result)
    insertChat(11, title: "100% Ready", into: &result)
    insertChat(12, title: "Other", into: &result)
    let inbox = InlineIntentInbox(result, accountID: 99)
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "ÉLODIE MARTIN").map(\.id.chatID) == [10])
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "@elodie").map(\.id.chatID) == [10])
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "%").map(\.id.chatID) == [11])
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "_").isEmpty)
  }

  @Test("suggestions are bounded; pinned chats precede server last-message recency")
  func bounds() throws {
    var result = GetChatsResult()
    for id in Int64(1)...30 { insertChat(id, title: "Chat \(id)", into: &result) }
    result.dialogs[0].pinned = true
    result.messages = [.with { $0.id = 1; $0.chatID = 2; $0.date = 100 }]
    // Duplicate server rows cannot produce repeated picker identifiers.
    result.chats.append(result.chats[0])
    let chats = InlineIntentChatStore.fetch(in: InlineIntentInbox(result, accountID: 99))
    #expect(chats.count == 20)
    #expect(chats.first?.id.chatID == 1)
    #expect(chats.dropFirst().first?.id.chatID == 2)
    result.users = [.with { $0.id = 88; $0.firstName = "Person" }]
    insertChat(31, title: "", userID: 88, into: &result)
    result.chats[result.chats.count - 1].date = 0
    let people = InlineIntentChatStore.fetch(in: InlineIntentInbox(result, accountID: 99), directMessagesOnly: true)
    #expect(people.map(\.id.chatID) == [31])
  }

  @Test("DM navigation uses the user namespace; unnamed missing peers are not selectable")
  func destination() throws {
    var result = GetChatsResult()
    result.users = [.with { $0.id = 99; $0.firstName = "Me" }]
    insertChat(10, title: "", userID: 99, into: &result)
    insertChat(11, title: "", userID: 123, into: &result)
    let inbox = InlineIntentInbox(result, accountID: 99)
    let chat = try #require(InlineIntentChatStore.fetch(in: inbox).first)
    #expect(chat.id.chatID == 10)
    #expect(chat.title == "Saved Messages")
    #expect(chat.peer == .user(id: 99))
    #expect(InlineIntentChatStore.fetch(in: inbox, search: "saved").count == 1)
    #expect(InlineIntentChatStore.fetch(in: inbox).count == 1)
  }

  @Test("send preserves text, has a stable request identity, and never becomes an offline queue")
  func sendContract() async throws {
    let chat = InlineIntentChat(id: .init(accountID: 99, chatID: 10), peer: .user(id: 88), title: "Person", subtitle: "")
    let text = "  First line\nSecond line 👋  "
    try InlineIntentService.validateMessage(text)
    #expect(throws: InlineIntentError.self) { try InlineIntentService.validateMessage(" \n\t") }
    let account = try Auth.mocked(authenticated: true).handle.beginAccountMutation()
    let transaction = InlineIntentSendTransaction(text: text, chat: chat, account: account)
    guard case let .sendMessage(first)? = transaction.input,
          case let .sendMessage(second)? = transaction.input else {
      Issue.record("Expected a send-message request")
      return
    }
    #expect(first.message == text)
    #expect(first.peerID.user.userID == 88)
    #expect(first.randomID > 0)
    #expect(first.randomID == second.randomID)
    #expect(transaction.effectiveReconnectReplayPolicy == .neverReplay)
    #expect(transaction.ephemeralConfig?.maxQueueAge == 5)
    await #expect(throws: TransactionExecutionError.self) { try await transaction.apply(nil) }
  }

  @Test("first-use self-chat response cannot resolve another recipient")
  func selfChatContract() throws {
    let account = try Auth.mocked(authenticated: true).handle.beginAccountMutation()
    var response = GetChatResult.with {
      $0.chat.id = 123
      $0.chat.peerID.user.userID = account.userID
      $0.dialog.chatID = 123
      $0.dialog.peer.user.userID = account.userID
      $0.user.id = account.userID
      $0.user.firstName = "Me"
    }
    let inbox = try InlineIntentInbox.empty(accountID: account.userID).addingConversation(response)
    #expect(try inbox.conversation("v1:\(account.userID):123").chat.peer == .user(id: account.userID))
    response.chat.peerID.user.userID = account.userID + 1
    #expect(throws: InlineIntentError.self) {
      try InlineIntentInbox.empty(accountID: account.userID).addingConversation(response)
    }
    #expect(throws: InlineIntentError.self) {
      try InlineIntentInbox.empty(accountID: account.userID).addingConversation(GetChatResult())
    }
  }

  private func insertChat(
    _ id: Int64, title: String, userID: Int64? = nil, hidden: Bool = false,
    archived: Bool = false, into result: inout GetChatsResult
  ) {
    let peer = InlineProtocol.Peer.with {
      if let userID { $0.user.userID = userID } else { $0.chat.chatID = id }
    }
    result.chats.append(.with { $0.id = id; $0.title = title; $0.peerID = peer; $0.date = id })
    result.dialogs.append(.with { $0.chatID = id; $0.peer = peer; $0.chatListHidden = hidden; $0.archived = archived })
  }
}
