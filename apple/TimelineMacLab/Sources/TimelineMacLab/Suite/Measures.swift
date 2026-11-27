import AppKit
import TimelineAppKit
import TimelineCore

// Measures over a recording: how far rows moved, how smoothly, whether sticky things kept their rules on every frame.

extension Recording {
  /// The largest distance a row's screen top was from `value` while it showed.
  func deviation(_ id: Int, from value: Double) -> Double {
    tops(id).map { abs($0 - value) }.max() ?? .infinity
  }

  /// The largest deviation of the distance between a row's top and the composer's top from its first value.
  func distanceToComposerDeviation(_ id: Int) -> Double {
    let distances = frames.compactMap { frame in frame.rows[id].map { Double(frame.composerTop - $0.minY) } }
    guard let first = distances.first else { return .infinity }
    return distances.map { abs($0 - first) }.max() ?? 0
  }

  /// Speed of a row's top between consecutive frames, points per second.
  func speeds(_ id: Int) -> [(t: Double, v: Double)] {
    var out: [(Double, Double)] = []
    var last: (t: Double, y: Double)?
    for frame in frames {
      guard let y = frame.rows[id]?.minY else { last = nil; continue }
      if let last, frame.t - last.t > 0.001 { out.append((frame.t, (Double(y) - last.y) / (frame.t - last.t))) }
      last = (frame.t, Double(y))
    }
    return out
  }

  /// The largest frame-to-frame change of speed beyond what a smooth deceleration gives: relative share of the speed,
  /// with a floor for slow motion. A stop-and-catch-up or a snap shows as a large value.
  func speedJump(_ id: Int, floor: Double = 150) -> Double {
    let v = speeds(id)
    guard v.count > 3 else { return 0 }
    var worst = 0.0
    for i in 1 ..< v.count {
      let a = v[i - 1].v
      let b = v[i].v
      let jump = abs(b - a) / max(floor, abs(a), abs(b))
      worst = max(worst, jump)
    }
    return worst
  }

  /// Total travel of a row's top from the first frame it showed to the last.
  func travel(_ id: Int) -> Double {
    let values = tops(id)
    guard let first = values.first, let last = values.last else { return 0 }
    return last - first
  }

  /// The largest overshoot of a row's bottom above `edge` (content moving up past the newest end).
  func overshootAbove(_ id: Int, edge: (Frame) -> CGFloat) -> Double {
    frames.compactMap { frame in frame.rows[id].map { Double(edge(frame) - $0.maxY) } }.max() ?? 0
  }

  func overshootBelow(_ id: Int, edge: (Frame) -> CGFloat) -> Double {
    frames.compactMap { frame in frame.rows[id].map { Double($0.minY - edge(frame)) } }.max() ?? 0
  }

  /// Frames where the speed reverses sign: a bounce shows one, a second oscillation more.
  func reversals(_ id: Int, minimumSpeed: Double = 30) -> Int {
    var sign = 0
    var count = 0
    for (_, v) in speeds(id) where abs(v) > minimumSpeed {
      let s = v > 0 ? 1 : -1
      if sign != 0, s != sign { count += 1 }
      sign = s
    }
    return count
  }
}

/// The sticky rules, evaluated from what is on screen in a frame.
@MainActor
enum StickyRules {
  /// Where an avatar should be in `frame`: its group's last row's resting place, lifted to the visible bottom edge but
  /// never above the group's first bubble. Nil when the group's last row is not shown.
  static func expectedAvatarBottom(lastRow id: Int, in frame: Frame, chat: LabChat, edge: CGFloat) -> CGFloat? {
    guard let row = frame.rows[id], let group = chat.group(id) else { return nil }
    let restBottom = row.maxY - LabChat.bottomGap(last: true)
    // The span's top: the top of the group's rows that show joined above this one (each touching the next), walking
    // up from it. It goes on above when that run reaches past the screen's top; it stops where the run is cut (the
    // group's first row, or a far jump's slide that joined another strip above: rows of one group can show in both).
    var spanTop = -CGFloat.infinity
    if let start = chat.index(group.start), var at = chat.index(id) {
      let ids = chat.ids
      var top = row
      while at > start, let above = frame.rows[ids[at - 1]], abs(above.maxY - top.minY) < 1 {
        top = above
        at -= 1
      }
      if at == start || top.minY > frame.usableTop { spanTop = top.minY + 2 }
    }
    let maxLift = max(0, restBottom - LabChat.avatarSize - spanTop)
    let lift = max(0, min(restBottom - edge, maxLift))
    return restBottom - lift
  }

  /// The worst avatar error over a recording, for avatars whose group's first row is shown or whose span reaches above
  /// the screen. `edge` gives the visible bottom edge for a frame.
  static func avatarError(_ recording: Recording, chat: LabChat, edge: (Frame) -> CGFloat) -> (error: Double, checked: Int) {
    var worst = 0.0
    var checked = 0
    for frame in recording.frames {
      for (id, avatar) in frame.avatars {
        guard chat.group(id) != nil else { continue }
        guard let expected = expectedAvatarBottom(lastRow: id, in: frame, chat: chat, edge: edge(frame)) else { continue }
        // Only avatars in sight matter.
        guard avatar.maxY > frame.usableTop, avatar.minY < frame.usableBottom + 40 else { continue }
        worst = max(worst, Double(abs(avatar.maxY - expected)))
        checked += 1
      }
    }
    return (worst, checked)
  }

  /// Where the floating header should be in `frame` and for which day: nil when hidden.
  static func expectedHeader(in frame: Frame, chat: LabChat) -> (y: CGFloat, title: String)? {
    let top = frame.usableTop
    let sorted = frame.rows.sorted { $0.value.minY < $1.value.minY }
    guard let topIndex = sorted.firstIndex(where: { $0.value.maxY > top + 1 }) else { return nil }
    let topRow = sorted[topIndex]
    guard let current = chat.section(topRow.key) else { return nil }
    if let own = frame.rows[current], own.minY >= top - 0.5 { return nil }
    var y = top
    if let next = sorted[(topIndex + 1)...].first(where: { $0.key != current && chat.section($0.key) == $0.key }) {
      y = min(top, next.value.minY - LabChat.dayHeight)
    }
    guard y + LabChat.dayHeight > top else { return nil }
    return (y, chat.row(current)?.text ?? "")
  }

  /// The worst header error over a recording: position error where it should show, frames shown where it should hide
  /// (or hidden where it should show), and wrong titles. Frames within 0.6 pt of a switch are not judged.
  static func headerError(_ recording: Recording, chat: LabChat) -> (position: Double, wrongVisibility: Int, wrongTitle: Int, checked: Int) {
    var worst = 0.0
    var visibility = 0
    var titles = 0
    var checked = 0
    var lastSliding: Double?
    for frame in recording.frames {
      // The idle policy hides the header's container (`sticky.header-idle` judges that): a header whose own layer shows
      // inside a faded-out container shows nothing, and is not judged here (it read as "shown" mid-slide while
      // invisible: `update.deleteAbove` mid-jump, 4–6 frames).
      if frame.header != nil, frame.headerAlpha < 0.01 { continue }
      // During a far jump's slide the date is hidden (decided 2026-11-27, as Telegram shows the target alone): shown
      // there is wrong, hidden is right, whatever the rows say.
      if frame.sliding {
        checked += 1
        if frame.header != nil, frame.headerAlpha > 0.5 { visibility += 1 }
        lastSliding = frame.t
        continue
      }
      // It fades back in over 0.1 s as the slide ends: not judged meanwhile.
      if let last = lastSliding, frame.t - last < 0.12 { continue }
      let expected = expectedHeader(in: frame, chat: chat)
      checked += 1
      switch (expected, frame.header) {
        case let (e?, shown?):
          worst = max(worst, Double(abs(shown.minY - e.y)))
          if frame.headerTitle != e.title { titles += 1 }
        case (nil, nil):
          break
        case let (e?, nil):
          // Borderline: the own row just reached the top.
          if !isBorderline(frame, chat: chat, expectedY: e.y) { visibility += 1 }
        case (nil, _?):
          if !isBorderline(frame, chat: chat, expectedY: nil) { visibility += 1 }
      }
    }
    return (worst, visibility, titles, checked)
  }

  private static func isBorderline(_ frame: Frame, chat: LabChat, expectedY: CGFloat?) -> Bool {
    let top = frame.usableTop
    for (id, rect) in frame.rows where chat.section(id) == id {
      if abs(rect.minY - top) < 1.5 || abs(rect.minY - LabChat.dayHeight - top) < 1.5 { return true }
    }
    if let expectedY, expectedY + LabChat.dayHeight - top < 1.5 { return true }
    return false
  }
}
