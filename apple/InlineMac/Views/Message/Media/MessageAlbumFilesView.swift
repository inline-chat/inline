import AppKit
import InlineKit

/// An album's files on the Mac: one row per file (`MessageAlbum.fileItems`), stacked under the
/// album's grid, or alone for an album of files. The message view lays the rows out as one
/// document slot their height and puts this view in it; each row is the file's own
/// `DocumentView`, so download, Quick Look, Finder and upload progress work per file.
final class MessageAlbumFilesView: NSView {
  /// The gap between two rows.
  static let rowSpacing: CGFloat = 8

  /// The rows' height: each file's row, with a gap between them.
  static func height(for items: [FullMessage]) -> CGFloat {
    let rows = items.compactMap(\.documentInfo).map(DocumentPresentationPlan.preferredHeight(for:))
    guard !rows.isEmpty else { return 0 }
    return rows.reduce(0, +) + CGFloat(rows.count - 1) * rowSpacing
  }

  /// The width the widest row asks for.
  static func preferredWidth(for items: [FullMessage]) -> CGFloat {
    items.compactMap(\.documentInfo).map(DocumentPresentationPlan.preferredWidth(for:)).max() ?? 0
  }

  private var rows: [Int64: DocumentView] = [:]
  private var order: [Int64] = []

  override var isFlipped: Bool { true }

  /// Each row takes the message's menu (`menu`), set by the message view.
  override var menu: NSMenu? {
    didSet { rows.values.forEach { $0.menu = menu } }
  }

  func configure(items: [FullMessage], white: Bool) {
    let files = items.filter { $0.documentInfo != nil }
    let ids = Set(files.map(\.id))
    for (id, row) in rows where !ids.contains(id) {
      row.removeFromSuperview()
      rows[id] = nil
    }
    order = files.map(\.id)
    for item in files {
      guard let documentInfo = item.documentInfo else { continue }
      if let row = rows[item.id] {
        row.update(with: documentInfo, fullMessage: item)
      } else {
        let row = DocumentView(documentInfo: documentInfo, fullMessage: item, white: white)
        row.translatesAutoresizingMaskIntoConstraints = true
        row.menu = menu
        addSubview(row)
        rows[item.id] = row
      }
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for id in order {
      guard let row = rows[id] else { continue }
      let height = DocumentPresentationPlan.preferredHeight(for: row.documentInfo)
      row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
      y += height + Self.rowSpacing
    }
  }

  /// The row under a point in this view, for actions aimed at one file.
  func row(at point: CGPoint) -> DocumentView? {
    order.lazy.compactMap { self.rows[$0] }.first { row in
      row.frame.insetBy(dx: 0, dy: -Self.rowSpacing / 2).contains(point)
    }
  }
}
