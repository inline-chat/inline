#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// The overlay scroller's knob. The content's extent is an estimate (only placed rows have heights, and history beyond
// the loaded rows is unknown), so the knob's place is state (`TimelineIndicator`): it moves only with the content,
// towards the end the content moves to, and rides a fling on the render server. Beyond a loaded end that is not a
// real end the extent counts two more screens (as iOS does), so the knob meets its end only at a real end. Its length
// is measured while it is hidden and holds while it shows: history pages landing mid-scroll change the row count, and
// a knob resized and moved by them reads as jumping. It can be dragged.

extension TimelineListView {
  func indicatorExtent() -> TimelineIndicator.Extent {
    state.layout.indicatorExtent(
      rowCount: state.rows.count, coverage: state.coverage, unknown: 2 * state.viewport.usableHeight
    )
  }

  func indicatorTrack() -> (top: CGFloat, length: CGFloat) {
    let viewport = state.viewport
    return (viewport.usableTop + 2, max(0, viewport.usableHeight - 4))
  }

  func indicatorTop(_ progress: CGFloat, track: (top: CGFloat, length: CGFloat)) -> CGFloat {
    track.top + max(0, track.length - indicatorLength) * min(1, max(0, progress))
  }

  /// After a change: a jump re-estimates the knob's place; a scroll moves it by the share of the estimated distance it
  /// covered.
  func moveIndicator(
    _ change: TimelineChange<ID>, scrolledBy: (extent: TimelineIndicator.Extent, delta: CGFloat)?, timing: TimelineTiming
  ) {
    let extent = indicatorExtent()
    if change.isDisjoint || (scrolledBy.map { !$0.extent.isScrollable } ?? false) {
      indicator = TimelineIndicator(progress: TimelineIndicator.estimate(extent))
    } else if let scrolledBy {
      let moved = change.previous.placements.first.flatMap { old in change.layout.placement(for: old.id).map { $0.y - old.y } }
      indicator = TimelineIndicator(
        progress: TimelineIndicator.progress(indicator.progress, extent: scrolledBy.extent, moved: moved ?? scrolledBy.delta)
      )
    }
    if !extent.isScrollable { indicator = TimelineIndicator(progress: 1) }
    placeIndicator(timing: timing)
  }

  func placeIndicator(timing: TimelineTiming) {
    let extent = indicatorExtent()
    let track = indicatorTrack()
    guard extent.isScrollable, track.length > 20 else {
      indicatorView.isHidden = true
      return
    }
    indicatorView.isHidden = false
    let key = IndicatorLengthKey(rows: state.rows.count, coverage: state.coverage, track: track.length)
    let hidden = indicatorView.alphaValue < 0.01 || indicatorLength == 0
    let trackChanged = indicatorLengthKey?.track != key.track
    if indicatorFlight == nil, indicatorLengthKey != key || indicatorLength == 0, hidden || trackChanged {
      indicatorLength = TimelineIndicator.length(extent, track: track.length, minimum: TimelineScrollIndicatorView.minimumLength)
      indicatorLengthKey = key
    }
    var progress = indicator.progress
    if let flight, let baked = indicatorFlight, baked.start == flight.start {
      progress = TimelineIndicator.progress(baked.progress, extent: baked.extent, moved: CGFloat(flight.path.end - baked.applied))
    }
    let top = indicatorTop(progress, track: track)
    let frame = NSRect(
      x: bounds.width - TimelineScrollIndicatorView.width - TimelineScrollIndicatorView.inset, y: top,
      width: TimelineScrollIndicatorView.width, height: indicatorLength
    )
    let old = indicatorView.frame
    guard old != frame else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicatorView.frame = frame
    if timing.isAnimated, old.height > 0, abs(old.minY - top) > 0.01,
       let track = timing.track(keyPath: "position.y", from: old.minY - top)
    {
      indicatorTrackCount &+= 1
      indicatorView.layer?.add(track, forKey: "\(Self.indicatorTrackKey).\(indicatorTrackCount)")
    }
    CATransaction.commit()
  }

  /// A flight's knob moves on the render server with the content: the flight's samples mapped to knob places by the
  /// indicator's rule from where it is now, on the content's clock.
  func bakeIndicator(_ flight: Flight) {
    guard let layer = indicatorView.layer else { return }
    layer.removeAnimation(forKey: Self.indicatorFlightKey)
    let extent = indicatorExtent()
    guard extent.isScrollable else {
      indicatorFlight = nil
      return
    }
    let baked = (start: flight.start, progress: indicator.progress, extent: extent, applied: flight.applied)
    indicatorFlight = baked
    placeIndicator(timing: .none)
    let track = indicatorTrack()
    let followed = flight.path.follow { shift in
      // `shift` is from the path's end; the rule moves from where the knob is now (at `applied`).
      let moved = CGFloat(flight.path.end - baked.applied) + shift
      return self.indicatorTop(TimelineIndicator.progress(baked.progress, extent: extent, moved: moved), track: track)
    }
    guard followed.varies, !indicatorView.isHidden else { return }
    layer.add(flightAnimation(keyPath: "position.y", values: followed.values, flight: flight, layer: layer),
              forKey: Self.indicatorFlightKey)
  }

  func endIndicatorFlight() {
    guard indicatorFlight != nil else { return }
    indicatorFlight = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicatorView.layer?.removeAnimation(forKey: Self.indicatorFlightKey)
    placeIndicator(timing: .none)
    CATransaction.commit()
  }

  func showIndicator() {
    guard showsScrollIndicator else { return }
    indicatorHide?.cancel()
    // Coming back from hidden: its length catches up with what landed meanwhile, before it shows.
    if indicatorView.alphaValue < 0.01, indicatorFlight == nil { placeIndicator(timing: .none) }
    if indicatorView.alphaValue < 1 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        indicatorView.animator().alphaValue = 1
      }
    }
  }

  func scheduleIndicatorHide() {
    indicatorHide?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isTracking, self.flight == nil, self.coast == nil, self.indicatorGrab == nil else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          self.indicatorView.animator().alphaValue = 0
        }
      }
    }
    indicatorHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  // MARK: - Dragging the knob

  /// The knob takes the pointer while it shows: a strip along the trailing edge, a little wider than it.
  func indicatorTakes(_ point: NSPoint) -> Bool {
    guard showsScrollIndicator, !indicatorView.isHidden, indicatorView.alphaValue > 0.5 else { return false }
    let frame = indicatorView.frame.insetBy(dx: -4, dy: -4)
    return point.x >= frame.minX && frame.contains(point)
  }

  func timeline_mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard indicatorTakes(point) else { return super.mouseDown(with: event) }
    catchFlight()
    caughtFlight = false
    indicatorGrab = point.y - indicatorView.frame.minY
    showIndicator()
    onScrollBegan?()
  }

  func timeline_mouseDragged(with event: NSEvent) {
    guard let grab = indicatorGrab else { return super.mouseDragged(with: event) }
    let point = convert(event.locationInWindow, from: nil)
    let track = indicatorTrack()
    let room = max(1, track.length - indicatorLength)
    let wanted = min(1, max(0, (point.y - grab - track.top) / room))
    let extent = indicatorExtent()
    // Content to move for the knob to reach `wanted`: the share of the estimated distance to that end.
    let delta: CGFloat
    if wanted < indicator.progress {
      delta = extent.above * (indicator.progress - wanted) / max(0.0001, indicator.progress)
    } else {
      delta = -extent.below * (wanted - indicator.progress) / max(0.0001, 1 - indicator.progress)
    }
    guard abs(delta) > 0.01 else { return }
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
  }

  func timeline_mouseUp(with event: NSEvent) {
    guard indicatorGrab != nil else { return super.mouseUp(with: event) }
    indicatorGrab = nil
    rest()
  }
}

/// The overlay scroller's knob, drawn as macOS draws it: a rounded bar on the trailing edge while the list moves.
final class TimelineScrollIndicatorView: NSView {
  static let width: CGFloat = 7
  static let inset: CGFloat = 2
  static let minimumLength: CGFloat = 28

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = Self.width / 2
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.4).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.4).cgColor
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
