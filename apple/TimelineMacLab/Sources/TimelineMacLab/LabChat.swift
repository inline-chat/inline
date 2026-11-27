import AppKit
import TimelineAppKit
import TimelineCore

/// A fake chat: rows are structs, heights come from Core Text at the row's width, views are plain AppKit. Messages
/// come in sender groups (an incoming group shows its sender's avatar on its last row, which sticks to the bottom edge
/// while the group is in sight) and day sections (a day separator row opens each; the day floats at the top).
@MainActor
final class LabChat {
  struct Row {
    var id: Int
    var text: String
    /// 0 is me (outgoing).
    var sender: Int
    var isDay: Bool
    var outgoing: Bool { sender == 0 }
  }

  struct Group {
    var start: Int
    var end: Int
  }

  private(set) var rows: [Row] = []
  private var byID: [Int: Int] = [:]
  /// Group of every message row by index; day rows have none.
  private var groups: [Int: Group] = [:]
  /// The day row each row's section opens with, by index.
  private var sections: [Int: Int] = [:]
  private var nextID = 1_000_000
  private var dayCounter = 0
  /// Milliseconds of busy work in every row make and update, to stand for heavier production rows.
  var rowCost: Double = 0
  /// Off: a host that lays its insides out at the new size at once (as Auto Layout does), not on the change's timing.
  var animatesInsides = true
  private var heightCache: [Int: (width: CGFloat, text: String, last: Bool, height: CGFloat)] = [:]
  private var pool: [LabRowView] = []
  private(set) var makes = 0
  private(set) var updates = 0
  /// Every placed row view, for probes.
  private(set) var live: [Int: LabRowView] = [:]

  static let font = NSFont.systemFont(ofSize: 13)
  static let words = "the quick brown fox jumps over a lazy dog while messages keep arriving in the chat window".split(separator: " ")
  static let avatarSize: CGFloat = 28
  static let topPinGap: CGFloat = 8
  static let dayHeight: CGFloat = 34

  init(count: Int, seed: UInt64 = 7, groupRun: Int = 4) {
    var rng = SplitMix(seed: seed)
    var sender = 1
    var left = 0
    for i in 0 ..< count {
      if i % 40 == 0 {
        rows.append(Row(id: i * 2 + 1, text: "Day \(dayCounter)", sender: -1, isDay: true))
        dayCounter += 1
      }
      if left == 0 {
        sender = Int(rng.next() % 4)
        left = 1 + Int(rng.next() % UInt64(max(1, groupRun * 2)))
      }
      left -= 1
      let length = Int(rng.next() % 40) + 1 + (rng.next() % 9 == 0 ? 60 : 0)
      let text = (0 ..< length).map { _ in String(Self.words[Int(rng.next() % UInt64(Self.words.count))]) }.joined(separator: " ")
      rows.append(Row(id: i * 2, text: "#\(i) " + text, sender: sender, isDay: false))
    }
    reindex()
  }

  private func reindex() {
    byID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    groups = [:]
    sections = [:]
    var start: Int?
    var day: Int?
    for (index, row) in rows.enumerated() {
      if row.isDay {
        day = index
        start = nil
        sections[index] = index
        continue
      }
      if let day { sections[index] = day }
      if start == nil { start = index }
      let nextIsSame = index + 1 < rows.count && !rows[index + 1].isDay && rows[index + 1].sender == row.sender
      if !nextIsSame, let s = start {
        closeGroup(from: s, to: index)
        start = nil
      }
    }
  }

  private func closeGroup(from start: Int, to end: Int) {
    guard start <= end else { return }
    for i in start ... end { groups[i] = Group(start: start, end: end) }
  }

  var ids: [Int] { rows.map(\.id) }
  func row(_ id: Int) -> Row? { byID[id].map { rows[$0] } }
  func index(_ id: Int) -> Int? { byID[id] }

  func group(_ id: Int) -> (start: Int, end: Int)? {
    guard let i = byID[id], let g = groups[i] else { return nil }
    return (rows[g.start].id, rows[g.end].id)
  }

  func isLastInGroup(_ id: Int) -> Bool { group(id)?.end == id }
  /// Minimal style: the avatar sits at the top of its group's first row and keeps to the top edge (a top pin).
  var topPins = false

  func showsAvatar(_ id: Int) -> Bool {
    guard let row = row(id), !row.isDay, !row.outgoing else { return false }
    return topPins ? group(id)?.start == id : isLastInGroup(id)
  }

  /// The day row the row's section opens with.
  func section(_ id: Int) -> Int? {
    guard let i = byID[id], let s = sections[i] else { return nil }
    return rows[s].id
  }

  // MARK: - Mutations

  @discardableResult
  func append(_ text: String, outgoing: Bool = false, sender: Int? = nil) -> Int {
    nextID += 1
    rows.append(Row(id: nextID, text: text, sender: sender ?? (outgoing ? 0 : 1), isDay: false))
    reindex()
    return nextID
  }

  /// A page of history above the oldest row: a day of `count` messages.
  func prepend(_ count: Int) -> [Int] {
    var page: [Row] = []
    nextID += 1
    page.append(Row(id: nextID, text: "Older day \(nextID)", sender: -1, isDay: true))
    for i in 0 ..< count {
      nextID += 1
      page.append(Row(
        id: nextID, text: "older \(i) " + String(repeating: "lorem ipsum ", count: 1 + i % 7), sender: (i / 3) % 3, isDay: false
      ))
    }
    rows.insert(contentsOf: page, at: 0)
    reindex()
    return page.map(\.id)
  }

  /// A page of newer history below the newest row.
  func appendPage(_ count: Int) -> [Int] {
    var page: [Row] = []
    for i in 0 ..< count {
      nextID += 1
      page.append(Row(id: nextID, text: "newer \(i) " + String(repeating: "dolor sit ", count: 1 + i % 5), sender: (i / 2) % 3, isDay: false))
    }
    rows.append(contentsOf: page)
    reindex()
    return page.map(\.id)
  }

  func setText(_ id: Int, _ text: String) {
    guard let i = byID[id] else { return }
    rows[i].text = text
  }

  func delete(_ id: Int) {
    rows.removeAll { $0.id == id }
    reindex()
  }

  // MARK: - Passages (where a point in a row's text goes when it rewraps)

  /// The text's top in its row: the bubble's top (2) and the label's inset in it (8).
  static let textTop: CGFloat = 10

  /// The row's text laid out at a row width: each line's first character, top and height (TextKit, the label's font).
  func lines(_ id: Int, width: CGFloat) -> [(location: Int, y: CGFloat, height: CGFloat)] {
    guard let row = row(id), !row.isDay else { return [] }
    let storage = NSTextStorage(string: row.text, attributes: [.font: Self.font])
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: Self.textWidth(width), height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    var lines: [(Int, CGFloat, CGFloat)] = []
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
      lines.append((manager.characterIndexForGlyph(at: glyphs.location), rect.minY, rect.height))
    }
    return lines
  }

  /// Where the content at `offset` in a row at width `from` sits at width `to`: the line it falls in, by its first
  /// character, at the same fraction of that line.
  func passage(_ id: Int, _ offset: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
    let old = lines(id, width: from)
    let new = lines(id, width: to)
    guard let first = old.first, !new.isEmpty else { return offset }
    let y = offset - Self.textTop
    guard y >= first.y else { return offset }
    let at = old.lastIndex { $0.y <= y } ?? 0
    let line = old[at]
    let fraction = line.height > 0 ? min(1, (y - line.y) / line.height) : 0
    // The new line holding that line's first character.
    let target = new.lastIndex { $0.location <= line.location } ?? 0
    return Self.textTop + new[target].y + fraction * new[target].height
  }

  /// Moves a row to another place (a pending message confirmed into a different position, a corrected time).
  func move(_ id: Int, toIndex index: Int) {
    guard let from = byID[id] else { return }
    let row = rows.remove(at: from)
    rows.insert(row, at: max(0, min(index, rows.count)))
    reindex()
  }

  /// Every row under a new id, the same content (a reload that renumbers: a cache rebuilt, a migration). Returns the
  /// old id → new id map.
  @discardableResult
  func renumber() -> [Int: Int] {
    var map: [Int: Int] = [:]
    for i in rows.indices {
      nextID += 1
      map[rows[i].id] = nextID
      rows[i].id = nextID
    }
    heightCache = [:]
    reindex()
    return map
  }

  /// Removes the oldest `count` rows (a window trimmed at the top).
  func trimOldest(_ count: Int) {
    rows.removeFirst(min(count, rows.count))
    reindex()
  }

  /// Keeps only the rows in `range` (a window around a far jump).
  func keep(_ range: Range<Int>) {
    rows = Array(rows[range])
    reindex()
  }

  // MARK: - Rows for the list

  static func textWidth(_ width: CGFloat) -> CGFloat { min(520, width * 0.7) - 24 }

  static func bottomGap(last: Bool) -> CGFloat { last ? 8 : 2 }

  /// Scales every row's height, as a text size change does (`pos.text-size-replan`).
  var heightScale: CGFloat = 1

  func height(_ id: Int, _ width: CGFloat) -> CGFloat {
    let base = baseHeight(id, width)
    return heightScale == 1 ? base : (base * heightScale).rounded()
  }

  private func baseHeight(_ id: Int, _ width: CGFloat) -> CGFloat {
    guard let row = row(id) else { return 0 }
    if row.isDay { return Self.dayHeight }
    let last = isLastInGroup(id)
    if let cached = heightCache[id], cached.width == width, cached.text == row.text, cached.last == last { return cached.height }
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
    makes += 1
    burn()
    let view = pool.popLast() ?? LabRowView()
    configure(view, id, width)
    live[id] = view
    return view
  }

  func update(_ id: Int, _ view: NSView, _ width: CGFloat, _ timing: TimelineTiming) {
    updates += 1
    burn()
    guard let view = view as? LabRowView else { return }
    // As a message view does: the bubble's box moves to its new size on the change's timing, so it grows and
    // shrinks with the list instead of jumping.
    let old = view.bubble.frame
    configure(view, id, width)
    let new = view.bubble.frame
    guard animatesInsides, timing.isAnimated, old != new, old.height > 0, !view.bubble.isHidden else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.bubble.layer?.addTrack(timing, keyPath: "position.y", from: old.minY - new.minY)
    view.bubble.layer?.addTrack(timing, keyPath: "bounds.size.height", from: old.height - new.height)
    CATransaction.commit()
  }

  func recycle(_ id: Int, _ view: NSView) {
    if live[id] === view { live[id] = nil }
    if let view = view as? LabRowView, pool.count < 64 { pool.append(view) }
  }

  private func configure(_ view: LabRowView, _ id: Int, _ width: CGFloat) {
    guard let row = row(id) else { return }
    view.configure(row: row, width: width, height: height(id, width), last: isLastInGroup(id), avatar: showsAvatar(id), topPin: topPins)
  }

  private func burn() {
    guard rowCost > 0 else { return }
    let end = CACurrentMediaTime() + rowCost / 1000
    while CACurrentMediaTime() < end {}
  }

  func pin(_ id: Int, _ view: NSView) -> TimelinePin<Int>? {
    guard let view = view as? LabRowView, showsAvatar(id), let group = group(id) else { return nil }
    if topPins {
      // As the old list's `.top` mode: 8 pt below the top edge, never below the group's last row's bubble.
      return TimelinePin(
        view: view.avatar, top: view.avatarRest.minY, height: Self.avatarSize, spanStart: group.start, spanEnd: group.end,
        spanBottomInset: Self.bottomGap(last: true), edgeGap: Self.topPinGap
      )
    }
    return TimelinePin(view: view.avatar, bottom: view.avatarRest.maxY, height: Self.avatarSize, spanStart: group.start)
  }

  /// Seconds spent in this host's row work (measuring, making, updating, recycling rows) as the list asked for it,
  /// so a probe can tell the list's own cost from the rows'.
  var hostSeconds: Double { calls + LabRowView.layoutSeconds }
  private var calls: Double = 0

  private func timed<T>(_ body: () -> T) -> T {
    let began = CACurrentMediaTime()
    defer { calls += CACurrentMediaTime() - began }
    return body()
  }

  func rowsAPI() -> TimelineRows<Int> {
    TimelineRows(
      height: { [unowned self] id, width in self.timed { self.height(id, width) } },
      make: { [unowned self] id, width in self.timed { self.make(id, width) } },
      update: { [unowned self] id, view, width, timing in self.timed { self.update(id, view, width, timing) } },
      recycle: { [unowned self] id, view in self.timed { self.recycle(id, view) } },
      pin: { [unowned self] id, view in self.timed { self.pin(id, view) } },
      spanTop: { _, _ in 2 },
      spanEnd: { [unowned self] id in
        self.timed {
          guard !self.topPins, let group = self.group(id), group.end != id, self.showsAvatar(group.end) else { return nil }
          return group.end
        }
      },
      spanStart: { [unowned self] id in
        self.timed {
          guard self.topPins, let group = self.group(id), group.start != id, self.showsAvatar(group.start) else { return nil }
          return group.start
        }
      },
      passage: { [unowned self] id, offset, from, to in self.passage(id, offset, from: from, to: to) },
      removalFocus: { _, view in CGPoint(x: view.bounds.midX, y: view.bounds.midY) }
    )
  }

  func floatingHeader() -> TimelineFloatingHeader<Int> {
    let pill = LabDayPill()
    return TimelineFloatingHeader(
      view: pill, height: Self.dayHeight, gap: 0, section: { [unowned self] in self.section($0) },
      configure: { [unowned self] view, id in (view as? LabDayPill)?.title = self.row(id)?.text ?? "" }
    )
  }
}

final class LabRowView: NSView {
  /// Seconds in rows' own layout passes (the list lays a new row out before pinning it), for `LabChat.hostSeconds`.
  static var layoutSeconds: Double = 0

  override func layoutSubtreeIfNeeded() {
    let began = CACurrentMediaTime()
    super.layoutSubtreeIfNeeded()
    Self.layoutSeconds += CACurrentMediaTime() - began
  }

  let bubble = NSView()
  let label = LabLabel(labelWithString: "")
  let avatar = NSView()
  /// The avatar's resting place, top-down in the row (the list moves its frame while it is lifted).
  private(set) var avatarRest = NSRect.zero
  private let day = LabDayPill()
  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    bubble.wantsLayer = true
    bubble.layer?.cornerRadius = 12
    addSubview(bubble)
    label.font = LabChat.font
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.cell?.wraps = true
    bubble.addSubview(label)
    avatar.wantsLayer = true
    avatar.layer?.cornerRadius = LabChat.avatarSize / 2
    avatar.layer?.backgroundColor = NSColor.systemOrange.cgColor
    addSubview(avatar)
    addSubview(day)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(row: LabChat.Row, width: CGFloat, height: CGFloat, last: Bool, avatar shows: Bool, topPin: Bool = false) {
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
    bubble.layer?.backgroundColor = (row.outgoing ? NSColor.systemBlue.withAlphaComponent(0.25) : NSColor.secondaryLabelColor.withAlphaComponent(0.12)).cgColor
    let textWidth = LabChat.textWidth(width)
    let used = min(textWidth, ceil(NSAttributedString(string: row.text, attributes: [.font: LabChat.font]).size().width) + 2)
    let bubbleWidth = used + 24
    let gap = LabChat.bottomGap(last: last)
    let bubbleHeight = height - 2 - gap
    let x = row.outgoing ? width - bubbleWidth - 16 : 16 + LabChat.avatarSize + 8
    bubble.frame = NSRect(x: x, y: 2, width: bubbleWidth, height: bubbleHeight)
    label.frame = NSRect(x: 12, y: 8, width: used, height: bubbleHeight - 16)
    avatar.isHidden = !shows
    avatarRest = NSRect(x: 16, y: topPin ? 2 : height - gap - LabChat.avatarSize, width: LabChat.avatarSize, height: LabChat.avatarSize)
    avatar.frame = avatarRest
  }
}

/// The row's text, recording whether AppKit has drawn what it was last given: the suite checks that every row on
/// screen shows its text, which frames alone don't tell.
final class LabLabel: NSTextField {
  private(set) var drawnText: String?
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawnText = stringValue
  }

  var showsItsText: Bool { drawnText == stringValue }
}

/// A day title in a capsule: the day separator's look, and the floating header's.
final class LabDayPill: NSView {
  private let capsule = NSView()
  private let label = NSTextField(labelWithString: "")
  override var isFlipped: Bool { true }

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
    capsule.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
    capsule.layer?.borderColor = NSColor.separatorColor.cgColor
    capsule.layer?.borderWidth = 1
    capsule.layer?.cornerRadius = 11
    addSubview(capsule)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
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

/// The chat window's layout: a top band and a composer over the list, as Inline's chat view lays them out.
@MainActor
final class LabChatView: NSView {
  let list: TimelineListView<Int>
  let chat: LabChat
  let band = NSVisualEffectView()
  let composer = NSVisualEffectView()
  private(set) var composerLines = 1
  static let bandHeight: CGFloat = 52
  override var isFlipped: Bool { true }

  init(chat: LabChat, floatingHeader: Bool = true) {
    self.chat = chat
    list = TimelineListView(rows: chat.rowsAPI())
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(list)
    band.material = .headerView
    band.blendingMode = .withinWindow
    addSubview(band)
    composer.material = .headerView
    composer.blendingMode = .withinWindow
    composer.wantsLayer = true
    composer.layer?.cornerRadius = 18
    addSubview(composer)
    if floatingHeader { list.floatingHeader = chat.floatingHeader() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  var composerHeight: CGFloat { 20 + CGFloat(composerLines) * 17 }
  var bottomInset: CGFloat { composerHeight + 24 }

  override func layout() {
    super.layout()
    list.frame = bounds
    band.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.bandHeight)
    composer.frame = composerFrame()
  }

  func composerFrame() -> NSRect {
    NSRect(x: 16, y: bounds.height - 12 - composerHeight, width: bounds.width - 32, height: composerHeight)
  }

  func start(coverage: TimelineCoverage = TimelineCoverage(reachesOldest: true, reachesNewest: true)) {
    list.apply(TimelineTransaction(
      rows: chat.ids, coverage: coverage, scroll: .latest, topInset: Self.bandHeight, bottomInset: bottomInset
    ))
  }

  /// The composer grows or shrinks; the list's bottom inset moves with it on one spring. Both in one transaction:
  /// tracks without a begin time start when their transaction commits, and the list's change does layout work first,
  /// so two transactions would start the two springs milliseconds apart (a point of drift at the spring's fastest).
  func setComposerLines(_ lines: Int, timing: TimelineTiming = .standard) {
    setComposerLines(lines, timing: timing, rows: nil, changed: [])
  }

  /// The composer change and a row update (`rows`, `changed`) in one list transaction (a send: the composer shrinks as
  /// the sent row lands).
  func setComposerLines(_ lines: Int, timing: TimelineTiming, rows: [Int]?, changed: Set<Int>) {
    let old = composer.frame
    composerLines = lines
    let new = composerFrame()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    composer.frame = new
    // The composer grows upward, so its top moves by the height change.
    composer.layer?.addTrack(timing, keyPath: "position.y", from: old.minY - new.minY)
    composer.layer?.addTrack(timing, keyPath: "bounds.size.height", from: old.height - new.height)
    list.apply(TimelineTransaction(rows: rows, bottomInset: bottomInset, changed: changed, timing: timing))
    CATransaction.commit()
  }
}

