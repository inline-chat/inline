import AppKit
import EngineBrake
import TimelineCore

/// The engine forked into the lab (EngineBrake): the same render-server flight, braking to the rows it has placed.
/// This file imports the fork only, so its types are the fork's.
@MainActor
final class BrakeSubject: ListSubject {
  let list: TimelineListView<Int>
  let kind = "engine-brake"
  var view: NSView { list }

  init(chat: LabChat) {
    list = TimelineListView(rows: TimelineRows(
      height: { [unowned chat] id, width in chat.height(id, width) },
      make: { [unowned chat] id, width in chat.make(id, width) },
      update: { [unowned chat] id, view, width, _ in chat.update(id, view, width) },
      recycle: { [unowned chat] id, view in chat.recycle(id, view) }
    ))
    list.showsScrollIndicator = true
    list.coastsOnMainThread = false
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
  var presentedScroll: CGFloat { list.diagnostics.presentedScrollPosition }
  var notes: String { "brakes \(list.brakeTimes.count), performs \(list.diagnostics.performCount), makes \(list.diagnostics.makes)" }
}
