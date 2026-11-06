#if canImport(AppKit)
import AppKit
import ChatListCore
@testable import ChatListAppKit
import QuartzCore
import Testing

/// Compare actual AppKit coordinates with independently chosen screen anchors.
/// Model/offset agreement alone would miss a flipped document or native clamp.
@Suite(.serialized) @MainActor
struct TimelineDocumentViewTests {
  private final class Root: NSView {
    override var isFlipped: Bool {
      true
    }
  }

  private final class Leaf: NSView {
    let footer = NSView()
    override var acceptsFirstResponder: Bool {
      true
    }

    override var isFlipped: Bool {
      true
    }

    override init(frame: NSRect) {
      super.init(frame: frame)
      addSubview(footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }
  }

  @MainActor private final class Fixture {
    let window: NSWindow
    let root = Root(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    let document = TimelineDocumentView<Int>(frame: .zero)
    var created = 0
    var recycled = 0

    init() {
      _ = NSApplication.shared
      window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = root
      root.addSubview(scroll)
      scroll.hasVerticalScroller = false
      scroll.automaticallyAdjustsContentInsets = false
      scroll.contentInsets = .init()
      scroll.documentView = document
      document.makeView = { [weak self] _, reused in
        if let reused {
          return reused
        }
        self?.created += 1
        return Leaf(frame: .zero)
      }
      document.recycleView = { [weak self] _ in self?.recycled += 1 }
      document.presentView = { _, view, placement in
        (view as? Leaf)?.footer.frame = placement.row.elements["footer"] ?? .zero
      }
      root.layoutSubtreeIfNeeded()
    }

    func install(_ layout: TimelineLayout<Int>) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      document.install(layout, visibleRect: CGRect(x: 0, y: layout.originY, width: 600, height: 600))
      if layout.originY < 0 || layout.originY > layout.maximumOrigin {
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: layout.originY))
      } else {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: layout.originY))
      }
      scroll.reflectScrolledClipView(scroll.contentView)
      root.layoutSubtreeIfNeeded()
      CATransaction.commit()
    }
  }

  @Test func `initial presentation has exact native extent and bottom`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600, topInset: 64, bottomInset: 72)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: (0 ..< 400).map { .init(id: $0, height: 40) }, viewport: viewport, animated: false, at: 0)
    fixture.install(timeline.layout)
    #expect(fixture.document.frame.height == 16_136)
    #expect(fixture.scroll.contentView.bounds.minY == 15_536)
    let last = try #require(fixture.document.materialized[399])
    #expect(last.convert(last.bounds, to: fixture.root).maxY == 528)
    #expect(fixture.document.materialized.count < 25)
    #expect(fixture.document.row(at: CGPoint(x: 300, y: 16_063)) == 399)
  }

  @Test func `glyph origin refinement mounts exposed edges without rebinding resident rows`() {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(
      rows: (0 ..< 100).map { .init(id: $0, height: 80) }, viewport: viewport,
      intent: .reading(.init(id: 10)), animated: false, at: 0
    )
    var presentations: [Int] = []
    fixture.document.presentView = { id, _, _ in presentations.append(id) }
    fixture.install(timeline.layout)
    let previous = fixture.document.materialized
    presentations.removeAll()
    let refined = timeline.refineReadingAnchor(.init(id: 12, localY: 60))
    #expect(refined)
    fixture.document.refineScrollOrigin(
      to: timeline.layout.originY,
      visibleRect: CGRect(x: 0, y: timeline.layout.originY, width: 600, height: 600)
    )
    let mounted = fixture.document.materialized
    let added = Set(mounted.keys).subtracting(previous.keys)
    #expect(!added.isEmpty)
    #expect(Set(presentations) == added)
    #expect(presentations.count == added.count)
    #expect(fixture.document.presentation?.originY == timeline.layout.originY)
    for (id, view) in mounted {
      #expect(view.frame == timeline.layout.placement(for: id)?.frame)
      if let original = previous[id] {
        #expect(view === original)
      }
    }
  }

  @Test(arguments: [60, 120]) func `native rows and child geometry track anchor on every frame`(hz: Int) throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600, topInset: 64, bottomInset: 72)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var rows = (0 ..< 70).map { TimelineRow(id: $0, height: 40) }
    rows[20] = .init(id: 20, height: 80, elements: ["footer": CGRect(x: 10, y: 60, width: 50, height: 20)])
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 21, viewportY: 200)), animated: false, at: 0)
    fixture.install(timeline.layout)
    rows[20] = .init(id: 20, height: 300, elements: ["footer": CGRect(x: 10, y: 280, width: 50, height: 20)])
    rows.insert(.init(id: -1, height: 32), at: 10)
    timeline.apply(rows: rows, viewport: viewport, animated: true, at: 0)
    for frame in 0 ... hz {
      timeline.advance(to: Double(frame) / Double(hz))
      fixture.install(timeline.layout)
      let anchor = try #require(fixture.document.materialized[21])
      #expect(abs(anchor.convert(anchor.bounds, to: fixture.root).minY - 264) < 0.01)
      if let message = fixture.document.materialized[20] as? Leaf {
        let footerBottom = message.footer.convert(message.footer.bounds, to: fixture.root).maxY
        let messageBottom = message.convert(message.bounds, to: fixture.root).maxY
        #expect(abs(footerBottom - messageBottom) < 0.01)
      }
      #expect(abs(fixture.scroll.contentView.bounds.minY - timeline.layout.originY) < 0.01)
      #expect(fixture.document.materialized.count < 30)
    }
  }

  @Test func `native clamp after large deletion matches current plan`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600, topInset: 64, bottomInset: 72)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: (0 ..< 100).map { .init(id: $0, height: 40) }, viewport: viewport, animated: false, at: 0)
    fixture.install(timeline.layout)
    timeline.apply(rows: [.init(id: 99, height: 40)], viewport: viewport, animated: true, at: 0)
    for frame in 0 ... 120 {
      timeline.advance(to: Double(frame) / 120)
      fixture.install(timeline.layout)
      #expect(abs(fixture.scroll.contentView.bounds.minY - timeline.layout.originY) < 0.01)
      let last = try #require(fixture.document.materialized[99])
      #expect(abs(last.convert(last.bounds, to: fixture.root).maxY - 528) < 0.01)
    }
    #expect(fixture.document.frame.height == 600)
  }

  @Test func `long native scroll reuses bounded views and keeps logical hit targets`() {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: (0 ..< 400).map { .init(id: $0, height: 80) }, viewport: viewport, animated: false, at: 0)
    for origin in stride(from: CGFloat(0), through: 30_000, by: 100) {
      timeline.userScrolled(to: origin)
      fixture.install(timeline.layout)
      #expect(fixture.document.materialized.count < 20)
      let index = Int((origin + 300) / 80)
      #expect(fixture.document.row(at: CGPoint(x: 300, y: origin + 300)) == index)
    }
    #expect(fixture.created < 20)
    #expect(fixture.recycled > 300)
    fixture.document.clear()
    #expect(fixture.document.subviews.isEmpty)
  }

  @Test func `accessibility children follow visual order after scrollback and omit exits`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    let rows = (0 ..< 400).map { TimelineRow(id: $0, height: 80) }
    timeline.apply(
      rows: rows, viewport: viewport, intent: .reading(.init(id: 350)), animated: false, at: 0
    )
    fixture.install(timeline.layout)
    timeline.beginUserScroll(at: timeline.layout.originY)
    timeline.userScrolled(to: timeline.layout.originY - 160)
    fixture.install(timeline.layout)

    func childIDs() -> [Int] {
      (fixture.document.accessibilityChildren() ?? []).compactMap {
        guard let view = $0 as? NSView else { return nil }
        return fixture.document.row(for: view)
      }
    }

    let physicalIDs = fixture.document.subviews.compactMap { fixture.document.row(for: $0) }
    let orderedIDs = childIDs()
    #expect(physicalIDs != physicalIDs.sorted())
    #expect(orderedIDs == orderedIDs.sorted())
    #expect(Set(orderedIDs) == Set(physicalIDs))

    let exitingID = try #require(orderedIDs.dropFirst(orderedIDs.count / 2).first)
    timeline.apply(
      rows: rows.filter { $0.id != exitingID }, viewport: viewport,
      animated: true, at: 1
    )
    fixture.install(timeline.layout)
    #expect(fixture.document.materialized[exitingID] != nil)
    #expect(!childIDs().contains(exitingID))
  }

  @Test func `focused resident row keeps current geometry outside virtualization range`() throws {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var rows = (0 ..< 100).map { TimelineRow(id: $0, height: 80) }
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 0)
    timeline.beginUserScroll(at: 0)
    fixture.install(timeline.layout)
    let focused = try #require(fixture.document.materialized[2])
    #expect(fixture.window.makeFirstResponder(focused))
    timeline.userScrolled(to: 3_000)
    fixture.install(timeline.layout)
    #expect(fixture.document.materialized[2] === focused)
    #expect((fixture.document.accessibilityChildren() ?? []).contains { ($0 as? NSView) === focused })
    rows.insert(.init(id: -1, height: 120), at: 0)
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 1)
    fixture.install(timeline.layout)
    #expect(focused.frame.minY == 280)
    #expect(fixture.document.materialized.count < 20)
    rows.removeAll { $0.id == 2 }
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 2)
    fixture.install(timeline.layout)
    #expect(fixture.window.firstResponder === fixture.document)
    #expect(fixture.document.materialized[2] == nil)
  }

  @Test func `native clip rejects synthetic rubber band offsets`() {
    let fixture = Fixture()
    defer { fixture.window.close() }
    let viewport = TimelineViewport(width: 600, height: 600, topInset: 64, bottomInset: 72)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var rows = (0 ..< 100).map { TimelineRow(id: $0, height: 40) }
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 0)
    timeline.beginUserScroll(at: -18)
    rows[5].height = 200
    timeline.apply(rows: rows, viewport: viewport, animated: true, at: 0)
    for frame in 0 ... 60 {
      timeline.advance(to: Double(frame) / 60)
      fixture.install(timeline.layout)
      #expect(abs(timeline.layout.originY + 18) < 0.01)
      // Native AppKit clamps programmatic negative offsets outside a real
      // gesture. The production host must defer geometry during rubber-band
      // input, rather than attempting to synthesize this offset on each tick.
      #expect(fixture.scroll.contentView.bounds.minY == 0)
    }
    timeline.userScrolled(to: 0)
    timeline.endUserScroll(at: 0, canFollowLatest: true)
    fixture.install(timeline.layout)
    #expect(fixture.scroll.contentView.bounds.minY == 0)
  }
}
#endif
