import AppKit
import Auth
import InlineKit
import InlineProtocol

/// One-directory browser shared by inspection and project-folder selection.
@MainActor
public final class RemoteFolderBrowser: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  public typealias Request = @MainActor (String, String, Bool) async throws -> BotFilesystemResponse
  private let request: Request
  private let hostLabel: String
  private var completion: ((String?) -> Void)?
  private var page: BotFilesystemListing?
  private var entries: [BotFilesystemEntry] = []
  private var history: [String] = []
  private(set) var task: Task<Void, Never>?
  private var accountTask: Task<Void, Never>?
  private var generation = 0
  private var busy = false
  private let table = RemoteDirectoryTableView()
  private let pathLabel = NSTextField(labelWithString: "Loading home directory…")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let backButton = NSButton(title: "Back", target: nil, action: nil)
  private let upButton = NSButton(title: "Up", target: nil, action: nil)
  private let homeButton = NSButton(title: "Home", target: nil, action: nil)
  private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
  private let moreButton = NSButton(title: "Load More", target: nil, action: nil)
  private let chooseButton = NSButton(title: "Use This Folder", target: nil, action: nil)
  private var sheet: NSWindow?

  public init(hostLabel: String, request: @escaping Request) {
    self.hostLabel = hostLabel
    self.request = request
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  public static func pick(on parent: NSWindow, hostLabel: String, request: @escaping Request) async throws -> String {
    guard parent.attachedSheet == nil else { throw RemoteFilesystemError.invalidResponse }
    let browser = RemoteFolderBrowser(hostLabel: hostLabel, request: request)
    let result: String? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let window = NSWindow(contentViewController: browser)
        window.styleMask = [.titled, .resizable]
        window.title = "Choose a Folder on \(hostLabel)"
        window.contentMinSize = NSSize(width: 560, height: 380)
        window.setContentSize(NSSize(width: 700, height: 480))
        browser.sheet = window
        browser.completion = { continuation.resume(returning: $0) }
        parent.beginSheet(window) { _ in
          browser.finish(nil)
        }
        let accountID = Auth.shared.getCurrentUserId()
        browser.accountTask = Task { [weak browser] in
          for await snapshot in Auth.shared.snapshots {
            guard !Task.isCancelled else { return }
            if !snapshot.status.isAuthenticated || snapshot.status.userId != accountID {
              browser?.finish(nil)
              return
            }
          }
        }
        browser.navigate("")
        if Task.isCancelled { browser.finish(nil) }
      }
    } onCancel: {
      Task { @MainActor in browser.finish(nil) }
    }
    guard let result else { throw CancellationError() }
    return result
  }

  public override func loadView() {
    view = NSView()
    let title = NSTextField(labelWithString: "Files on \(hostLabel)")
    title.font = .boldSystemFont(ofSize: 14)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.isSelectable = true
    pathLabel.setAccessibilityLabel("Current remote folder")
    let nav = NSStackView(views: [backButton, upButton, homeButton, refreshButton])
    nav.spacing = 8
    for (button, action) in [(backButton, #selector(goBack)), (upButton, #selector(goUp)), (homeButton, #selector(goHome)), (refreshButton, #selector(refresh)), (moreButton, #selector(loadMore)), (chooseButton, #selector(choose))] {
      button.target = self
      button.action = action
      button.bezelStyle = .rounded
    }
    chooseButton.keyEquivalent = "\r"
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelBrowser))
    cancel.keyEquivalent = "\u{1b}"
    let footer = NSStackView(views: [moreButton, NSView(), cancel, chooseButton])
    footer.spacing = 8
    table.style = .inset
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = false
    table.rowHeight = 24
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.openFolder = { [weak self] in self?.openSelected() }
    table.parentFolder = { [weak self] in self?.goUp() }
    table.setAccessibilityLabel("Remote files and folders")
    for (id, title, width) in [("name", "Name", 420.0), ("kind", "Kind", 110.0), ("size", "Size", 90.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = 70
      table.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    status.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: 11)
    let stack = NSStackView(views: [title, nav, pathLabel, scroll, status, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
      pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      status.widthAnchor.constraint(equalTo: stack.widthAnchor),
      footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    updateControls()
  }

  public func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard entries.indices.contains(row), let column = tableColumn else { return nil }
    let entry = entries[row]
    if column.identifier.rawValue == "name" {
      let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
      cell.identifier = column.identifier
      if cell.textField == nil {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView()
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.textField = label
        cell.imageView = icon
        NSLayoutConstraint.activate([
          icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
          icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
          label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
          label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
          label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
      }
      cell.textField?.stringValue = entry.name
      let symbol = entry.kind == .directory ? "folder" : entry.kind == .symlink ? "link" : "doc"
      cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      return cell
    }
    let field = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
    field.identifier = column.identifier
    field.lineBreakMode = .byTruncatingMiddle
    switch column.identifier.rawValue {
    case "name": field.stringValue = entry.name
    case "kind": field.stringValue = switch entry.kind { case .directory: "Folder"; case .file: "File"; case .symlink: "Symbolic Link"; default: "Other" }
    default: field.stringValue = entry.kind == .file ? ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file) : "—"
    }
    return field
  }

  public override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.keyCode == 125 { openSelected(); return }
    if event.modifierFlags.contains(.command), event.keyCode == 126 { goUp(); return }
    super.keyDown(with: event)
  }

  @objc private func goBack() { guard !busy, let path = history.last else { return }; navigate(path, back: true) }
  @objc private func goUp() { guard !busy, let page, page.hasParentPath else { return }; navigate(page.parentPath) }
  @objc private func goHome() { guard !busy else { return }; navigate("") }
  @objc private func refresh() { guard !busy else { return }; navigate(page?.path ?? "", remember: false) }
  @objc private func loadMore() { guard !busy, entries.count < 10_000, let page, page.hasNextAfter else { return }; navigate(page.path, after: page.nextAfter, remember: false) }
  @objc private func cancelBrowser() { finish(nil) }

  @objc private func openSelected() {
    guard !busy, entries.indices.contains(table.selectedRow), let page else { return }
    let entry = entries[table.selectedRow]
    guard entry.kind == .directory || entry.kind == .symlink else { return }
    navigate((page.path as NSString).appendingPathComponent(entry.name))
  }

  func navigate(_ path: String, after: String = "", remember: Bool = true, back: Bool = false) {
    generation += 1
    let expected = generation
    task?.cancel()
    busy = true
    status.stringValue = "Loading…"
    updateControls()
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await request(path, after, false)
        guard !Task.isCancelled, generation == expected else { return }
        switch response.result {
        case let .listing(listing):
          guard listing.entries.count <= 200, !listing.path.isEmpty,
                after.isEmpty || listing.path == page?.path,
                !listing.hasNextAfter || (!listing.nextAfter.isEmpty && listing.nextAfter != after && listing.nextAfter == listing.entries.last?.name) else { throw RemoteFilesystemError.invalidResponse }
          if after.isEmpty {
            if back { _ = history.popLast() }
            else if remember, let old = page?.path, old != listing.path { history.append(old) }
            entries = listing.entries
          } else {
            let known = Set(entries.map(\.name))
            entries.append(contentsOf: listing.entries.filter { !known.contains($0.name) })
          }
          page = listing
          pathLabel.stringValue = listing.path
          table.reloadData()
          if after.isEmpty, !entries.isEmpty { table.scrollRowToVisible(0) }
          status.stringValue = entries.isEmpty ? "No items to show." : "\(entries.count) items loaded. Double-click a folder to open it."
        case let .problem(message): status.stringValue = message
        default: throw RemoteFilesystemError.invalidResponse
        }
      } catch is CancellationError {
        guard generation == expected else { return }
        finish(nil)
        return
      } catch {
        guard generation == expected else { return }
        status.stringValue = "Couldn’t open this folder. Check the connection and try again."
      }
      guard generation == expected else { return }
      busy = false
      updateControls()
    }
  }

  @objc private func choose() {
    guard !busy, let page else { return }
    busy = true
    generation += 1
    let expected = generation
    status.stringValue = "Choosing folder…"
    updateControls()
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await request(page.path, "", true)
        guard !Task.isCancelled, generation == expected else { return }
        switch response.result {
        case let .workspaceID(id) where !id.isEmpty: finish(id); return
        case let .problem(message): status.stringValue = message
        default: throw RemoteFilesystemError.invalidResponse
        }
      } catch is CancellationError {
        guard generation == expected else { return }
        finish(nil)
        return
      } catch {
        guard generation == expected else { return }
        status.stringValue = "Couldn’t choose this folder. Try again."
      }
      busy = false
      updateControls()
    }
  }

  private func updateControls() {
    backButton.isEnabled = !busy && !history.isEmpty
    upButton.isEnabled = !busy && page?.hasParentPath == true
    homeButton.isEnabled = !busy
    refreshButton.isEnabled = !busy
    moreButton.isHidden = page?.hasNextAfter != true
    moreButton.isEnabled = !busy && entries.count < 10_000
    if !busy, entries.count >= 10_000, page?.hasNextAfter == true {
      status.stringValue = "Showing the first 10,000 items. Open a subfolder to inspect more."
    }
    chooseButton.isEnabled = !busy && page != nil && page?.hasParentPath == true
  }

  private func finish(_ result: String?) {
    generation += 1
    task?.cancel()
    task = nil
    accountTask?.cancel()
    accountTask = nil
    let callback = completion
    completion = nil
    if let sheet { sheet.sheetParent?.endSheet(sheet) }
    sheet = nil
    entries = []
    pathLabel.stringValue = ""
    status.stringValue = ""
    table.reloadData()
    page = nil
    history = []
    callback?(result)
  }
}

@MainActor
private final class RemoteDirectoryTableView: NSTableView {
  var openFolder: (() -> Void)?
  var parentFolder: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.keyCode == 125 { openFolder?(); return }
    if event.modifierFlags.contains(.command), event.keyCode == 126 { parentFolder?(); return }
    super.keyDown(with: event)
  }
}
