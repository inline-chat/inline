import Foundation
import GRDB
import Testing
@testable import InlineKit

@MainActor
@Suite("Compose Autocomplete View Model")
struct ComposeAutocompleteViewModelTests {
  @Test("selection wraps at item edges")
  func selectionWrapsAtItemEdges() {
    let viewModel = ComposeAutocompleteViewModel(
      emojiItems: { _, _ in
        [
          ComposeAutocompleteItem(
            id: "emoji-smile",
            kind: .emoji,
            title: ":smile:",
            emoji: "😄",
            payload: .emoji(value: "😄", shortcode: "smile")
          ),
          ComposeAutocompleteItem(
            id: "emoji-joy",
            kind: .emoji,
            title: ":joy:",
            emoji: "😂",
            payload: .emoji(value: "😂", shortcode: "joy")
          ),
        ]
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .emoji,
        range: NSRange(location: 0, length: 4),
        query: "smi"
      )
    )

    #expect(viewModel.selectedIndex == 0)

    viewModel.selectPrevious()
    #expect(viewModel.selectedIndex == 1)

    viewModel.selectNext()
    #expect(viewModel.selectedIndex == 0)

    viewModel.selectNext()
    #expect(viewModel.selectedIndex == 1)

    viewModel.selectNext()
    #expect(viewModel.selectedIndex == 0)

    viewModel.selectPrevious()
    #expect(viewModel.selectedIndex == 1)
  }

  @Test("changing an async match clears stale items immediately")
  func changingAsyncMatchClearsStaleItemsImmediately() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 3),
        query: "ro"
      )
    )
    #expect(viewModel.loadState == .loading)
    await waitForItems(viewModel, count: 1)
    #expect(viewModel.loadState == .idle)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 4),
        query: "zzz"
      )
    )

    #expect(viewModel.items.isEmpty)
    #expect(viewModel.selectedIndex == 0)
    #expect(viewModel.loadState == .loading)
  }

  @Test("rapid thread refinements publish only the latest query")
  func rapidThreadRefinementsPublishOnlyLatestQuery() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let roadmap = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      let zebra = Chat(
        id: 43,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Zebra",
        spaceId: nil
      )
      try Self.insertCatalogChat(roadmap, in: sqlDb)
      try Self.insertCatalogChat(zebra, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 3),
        query: "ro"
      )
    )
    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 3),
        query: "ze"
      )
    )

    try await Task.sleep(for: .milliseconds(40))
    #expect(viewModel.items.isEmpty)
    #expect(viewModel.loadState == .loading)

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.map(\.title) == ["Zebra"])
    #expect(viewModel.loadState == .idle)
  }

  @Test("bare thread opener shows recent thread items")
  func bareThreadOpenerShowsRecentThreadItems() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(sqlDb)
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: 7,
        emoji: "🧭"
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      recentThreadChatIds: { limit in Array([Int64(42)].prefix(limit)) }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 2),
        query: ""
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Roadmap")
    #expect(viewModel.items.first?.subtitle == "Engineering")
    #expect(viewModel.items.first?.emoji == "🧭")
    #expect(viewModel.items.first?.payload == .thread(chatId: 42, spaceId: 7, title: "Roadmap"))
  }

  @Test("bare thread opener fills six visible catalog threads by navigation and recency")
  func bareThreadOpenerFillsSixVisibleCatalogThreadsByNavigationAndRecency() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      for index in 1 ... 7 {
        let chat = Chat(
          id: Int64(1_000 + index),
          date: Date(timeIntervalSince1970: TimeInterval(index)),
          type: .thread,
          title: "Thread \(index)",
          spaceId: nil
        )
        try Self.insertCatalogChat(
          chat,
          openedDate: index == 1 ? Date(timeIntervalSince1970: 500) : nil,
          in: sqlDb
        )
      }

      let archived = Chat(
        id: 2_001,
        date: Date(timeIntervalSince1970: 100),
        type: .thread,
        title: "Archived",
        spaceId: nil
      )
      try archived.insert(sqlDb)
      var archivedDialog = Dialog(optimisticForChat: archived)
      archivedDialog.archived = true
      try archivedDialog.insert(sqlDb)

      let replyThread = Chat(
        id: 2_002,
        date: Date(timeIntervalSince1970: 101),
        type: .thread,
        title: "Re: @Georges teste...",
        spaceId: nil,
        isUntitled: true,
        parentChatId: 1_001,
        parentMessageId: 1
      )
      try Self.insertCatalogChat(replyThread, in: sqlDb)

      let hidden = Chat(
        id: 2_003,
        date: Date(timeIntervalSince1970: 102),
        type: .thread,
        title: "Hidden",
        spaceId: nil
      )
      try hidden.insert(sqlDb)
      var hiddenDialog = Dialog(optimisticForChat: hidden)
      hiddenDialog.chatListHidden = true
      try hiddenDialog.insert(sqlDb)
    }

    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      recentThreadChatIds: { _ in [2_002] }
    )
    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 2),
        query: ""
      )
    )

    await waitForItems(viewModel, count: 6)
    #expect(viewModel.items.map(\.title) == [
      "Re: @Georges teste...",
      "Thread 1",
      "Thread 7",
      "Thread 6",
      "Thread 5",
      "Thread 4",
    ])
    #expect(viewModel.items.first?.subtitle == "Thread 1")

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 5),
        query: "re:"
      )
    )
    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Re: @Georges teste...")
  }

  @Test("reply thread uses and searches the sidebar-resolved fallback title")
  func replyThreadUsesAndSearchesSidebarResolvedFallbackTitle() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let parent = Chat(
        id: 3_001,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Wish Pool",
        spaceId: nil
      )
      let reply = Chat(
        id: 3_002,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: nil,
        spaceId: nil,
        isUntitled: true,
        parentChatId: parent.id,
        parentMessageId: 77
      )
      try User(id: 9, email: nil, firstName: "Boba").insert(sqlDb)
      try Self.insertCatalogChat(parent, in: sqlDb)
      try Message(
        messageId: 77,
        fromId: 9,
        date: Date(timeIntervalSince1970: 1),
        text: "Wishlist intake quiet",
        peerUserId: nil,
        peerThreadId: parent.id,
        chatId: parent.id
      ).insert(sqlDb)
      try Self.insertCatalogChat(reply, in: sqlDb)
    }

    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      recentThreadChatIds: { _ in [3_002] }
    )
    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 16),
        query: "wishlistintake"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Wishlist intake quiet")
    #expect(viewModel.items.first?.subtitle == "Wish Pool")
    #expect(
      viewModel.items.first?.payload
        == .thread(chatId: 3_002, spaceId: nil, title: "Wishlist intake quiet")
    )
  }

  @Test("numbered space reply thread is searchable by its provisional reference")
  func numberedSpaceReplyThreadIsSearchableByReference() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(sqlDb)
      let parent = Chat(
        id: 4_001,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Planning",
        spaceId: 7
      )
      let reply = Chat(
        id: 4_002,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Decision follow-up",
        spaceId: 7,
        number: 123,
        parentChatId: parent.id,
        parentMessageId: 77
      )
      let home = Chat(
        id: 4_003,
        date: Date(timeIntervalSince1970: 3),
        type: .thread,
        title: "Home notes",
        spaceId: nil,
        number: 123
      )
      try Self.insertCatalogChat(parent, in: sqlDb)
      try Self.insertCatalogChat(reply, in: sqlDb)
      try Self.insertCatalogChat(home, in: sqlDb)
    }

    var externalCallCount = 0
    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      externalResourceItems: { _, _ in
        externalCallCount += 1
        return []
      }
    )

    for query in ["123", "#123"] {
      viewModel.update(
        match: ComposeAutocompleteMatch(
          kind: .thread,
          range: NSRange(location: 0, length: query.utf16.count + 2),
          query: query
        )
      )

      await waitForItems(viewModel, count: 1)
      #expect(viewModel.items.first?.title == "Decision follow-up")
      #expect(viewModel.items.first?.subtitle == "Planning • #123")
      #expect(
        viewModel.items.first?.payload
          == .thread(chatId: 4_002, spaceId: 7, title: "Decision follow-up")
      )
    }

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .threadNumber,
        range: NSRange(location: 0, length: 3),
        query: "12"
      )
    )
    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.kind == .threadNumber)
    #expect(viewModel.items.first?.spaceThreadReference == SpaceThreadReference(chatId: 4_002, number: 123))
    #expect(externalCallCount == 0)

    try await db.dbWriter.write { sqlDb in
      try Self.insertCatalogChat(
        Chat(
          id: 4_004,
          date: Date(timeIntervalSince1970: 4),
          type: .thread,
          title: "Ticket 123",
          spaceId: 7,
          number: 999
        ),
        in: sqlDb
      )
      try Self.insertCatalogChat(
        Chat(
          id: 4_005,
          date: Date(timeIntervalSince1970: 5),
          type: .thread,
          title: "Later prefix",
          spaceId: 7,
          number: 1_234
        ),
        in: sqlDb
      )
    }

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .threadNumber,
        range: NSRange(location: 0, length: 4),
        query: "123"
      )
    )
    await waitForItems(viewModel, count: 2)
    #expect(viewModel.items.compactMap(\.spaceThreadReference?.chatId) == [4_002, 4_005])
    #expect(externalCallCount == 0)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 6),
        query: "#123"
      )
    )
    await waitForItems(viewModel, count: 2)
    try await Task.sleep(for: .milliseconds(300))
    #expect(externalCallCount == 0)
  }

  @Test("thread lookup starts on one character")
  func threadLookupStartsOnOneCharacter() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 3),
        query: "R"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Roadmap")
  }

  @Test("thread lookup searches all visible threads and uses space subtitles")
  func threadLookupSearchesAllVisibleThreadsAndUsesSpaceSubtitles() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(sqlDb)
      let roadmap = Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: 7,
        emoji: "🧭"
      )
      let homeRoadmap = Chat(
        id: 2,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Home Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(roadmap, in: sqlDb)
      try Self.insertCatalogChat(homeRoadmap, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 5),
        query: "roa"
      )
    )

    await waitForItems(viewModel, count: 2)

    #expect(viewModel.items.map(\.title) == ["Home Roadmap", "Roadmap"])
    #expect(viewModel.items.map(\.subtitle) == ["Thread", "Engineering"])
    #expect(viewModel.items.first { $0.title == "Roadmap" }?.emoji == "🧭")
  }

  @Test("thread lookup ignores whitespace")
  func threadLookupIgnoresWhitespace() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 13),
        query: "replythread"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Reply Thread")
  }

  @Test("thread lookup treats sql wildcards as literals")
  func threadLookupTreatsSQLWildcardsAsLiterals() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let alpha = Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Alpha",
        spaceId: nil
      )
      let plan = Chat(
        id: 2,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "100% Plan",
        spaceId: nil
      )
      try Self.insertCatalogChat(alpha, in: sqlDb)
      try Self.insertCatalogChat(plan, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 3),
        query: "%"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.map(\.title) == ["100% Plan"])
  }

  @Test("thread results stay above external resources")
  func threadResultsStayAboveExternalResources() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let resource = externalResource(id: "notion-roadmap", title: "Roadmap notes")
    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      externalResourceItems: { _, _ in [resource] }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 6),
        query: "road"
      )
    )

    await waitForItems(viewModel, count: 2)
    #expect(viewModel.items.map(\.title) == ["Roadmap", "Roadmap notes"])
    #expect(viewModel.items[0].payload == .thread(chatId: 42, spaceId: nil, title: "Roadmap"))
    #expect(viewModel.items[1].payload == .externalResource(resource))
  }

  @Test("Notion scope searches only the text after the slash")
  func notionScopeSearchesOnlyTheTextAfterTheSlash() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    var receivedQuery: String?
    let resource = externalResource(id: "notion-roadmap", title: "Roadmap notes")
    let linearResource = ExternalResourceReference(
      id: "linear-roadmap",
      provider: .linear,
      kind: .issue,
      title: "Linear roadmap",
      url: URL(string: "https://linear.app/example/issue/ROAD-1")!,
      subtitle: "Linear issue"
    )
    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      externalResourceItems: { query, _ in
        receivedQuery = query
        return [resource, linearResource]
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 15),
        query: "NoTiOn/ road"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(receivedQuery == "road")
    #expect(viewModel.items.map(\.payload) == [.externalResource(resource)])
  }

  @Test("Inline scope never requests an external provider")
  func inlineScopeNeverRequestsAnExternalProvider() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    var externalCallCount = 0
    let viewModel = ComposeAutocompleteViewModel(
      db: db,
      externalResourceItems: { _, _ in
        externalCallCount += 1
        return []
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 15),
        query: "inline/road"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(externalCallCount == 0)
    #expect(viewModel.items.map(\.payload) == [
      .thread(chatId: 42, spaceId: nil, title: "Roadmap"),
    ])
  }

  @Test("Linear scope does not fall through to Notion")
  func linearScopeDoesNotFallThroughToNotion() {
    var externalCallCount = 0
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { _, _ in
        externalCallCount += 1
        return []
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 15),
        query: "linear/road"
      )
    )

    #expect(viewModel.items.isEmpty)
    #expect(viewModel.loadState == .idle)
    #expect(externalCallCount == 0)
  }

  @Test("unknown slash prefix remains an unscoped query")
  func unknownSlashPrefixRemainsAnUnscopedQuery() async {
    var receivedQuery: String?
    let resource = externalResource(id: "custom-roadmap", title: "Custom roadmap")
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { query, _ in
        receivedQuery = query
        return [resource]
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 17),
        query: "custom/roadmap"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(receivedQuery == "custom/roadmap")
    #expect(viewModel.items.map(\.payload) == [.externalResource(resource)])
  }

  @Test("Notion slash requests six recent accessible resources")
  func notionSlashRequestsSixRecentAccessibleResources() async {
    var receivedQuery: String?
    var receivedLimit: Int?
    let resources = (1 ... 6).map { index in
      externalResource(id: "recent-\(index)", title: "Recent \(index)")
    }
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { query, limit in
        receivedQuery = query
        receivedLimit = limit
        return resources
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 9),
        query: "Notion/"
      )
    )

    await waitForItems(viewModel, count: 6)
    #expect(receivedQuery == "")
    #expect(receivedLimit == 6)
    #expect(viewModel.items.map(\.title) == resources.map(\.title))
  }

  @Test("bare opener remains local and makes no external request")
  func bareOpenerRemainsLocalAndMakesNoExternalRequest() async throws {
    var externalCallCount = 0
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { _, _ in
        externalCallCount += 1
        return []
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 2),
        query: ""
      )
    )

    await waitForLoadState(viewModel, state: .idle)
    #expect(viewModel.loadState == .idle)
    #expect(externalCallCount == 0)
  }

  @Test("external resource lookup caches repeated queries")
  func externalResourceLookupCachesRepeatedQueries() async {
    var callCount = 0
    let resource = externalResource(id: "notion-roadmap", title: "Roadmap notes")
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { _, _ in
        callCount += 1
        return [resource]
      }
    )
    let match = ComposeAutocompleteMatch(
      kind: .thread,
      range: NSRange(location: 0, length: 6),
      query: "road"
    )

    viewModel.update(match: match)
    await waitForItems(viewModel, count: 1)
    #expect(callCount == 1)

    viewModel.update(match: nil)
    viewModel.update(match: match)
    await waitForItems(viewModel, count: 1)
    #expect(callCount == 1)
  }

  @Test("late external results cannot replace a newer query")
  func lateExternalResultsCannotReplaceNewerQuery() async throws {
    let oldResource = externalResource(id: "notion-roadmap", title: "Roadmap notes")
    let newResource = externalResource(id: "notion-zebra", title: "Zebra notes")
    let viewModel = ComposeAutocompleteViewModel(
      db: AppDatabase.empty(),
      externalResourceItems: { query, _ in
        if query == "road" {
          try? await Task.sleep(for: .milliseconds(300))
          return [oldResource]
        }
        return [newResource]
      }
    )

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 6),
        query: "road"
      )
    )
    try await Task.sleep(for: .milliseconds(240))
    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 5),
        query: "zeb"
      )
    )

    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.map(\.title) == ["Zebra notes"])
    try await Task.sleep(for: .milliseconds(320))
    #expect(viewModel.items.map(\.title) == ["Zebra notes"])
  }

  @Test("escape suppresses current autocomplete match only")
  func escapeSuppressesCurrentAutocompleteMatchOnly() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      let chat = Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil
      )
      try Self.insertCatalogChat(chat, in: sqlDb)
    }
    let viewModel = ComposeAutocompleteViewModel(db: db)
    let firstMatch = ComposeAutocompleteMatch(
      kind: .thread,
      range: NSRange(location: 0, length: 3),
      query: "r"
    )

    viewModel.update(match: firstMatch)
    await waitForItems(viewModel, count: 1)

    viewModel.hide(suppressCurrentMatch: true)
    viewModel.update(match: firstMatch)
    #expect(viewModel.items.isEmpty)

    viewModel.update(
      match: ComposeAutocompleteMatch(
        kind: .thread,
        range: NSRange(location: 0, length: 4),
        query: "re"
      )
    )
    await waitForItems(viewModel, count: 1)
    #expect(viewModel.items.first?.title == "Reply Thread")
  }

  private func waitForItems(_ viewModel: ComposeAutocompleteViewModel, count: Int) async {
    for _ in 0 ..< 100 {
      if viewModel.items.count == count {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func waitForLoadState(
    _ viewModel: ComposeAutocompleteViewModel,
    state: ComposeAutocompleteLoadState
  ) async {
    for _ in 0 ..< 200 {
      if viewModel.loadState == state {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func externalResource(id: String, title: String) -> ExternalResourceReference {
    ExternalResourceReference(
      id: id,
      provider: .notion,
      kind: .page,
      title: title,
      url: URL(string: "https://www.notion.so/\(id)")!,
      subtitle: "Notion page"
    )
  }

  nonisolated private static func insertCatalogChat(
    _ chat: Chat,
    openedDate: Date? = nil,
    in db: Database
  ) throws {
    try chat.insert(db)
    var dialog = Dialog(optimisticForChat: chat)
    dialog.openedDate = openedDate
    try dialog.insert(db)
  }
}
