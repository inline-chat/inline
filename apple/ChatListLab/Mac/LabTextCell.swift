import AppKit
import ChatListCore

struct MacGlyphToken: Hashable {
  let row: Int64
  let character: Int
}

final class MacLabTextCell: NSView {
  override var isFlipped: Bool { true }

  let title = NSTextField(labelWithString: "")
  let header = NSTextField(labelWithString: "")
  private let textStorage: NSTextStorage
  let text: NSTextView
  private(set) var rowID: Int64?

  override init(frame: NSRect) {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    textStorage = storage
    text = NSTextView(frame: .zero, textContainer: container)
    super.init(frame: frame)
    autoresizesSubviews = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.cornerRadius = 10
    layer?.masksToBounds = true
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .secondaryLabelColor
    header.font = .systemFont(ofSize: 13, weight: .medium)
    header.textColor = .systemOrange
    text.font = .systemFont(ofSize: 15)
    text.textColor = .labelColor
    text.drawsBackground = false
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = true
    text.isHorizontallyResizable = false
    text.isVerticallyResizable = false
    text.textContainer?.heightTracksTextView = false
    text.autoresizingMask = []
    // Eager layer creation prevents AppKit's later setLayer pass from resizing this prepared child frame.
    text.wantsLayer = true
    addSubview(title)
    addSubview(header)
    addSubview(text)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func bind(_ item: ChatListItem<Int64, LabContent>) {
    rowID = item.id
    title.stringValue = item.content.title
    header.stringValue = item.content.headerText ?? ""
    if text.string != item.content.text { text.string = item.content.text }
    setAccessibilityIdentifier("message-\(item.id)")
  }

  func present(_ placement: TimelineLayout<Int64>.Placement) {
    title.frame = CGRect(x: 18, y: 7, width: max(1, placement.frame.width - 36), height: 18)
    header.frame = placement.row.elements["header"] ?? .zero
    text.frame = placement.row.elements["body"] ?? .zero
  }

  func recycle() {
    rowID = nil
    text.string = ""
    title.stringValue = ""
    header.stringValue = ""
  }

  func capture(_ visible: CGRect) -> ChatListCellAnchor? {
    guard let rowID, let intersection = visible.intersection(text.frame).nonEmpty else { return nil }
    guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
    layout.ensureLayout(for: container)
    let visibleInText = text.convert(intersection, from: self)
    let origin = text.textContainerOrigin
    let visibleInContainer = visibleInText.offsetBy(dx: -origin.x, dy: -origin.y)
    let glyphs = layout.glyphRange(forBoundingRect: visibleInContainer, in: container)
    guard glyphs.location != NSNotFound else { return nil }
    let target = CGPoint(x: visibleInText.midX, y: visibleInText.midY)
    var nearest: (character: Int, distance: CGFloat)?
    for glyph in glyphs.location ..< NSMaxRange(glyphs) {
      let rect = layout.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1), in: container
      )
      guard !rect.isEmpty else { continue }
      let point = CGPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
      guard visibleInText.insetBy(dx: -1, dy: -1).contains(point) else { continue }
      let dx = point.x - target.x
      let dy = point.y - target.y
      let distance = dx * dx + dy * dy
      if nearest.map({ distance < $0.distance }) ?? true {
        nearest = (layout.characterIndexForGlyph(at: glyph), distance)
      }
    }
    guard let nearest,
          nearest.character < text.string.utf16.count else { return nil }
    guard let retainedPoint = glyphPoint(nearest.character),
          visibleInText.insetBy(dx: -1, dy: -1).contains(retainedPoint) else { return nil }
    let localY = text.convert(retainedPoint, to: self).y
    return .init(token: MacGlyphToken(row: rowID, character: nearest.character), localY: localY)
  }

  func resolve(_ anchor: ChatListCellAnchor) -> ChatListAnchorLocation? {
    guard let token = anchor.token.base as? MacGlyphToken, token.row == rowID,
          let localY = localGlyphY(token.character) else { return nil }
    guard localY >= text.frame.minY, localY <= text.frame.maxY,
          localY >= 0, localY <= bounds.height else { return nil }
    return .init(element: "body", offsetY: localY - text.frame.minY)
  }

  func screenGlyphY(_ character: Int) -> CGFloat? {
    guard let window, let point = glyphPoint(character) else { return nil }
    let inWindow = text.convert(point, to: nil)
    return window.convertToScreen(CGRect(origin: inWindow, size: .zero)).minY
  }

  func localGlyphY(_ character: Int) -> CGFloat? {
    guard let point = glyphPoint(character) else { return nil }
    return text.convert(point, to: self).y
  }

  func glyphDiagnostics(_ visible: CGRect) -> String {
    let intersection = visible.intersection(text.frame)
    let localFirst = localGlyphY(0).map(String.init(describing:)) ?? "none"
    let localLast = localGlyphY(max(0, text.string.utf16.count - 1))
      .map(String.init(describing:)) ?? "none"
    return "row \(rowID.map(String.init(describing:)) ?? "none"), cell \(frame), " +
      "body \(text.frame), visible \(visible), text intersection \(intersection), " +
      "characters \(text.string.utf16.count), first glyph \(localFirst), last glyph \(localLast)"
  }

  private func glyphPoint(_ character: Int) -> CGPoint? {
    guard character < text.string.utf16.count else { return nil }
    guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
    layout.ensureLayout(for: container)
    let range = layout.glyphRange(
      forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil
    )
    guard range.length > 0 else { return nil }
    let rect = layout.boundingRect(forGlyphRange: range, in: container)
    guard !rect.isEmpty, rect.minY.isFinite, rect.midY.isFinite else { return nil }
    let origin = text.textContainerOrigin
    return CGPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
  }
}

private extension CGRect {
  var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
