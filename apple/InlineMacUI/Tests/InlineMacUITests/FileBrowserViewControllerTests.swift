import AppKit
import GRDB
import InlineKit
@testable import InlineMacUI
import InlineProtocol
import Testing

@Suite("Files outline", .serialized)
@MainActor
struct FileBrowserViewControllerTests {
  private func makeController() throws -> FileBrowserViewController {
    _ = NSApplication.shared
    let controller = try FileBrowserViewController(database: AppDatabase(DatabaseQueue()), showInChat: { _, _ in })
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    controller.applyCatalog([
      ChatListItemSnapshot(peer: .thread(id: 42), chatID: 42, title: "Design"),
      ChatListItemSnapshot(peer: .thread(id: 43), chatID: 43, title: "Archived", isArchived: true),
    ])
    return controller
  }

  private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
  }

  private func file(_ id: Int64, name: String, mime: String = "application/pdf") -> InlineProtocol.Message {
    .with {
      $0.id = id
      $0.chatID = 42
      $0.peerID = .with { $0.type = .chat(.with { $0.chatID = 42 }) }
      $0.media = .with {
        $0.media = .document(.with {
          $0.document = .with { $0.id = id
            $0.fileName = name
            $0.mimeType = mime
          }
        })
      }
    }
  }

  private func text(_ outline: NSOutlineView, row: Int) throws -> String {
    let item = try #require(outline.item(atRow: row))
    let view = outline.delegate?.outlineView?(outline, viewFor: outline.tableColumns[0], item: item)
    return try #require((view as? NSTableCellView)?.textField?.stringValue)
  }

  @Test func expansionSortingAndFilteringRenderRealOutlineRows() async throws {
    let controller = try makeController()
    defer { controller.stop() }
    let page = try ChatFileListing().appending(
      documents: [file(3, name: "Zebra.pdf"), file(2, name: "Alpha.png", mime: "image/png")], media: [], chatID: 42
    )
    controller.loadPage = { _, _, _ in page }
    let outline = try #require(descendant(NSOutlineView.self, in: controller.view))
    #expect(outline.numberOfRows == 1) // Archived is opt-in.
    let folder = try #require(outline.item(atRow: 0))
    outline.expandItem(folder)
    let task = try #require(controller.loads[42])
    await task.value
    #expect(outline.numberOfRows == 3)
    #expect(try text(outline, row: 1) == "Alpha.png")
    outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
    #expect(try text(outline, row: 1) == "Zebra.pdf")
    let filter = try #require(descendant(NSPopUpButton.self, in: controller.view))
    filter.selectItem(at: 2)
    try NSApplication.shared.sendAction(#require(filter.action), to: filter.target, from: filter)
    #expect(outline.numberOfRows == 2)
    #expect(try text(outline, row: 1) == "Alpha.png")
    #expect(outline.isItemExpanded(folder))
  }

  @Test func filteringBeforeCatalogArrivesDoesNotClaimAnEmptyCatalog() throws {
    _ = NSApplication.shared
    let controller = try FileBrowserViewController(database: AppDatabase(DatabaseQueue()), showInChat: { _, _ in })
    defer { controller.stop() }
    let filter = try #require(descendant(NSPopUpButton.self, in: controller.view))
    let footer = try #require(controller.view.subviews.compactMap { $0 as? NSTextField }.first)
    filter.selectItem(at: 2)
    try NSApplication.shared.sendAction(#require(filter.action), to: filter.target, from: filter)
    #expect(footer.stringValue == "Loading chats…")
    controller.applyCatalog([])
    #expect(footer.stringValue == "No chats available.")
  }

  @Test func failedLoadShowsRetryInsteadOfEmptyFolder() async throws {
    let controller = try makeController()
    defer { controller.stop() }
    controller.loadPage = { _, _, _ in throw URLError(.notConnectedToInternet) }
    let outline = try #require(descendant(NSOutlineView.self, in: controller.view))
    let folder = try #require(outline.item(atRow: 0))
    outline.expandItem(folder)
    let task = try #require(controller.loads[42])
    await task.value
    let status = try text(outline, row: 1)
    #expect(status == "Couldn’t load files. Double-click to retry.")
    #expect(outline.numberOfRows == 2)
    #expect(controller.loads.isEmpty)

    let page = try ChatFileListing().appending(documents: [file(1, name: "Retry.pdf")], media: [], chatID: 42)
    controller.loadPage = { _, _, _ in page }
    outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    try NSApplication.shared.sendAction(#require(outline.doubleAction), to: outline.target, from: outline)
    let retry = try #require(controller.loads[42])
    await retry.value
    #expect(try text(outline, row: 1) == "Retry.pdf")
  }

  @Test func closingRejectsPendingResults() async throws {
    let controller = try makeController()
    let page = try ChatFileListing().appending(documents: [file(1, name: "Late.pdf")], media: [], chatID: 42)
    controller.loadPage = { _, _, _ in page }
    let outline = try #require(descendant(NSOutlineView.self, in: controller.view))
    let folder = try #require(outline.item(atRow: 0))
    outline.expandItem(folder)
    let pending = try #require(controller.loads[42])
    controller.stop()
    await pending.value
    #expect(outline.numberOfRows == 0)
    #expect(controller.loads.isEmpty)
  }
}
