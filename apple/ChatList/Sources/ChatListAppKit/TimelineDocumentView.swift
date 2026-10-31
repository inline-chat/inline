#if canImport(AppKit)
import AppKit
import ChatListCore
import QuartzCore

/// A virtual, upright AppKit document. It displays exact prepared geometry and
/// never asks a row for an intrinsic size. The factory must only bind a plan.
@MainActor
public final class TimelineDocumentView<ID: Hashable & Sendable>: NSView {
  public var overscan: CGFloat = 160
  public var maximumReusableViewsPerKind = 12
  public var reuseIdentifier: ((ID) -> String)?
  public var makeView: ((ID, NSView?) -> NSView?)?
  public var presentView: ((ID, NSView, TimelineLayout<ID>.Placement) -> Void)?
  public var recycleView: ((NSView) -> Void)?
  public var onMouseMoved: ((NSEvent) -> Void)?
  public var onMouseExited: (() -> Void)?
  public var onBeginMessageSelection: ((NSView) -> Void)?
  public private(set) var materialized: [ID: NSView] = [:]
  public private(set) var presentation: TimelineLayout<ID>?
  private var reusePool: [String: [NSView]] = [:]
  private var pinnedIDs: Set<ID> = []
  private var tracking: NSTrackingArea?
  private var installing = false

  override public var isFlipped: Bool {
    true
  }

  override public var acceptsFirstResponder: Bool {
    true
  }

  /// AppKit's default follows subview insertion order, which changes as
  /// recycled rows are appended during scrollback. Expose only resident rows
  /// in timeline order so assistive navigation follows the visual list.
  override public func accessibilityChildren() -> [Any]? {
    guard let presentation else { return [] }
    return materialized.compactMap { id, view -> (Int, NSView)? in
      guard let index = presentation.index(for: id),
            !presentation.rows[index].isExiting else { return nil }
      return (index, view)
    }
    .sorted { $0.0 < $1.0 }
    .map { $0.1 }
  }

  override public init(frame: NSRect) {
    super.init(frame: frame)
    autoresizesSubviews = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    setAccessibilityElement(false)
    setAccessibilityRole(.list)
    setAccessibilityLabel("Messages")
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The coordinator calls this in the same disabled-actions transaction as
  /// clip scrolling and overlay placement. No layoutSubtreeIfNeeded recursion.
  public func install(_ presentation: TimelineLayout<ID>, visibleRect: CGRect) {
    guard !installing else { return }
    installing = true
    defer { installing = false }
    self.presentation = presentation
    let size = CGSize(width: presentation.viewport.width, height: presentation.contentHeight)
    if frame.size != size {
      setFrameSize(size)
    }
    materialize(in: visibleRect)
  }

  public func materialize(in rect: CGRect) {
    materialize(in: rect, updateExisting: true)
  }

  /// Keep a native interaction alive outside the visible region. A removed
  /// logical row is still retired on the next presentation.
  public func pin(_ id: ID) {
    pinnedIDs.insert(id)
  }

  public func unpin(_ id: ID) {
    pinnedIDs.remove(id)
  }

  public func trimReusePool() {
    for key in Array(reusePool.keys) {
      reusePool[key] = Array(reusePool[key, default: []].suffix(max(0, maximumReusableViewsPerKind)))
    }
  }

  /// A renderer-derived reading coordinate can move the clip after the current
  /// frame has been installed. Mount newly exposed edges without presenting
  /// every existing row a second time in the same display callback.
  public func refineScrollOrigin(to origin: CGFloat, visibleRect: CGRect) {
    guard let presentation else { return }
    self.presentation = presentation.scrolled(to: origin)
    materialize(in: visibleRect, updateExisting: false)
  }

  private func materialize(in rect: CGRect, updateExisting: Bool) {
    guard let presentation else { return }
    let guardRect = rect.insetBy(dx: 0, dy: -max(0, overscan))
    let visible = presentation.visibleRows(in: guardRect)
    let visibleIDs = Set(presentation.rows[visible].map(\.row.id))
    var required = visibleIDs
    for id in pinnedIDs where presentation.placement(for: id) != nil {
      required.insert(id)
    }
    required.formUnion(presentation.departingIDs)
    // Keep a native text editor alive while it owns selection/focus. Its view
    // cannot be recycled merely because autoscroll crosses the guard band.
    if let responder = window?.firstResponder as? NSView, let id = row(for: responder),
       presentation.placement(for: id) != nil {
      required.insert(id)
    }
    if let focused = NSApp.accessibilityApplicationFocusedUIElement() as? NSView,
       let id = row(for: focused), presentation.placement(for: id) != nil {
      required.insert(id)
    }
    for id in Array(materialized.keys) where !required.contains(id) {
      guard let view = materialized.removeValue(forKey: id) else { continue }
      // History eviction ends a native text selection deliberately. Viewport
      // virtualization alone never does (the focused resident row is pinned).
      if let responder = window?.firstResponder as? NSView,
         responder === view || responder.isDescendant(of: view)
      {
        window?.makeFirstResponder(self)
      }
      recycleView?(view)
      view.removeFromSuperview()
      let key = view.identifier?.rawValue ?? "row"
      if (reusePool[key]?.count ?? 0) < max(0, maximumReusableViewsPerKind) {
        reusePool[key, default: []].append(view)
      }
    }
    for index in visible {
      present(presentation.rows[index], updateExisting: updateExisting)
    }
    for id in required where !visibleIDs.contains(id) {
      if let placement = presentation.placement(for: id) {
        present(placement, updateExisting: updateExisting)
      }
    }
  }

  private func present(_ placement: TimelineLayout<ID>.Placement, updateExisting: Bool) {
    let id = placement.row.id
    let key = reuseIdentifier?(id) ?? "row"
    if let existing = materialized[id], existing.identifier?.rawValue != key {
      if let responder = window?.firstResponder as? NSView,
         responder === existing || responder.isDescendant(of: existing) {
        window?.makeFirstResponder(self)
      }
      materialized.removeValue(forKey: id)
      recycleView?(existing)
      existing.removeFromSuperview()
      let oldKey = existing.identifier?.rawValue ?? "row"
      if (reusePool[oldKey]?.count ?? 0) < max(0, maximumReusableViewsPerKind) {
        reusePool[oldKey, default: []].append(existing)
      }
    }
    let view: NSView
    if let existing = materialized[id] {
      guard updateExisting else { return }
      view = existing
    } else {
      if placement.isExiting { return }
      let reused = reusePool[key]?.popLast()
      guard let created = makeView?(id, reused) else { return }
      view = created
      view.identifier = NSUserInterfaceItemIdentifier(key)
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
      materialized[id] = view
    }
    if view.frame != placement.frame { view.frame = placement.frame }
    if view.alphaValue != placement.opacity { view.alphaValue = placement.opacity }
    presentView?(id, view, placement)
  }

  override public func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    if let id = row(for: hit), presentation?.placement(for: id)?.isExiting == true {
      return nil
    }
    return hit
  }

  public func row(at point: CGPoint) -> ID? {
    guard let presentation else { return nil }
    let range = presentation.visibleRows(in: CGRect(x: point.x, y: point.y, width: 1, height: 0.01))
    return presentation.rows[range].first { !$0.isExiting && $0.frame.contains(point) }?.row.id
  }

  public func row(for view: NSView) -> ID? {
    materialized.first { view === $0.value || view.isDescendant(of: $0.value) }?.key
  }

  public func clear() {
    if let responder = window?.firstResponder as? NSView, row(for: responder) != nil {
      window?.makeFirstResponder(self)
    }
    for view in materialized.values {
      recycleView?(view)
      view.removeFromSuperview()
    }
    materialized.removeAll()
    reusePool.removeAll()
    pinnedIDs.removeAll()
    presentation = nil
  }

  override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking {
      removeTrackingArea(tracking)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    tracking = area
  }

  override public func mouseMoved(with event: NSEvent) {
    onMouseMoved?(event)
  }

  override public func mouseExited(with event: NSEvent) {
    onMouseExited?()
  }
}

/// Weak display-link target avoids the link -> target -> owner retention cycle.
@MainActor
public final class TimelineDisplayClock {
  @MainActor private final class Target: NSObject {
    weak var owner: TimelineDisplayClock?
    /// Present the state for the frame being rendered, not the one on screen.
    @objc func tick(_ link: CADisplayLink) {
      owner?.onFrame?(link.targetTimestamp)
    }
  }

  public var onFrame: ((Double) -> Void)?
  private let target = Target()
  private var link: CADisplayLink?
  public var isRunning: Bool {
    link != nil
  }

  public init() {
    target.owner = self
  }

  public func start(in window: NSWindow) {
    guard link == nil else { return }
    let link = window.displayLink(target: target, selector: #selector(Target.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    self.link = link
    link.add(to: .main, forMode: .common)
  }

  public func stop() {
    link?.invalidate()
    link = nil
  }

  isolated deinit { link?.invalidate() }
}
#endif
