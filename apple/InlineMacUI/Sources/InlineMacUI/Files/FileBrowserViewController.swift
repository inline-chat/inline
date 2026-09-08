import AppKit
import Combine
import GRDB
import InlineKit
import Quartz

/// Finder-style projection of existing chats and filter-only media queries.
@MainActor
public final class FileBrowserViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
  @MainActor QLPreviewPanelDataSource, NSMenuItemValidation
{
  private final class Folder: NSObject {
    var chat: ChatListItemSnapshot
    var listing = ChatFileListing()
    var children: [NSObject] = []
    var files: [ChatFileEntry.ID: FileRow] = [:]
    let status = StatusRow()
    var hasLoaded = false
    var isLoading = false
    var error: String?
    init(chat: ChatListItemSnapshot) {
      self.chat = chat
    }
  }

  private final class FileRow: NSObject {
    var entry: ChatFileEntry
    init(_ entry: ChatFileEntry) {
      self.entry = entry
    }
  }

  private final class StatusRow: NSObject {
    var title = "Loading…"
    var chatID: Int64 = 0
    var canLoad = false
  }

  private let database: AppDatabase
  private let showInChat: @MainActor (Peer, Int64) -> Void
  private let outline = FileBrowserOutlineView()
  private let filter = NSPopUpButton()
  private let archived = NSButton(checkboxWithTitle: "Include Archived", target: nil, action: nil)
  private let footer = NSTextField(labelWithString: "Loading chats…")
  private var observation: AnyCancellable?
  private var folders: [Int64: Folder] = [:]
  private var roots: [Folder] = []
  private(set) var loads: [Int64: Task<Void, Never>] = [:]
  var loadPage: (Peer, Int64, ChatFileListing) async throws -> ChatFileListing = { peer, chatID, listing in
    try await ChatFileBrowser.loadMore(peer: peer, chatID: chatID, listing: listing)
  }

  private var actionTask: Task<Void, Never>?
  private var previewURL: URL?
  private var isStopped = false
  private enum CatalogState { case loading, ready, failed }
  private var catalogState = CatalogState.loading

  public init(database: AppDatabase, showInChat: @escaping @MainActor (Peer, Int64) -> Void) {
    self.database = database
    self.showInChat = showInChat
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError()
  }

  override public func loadView() {
    view = NSView()
    filter.addItems(withTitles: ["All Types", "Files", "Images", "Videos"])
    filter.target = self
    filter.action = #selector(changeFilter)
    filter.setAccessibilityLabel("File type")
    archived.target = self
    archived.action = #selector(changeFilter)
    let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshFiles))
    let controls = NSStackView(views: [filter, archived, refresh])
    controls.spacing = 12
    controls.orientation = .horizontal

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    outline.rowSizeStyle = .medium
    outline.rowHeight = 28
    outline.usesAlternatingRowBackgroundColors = true
    outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    outline.allowsMultipleSelection = false
    outline.autosaveName = "InlineFilesColumns"
    outline.autosaveTableColumns = true
    for (key, title, width) in [
      ("name", "Name", 380.0),
      ("kind", "Kind", 90.0),
      ("date", "Shared", 150.0),
      ("size", "Size", 90.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
      column.title = title
      column.width = width
      column.minWidth = key == "name" ? 200 : 70
      column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "name" || key == "kind")
      outline.addTableColumn(column)
    }
    outline.outlineTableColumn = outline.tableColumns.first
    outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.doubleAction = #selector(openSelected)
    outline.onSpace = { [weak self] in self?.previewSelected() }
    outline.setAccessibilityLabel("Chat files")
    let menu = NSMenu()
    for (title, selector) in [
      ("Open", #selector(openSelected)), ("Quick Look", #selector(previewSelected)),
      ("Download", #selector(downloadSelected)), ("Show in Chat", #selector(revealMessage)),
    ] {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    outline.menu = menu
    scroll.documentView = outline
    footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    footer.textColor = .secondaryLabelColor
    footer.lineBreakMode = .byTruncatingTail
    for child in [controls, scroll, footer] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
      controls.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
      scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])
  }

  override public func viewWillAppear() {
    super.viewWillAppear()
    if !isStopped, observation == nil { observeChats() }
  }

  public func stop() {
    isStopped = true
    observation?.cancel()
    observation = nil
    for task in loads.values {
      task.cancel()
    }
    loads.removeAll()
    actionTask?.cancel()
    actionTask = nil
    if previewURL != nil, let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil,
       panel.dataSource === self
    {
      panel.orderOut(nil)
      panel.dataSource = nil
    }
    previewURL = nil
    folders.removeAll()
    roots.removeAll()
    outline.reloadData()
  }

  private func observeChats() {
    observation?.cancel()
    catalogState = .loading
    footer.stringValue = "Loading chats…"
    observation = ValueObservation.tracking { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db, spaceID: nil, includeSpaceChatsInHome: true,
        translationLanguage: ""
      )
    }.publisher(in: database.dbWriter, scheduling: .mainActor)
      .sink(receiveCompletion: { [weak self] completion in
        guard let self, !isStopped, case .failure = completion else { return }
        catalogState = .failed
        footer.stringValue = "Couldn’t load chats. Click Refresh to retry."
      }, receiveValue: { [weak self] chats in
        guard let self, !isStopped else { return }
        applyCatalog(chats)
      })
  }

  func applyCatalog(_ chats: [ChatListItemSnapshot]) {
    guard !isStopped else { return }
    let ids = Set(chats.map(\.chatID))
    var catalogChanged = catalogState != .ready || ids != Set(folders.keys)
    catalogState = .ready
    for id in Array(folders.keys) where !ids.contains(id) {
      loads.removeValue(forKey: id)?.cancel()
      folders[id] = nil
    }
    for chat in chats {
      if let existing = folders[chat.chatID] {
        catalogChanged = catalogChanged || existing.chat.title != chat.title
          || existing.chat.spaceName != chat.spaceName || existing.chat.isArchived != chat.isArchived
        existing.chat = chat
      } else { folders[chat.chatID] = Folder(chat: chat) }
    }
    // Message previews share this observation, but do not change the file tree.
    if catalogChanged || roots.isEmpty { rebuild() }
  }

  private var selectedKind: ChatFileKind? {
    switch filter.indexOfSelectedItem {
      case 1: .file
      case 2: .image
      case 3: .video
      default: nil
    }
  }

  @objc private func changeFilter() {
    rebuild()
  }

  private func rebuild() {
    let expanded = Set(roots.filter { outline.isItemExpanded($0) }.map(\.chat.chatID))
    let selected = selectedFile?.id
    let folderAscending = outline.sortDescriptors.first?.key == "name" ? outline.sortDescriptors.first?
      .ascending ?? true : true
    roots = folders.values.filter { !$0.chat.isArchived || archived.state == .on }
      .sorted {
        let comparison = $0.chat.title.localizedStandardCompare($1.chat.title)
        if comparison == .orderedSame { return $0.chat.chatID < $1.chat.chatID }
        return folderAscending ? comparison == .orderedAscending : comparison == .orderedDescending
      }
    for folder in roots {
      project(folder)
    }
    outline.reloadData()
    for folder in roots where expanded.contains(folder.chat.chatID) {
      outline.expandItem(folder)
    }
    if let selected {
      for row in 0 ..< outline.numberOfRows {
        if let file = outline.item(atRow: row) as? FileRow, file.entry.id == selected {
          outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          break
        }
      }
    }
    if actionTask == nil {
      switch catalogState {
        case .loading: footer.stringValue = "Loading chats…"
        case .failed: footer.stringValue = "Couldn’t load chats. Click Refresh to retry."
        case .ready:
          footer.stringValue = roots.isEmpty ? "No chats available." : "\(roots.count) chats · Sort applies to loaded files. Expand a chat to browse."
      }
    }
  }

  private func project(_ folder: Folder) {
    let descriptor = outline.sortDescriptors.first
    let sort = ChatFileSort(rawValue: descriptor?.key ?? "name") ?? .name
    let entries = ChatFileEntry.sorted(folder.listing.entries.filter {
      selectedKind == nil || $0.kind == selectedKind
    }, by: sort, ascending: descriptor?.ascending ?? true)
    folder.children = entries.map { entry in
      if let row = folder.files[entry.id] { row.entry = entry
        return row
      }
      let row = FileRow(entry)
      folder.files[entry.id] = row
      return row
    }
    let status = folder.status
    status.chatID = folder.chat.chatID
    status.canLoad = !folder.isLoading && (!folder.listing.isComplete || folder.error != nil)
    if folder.isLoading { status.title = "Loading files…" }
    else if folder.error != nil { status.title = "Couldn’t load files. Double-click to retry." }
    else if !folder.hasLoaded { status.title = "Double-click to load files" }
    else if !folder.listing.isComplete { status.title = "Load More — double-click for older files" }
    else { status.title = selectedKind == nil ? "No files in this chat" : "No files of this type" }
    if folder.isLoading || folder.error != nil || !folder.listing.isComplete || folder.children.isEmpty {
      folder.children.append(status)
    }
  }

  private func load(_ folder: Folder) {
    let id = folder.chat.chatID
    guard !isStopped, !folder.isLoading, loads[id] == nil, !folder.listing.isComplete else { return }
    folder.isLoading = true
    folder.error = nil
    project(folder)
    outline.reloadItem(folder, reloadChildren: true)
    let listing = folder.listing
    let peer = folder.chat.peer
    loads[id] = Task { [weak self, weak folder] in
      let result: Result<ChatFileListing, any Error>
      do {
        guard let self else { return }
        result = try await .success(loadPage(peer, id, listing))
      } catch { result = .failure(error) }
      guard let self, let folder, !Task.isCancelled, !isStopped, folders[id] === folder else { return }
      loads[id] = nil
      folder.isLoading = false
      switch result {
        case let .success(listing): folder.listing = listing
          folder.hasLoaded = true
        case let .failure(error): folder.error = error.localizedDescription
      }
      project(folder)
      outline.reloadItem(folder, reloadChildren: true)
      if let error = folder.error { footer.stringValue = error }
    }
  }

  @objc private func refreshFiles() {
    actionTask?.cancel()
    actionTask = nil
    for task in loads.values {
      task.cancel()
    }
    loads.removeAll()
    let expanded = roots.filter { outline.isItemExpanded($0) }
    for folder in folders.values {
      folder.listing = ChatFileListing()
      folder.files.removeAll()
      folder.error = nil
      folder.hasLoaded = false
      folder.isLoading = false
    }
    rebuild()
    observeChats()
    for folder in expanded {
      load(folder)
    }
  }

  public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? Folder)?.children.count ?? (item == nil ? roots.count : 0)
  }

  public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let folder = item as? Folder { return folder.children[index] }
    return roots[index]
  }

  public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    item is Folder
  }

  public func outlineViewItemDidExpand(_ notification: Notification) {
    // AppKit can re-emit expansion while reloading children. Failed loads retry
    // only through the status row, not through that programmatic expansion.
    guard let folder = notification.userInfo?["NSObject"] as? Folder,
          !folder.hasLoaded, folder.error == nil else { return }
    load(folder)
  }

  public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    rebuild()
  }

  public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    let key = tableColumn?.identifier.rawValue ?? "name"
    let cellID = NSUserInterfaceItemIdentifier("files.\(key)")
    let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? makeCell(
      cellID,
      icon: key == "name"
    )
    cell.imageView?.image = nil
    cell.textField?.textColor = .labelColor
    cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
    var text = ""
    if let folder = item as? Folder {
      if key == "name" {
        let context = folder.chat.spaceName ?? "Home"
        text = "\(folder.chat.title) — \(context)"
        cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Chat folder")
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
      }
    } else if let row = item as? FileRow {
      let entry = row.entry
      switch key {
        case "name":
          text = entry.name
          cell.imageView?.image = NSImage(
            systemSymbolName: entry.kind == .image ? "photo" : entry.kind == .video ? "film" : "doc",
            accessibilityDescription: nil
          )
        case "kind": text = entry.kind == .image ? "Image" : entry.kind == .video ? "Video" : "File"
        case "date": text = entry.date.formatted(date: .abbreviated, time: .omitted)
        case "size": text = entry.size > 0 ? ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) : "—"
        default: break
      }
    } else if let status = item as? StatusRow, key == "name" {
      text = status.title
      cell.textField?.textColor = .secondaryLabelColor
    }
    cell.textField?.stringValue = text
    cell.toolTip = text.isEmpty ? nil : text
    return cell
  }

  private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    var leading = cell.leadingAnchor
    if icon {
      let image = NSImageView()
      image.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(image)
      cell.imageView = image
      NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
      ])
      leading = image.trailingAnchor
    }
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leading, constant: 6),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private var selectedFile: ChatFileEntry? {
    guard outline.selectedRow >= 0 else { return nil }
    return (outline.item(atRow: outline.selectedRow) as? FileRow)?.entry
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    selectedFile != nil && actionTask == nil
  }

  @objc private func openSelected() {
    guard outline.selectedRow >= 0 else { return }
    if let folder = outline.item(atRow: outline.selectedRow) as? Folder {
      if outline.isItemExpanded(folder) { outline.collapseItem(folder) } else { outline.expandItem(folder) }
    } else if let status = outline.item(atRow: outline.selectedRow) as? StatusRow,
              status.canLoad, let folder = folders[status.chatID] { load(folder) }
    else { performFileAction(.open) }
  }

  @objc private func previewSelected() {
    performFileAction(.preview)
  }

  @objc private func downloadSelected() {
    performFileAction(.download)
  }

  @objc private func revealMessage() {
    guard let entry = selectedFile else { return }
    showInChat(entry.peer, entry.id.messageID)
  }

  private enum FileAction { case open, preview, download }
  private func performFileAction(_ action: FileAction) {
    guard let entry = selectedFile, !isStopped else { return }
    actionTask?.cancel()
    footer.stringValue = "Preparing \(entry.name)…"
    actionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let source = try await ChatFileBrowser.localURL(for: entry, database: database)
        try Task.checkCancellation()
        guard !isStopped else { return }
        switch action {
          case .open:
            guard NSWorkspace.shared.open(source) else { throw ChatFileBrowserError.downloadFailed }
          case .preview:
            previewURL = source
            if let panel = QLPreviewPanel.shared() {
              panel.updateController()
              panel.dataSource = self
              panel.reloadData()
              panel.makeKeyAndOrderFront(nil)
            }
          case .download:
            let destination = try await Task.detached(priority: .userInitiated) {
              try Self.copyToDownloads(source, name: entry.name)
            }.value
            try Task.checkCancellation()
            guard !isStopped else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        footer.stringValue = "\(entry.name) is ready."
      } catch is CancellationError { return }
      catch { if !isStopped, !Task.isCancelled { footer.stringValue = error.localizedDescription } }
      guard !Task.isCancelled else { return }
      actionTask = nil
    }
  }

  private nonisolated static func copyToDownloads(_ source: URL, name: String) throws -> URL {
    let directory = try FileManager.default.url(
      for: .downloadsDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let basename = URL(fileURLWithPath: name).lastPathComponent
    let safeName = basename.isEmpty || basename == "." || basename == ".." ? "File" : basename
    let file = URL(fileURLWithPath: safeName)
    for index in 0 ..< 10_000 {
      try Task.checkCancellation()
      let suffix = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
      let candidate = index == 0 ? safeName : "\(file.deletingPathExtension().lastPathComponent) (\(index))\(suffix)"
      let destination = directory.appendingPathComponent(candidate)
      do { try FileManager.default.copyItem(at: source, to: destination)
        return destination
      } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
    }
    throw CocoaError(.fileWriteFileExists)
  }

  public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewURL == nil ? 0 : 1
  }

  public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    previewURL as NSURL?
  }
}

@MainActor
private final class FileBrowserOutlineView: NSOutlineView {
  var onSpace: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49 { onSpace?() } else { super.keyDown(with: event) }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    else { deselectAll(nil) }
    return super.menu(for: event)
  }
}
