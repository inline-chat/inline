import Foundation
import GRDB
import Testing
@testable import InlineKit

@MainActor
@Suite("Compose Autocomplete View Model")
struct ComposeAutocompleteViewModelTests {
  @Test("selection clamps at item edges")
  func selectionClampsAtItemEdges() {
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
    #expect(viewModel.selectedIndex == 0)

    viewModel.selectNext()
    #expect(viewModel.selectedIndex == 1)

    viewModel.selectNext()
    #expect(viewModel.selectedIndex == 1)

    viewModel.selectPrevious()
    #expect(viewModel.selectedIndex == 0)
  }

  @Test("bare thread opener shows recent thread items")
  func bareThreadOpenerShowsRecentThreadItems() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(sqlDb)
      try Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: 7,
        emoji: "🧭"
      ).insert(sqlDb)
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

  @Test("thread lookup starts on one character")
  func threadLookupStartsOnOneCharacter() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: nil
      ).insert(sqlDb)
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

  @Test("thread lookup searches all threads and uses space subtitles")
  func threadLookupSearchesAllThreadsAndUsesSpaceSubtitles() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(sqlDb)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Roadmap",
        spaceId: 7,
        emoji: "🧭"
      ).insert(sqlDb)
      try Chat(
        id: 2,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Home Roadmap",
        spaceId: nil
      ).insert(sqlDb)
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
      try Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil
      ).insert(sqlDb)
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
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Alpha",
        spaceId: nil
      ).insert(sqlDb)
      try Chat(
        id: 2,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "100% Plan",
        spaceId: nil
      ).insert(sqlDb)
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

  @Test("escape suppresses current autocomplete match only")
  func escapeSuppressesCurrentAutocompleteMatchOnly() async throws {
    let db = AppDatabase.empty()
    try await db.dbWriter.write { sqlDb in
      try Chat(
        id: 42,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil
      ).insert(sqlDb)
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
    for _ in 0 ..< 20 {
      if viewModel.items.count == count {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}
