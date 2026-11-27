import AppKit
import QuartzCore

/// Prepares row plans ahead of the list in idle main-thread slices (the row-cost plan's step 1): when the main run loop
/// is about to sleep, up to `budget` of plan work for the rows within reach of what is on screen, the direction of
/// motion first. The same for every host: it reads only which rows show and where the content is going.
@MainActor
final class RowPreparer {
  let lab: LabWindow
  /// Plan work per idle slice (seconds): 3 ms, as the plan.
  var budget: Double = 0.003
  /// Rows prepared ahead of the motion, and behind it.
  var ahead = 60
  var behind = 15
  private var observer: CFRunLoopObserver?
  private var lastScroll: CGFloat = 0
  private var direction = 0
  private(set) var slices = 0
  private(set) var seconds: Double = 0

  init(lab: LabWindow) {
    self.lab = lab
  }

  func start() {
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_000_000
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.slice() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  func stop() {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    observer = nil
  }

  private func slice() {
    let chat = lab.chat
    guard chat.preparesAhead, chat.rowCost > 0 else { return }
    let began = CACurrentMediaTime()
    let shown = lab.subject.shownRows()
    guard !shown.isEmpty else { return }
    // Which way the content goes: rows entering from the top (older, lower indexes) or the bottom.
    let top = shown.min { $0.frame.minY < $1.frame.minY }!
    let scroll = top.frame.minY
    if abs(scroll - lastScroll) > 0.5 { direction = scroll > lastScroll ? -1 : 1 }
    lastScroll = scroll
    let indexes = shown.compactMap { chat.index($0.id) }
    guard let low = indexes.min(), let high = indexes.max() else { return }
    let ids = chat.ids
    // Order: ahead of the motion first, then behind it.
    var order: [Int] = []
    let olderFirst = direction <= 0
    let older = stride(from: low - 1, through: max(0, low - (olderFirst ? ahead : behind)), by: -1)
    let newer = stride(from: high + 1, to: min(ids.count, high + 1 + (olderFirst ? behind : ahead)), by: 1)
    if olderFirst { order = Array(older) + Array(newer) } else { order = Array(newer) + Array(older) }
    var left = false
    for index in order {
      if CACurrentMediaTime() - began >= budget {
        left = true
        break
      }
      chat.preparePlan(ids[index], width: lab.subject.view.bounds.width)
    }
    slices += 1
    seconds += CACurrentMediaTime() - began
    // Work left: come back on the next run-loop turn (wake it, or an idle main thread would sleep with plans to make).
    if left {
      RunLoop.main.perform(inModes: [.common]) {}
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }
}
