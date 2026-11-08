import AppKit
import InlineWebWidget

enum SpikeRow {
  case text(String)
  case widget(WidgetContent, SpikeFixture)
}

/// A message-list-shaped NSTableView: planned row heights, no automatic row
/// heights, `noteHeightOfRows` for async height changes, idle-gated mounting.
@MainActor
final class SpikeListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, WidgetCoordinatorDelegate {
  static let horizontalInset: CGFloat = 16
  static let verticalInset: CGFloat = 8
  static let idleDelay: TimeInterval = 0.15

  let scrollView = NSScrollView()
  let tableView = NSTableView()
  let coordinator: WidgetCoordinator
  let rows: [SpikeRow]
  let metrics: SpikeMetrics
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("chat.inline.widget-spike"))
  private var idleTimer: Timer?
  private(set) var isScrolling = false
  private var rowIndexByKey: [String: Int] = [:]

  init(coordinator: WidgetCoordinator, rows: [SpikeRow], metrics: SpikeMetrics) {
    self.coordinator = coordinator
    self.rows = rows
    self.metrics = metrics
    super.init()
    for (index, row) in rows.enumerated() {
      if case let .widget(content, _) = row { rowIndexByKey[content.key] = index }
    }
    coordinator.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.usesAutomaticRowHeights = false
    tableView.intercellSpacing = .zero
    tableView.selectionHighlightStyle = .none
    tableView.backgroundColor = .clear
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.dataSource = self
    tableView.delegate = self
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  // Must equal the host view's width, which keys the height and snapshot caches.
  var contentWidth: CGFloat { max(320, (tableView.tableColumns.first?.width ?? tableView.bounds.width) - Self.horizontalInset * 2) }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .text: 44
    case let .widget(content, _):
      Self.verticalInset * 2 + WidgetHostView.headerHeight + CGFloat(coordinator.plannedHeight(for: content, width: contentWidth))
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case let .text(text):
      let id = NSUserInterfaceItemIdentifier("text")
      let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SpikeTextCell ?? SpikeTextCell(identifier: id)
      cell.label.stringValue = text
      return cell
    case let .widget(content, _):
      let id = NSUserInterfaceItemIdentifier("widget")
      let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SpikeWidgetCell ?? SpikeWidgetCell(identifier: id)
      if let old = cell.host.content?.key, old != content.key, coordinator.isLive(old) {
        coordinator.unmount(key: old, snapshot: false)
      }
      let width = contentWidth
      let snapshot = coordinator.snapshot(for: content, width: width)
      let measured = coordinator.measuredHeight(for: content, width: width)
      let planned = coordinator.plannedHeight(for: content, width: width)
      cell.host.configure(
        content: content,
        snapshot: snapshot,
        contentHeight: CGFloat(measured ?? planned),
        isClipped: (measured ?? content.heightHint ?? 0) > planned
      )
      metrics.rowConfigured(hadSnapshot: snapshot != nil, hadMeasuredHeight: measured != nil)
      return cell
    }
  }

  func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
    guard let cell = rowView.view(atColumn: 0) as? SpikeWidgetCell, let key = cell.host.content?.key, coordinator.isLive(key) else { return }
    coordinator.unmount(key: key)
  }

  // MARK: Scrolling and mounting

  @objc private func boundsChanged() {
    isScrolling = true
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.becameIdle() }
    }
  }

  func becameIdle() {
    isScrolling = false
    let visible = tableView.visibleRect
    // Unmount anything a screen or more away.
    let keepRect = visible.insetBy(dx: 0, dy: -visible.height)
    for key in coordinator.liveKeys {
      guard let row = rowIndexByKey[key] else { continue }
      if !tableView.rect(ofRow: row).intersects(keepRect) { coordinator.unmount(key: key) }
    }
    // Mount widgets at least half visible, top first, within the budget.
    var hosts: [WidgetHostView] = []
    let range = tableView.rows(in: visible)
    for row in range.location..<(range.location + range.length) {
      guard case .widget = rows[row], let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeWidgetCell else { continue }
      let rect = tableView.rect(ofRow: row)
      let shown = rect.intersection(visible).height
      if shown >= min(rect.height, visible.height) * 0.5 { hosts.append(cell.host) }
    }
    let keep = Set(hosts.compactMap { $0.content?.key })
    for host in hosts.prefix(coordinator.configuration.maxLive) {
      coordinator.mount(host, keep: keep)
    }
  }

  // MARK: Coordinator delegate

  func widgetCoordinator(_ coordinator: WidgetCoordinator, heightChangedFor key: String) {
    guard let row = rowIndexByKey[key], case let .widget(content, _) = rows[row] else { return }
    let visible = tableView.visibleRect
    let oldRect = tableView.rect(ofRow: row)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }
    let newRect = tableView.rect(ofRow: row)
    // Keep the reading position when a row above the viewport changes height.
    if oldRect.maxY <= visible.minY + 1, newRect.height != oldRect.height {
      let origin = NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y + newRect.height - oldRect.height)
      scrollView.contentView.setBoundsOrigin(origin)
      metrics.anchorCorrections += 1
    }
    metrics.heightChanges += 1
    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeWidgetCell {
      let measured = coordinator.measuredHeight(for: content, width: contentWidth) ?? 0
      cell.host.contentHeight = CGFloat(measured)
      cell.host.isClipped = measured > coordinator.plannedHeight(for: content, width: contentWidth)
      cell.needsLayout = true
    }
  }

  func widgetCoordinator(_ coordinator: WidgetCoordinator, perform request: WidgetRequest, for key: String) -> String? {
    metrics.requests.append("\(key): \(request)")
    switch request {
    case let .copy(text):
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    case .sendPrompt, .action, .openLink, .openImage:
      // The spike records these; the app would fill the composer, invoke the
      // bot callback, open the browser, or show the image viewer.
      break
    }
    return nil
  }

  func widgetCoordinator(_ coordinator: WidgetCoordinator, didEmit event: WidgetEvent) {
    metrics.record(event, isScrolling: isScrolling)
  }
}

final class SpikeTextCell: NSTableCellView {
  let label = NSTextField(wrappingLabelWithString: "")
  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    label.font = .systemFont(ofSize: 13)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    label.frame = bounds.insetBy(dx: SpikeListController.horizontalInset, dy: 6)
  }
}

final class SpikeWidgetCell: NSTableCellView {
  let host = WidgetHostView(frame: .zero)
  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    addSubview(host)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    host.frame = bounds.insetBy(dx: SpikeListController.horizontalInset, dy: SpikeListController.verticalInset)
  }
}
