import AppKit
import ScrollTimeline
import TimelineAppKit
import TimelineCore

// The lab chat of TimelineMacLab (same rows, same text, same heights, same views), copied so both lists get identical
// rows, with two additions for the screen measurement: every row paints a full-width shade (two shades alternating,
// so a row's extent on screen is visible) and the window behind the list is white (so a blank strip is white).
// Sticky avatars and the floating date are left out: the prototype does not have them, so the engine runs without
// them too (its pins and header cost a little per frame; noted where it matters).

@MainActor
final class LabChat {
  struct Row {
    var id: Int
    var text: String
    var sender: Int
    var isDay: Bool
    /// 0 or 1: alternates between neighbours, so row boundaries show on screen.
    var shade: Int
    var outgoing: Bool { sender == 0 }
  }

  private(set) var rows: [Row] = []
  private var byID: [Int: Int] = [:]
  private var groupEnd: [Int: Bool] = [:]
  /// Group (first id, last id) of every message row, and the day row each row's section opens with.
  private var groups: [Int: (start: Int, end: Int)] = [:]
  private var sections: [Int: Int] = [:]
  /// Sticky avatars are drawn by the list (the prototype's two containers), not by the rows.
  var listDrawsAvatars = false
  private var nextID = 1_000_000
  /// Milliseconds of busy work in every row make and update, standing for heavier production rows.
  var rowCost: Double = 0
  /// Row discipline of the row-cost plan (secret-sauce 2026-11-27-macos-row-cost-plan.md): a row's plan (its layout,
  /// the bulk of `rowCost`) is cached once made; a row whose plan is ready costs only `bindCost` to make or update.
  /// With `preparesAhead`, plans are made ahead of the list in idle main-thread slices (`RowPreparer`).
  var bindCost: Double = 0.2
  var preparesAhead = false
  private(set) var plans = Set<Int>()
  private(set) var plansMadeOnDemand = 0
  private(set) var plansMadeAhead = 0
  private var heightCache: [Int: (width: CGFloat, text: String, last: Bool, height: CGFloat)] = [:]
  private var pool: [LabRowView] = []
  private(set) var makes = 0
  private(set) var updates = 0
  /// Seconds spent in the host's row work (heights, makes, updates, recycles) as the list asked for it.
  private(set) var hostSeconds: Double = 0
  private(set) var live: [Int: LabRowView] = [:]

  static let font = NSFont.systemFont(ofSize: 13)
  static let words = "the quick brown fox jumps over a lazy dog while messages keep arriving in the chat window"
    .split(separator: " ")
  static let avatarSize: CGFloat = 28
  static let dayHeight: CGFloat = 34

  init(count: Int, seed: UInt64 = 7, groupRun: Int = 4) {
    _ = 0
    var rng = SplitMix(seed: seed)
    var sender = 1
    var left = 0
    var day = 0
    for i in 0 ..< count {
      if i % 40 == 0 {
        rows.append(Row(id: i * 2 + 1, text: "Day \(day)", sender: -1, isDay: true, shade: rows.count % 2))
        day += 1
      }
      if left == 0 {
        sender = Int(rng.next() % 4)
        left = 1 + Int(rng.next() % UInt64(max(1, groupRun * 2)))
      }
      left -= 1
      let length = Int(rng.next() % 40) + 1 + (rng.next() % 9 == 0 ? 60 : 0)
      let text = (0 ..< length).map { _ in String(Self.words[Int(rng.next() % UInt64(Self.words.count))]) }
        .joined(separator: " ")
      rows.append(Row(id: i * 2, text: "#\(i) " + text, sender: sender, isDay: false, shade: rows.count % 2))
    }
    reindex()
  }

  private func reindex() {
    byID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    groupEnd = [:]
    groups = [:]
    sections = [:]
    var start: Int?
    var day: Int?
    for (index, row) in rows.enumerated() {
      if row.isDay {
        day = row.id
        sections[row.id] = row.id
        start = nil
        continue
      }
      if let day { sections[row.id] = day }
      if start == nil { start = index }
      let nextIsSame = index + 1 < rows.count && !rows[index + 1].isDay && rows[index + 1].sender == row.sender
      groupEnd[row.id] = !nextIsSame
      if !nextIsSame, let s = start {
        for i in s ... index { groups[rows[i].id] = (rows[s].id, row.id) }
        start = nil
      }
    }
  }

  func group(_ id: Int) -> (start: Int, end: Int)? { groups[id] }
  func section(_ id: Int) -> Int? { sections[id] }

  var ids: [Int] { rows.map(\.id) }
  func row(_ id: Int) -> Row? { byID[id].map { rows[$0] } }
  func index(_ id: Int) -> Int? { byID[id] }
  func isLastInGroup(_ id: Int) -> Bool { groupEnd[id] ?? true }
  func showsAvatar(_ id: Int) -> Bool {
    guard let row = row(id), !row.isDay, !row.outgoing else { return false }
    return isLastInGroup(id)
  }

  // MARK: - Mutations

  @discardableResult
  func append(_ text: String, sender: Int = 1) -> Int {
    nextID += 1
    let shade = 1 - (rows.last?.shade ?? 1)
    rows.append(Row(id: nextID, text: text, sender: sender, isDay: false, shade: shade))
    reindex()
    return nextID
  }

  /// A page of history above the oldest row: a day of `count` messages.
  @discardableResult
  func prepend(_ count: Int) -> [Int] {
    var page: [Row] = []
    nextID += 1
    page.append(Row(id: nextID, text: "Older day \(nextID)", sender: -1, isDay: true, shade: 0))
    for i in 0 ..< count {
      nextID += 1
      page.append(Row(
        id: nextID, text: "older \(i) " + String(repeating: "lorem ipsum ", count: 1 + i % 7), sender: (i / 3) % 3,
        isDay: false, shade: 0
      ))
    }
    // Alternate backwards from the old first row.
    var shade = rows.first?.shade ?? 0
    for i in page.indices.reversed() {
      shade = 1 - shade
      page[i].shade = shade
    }
    rows.insert(contentsOf: page, at: 0)
    reindex()
    return page.map(\.id)
  }

  func setText(_ id: Int, _ text: String) {
    guard let i = byID[id] else { return }
    rows[i].text = text
  }

  // MARK: - Rows

  static func textWidth(_ width: CGFloat) -> CGFloat { min(520, width * 0.7) - 24 }
  static func bottomGap(last: Bool) -> CGFloat { last ? 8 : 2 }

  func height(_ id: Int, _ width: CGFloat) -> CGFloat {
    let began = CACurrentMediaTime()
    defer { hostSeconds += CACurrentMediaTime() - began }
    guard let row = row(id) else { return 0 }
    if row.isDay { return Self.dayHeight }
    let last = isLastInGroup(id)
    if let cached = heightCache[id], cached.width == width, cached.text == row.text, cached.last == last {
      return cached.height
    }
    let rect = NSAttributedString(string: row.text, attributes: [.font: Self.font]).boundingRect(
      with: NSSize(width: Self.textWidth(width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    var height = 2 + ceil(rect.height) + 16 + Self.bottomGap(last: last)
    if showsAvatar(id) { height = max(height, 2 + Self.avatarSize + Self.bottomGap(last: true)) }
    heightCache[id] = (width, row.text, last, height)
    return height
  }

  func make(_ id: Int, _ width: CGFloat) -> NSView {
    let began = CACurrentMediaTime()
    defer { hostSeconds += CACurrentMediaTime() - began }
    makes += 1
    burn(id)
    let view = pool.popLast() ?? LabRowView()
    configure(view, id, width)
    live[id] = view
    return view
  }

  func update(_ id: Int, _ view: NSView, _ width: CGFloat) {
    let began = CACurrentMediaTime()
    defer { hostSeconds += CACurrentMediaTime() - began }
    updates += 1
    burn(id)
    guard let view = view as? LabRowView else { return }
    configure(view, id, width)
  }

  func recycle(_ id: Int, _ view: NSView) {
    if live[id] === view { live[id] = nil }
    if let view = view as? LabRowView, pool.count < 64 { pool.append(view) }
  }

  private func configure(_ view: LabRowView, _ id: Int, _ width: CGFloat) {
    guard let row = row(id) else { return }
    view.configure(row: row, width: width, height: height(id, width), last: isLastInGroup(id),
                   avatar: showsAvatar(id) && !listDrawsAvatars,
                   textFrame: Self.textInLayer && !row.isDay ? textFrame(id, width) : nil)
  }

  /// Row text drawn by Core Animation in a plain layer from a prebuilt Core Text frame (`--layer-text`), instead of an
  /// NSTextField drawn by AppKit.
  static let textInLayer = CommandLine.arguments.contains("--layer-text")
  /// Core Text frames by row: part of a row's plan (kept with it, made ahead with it); without the plan discipline,
  /// typeset again on every bind.
  private var textFrames: [Int: (width: CGFloat, text: String, frame: CTFrame)] = [:]

  func textFrame(_ id: Int, _ width: CGFloat) -> CTFrame? {
    guard let row = row(id) else { return nil }
    if preparesAhead, let cached = textFrames[id], cached.width == width, cached.text == row.text { return cached.frame }
    let size = LabRowView.textSize(row.text, width: width, height: height(id, width), last: isLastInGroup(id))
    let attributed = NSAttributedString(string: row.text, attributes: [.font: Self.font, .foregroundColor: NSColor.black])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                         CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
    if preparesAhead { textFrames[id] = (width, row.text, frame) }
    return frame
  }

  /// A row's cost when the list asks for it: the whole cost without a plan (which is then kept), the bind only with one.
  /// Without the prepared discipline every make and update pays the whole cost, as before.
  private func burn(_ id: Int) {
    guard rowCost > 0 else { return }
    var cost = rowCost
    if preparesAhead {
      if plans.contains(id) {
        cost = min(rowCost, bindCost)
      } else {
        plans.insert(id)
        plansMadeOnDemand += 1
      }
    }
    let end = CACurrentMediaTime() + cost / 1000
    while CACurrentMediaTime() < end {}
  }

  /// Makes a row's plan ahead (the cost a cold row pays beyond its bind). Returns false when it already had one.
  @discardableResult
  func preparePlan(_ id: Int, width: CGFloat = 0) -> Bool {
    guard rowCost > 0, !plans.contains(id), byID[id] != nil else { return false }
    plans.insert(id)
    plansMadeAhead += 1
    if Self.textInLayer, width > 0, row(id)?.isDay == false { _ = textFrame(id, width) }
    let end = CACurrentMediaTime() + max(0, rowCost - min(rowCost, bindCost)) / 1000
    while CACurrentMediaTime() < end {}
    return true
  }

  func engineRows(sticky: Bool = false) -> TimelineRows<Int> {
    guard sticky else {
      return TimelineRows(
        height: { [unowned self] id, width in self.height(id, width) },
        make: { [unowned self] id, width in self.make(id, width) },
        update: { [unowned self] id, view, width, _ in self.update(id, view, width) },
        recycle: { [unowned self] id, view in self.recycle(id, view) }
      )
    }
    return TimelineRows(
      height: { [unowned self] id, width in self.height(id, width) },
      make: { [unowned self] id, width in self.make(id, width) },
      update: { [unowned self] id, view, width, _ in self.update(id, view, width) },
      recycle: { [unowned self] id, view in self.recycle(id, view) },
      pin: { [unowned self] id, view in
        guard let view = view as? LabRowView, self.showsAvatar(id), let group = self.group(id) else { return nil }
        return TimelinePin(view: view.avatar, bottom: view.avatarRest.maxY, height: Self.avatarSize, spanStart: group.start)
      },
      spanTop: { _, _ in 2 },
      spanEnd: { [unowned self] id in
        guard let group = self.group(id), group.end != id, self.showsAvatar(group.end) else { return nil }
        return group.end
      }
    )
  }

  func engineHeader() -> TimelineFloatingHeader<Int> {
    TimelineFloatingHeader(
      view: LabDayPill(), height: Self.dayHeight, gap: 0, section: { [unowned self] in self.section($0) },
      configure: { [unowned self] view, id in (view as? LabDayPill)?.title = self.row(id)?.text ?? "" }
    )
  }

  /// The prototype's floating date (the same pill).
  func scrollHeader(host: ScrollListHeader<Int>.Host) -> ScrollListHeader<Int> {
    ScrollListHeader(
      view: LabDayPill(), height: Self.dayHeight, gap: 0, section: { [unowned self] in self.section($0) },
      configure: { [unowned self] view, id in (view as? LabDayPill)?.title = self.row(id)?.text ?? "" }, host: host
    )
  }

  func scrollRows(sticky: Bool = false) -> ScrollListRows<Int> {
    var rows = ScrollListRows<Int>(
      height: { [unowned self] id, width in self.height(id, width) },
      make: { [unowned self] id, width in self.make(id, width) },
      update: { [unowned self] id, view, width in self.update(id, view, width) },
      recycle: { [unowned self] id, view in self.recycle(id, view) }
    )
    guard sticky else { return rows }
    listDrawsAvatars = true
    rows.pin = { [unowned self] id, width in
      guard self.showsAvatar(id), let group = self.group(id) else { return nil }
      let bottom = self.height(id, width) - Self.bottomGap(last: true)
      return ScrollListPin(bottom: bottom, height: Self.avatarSize, x: 16, width: Self.avatarSize, spanStart: group.start)
    }
    rows.spanTop = { _ in 2 }
    rows.spanEnd = { [unowned self] id in
      guard let group = self.group(id), group.end != id, self.showsAvatar(group.end) else { return nil }
      return group.end
    }
    rows.makePin = {
      let view = NSView()
      view.wantsLayer = true
      view.layer?.cornerRadius = Self.avatarSize / 2
      view.layer?.backgroundColor = NSColor.systemOrange.cgColor
      return view
    }
    return rows
  }
}

/// The two row shades, the text colour threshold and the white behind the list: what the screen analysis reads.
enum LabColors {
  static let shades: [NSColor] = [
    NSColor(srgbRed: 0.86, green: 0.91, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 1.0, green: 0.92, blue: 0.82, alpha: 1),
  ]
  static let band = NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
  static let composer = NSColor(srgbRed: 0.75, green: 0.6, blue: 0.9, alpha: 1)
}

final class LabRowView: NSView {
  let bubble = NSView()
  let label = LabLabel(labelWithString: "")
  let textLayer = LabTextLayer()
  let avatar = NSView()
  private let day = LabDayPill()
  override var isFlipped: Bool { true }
  override class var isCompatibleWithResponsiveScrolling: Bool { true }
  private(set) var rowID = 0
  /// The avatar's resting place, top-down in the row (the engine moves its frame while it is lifted).
  private(set) var avatarRest = NSRect.zero

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    bubble.wantsLayer = true
    bubble.layer?.cornerRadius = 12
    addSubview(bubble)
    label.font = LabChat.font
    label.textColor = .black
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.cell?.wraps = true
    bubble.addSubview(label)
    bubble.layer?.addSublayer(textLayer)
    avatar.wantsLayer = true
    avatar.layer?.cornerRadius = LabChat.avatarSize / 2
    avatar.layer?.backgroundColor = NSColor.systemOrange.cgColor
    addSubview(avatar)
    addSubview(day)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Whether the row's text is drawn as last configured (the text field's or the text layer's).
  var showsItsText: Bool { textLayer.isHidden ? label.showsItsText : textLayer.showsItsText }

  /// The text's box in the bubble.
  static func textSize(_ text: String, width: CGFloat, height: CGFloat, last: Bool) -> CGSize {
    let used = min(LabChat.textWidth(width), ceil(NSAttributedString(string: text, attributes: [.font: LabChat.font]).size().width) + 2)
    return CGSize(width: used, height: height - 2 - LabChat.bottomGap(last: last) - 16)
  }

  func configure(row: LabChat.Row, width: CGFloat, height: CGFloat, last: Bool, avatar shows: Bool, textFrame: CTFrame? = nil) {
    rowID = row.id
    layer?.backgroundColor = LabColors.shades[row.shade].cgColor
    if row.isDay {
      bubble.isHidden = true
      avatar.isHidden = true
      day.isHidden = false
      day.title = row.text
      day.frame = NSRect(x: 0, y: 0, width: width, height: height)
      return
    }
    day.isHidden = true
    bubble.isHidden = false
    label.stringValue = row.text
    label.alignment = .left
    bubble.layer?.backgroundColor = (row.outgoing
      ? NSColor(srgbRed: 0.7, green: 0.82, blue: 1, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)).cgColor
    let textWidth = LabChat.textWidth(width)
    let used = min(textWidth, ceil(NSAttributedString(string: row.text, attributes: [.font: LabChat.font]).size().width) + 2)
    let bubbleWidth = used + 24
    let gap = LabChat.bottomGap(last: last)
    let bubbleHeight = height - 2 - gap
    let x = row.outgoing ? width - bubbleWidth - 16 : 16 + LabChat.avatarSize + 8
    bubble.frame = NSRect(x: x, y: 2, width: bubbleWidth, height: bubbleHeight)
    label.frame = NSRect(x: 12, y: 8, width: used, height: bubbleHeight - 16)
    if let textFrame {
      label.isHidden = true
      textLayer.isHidden = false
      textLayer.contentsScale = window?.backingScaleFactor ?? 2
      textLayer.frame = label.frame
      textLayer.set(row.text, frame: textFrame)
    } else {
      label.isHidden = false
      textLayer.isHidden = true
    }
    avatar.isHidden = !shows
    avatarRest = NSRect(x: 16, y: height - gap - LabChat.avatarSize, width: LabChat.avatarSize, height: LabChat.avatarSize)
    avatar.frame = avatarRest
  }
}

/// The row's text, recording whether AppKit has drawn what it was last given (a recycled row shows its old text
/// until it draws again; the screen alone cannot tell old text from new).
/// Text drawn by Core Animation in a plain layer from a prebuilt Core Text frame (Telegram's `TextViewLayer`,
/// TimelineMacLab's `LabTextLayer`): null actions, marked for display on bind, drawn wherever the layer is, whatever
/// AppKit's visible rect says.
final class LabTextLayer: CALayer {
  private(set) var drawnText: String?
  private(set) var text = ""
  private var ctFrame: CTFrame?

  override init() {
    super.init()
    needsDisplayOnBoundsChange = false
  }

  override init(layer: Any) { super.init(layer: layer) }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func action(forKey event: String) -> (any CAAction)? { NSNull() }

  func set(_ text: String, frame: CTFrame) {
    self.text = text
    ctFrame = frame
    setNeedsDisplay()
  }

  override func draw(in ctx: CGContext) {
    guard let ctFrame else { return }
    ctx.saveGState()
    // Core Text draws y-up; a flipped context (contents flipped by a flipped ancestor) is turned back.
    if contentsAreFlipped() {
      ctx.translateBy(x: 0, y: bounds.height)
      ctx.scaleBy(x: 1, y: -1)
    }
    ctx.textMatrix = .identity
    CTFrameDraw(ctFrame, ctx)
    ctx.restoreGState()
    drawnText = text
  }

  var showsItsText: Bool { drawnText == text && !text.isEmpty }
}

final class LabLabel: NSTextField {
  private(set) var drawnText: String?
  override class var isCompatibleWithResponsiveScrolling: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawnText = stringValue
  }

  var showsItsText: Bool { drawnText == stringValue }
}

final class LabDayPill: NSView {
  private let capsule = NSView()
  let label = NSTextField(labelWithString: "")
  override var isFlipped: Bool { true }
  override class var isCompatibleWithResponsiveScrolling: Bool { true }

  var title: String = "" {
    didSet {
      label.stringValue = title
      needsLayout = true
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    capsule.wantsLayer = true
    capsule.layer?.backgroundColor = NSColor.white.cgColor
    capsule.layer?.borderColor = NSColor.gray.cgColor
    capsule.layer?.borderWidth = 1
    capsule.layer?.cornerRadius = 11
    addSubview(capsule)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .black
    label.alignment = .center
    capsule.addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let w: CGFloat = 110
    capsule.frame = NSRect(x: (bounds.width - w) / 2, y: 6, width: w, height: 22)
    label.frame = NSRect(x: 0, y: 3, width: w, height: 16)
  }
}

struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
