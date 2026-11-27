import AppKit
import ScrollTimeline
import TimelineAppKit
import TimelineCore

/// One of the two lists under test, behind the same calls.
@MainActor
protocol ListSubject: AnyObject {
  var kind: String { get }
  var view: NSView { get }
  func apply(
    rows: [Int]?, coverage: TimelineCoverage?, scroll: TimelineScroll<Int>, top: CGFloat?, bottom: CGFloat?,
    changed: Set<Int>, timing: TimelineTiming
  )
  var layout: TimelineLayout<Int> { get }
  var topInset: CGFloat { get }
  var bottomInset: CGFloat { get }
  /// Rows that have a view, where each shows now (presentation layers) in the list view's coordinates.
  func shownRows() -> [(id: Int, frame: CGRect, view: NSView)]
  var isMoving: Bool { get }
  var onDemand: ((Set<TimelineEdge>) -> Void)? { get set }
  /// Seconds spent in the list's own passes so far (solver, realisation, commit), rows' own work included.
  var listSeconds: Double { get }
  /// Anything worth printing about the run (engine or scroll view internals).
  var notes: String { get }
  /// Sticky avatars on screen by the row holding each, and the floating date (frame, title) when shown; presented,
  /// in the list's coordinates.
  func avatarFrames() -> [Int: CGRect]
  func headerShown() -> (frame: CGRect, title: String)?
}

extension ListSubject {
  func avatarFrames() -> [Int: CGRect] { [:] }
  func headerShown() -> (frame: CGRect, title: String)? { nil }
}

/// A view's presented frame in another view's coordinates, with every animation on the way.
@MainActor
func presentedFrame(of view: NSView, in container: NSView) -> CGRect? {
  guard let target = view.layer, let mine = container.layer else { return nil }
  let from = target.presentation() ?? target
  let to = mine.presentation() ?? mine
  return from.convert(from.bounds, to: to)
}

/// Opacity as shown: the layer's and its ancestors' up to `container`.
@MainActor
func presentedOpacity(of view: NSView, in container: NSView) -> CGFloat {
  var opacity: CGFloat = 1
  var current: NSView? = view
  while let v = current, v !== container {
    if let layer = v.layer { opacity *= CGFloat((layer.presentation() ?? layer).opacity) }
    if v.isHidden { return 0 }
    current = v.superview
  }
  return opacity
}

extension ListSubject {
  func apply(
    rows: [Int]? = nil, coverage: TimelineCoverage? = nil, scroll: TimelineScroll<Int> = .preserve,
    top: CGFloat? = nil, bottom: CGFloat? = nil, changed: Set<Int> = [], timing: TimelineTiming = .none
  ) {
    apply(rows: rows, coverage: coverage, scroll: scroll, top: top, bottom: bottom, changed: changed, timing: timing)
  }
}

/// The current custom engine (not an NSScrollView): TimelineAppKit's TimelineListView.
@MainActor
final class EngineSubject: ListSubject {
  let list: TimelineListView<Int>
  let kind = "engine"
  var view: NSView { list }

  init(chat: LabChat, sticky: Bool = false) {
    list = TimelineListView(rows: chat.engineRows(sticky: sticky))
    list.showsScrollIndicator = true
    if sticky { list.floatingHeader = chat.engineHeader() }
  }

  func avatarFrames() -> [Int: CGRect] {
    var out: [Int: CGRect] = [:]
    for (id, view) in list.shownViews {
      guard let row = view as? LabRowView, !row.avatar.isHidden, let frame = list.presentedFrame(of: row.avatar) else { continue }
      out[id] = frame
    }
    return out
  }

  func headerShown() -> (frame: CGRect, title: String)? {
    guard let header = list.floatingHeader, presentedOpacity(of: header.view, in: list) > 0.01,
          let frame = list.presentedFrame(of: header.view) else { return nil }
    return (frame, (header.view as? LabDayPill)?.title ?? "")
  }

  func apply(
    rows: [Int]?, coverage: TimelineCoverage?, scroll: TimelineScroll<Int>, top: CGFloat?, bottom: CGFloat?,
    changed: Set<Int>, timing: TimelineTiming
  ) {
    list.apply(TimelineTransaction(
      rows: rows, coverage: coverage, scroll: scroll, topInset: top, bottomInset: bottom, changed: changed,
      timing: timing, arrives: true
    ))
  }

  var layout: TimelineLayout<Int> { list.timelineLayout }
  var topInset: CGFloat { list.topInset }
  var bottomInset: CGFloat { list.bottomInset }

  func shownRows() -> [(id: Int, frame: CGRect, view: NSView)] {
    list.shownViews.compactMap { id, view in list.presentedFrame(for: id).map { (id, $0, view) } }
  }

  var isMoving: Bool { list.isMoving }
  var onDemand: ((Set<TimelineEdge>) -> Void)? {
    get { list.onDemand }
    set { list.onDemand = newValue }
  }

  var listSeconds: Double { list.diagnostics.totalPerformDuration }
  var notes: String {
    let d = list.diagnostics
    return "performs \(d.performCount), makes \(d.makes)"
  }
}

/// The prototype: TimelineCore placing rows in a stock NSScrollView.
@MainActor
final class ScrollSubject: ListSubject {
  let list: TimelineScrollList<Int>
  let kind = "nsscroll"
  var view: NSView { list }

  init(chat: LabChat, sticky: Bool = false, headerHost: ScrollListHeader<Int>.Host = .floatingSubview) {
    list = TimelineScrollList(rows: chat.scrollRows(sticky: sticky))
    if sticky { list.floatingHeader = chat.scrollHeader(host: headerHost) }
  }

  func avatarFrames() -> [Int: CGRect] {
    var out: [Int: CGRect] = [:]
    for (id, view) in list.pinnedViews {
      if let frame = presentedFrame(of: view, in: list) { out[id] = frame }
    }
    return out
  }

  func headerShown() -> (frame: CGRect, title: String)? {
    guard let header = list.floatingHeader, presentedOpacity(of: header.view, in: list) > 0.01,
          let frame = presentedFrame(of: header.view, in: list) else { return nil }
    return (frame, (header.view as? LabDayPill)?.title ?? "")
  }

  func apply(
    rows: [Int]?, coverage: TimelineCoverage?, scroll: TimelineScroll<Int>, top: CGFloat?, bottom: CGFloat?,
    changed: Set<Int>, timing: TimelineTiming
  ) {
    list.apply(ScrollListTransaction(
      rows: rows, coverage: coverage, scroll: scroll, topInset: top, bottomInset: bottom, changed: changed, timing: timing
    ))
  }

  var layout: TimelineLayout<Int> { list.timelineLayout }
  var topInset: CGFloat { list.topInset }
  var bottomInset: CGFloat { list.bottomInset }

  func shownRows() -> [(id: Int, frame: CGRect, view: NSView)] {
    let scroll = list.presentedScrollPosition
    return list.placedViews.map { id, view in
      (id, CGRect(x: 0, y: view.frame.minY - scroll, width: view.frame.width, height: view.frame.height), view)
    }
  }

  var isMoving: Bool { list.isMoving }
  var onDemand: ((Set<TimelineEdge>) -> Void)? {
    get { list.onDemand }
    set { list.onDemand = newValue }
  }

  var listSeconds: Double { list.stats.performSeconds }
  var notes: String {
    let s = list.stats
    return "performs \(s.performs) (follows \(s.follows)), makes \(s.makes), edge moves \(s.edgeMoves), clip moves \(s.clipMoves) (\(s.clipMovesWhileLive) live), clamps \(s.clamps), prepares \(s.prepares), overdraw above/below \(Int(s.maxOverdrawAbove))/\(Int(s.maxOverdrawBelow)) pt, concurrent-compatible \(list.isConcurrentScrollingCompatible.map { $0 ? "yes" : "no" } ?? "?")"
  }
}

/// Telegram macOS's configuration: unflipped document, a sliding window of 90 rows with exact heights, the composer
/// as a bottom spacer row, saveVisible merges, responsive scrolling with coalesced bookkeeping.
@MainActor
final class TelegramSubject: ListSubject {
  let list: WindowedScrollList<Int>
  let kind = "tg"
  var view: NSView { list }
  private var top: CGFloat = 0
  private var bottom: CGFloat = 0

  init(chat: LabChat) {
    list = WindowedScrollList(rows: chat.scrollRows())
  }

  func apply(
    rows: [Int]?, coverage: TimelineCoverage?, scroll: TimelineScroll<Int>, top: CGFloat?, bottom: CGFloat?,
    changed: Set<Int>, timing: TimelineTiming
  ) {
    if let top { self.top = top }
    if let bottom { self.bottom = bottom }
    list.apply(rows: rows, coverage: coverage, scroll: scroll, top: top, bottom: bottom, changed: changed, timing: timing)
  }

  var layout: TimelineLayout<Int> { .empty(viewport: TimelineViewport(width: 0, height: 0)) }
  var topInset: CGFloat { top }
  var bottomInset: CGFloat { bottom }

  func shownRows() -> [(id: Int, frame: CGRect, view: NSView)] {
    list.placedViews.compactMap { id, view in list.presentedFrame(for: id).map { (id, $0, view) } }
  }

  /// Monotonic with the content's travel (positive towards newer, like the others' scroll positions).
  var presentedScroll: CGFloat { -(list.presentedScrollY - list.preservingShift) }
  var isMoving: Bool { list.isMoving }
  var onDemand: ((Set<TimelineEdge>) -> Void)? {
    get { list.onDemand }
    set { list.onDemand = newValue }
  }

  var listSeconds: Double { list.stats.performSeconds + list.stats.followSeconds }
  var notes: String {
    let s = list.stats
    return "window \(list.hi - list.lo) of \(list.all.count) rows, merges \(s.edgeMoves), bounds steps \(s.follows), makes \(s.makes), clip moves \(s.clipMoves) (\(s.clipMovesWhileLive) live), clamps \(s.clamps), overdraw above/below \(Int(s.maxOverdrawAbove))/\(Int(s.maxOverdrawBelow)) pt"
  }
}

/// The control: a stock NSScrollView with every row built up front in a flipped document (no list logic, no
/// observers), as a reference for what NSScrollView itself does.
@MainActor
final class PlainSubject: ListSubject {
  final class Document: NSView {
    override var isFlipped: Bool { true }
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
  }

  let kind = "plain"
  let scrollView = NSScrollView()
  let document = Document()
  let chat: LabChat
  var views: [Int: NSView] = [:]
  var tops: [Int: CGFloat] = [:]
  var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)
  var built = false
  var view: NSView { scrollView }
  var onDemand: ((Set<TimelineEdge>) -> Void)?

  init(chat: LabChat) {
    self.chat = chat
    scrollView.wantsLayer = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentView.drawsBackground = false
    document.wantsLayer = true
    scrollView.documentView = document
  }

  func build(width: CGFloat) {
    for view in views.values { view.removeFromSuperview() }
    views = [:]
    var y: CGFloat = 0
    for id in chat.ids {
      let height = chat.height(id, width)
      let view = chat.make(id, width)
      view.frame = NSRect(x: 0, y: y, width: width, height: height)
      document.addSubview(view)
      views[id] = view
      tops[id] = y
      y += height
    }
    document.frame = NSRect(x: 0, y: 0, width: width, height: y)
    built = true
  }

  func apply(
    rows: [Int]?, coverage: TimelineCoverage?, scroll: TimelineScroll<Int>, top: CGFloat?, bottom: CGFloat?,
    changed: Set<Int>, timing: TimelineTiming
  ) {
    if let top { insets.top = top }
    if let bottom { insets.bottom = bottom }
    scrollView.contentInsets = NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
    scrollView.layoutSubtreeIfNeeded()
    let width = scrollView.contentView.bounds.width
    if !built || rows != nil { build(width: width) }
    let clip = scrollView.contentView
    switch scroll {
      case .latest:
        clip.scroll(to: NSPoint(x: 0, y: document.frame.height - clip.bounds.height + insets.bottom))
      case let .to(id, _):
        if let top = tops[id] { clip.scroll(to: NSPoint(x: 0, y: top - clip.bounds.height / 2)) }
      case .preserve, .by:
        break
    }
    scrollView.reflectScrolledClipView(clip)
  }

  var layout: TimelineLayout<Int> { .empty(viewport: TimelineViewport(width: 0, height: 0)) }
  var topInset: CGFloat { insets.top }
  var bottomInset: CGFloat { insets.bottom }
  var presentedScroll: CGFloat {
    let layer = scrollView.contentView.layer!
    return (layer.presentation() ?? layer).bounds.origin.y
  }

  func shownRows() -> [(id: Int, frame: CGRect, view: NSView)] {
    let scroll = presentedScroll
    let height = scrollView.bounds.height
    return views.compactMap { id, view in
      let y = view.frame.minY - scroll
      guard y + view.frame.height > -200, y < height + 200 else { return nil }
      return (id, CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height), view)
    }
  }

  var isMoving: Bool { false }
  var listSeconds: Double { 0 }
  var notes: String { "\(views.count) rows built" }
}

/// The chat window: an opaque top band and composer over the list, as Inline's chat view lays them out, on white.
@MainActor
final class LabWindow {
  let window: NSWindow
  let root: RootView
  let chat: LabChat
  let subject: ListSubject
  static let bandHeight: CGFloat = 52
  var composerLines = 1

  final class RootView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() {
      super.layout()
      onLayout?()
    }
  }

  let band = NSView()
  let composer = NSView()

  init(kind: String, count: Int, rowCost: Double = 0, size: NSSize = NSSize(width: 520, height: 760),
       coverage: TimelineCoverage = TimelineCoverage(), origin: NSPoint = LabPlacement.origin, groupRun: Int = 4,
       sticky: Bool = false, headerHost: ScrollListHeader<Int>.Host = .floatingSubview)
  {
    chat = LabChat(count: count, groupRun: groupRun)
    chat.rowCost = rowCost
    subject = switch kind {
      case "engine": EngineSubject(chat: chat, sticky: sticky)
      case "nsscroll": ScrollSubject(chat: chat, sticky: sticky, headerHost: headerHost)
      case "plain": PlainSubject(chat: chat)
      case "tg": TelegramSubject(chat: chat)
      case "brake": BrakeSubject(chat: chat)
      default: ScrollSubject(chat: chat)
    }
    window = NSWindow(
      contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .white
    window.title = kind
    root = RootView(frame: window.contentView!.bounds)
    root.autoresizingMask = [.width, .height]
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.white.cgColor
    window.contentView!.addSubview(root)
    root.addSubview(subject.view)
    band.wantsLayer = true
    band.layer?.backgroundColor = LabColors.band.cgColor
    root.addSubview(band)
    composer.wantsLayer = true
    composer.layer?.backgroundColor = LabColors.composer.cgColor
    composer.layer?.cornerRadius = 18
    root.addSubview(composer)
    root.onLayout = { [unowned self] in self.layoutChrome() }
    window.orderFrontRegardless()
    root.layoutSubtreeIfNeeded()
    subject.apply(
      rows: chat.ids, coverage: coverage, scroll: .latest, top: Self.bandHeight, bottom: bottomInset
    )
    root.layoutSubtreeIfNeeded()
  }

  var composerHeight: CGFloat { 20 + CGFloat(composerLines) * 17 }
  var bottomInset: CGFloat { composerHeight + 24 }

  func layoutChrome() {
    subject.view.frame = root.bounds
    band.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: Self.bandHeight)
    composer.frame = composerFrame()
  }

  func composerFrame() -> NSRect {
    NSRect(x: 16, y: root.bounds.height - 12 - composerHeight, width: root.bounds.width - 32, height: composerHeight)
  }

  /// The composer grows or shrinks; the list's bottom inset moves with it on one spring, in one transaction.
  func setComposerLines(_ lines: Int, timing: TimelineTiming = .standard) {
    let old = composer.frame
    composerLines = lines
    let new = composerFrame()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    composer.frame = new
    if let a = timing.labAnimation(keyPath: "position.y", from: old.minY - new.minY) { composer.layer?.add(a, forKey: "c.y") }
    if let a = timing.labAnimation(keyPath: "bounds.size.height", from: old.height - new.height) {
      composer.layer?.add(a, forKey: "c.h")
    }
    subject.apply(bottom: bottomInset, timing: timing)
    CATransaction.commit()
  }

  var usableTop: CGFloat { subject.topInset }
  var usableBottom: CGFloat { subject.view.bounds.height - subject.bottomInset }

  func close() {
    window.orderOut(nil)
    window.close()
  }

  var screenGeometry: ScreenWatch.Geometry {
    let contentTop = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
    return ScreenWatch.Geometry(contentTop: Double(contentTop), usableTop: Double(usableTop),
                                usableBottom: Double(usableBottom), width: Double(window.frame.width))
  }

  /// The list's centre in the window's frame, top-left origin (where AppKit places a window's event).
  var windowEventLocation: CGPoint {
    let view = subject.view
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    return CGPoint(x: center.x, y: window.frame.height - center.y)
  }

  func player(_ steps: [Synth.Step], delivery: EventPlayer.Delivery = EventPlayer.preferred) -> EventPlayer {
    EventPlayer(steps: steps, location: eventLocation, windowLocation: windowEventLocation,
                windowNumber: window.windowNumber, delivery: delivery)
  }

  /// The list's centre in global display coordinates (top-left origin), where events are posted.
  var eventLocation: CGPoint {
    let view = subject.view
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: center)
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: screen.x, y: mainHeight - screen.y)
  }
}

extension TimelineTiming {
  var labDuration: Double {
    switch self {
      case .none: 0
      case let .spring(_, _, _, duration): Double(duration)
      case let .curve(duration, _, _, _, _): Double(duration)
    }
  }

  func labAnimation(keyPath: String, from delta: CGFloat) -> CAAnimation? {
    guard abs(delta) > 0.01 else { return nil }
    switch self {
      case .none:
        return nil
      case let .spring(mass, stiffness, damping, duration):
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = mass
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = CFTimeInterval(duration)
        spring.fromValue = delta
        spring.toValue = 0
        spring.isAdditive = true
        spring.fillMode = .backwards
        return spring
      case let .curve(duration, c1x, c1y, c2x, c2y):
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.duration = CFTimeInterval(duration)
        basic.timingFunction = CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
        basic.fromValue = delta
        basic.toValue = 0
        basic.isAdditive = true
        basic.fillMode = .backwards
        return basic
    }
  }
}
