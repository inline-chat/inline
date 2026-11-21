import UIKit
import ChatListCore

struct PhoneGlyphToken: Hashable {
  let row: Int64
  let character: Int
}

final class PhoneLabTextCell: UIView {
  let title = UILabel()
  let header = UILabel()
  private let textStorage: NSTextStorage
  let text: UITextView
  private(set) var rowID: Int64?

  override init(frame: CGRect) {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    textStorage = storage
    text = UITextView(frame: .zero, textContainer: container)
    super.init(frame: frame)
    backgroundColor = .secondarySystemBackground
    layer.cornerRadius = 10
    clipsToBounds = true
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .secondaryLabel
    header.font = .systemFont(ofSize: 13, weight: .medium)
    header.textColor = .systemOrange
    header.numberOfLines = 2
    text.font = .systemFont(ofSize: 16)
    text.textColor = .label
    text.backgroundColor = .clear
    text.isEditable = false
    text.isSelectable = true
    text.isScrollEnabled = false
    text.textContainerInset = .zero
    text.textContainer.lineFragmentPadding = 0
    text.textContainer.widthTracksTextView = true
    text.textContainer.heightTracksTextView = false
    // UIKit may reset the container size when installing it in a zero-frame
    // text view. Retain full glyph layout below a temporarily shortened frame.
    text.textContainer.size = CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    addSubview(title)
    addSubview(header)
    addSubview(text)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func bind(_ item: ChatListItem<Int64, LabContent>) {
    rowID = item.id
    title.text = item.content.title
    header.text = item.content.headerText
    if text.text != item.content.text { text.text = item.content.text }
    accessibilityIdentifier = "message-\(item.id)"
    text.accessibilityIdentifier = "message-body-\(item.id)"
  }

  func present(_ placement: TimelineLayout<Int64>.Placement) {
    title.frame = CGRect(x: 18, y: 7, width: max(1, placement.frame.width - 36), height: 18)
    header.frame = placement.row.elements["header"] ?? .zero
    let body = placement.row.elements["body"] ?? .zero
    if text.frame != body { text.frame = body }
    // UITextView replaces the container height with the visible frame height
    // when its frame changes, even with heightTracksTextView disabled. Keep
    // full TextKit glyph geometry so a retained anchor can be classified as
    // clipped after a height change instead of disappearing from layout.
    let container = text.textContainer
    if container.size.height != CGFloat.greatestFiniteMagnitude {
      container.size = CGSize(width: container.size.width, height: CGFloat.greatestFiniteMagnitude)
    }
  }

  func recycle() {
    rowID = nil
    text.text = ""
    title.text = nil
    header.text = nil
  }

  func capture(_ visible: CGRect) -> ChatListCellAnchor? {
    guard let rowID, let intersection = visible.intersection(text.frame).nonEmpty else { return nil }
    let point = text.convert(CGPoint(x: intersection.midX, y: intersection.midY), from: self)
    let containerPoint = CGPoint(
      x: point.x - text.textContainerInset.left,
      y: point.y - text.textContainerInset.top
    )
    let manager = text.layoutManager
    let glyph = manager.glyphIndex(for: containerPoint, in: text.textContainer)
    guard glyph < manager.numberOfGlyphs else { return nil }
    let character = manager.characterIndexForGlyph(at: glyph)
    guard let glyphPoint = glyphPointInText(character) else { return nil }
    let inCell = text.convert(glyphPoint, to: self)
    guard intersection.insetBy(dx: -1, dy: -1).contains(inCell) else { return nil }
    return .init(token: PhoneGlyphToken(row: rowID, character: character), localY: inCell.y)
  }

  func resolve(_ anchor: ChatListCellAnchor) -> ChatListAnchorLocation? {
    guard let token = anchor.token.base as? PhoneGlyphToken, token.row == rowID,
          let localY = glyphLocalY(token.character) else { return nil }
    guard localY >= text.frame.minY, localY <= text.frame.maxY,
          localY >= 0, localY <= bounds.height else { return nil }
    return .init(element: "body", offsetY: localY - text.frame.minY)
  }

  func screenGlyphY(_ character: Int) -> CGFloat? {
    guard let window, let point = glyphPointInText(character) else { return nil }
    return text.convert(point, to: window).y
  }

  func glyphY(_ character: Int, in root: UIView) -> CGFloat? {
    guard let point = glyphPointInText(character) else { return nil }
    return text.convert(point, to: root).y
  }

  private func glyphLocalY(_ character: Int) -> CGFloat? {
    guard let point = glyphPointInText(character) else { return nil }
    return text.convert(point, to: self).y
  }

  func localGlyphY(_ character: Int) -> CGFloat? { glyphLocalY(character) }

  private func glyphPointInText(_ character: Int) -> CGPoint? {
    guard character >= 0, character < (text.text as NSString).length else { return nil }
    let manager = text.layoutManager
    let characterRange = NSRange(location: character, length: 1)
    manager.ensureLayout(forCharacterRange: characterRange)
    let glyphRange = manager.glyphRange(forCharacterRange: characterRange,
                                        actualCharacterRange: nil)
    guard glyphRange.length > 0, glyphRange.location < manager.numberOfGlyphs else { return nil }
    let rect = manager.boundingRect(
      forGlyphRange: NSRange(location: glyphRange.location, length: 1), in: text.textContainer
    )
    guard !rect.isNull, !rect.isEmpty, rect.minX.isFinite, rect.midY.isFinite else { return nil }
    return CGPoint(
      x: rect.midX + text.textContainerInset.left,
      y: rect.midY + text.textContainerInset.top
    )
  }
}

private extension CGRect {
  var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
