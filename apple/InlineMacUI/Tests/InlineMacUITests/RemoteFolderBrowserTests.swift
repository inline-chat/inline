import AppKit
@testable import InlineMacUI
import InlineProtocol
import Testing

@Suite("Remote folder browser", .serialized)
@MainActor
struct RemoteFolderBrowserTests {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  private func click(_ title: String, in controller: RemoteFolderBrowser) throws {
    let button = try #require(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title })
    #expect(button.isEnabled)
    try NSApplication.shared.sendAction(#require(button.action), to: button.target, from: button)
  }

  private func listing(_ path: String, names: [String], next: String? = nil) -> BotFilesystemResponse {
    .with { response in
      response.listing = .with {
        $0.path = path
        $0.parentPath = "/"
        $0.entries = names.map { name in .with { $0.name = name; $0.kind = .directory } }
        if let next { $0.nextAfter = next }
      }
    }
  }

  @Test func navigationPaginationMetadataAndRegistration() async throws {
    _ = NSApplication.shared
    var calls: [(String, String, Bool)] = []
    let controller = RemoteFolderBrowser(hostLabel: "Test host") { path, after, register in
      calls.append((path, after, register))
      if register { return .with { $0.workspaceID = "registered-folder" } }
      if path == "/home/projects" { return listing(path, names: ["source"]) }
      if !after.isEmpty { return listing("/home", names: ["second"]) }
      return listing("/home", names: ["projects"], next: "projects")
    }
    controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
    let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
    controller.navigate("")
    await controller.task?.value
    #expect(table.numberOfRows == 1)
    let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTableCellView
    #expect(cell?.textField?.stringValue == "projects")
    let kind = controller.tableView(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField
    #expect(kind?.stringValue == "Folder")
    try click("Load More", in: controller)
    await controller.task?.value
    #expect(table.numberOfRows == 2)
    #expect(calls.last?.1 == "projects")
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    try NSApplication.shared.sendAction(#require(table.doubleAction), to: table.target, from: table)
    await controller.task?.value
    #expect(calls.last?.0 == "/home/projects")
    try click("Back", in: controller)
    await controller.task?.value
    #expect(calls.last?.0 == "/home")
    try click("Use This Folder", in: controller)
    await controller.task?.value
    #expect(calls.last?.2 == true)
    #expect(calls.last?.0 == "/home")
    #expect(table.numberOfRows == 0)
  }

  @Test func supersededRequestCannotCloseOrReplaceNewDirectory() async throws {
    _ = NSApplication.shared
    var pending: CheckedContinuation<BotFilesystemResponse, Error>?
    let controller = RemoteFolderBrowser(hostLabel: "Test host") { path, _, _ in
      if path == "/slow" { return try await withCheckedThrowingContinuation { pending = $0 } }
      return listing("/home", names: ["projects"])
    }
    _ = controller.view
    controller.navigate("/slow")
    let oldTask = controller.task
    while pending == nil { await Task.yield() }
    controller.navigate("/home")
    await controller.task?.value
    pending?.resume(throwing: CancellationError())
    await oldTask?.value
    let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
    #expect(table.numberOfRows == 1)
    try click("Cancel", in: controller)
    #expect(table.numberOfRows == 0)
  }
}
