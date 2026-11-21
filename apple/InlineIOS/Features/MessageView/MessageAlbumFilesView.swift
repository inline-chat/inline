import InlineKit
import UIKit

/// An album's files: one row per file, stacked under the album's grid (or alone, for an album of
/// files). Each row is the file's own `DocumentView`, so download, open, upload progress and
/// retry work per file exactly as for a single file.
final class MessageAlbumFilesView: UIView {
  /// The gap between two rows.
  static let rowSpacing: CGFloat = 8

  /// The rows' height for `count` files.
  static func height(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * DocumentView.preferredHeight + CGFloat(count - 1) * rowSpacing
  }

  /// The width the widest row asks for.
  static func preferredWidth(for items: [FullMessage]) -> CGFloat {
    items.map { item in
      DocumentView.preferredWidth(fileName: item.documentInfo?.document.fileName, size: item.documentInfo?.document.size)
    }.max() ?? 0
  }

  private var rows: [Int64: DocumentView] = [:]
  private var order: [Int64] = []

  func configure(items: [FullMessage], outgoing: Bool) {
    let ids = Set(items.map(\.id))
    for (id, row) in rows where !ids.contains(id) {
      row.removeFromSuperview()
      rows[id] = nil
    }
    order = items.map(\.id)
    for item in items {
      if let row = rows[item.id] {
        row.update(with: item, outgoing: outgoing)
      } else {
        let row = DocumentView(fullMessage: item, outgoing: outgoing)
        addSubview(row)
        rows[item.id] = row
      }
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let step = DocumentView.preferredHeight + Self.rowSpacing
    for (index, id) in order.enumerated() {
      rows[id]?.frame = CGRect(x: 0, y: CGFloat(index) * step, width: bounds.width, height: DocumentView.preferredHeight)
    }
  }

  /// The file a point in this view falls on, for menus and replies aimed at one file.
  func item(at point: CGPoint) -> FullMessage? {
    for id in order {
      guard let row = rows[id], row.frame.insetBy(dx: 0, dy: -Self.rowSpacing / 2).contains(point) else { continue }
      return row.fullMessage
    }
    return nil
  }

  /// The row showing `messageId`, for the menu's Open Document.
  func rowView(messageId: Int64) -> DocumentView? {
    rows.values.first { $0.fullMessage?.message.messageId == messageId }
  }
}
