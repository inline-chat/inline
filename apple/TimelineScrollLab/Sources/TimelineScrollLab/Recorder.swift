import AppKit
import QuartzCore

/// What the presentation layers showed at one display frame.
struct FrameSample {
  var t: CFTimeInterval
  /// The content's scroll position as shown (row coordinates are fixed in it): motion is its change.
  var scroll: CGFloat
  /// Rows on screen in the usable area, top to bottom: (id, top, bottom) in the list's coordinates.
  var rows: [(id: Int, top: CGFloat, bottom: CGFloat)]
  /// Message rows in the usable area that have not drawn their current text.
  var undrawn: Int
  /// The longest stretch of the usable area no row covers.
  var blank: CGFloat
  var listSeconds: Double
  var hostSeconds: Double
  /// With `recordsSticky`: every shown row, the avatars, the floating date, and the visible bottom edge (the
  /// composer's presented top less its 12 pt gap).
  var allRows: [Int: CGRect] = [:]
  var avatars: [Int: CGRect] = [:]
  var header: CGRect?
  var headerTitle: String?
  var edge: CGFloat = 0
  var usableTop: CGFloat = 0
}

/// Records every display frame (a display link on the lab window) and the main thread's busy time (a run loop
/// observer from wake to sleep).
@MainActor
final class Recorder: NSObject {
  let lab: LabWindow
  private(set) var samples: [FrameSample] = []
  private var link: CADisplayLink?
  private var observer: CFRunLoopObserver?
  /// Busy intervals of the main run loop: from waking to going to sleep.
  private(set) var busy: [(start: CFTimeInterval, end: CFTimeInterval)] = []
  private var busyStart: CFTimeInterval?
  /// Seconds the recorder itself spent sampling (taken out of the busy time).
  private(set) var ownSeconds: [(t: CFTimeInterval, seconds: Double)] = []
  var extraSample: ((CFTimeInterval) -> Void)?
  var recordsSticky = false

  init(lab: LabWindow) {
    self.lab = lab
  }

  func start() {
    samples = []
    busy = []
    ownSeconds = []
    let link = lab.root.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
          self.busyStart = now
        } else if let start = self.busyStart {
          self.busy.append((start, now))
          self.busyStart = nil
        }
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
    sample(CACurrentMediaTime())
  }

  func stop() {
    link?.invalidate()
    link = nil
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    observer = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    sample(link.timestamp)
  }

  func sample(_ t: CFTimeInterval) {
    let began = CACurrentMediaTime()
    let subject = lab.subject
    let top = lab.usableTop
    let bottom = lab.usableBottom
    var rows: [(id: Int, top: CGFloat, bottom: CGFloat)] = []
    var undrawn = 0
    for row in subject.shownRows() where row.frame.maxY > top && row.frame.minY < bottom {
      rows.append((row.id, row.frame.minY, row.frame.maxY))
      if let view = row.view as? LabRowView, !view.bubble.isHidden, !view.showsItsText,
         row.frame.maxY > top + 1, row.frame.minY < bottom - 1
      {
        undrawn += 1
      }
    }
    rows.sort { $0.top < $1.top }
    var blank: CGFloat = 0
    var cursor = top
    for row in rows {
      if row.top > cursor { blank = max(blank, row.top - cursor) }
      cursor = max(cursor, row.bottom)
    }
    if cursor < bottom { blank = max(blank, bottom - cursor) }
    var sample = FrameSample(
      t: t, scroll: scrollPosition(), rows: rows, undrawn: undrawn, blank: blank, listSeconds: subject.listSeconds,
      hostSeconds: lab.chat.hostSeconds
    )
    if recordsSticky {
      for row in subject.shownRows() { sample.allRows[row.id] = row.frame }
      sample.avatars = subject.avatarFrames()
      if let shown = subject.headerShown() {
        sample.header = shown.frame
        sample.headerTitle = shown.title
      }
      if let layer = lab.composer.layer {
        sample.edge = (layer.presentation() ?? layer).frame.minY - 12
      }
      sample.usableTop = top
    }
    samples.append(sample)
    extraSample?(t)
    // Reading presentation layers opened a transaction: close it, or the next pass runs on its stale time.
    CATransaction.flush()
    ownSeconds.append((t, CACurrentMediaTime() - began))
  }

  func scrollPosition() -> CGFloat {
    if let engine = lab.subject as? EngineSubject { return engine.list.diagnostics.presentedScrollPosition }
    if let scroll = lab.subject as? ScrollSubject { return scroll.list.presentedScrollPosition }
    if let plain = lab.subject as? PlainSubject { return plain.presentedScroll }
    if let tg = lab.subject as? TelegramSubject { return tg.presentedScroll }
    if let brake = lab.subject as? BrakeSubject { return brake.presentedScroll }
    return 0
  }

  /// Main-thread busy time (ms) in each display frame between `from` and `to`, the recorder's own sampling taken out.
  func busyPerFrame(from: CFTimeInterval, to: CFTimeInterval) -> [Double] {
    let frames = samples.filter { $0.t >= from && $0.t <= to }.map(\.t)
    guard frames.count >= 2 else { return [] }
    var out: [Double] = []
    var j = 0
    var k = 0
    for i in 0 ..< frames.count - 1 {
      let a = frames[i]
      let b = frames[i + 1]
      var total = 0.0
      while j < busy.count, busy[j].end < a { j += 1 }
      var m = j
      while m < busy.count, busy[m].start < b {
        total += max(0, min(b, busy[m].end) - max(a, busy[m].start))
        m += 1
      }
      while k < ownSeconds.count, ownSeconds[k].t < a { k += 1 }
      var own = 0.0
      var n = k
      while n < ownSeconds.count, ownSeconds[n].t < b {
        own += ownSeconds[n].seconds
        n += 1
      }
      out.append(max(0, total - own) * 1000)
    }
    return out
  }
}
