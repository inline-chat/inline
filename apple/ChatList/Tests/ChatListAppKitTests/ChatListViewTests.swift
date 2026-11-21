#if canImport(AppKit)
import AppKit
import ChatListCore
@testable import ChatListAppKit
import Testing

@Suite(.serialized) @MainActor
struct ChatListViewTests {
  private final class Cell: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
  }

  private final class GlyphCell: NSView {
    let glyph = NSView(frame: .zero)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  }

  @MainActor private final class Counters {
    var created = 0
    var bound: [Int: Int] = [:]
    var recycled = 0
  }

  @MainActor private final class Fixture {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let host: ChatListView<Int, String>
    let window: NSWindow
    let counters: Counters
    var created: Int { counters.created }
    var bound: [Int: Int] { counters.bound }
    var recycled: Int { counters.recycled }

    init() {
      let counters = Counters()
      self.counters = counters
      _ = NSApplication.shared
      host = ChatListView(
        session: session,
        configuration: .init(overscan: 80, usesAutomaticDisplayClock: false)
      ) { [counters] _, reused in
        if let reused { return reused }
        counters.created += 1
        return Cell(frame: .zero)
      }
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.borderless], backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = host
      host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
      host.bindCell = { [counters] _, item, _ in counters.bound[item.id, default: 0] += 1 }
      host.recycleCell = { [counters] _ in counters.recycled += 1 }
      host.layoutSubtreeIfNeeded()
    }

    func apply(revision: UInt64 = 0, changedHeight: CGFloat? = nil) throws {
      let items = (0 ..< 100).map { index in
        ChatListItem(
          id: index, revision: index == 20 ? revision : 0, content: "row \(index)",
          height: index == 20 ? changedHeight ?? 80 : 80
        )
      }
      let snapshot = ChatListSnapshot(context: session.layoutContext, items: items)
      _ = try session.apply(snapshot, animation: .none, at: 0)
      host.advance(to: 0)
    }
  }

  @Test func `native scrollers follow animated occlusions without changing the content inset`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    let clipSize = fixture.host.scrollView.contentView.bounds.size
    var viewport = fixture.session.timeline.targetViewport
    viewport.topInset = 35
    viewport.bottomInset = 92
    fixture.session.updateViewport(viewport, animation: .animated, at: 0)
    for frame in 0 ... 120 {
      fixture.host.advance(to: Double(frame) / 60)
      let presented = fixture.session.timeline.layout.viewport
      let scrollView = fixture.host.scrollView
      #expect(scrollView.scrollerInsets.top == presented.topInset)
      #expect(scrollView.scrollerInsets.bottom == presented.bottomInset)
      #expect(scrollView.contentInsets.top == 0 && scrollView.contentInsets.bottom == 0)
      #expect(scrollView.contentView.bounds.size == clipSize)
      #expect(abs(scrollView.contentView.bounds.minY - fixture.session.timeline.layout.originY) < 0.01)
      #expect(!fixture.session.isUserScrolling)
      #expect(fixture.session.timeline.intent == .latest)
    }
  }

  @Test(arguments: [false, true])
  func `native clip and scrollers follow live occlusions without consuming rubber band input`(
    bouncingAtBottom: Bool
  ) throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    let distance: CGFloat = 23
    let origin = bouncingAtBottom ? fixture.session.timeline.layout.maximumOrigin + distance : -distance
    fixture.session.beginUserScroll(at: origin)
    fixture.session.userScrolled(to: origin)
    var target = fixture.session.timeline.targetViewport
    target.topInset = 35
    target.bottomInset = 92
    fixture.session.updateViewport(
      target, displayScale: fixture.session.layoutContext.displayScale,
      environmentRevision: fixture.session.layoutContext.environmentRevision, animation: .none, at: 1
    )
    let layout = fixture.session.timeline.layout
    let expectedOrigin = bouncingAtBottom ? layout.maximumOrigin + distance : -distance
    let scrollView = fixture.host.scrollView
    #expect(layout.viewport == target)
    #expect(abs(layout.originY - expectedOrigin) < 0.01)
    #expect(abs(scrollView.contentView.bounds.minY - expectedOrigin) < 0.01)
    #expect(scrollView.scrollerInsets.top == target.topInset)
    #expect(scrollView.scrollerInsets.bottom == target.bottomInset)
    #expect(scrollView.contentInsets.top == 0 && scrollView.contentInsets.bottom == 0)
    #expect(fixture.session.isUserScrolling)
    #expect(fixture.session.generation == 1)
  }

  @Test func `host installs exact geometry and reuses bounded native cells`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    #expect(fixture.host.scrollView.documentView?.frame.height == 8_000)
    #expect(fixture.host.cell(for: 99) != nil)
    #expect(fixture.host.materializedCells.count < 12)
    let initialBindCount = fixture.bound[99]
    var presentations = 0
    fixture.host.presentCell = { _, placement in
      if placement.row.id == 99 { presentations += 1 }
    }
    fixture.host.advance(to: 1)
    #expect(fixture.bound[99] == initialBindCount)
    #expect(presentations == 1)

    fixture.session.navigate(to: .reading(.init(id: 2)), animation: .none, at: 1)
    fixture.host.advance(to: 1)
    let pinned = try #require(fixture.host.cell(for: 2))
    fixture.host.pinCell(for: 2)
    fixture.session.navigate(to: .reading(.init(id: 90)), animation: .none, at: 2)
    fixture.host.advance(to: 2)
    #expect(fixture.host.cell(for: 2) === pinned)
    fixture.host.unpinCell(for: 2)
    #expect(fixture.host.cell(for: 2) == nil)
    #expect(fixture.created < 20)
    #expect(fixture.recycled > 0)
  }

  @Test func `animated row clipping does not autoresize the exact prepared cell canvas`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    fixture.host.makeCell = { _, reused in
      let cell = reused ?? Cell(frame: .zero)
      cell.autoresizingMask = [.width, .height]
      return cell
    }
    try fixture.apply()
    fixture.session.navigate(to: .reading(.init(id: 20)), animation: .none, at: 0)
    let items = (0 ..< 100).map {
      ChatListItem(id: $0, revision: UInt64($0 == 20 ? 1 : 0), content: "row \($0)", height: $0 == 20 ? 440 : 80)
    }
    try fixture.session.apply(.init(context: fixture.session.layoutContext, items: items),
                              animation: .animated, at: 0)
    for frame in 0 ... 90 {
      fixture.host.advance(to: Double(frame) / 120)
      let cell = try #require(fixture.host.cell(for: 20))
      #expect(cell.frame == CGRect(x: 0, y: 0, width: 400, height: 440))
      #expect(cell.superview?.frame == fixture.session.timeline.layout.placement(for: 20)?.frame)
    }
  }

  @Test func `resize keeps latest intent and waits for exact new width`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    #expect(fixture.session.timeline.intent == .latest)
    let installedWidth = fixture.session.snapshot?.context.width
    fixture.host.frame = NSRect(x: 0, y: 0, width: 350, height: 260)
    fixture.host.layoutSubtreeIfNeeded()
    #expect(fixture.session.timeline.intent == .latest)
    #expect(fixture.session.layoutContext.width != installedWidth)
    #expect(fixture.session.snapshot?.context.width == installedWidth)
    #expect(fixture.host.scrollView.documentView?.frame.width == installedWidth)
  }

  @Test func `bottom inset and row growth retain the captured bottom cell point`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    fixture.session.navigate(to: .reading(.init(id: 20)), animation: .none, at: 1)
    fixture.host.advance(to: 1)

    let previousViewport = fixture.session.timeline.targetViewport
    fixture.session.updateViewport(
      .init(width: previousViewport.width, height: previousViewport.height, bottomInset: 100),
      displayScale: fixture.session.layoutContext.displayScale,
      environmentRevision: fixture.session.layoutContext.environmentRevision,
      at: 2
    )
    fixture.host.advance(to: 2)
    let before = fixture.session.timeline.layout
    let visible = before.visibleRows(in: before.readingRect)
    let bottomRow = try #require(before.rows[visible].last { !$0.isExiting })
    let bottomID = bottomRow.row.id
    let bottomLocalY = before.readingRect.maxY - bottomRow.frame.minY
    #expect(bottomLocalY >= 0 && bottomLocalY <= bottomRow.frame.height)

    var capturedIDs: [Int] = []
    var resolutions = 0
    fixture.host.captureCellAnchor = { _, item, visible in
      capturedIDs.append(item.id)
      return .init(token: item.id, localY: visible.maxY)
    }
    fixture.host.resolveCellAnchor = { _, item, address in
      resolutions += 1
      guard address.token == AnyHashable(item.id) else { return nil }
      return .init(offsetY: address.localY)
    }
    let items = (0 ..< 100).map { index in
      ChatListItem(
        id: index, revision: index == 20 ? 1 : 0, content: "row \(index)",
        height: index == 20 ? 200 : 80
      )
    }
    _ = try fixture.session.apply(
      .init(context: fixture.session.layoutContext, items: items), animation: .animated, at: 3
    )
    #expect(capturedIDs.first == bottomID)
    #expect(resolutions == 1)

    for frame in 0 ... 12 {
      fixture.host.advance(to: 3 + Double(frame) / 60)
      let layout = fixture.session.timeline.layout
      guard case let .reading(anchor) = fixture.session.timeline.intent else {
        Issue.record("Row growth lost reading intent")
        return
      }
      #expect(anchor.edge == .bottom)
      #expect(anchor.id == bottomID)
      let placement = try #require(layout.placement(for: bottomID))
      let nativeY = placement.frame.minY + bottomLocalY - fixture.host.scrollView.contentView.bounds.minY
      #expect(abs(nativeY - (layout.viewport.height - layout.viewport.bottomInset)) < 0.5)
    }
    #expect(resolutions == 1)
  }

  @Test func `native width reflow preserves a named child rather than the row top`() async throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    fixture.host.makeCell = { _, reused in reused ?? GlyphCell(frame: .zero) }
    fixture.host.bindCell = { view, item, _ in
      (view as? GlyphCell)?.glyph.frame = item.elements["glyph"] ?? .zero
    }
    func items(glyphY: CGFloat) -> [ChatListItem<Int, String>] {
      (0 ..< 100).map { index in
        ChatListItem(
          id: index, revision: index == 20 && glyphY > 120 ? 1 : 0, content: "row \(index)",
          height: index == 20 ? 300 : 80,
          elements: index == 20
            ? ["glyph": CGRect(x: 20, y: glyphY, width: 20, height: 10)] : [:]
        )
      }
    }
    _ = try fixture.session.apply(
      .init(context: fixture.session.layoutContext, items: items(glyphY: 120)),
      animation: .none, at: 0
    )
    fixture.host.advance(to: 0)
    fixture.session.navigate(to: .reading(.init(id: 20)), animation: .none, at: 1)
    fixture.host.advance(to: 1)
    let priorOrigin = fixture.session.timeline.layout.originY
    var captures = 0
    var resolutions = 0
    fixture.host.captureCellAnchor = { view, item, visible in
      guard item.id == 20, let cell = view as? GlyphCell else { return nil }
      let localY = cell.glyph.frame.minY
      guard visible.minY <= localY && localY < visible.maxY else { return nil }
      captures += 1
      return .init(token: item.id, localY: localY)
    }
    fixture.host.resolveCellAnchor = { _, item, address in
      guard address.token == AnyHashable(item.id) else { return nil }
      resolutions += 1
      return .init(element: "glyph", offsetY: 0)
    }

    fixture.host.frame = NSRect(x: 0, y: 0, width: 350, height: 300)
    fixture.host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!fixture.session.isUserScrolling)
    #expect(fixture.session.snapshot?.context.width == 400)
    _ = try fixture.session.apply(
      .init(context: fixture.session.layoutContext, items: items(glyphY: 143)),
      animation: .none, at: 2
    )
    fixture.host.advance(to: 2)
    #expect(captures == 1)
    #expect(resolutions == 1)
    #expect(abs(fixture.session.timeline.layout.originY - (priorOrigin + 23)) < 0.5)
    #expect(abs(fixture.host.scrollView.contentView.bounds.minY - (priorOrigin + 23)) < 0.5)
  }

  @Test func `unphased wheel movement starts ownership and settles after idle`() async throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    let initialOrigin = fixture.host.scrollView.contentView.bounds.minY
    let cgEvent = try #require(CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
      wheel1: 31, wheel2: 0, wheel3: 0
    ))
    let event = try #require(NSEvent(cgEvent: cgEvent))
    fixture.host.scrollView.scrollWheel(with: event)
    // AppKit delivers smooth wheel displacement asynchronously.
    try await Task.sleep(for: .milliseconds(50))
    let movedOrigin = fixture.host.scrollView.contentView.bounds.minY
    #expect(abs(movedOrigin - initialOrigin) > 1)
    #expect(fixture.session.isUserScrolling)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!fixture.session.isUserScrolling)
    #expect(abs(fixture.session.timeline.layout.originY
      - fixture.host.scrollView.contentView.bounds.minY) < 0.5)
  }

  @Test func `live scroll stays active while input is stationary after native movement`() async throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.host.scrollView
    )
    let clipView = fixture.host.scrollView.contentView
    clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY - 31))
    fixture.host.scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    #expect(fixture.session.isUserScrolling)
    try await Task.sleep(for: .milliseconds(250))
    #expect(fixture.session.isUserScrolling)

    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: fixture.host.scrollView
    )
    #expect(!fixture.session.isUserScrolling)
  }

  @Test(arguments: [false, true])
  func `zero displacement live phases retain initial intent until the native clip actually moves`(
    initiallyLatest: Bool
  ) throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    func snapshot(_ revision: UInt64) -> ChatListSnapshot<Int, String> {
      .init(context: fixture.session.layoutContext, items: (0 ..< (revision == 0 ? 100 : 101)).map { id in
        .init(id: id, revision: revision, content: "row \(id)", height: id == 20 ? 1_500 : 80)
      })
    }
    let initial: TimelineIntent<Int> = initiallyLatest
      ? .latest : .reading(.init(id: 20, localY: 700, viewportY: 93))
    try fixture.session.apply(snapshot(0), intent: initial, animation: .none, at: 0)
    #expect(fixture.session.timeline.intent == initial)
    let initialOrigin = fixture.session.timeline.layout.originY
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.host.scrollView
    )
    #expect(fixture.session.timeline.intent == initial)
    #expect(fixture.session.timeline.layout.originY == initialOrigin)
    try fixture.session.apply(snapshot(1), animation: .none, at: 0)
    #expect(fixture.session.timeline.intent == initial)
    if initiallyLatest {
      #expect(fixture.session.timeline.layout.originY == fixture.session.timeline.layout.maximumOrigin)
    } else {
      let row = try #require(fixture.session.timeline.layout.placement(for: 20))
      #expect(abs(row.frame.minY + 700 - fixture.session.timeline.layout.readingRect.minY - 93) < 0.01)
    }
    let idleOrigin = fixture.session.timeline.layout.originY
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: fixture.host.scrollView
    )
    #expect(fixture.session.timeline.intent == initial)
    #expect(fixture.session.timeline.layout.originY == idleOrigin)

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.host.scrollView
    )
    let requestedOrigin = idleOrigin + (initiallyLatest ? -31 : 31)
    let clipView = fixture.host.scrollView.contentView
    clipView.scroll(to: NSPoint(x: 0, y: requestedOrigin))
    fixture.host.scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    #expect(abs(clipView.bounds.minY - requestedOrigin) < 0.01)
    #expect(abs(fixture.session.timeline.layout.originY - requestedOrigin) < 0.01)
    #expect(fixture.session.timeline.intent != initial)
    #expect(fixture.session.isUserScrolling)
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: fixture.host.scrollView
    )
    #expect(!fixture.session.isUserScrolling)
    #expect(abs(fixture.session.timeline.layout.originY - requestedOrigin) < 0.01)
    #expect(fixture.session.timeline.intent != initial)
  }

  @Test func `detaching during live scroll permits a fresh gesture on reattach`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    try fixture.apply()
    let attachedScale = fixture.session.layoutContext.displayScale

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.host.scrollView
    )
    let clipView = fixture.host.scrollView.contentView
    clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY - 31))
    fixture.host.scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    #expect(fixture.session.isUserScrolling)
    fixture.window.contentView = NSView(frame: fixture.host.frame)
    #expect(!fixture.session.isUserScrolling)
    fixture.host.layoutSubtreeIfNeeded()
    #expect(fixture.session.layoutContext.displayScale == attachedScale)

    fixture.window.contentView = fixture.host
    fixture.host.layoutSubtreeIfNeeded()
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: fixture.host.scrollView
    )
    clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY - 31))
    fixture.host.scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    #expect(fixture.session.isUserScrolling)
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: fixture.host.scrollView
    )
    #expect(!fixture.session.isUserScrolling)
  }
}
#endif
