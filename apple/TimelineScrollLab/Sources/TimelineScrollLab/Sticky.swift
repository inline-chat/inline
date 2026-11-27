import AppKit
import QuartzCore
import TimelineCore

// Sticky avatars and the floating date, by the engine suite's own rules (TimelineMacLab `StickyRules`, `sticky.*`
// cases), on the engine and the prototype: per display frame from the presentation layers, events through the window
// server.

@MainActor
enum StickyCheck {
  /// Where a group's avatar should be: its last row's resting place, lifted to the visible bottom edge but never above
  /// the group's first bubble (TimelineMacLab `StickyRules.expectedAvatarBottom`).
  static func expectedAvatarBottom(lastRow id: Int, in frame: FrameSample, chat: LabChat) -> CGFloat? {
    guard let row = frame.allRows[id], let group = chat.group(id) else { return nil }
    let restBottom = row.maxY - LabChat.bottomGap(last: true)
    var spanTop = -CGFloat.infinity
    if let start = chat.index(group.start), var at = chat.index(id) {
      let ids = chat.ids
      var top = row
      while at > start, let above = frame.allRows[ids[at - 1]], abs(above.maxY - top.minY) < 1 {
        top = above
        at -= 1
      }
      if at == start || top.minY > frame.usableTop { spanTop = top.minY + 2 }
    }
    let maxLift = max(0, restBottom - LabChat.avatarSize - spanTop)
    let lift = max(0, min(restBottom - frame.edge, maxLift))
    return restBottom - lift
  }

  static func avatarError(_ frames: [FrameSample], chat: LabChat, bottom: CGFloat) -> (error: Double, checked: Int, missing: Int) {
    var worst = 0.0
    var checked = 0
    var missing = 0
    for frame in frames {
      for (id, avatar) in frame.avatars {
        guard chat.group(id) != nil,
              let expected = expectedAvatarBottom(lastRow: id, in: frame, chat: chat) else { continue }
        guard avatar.maxY > frame.usableTop, avatar.minY < bottom + 40 else { continue }
        worst = max(worst, Double(abs(avatar.maxY - expected)))
        checked += 1
      }
      // A group's last row in sight with no avatar shown for it.
      for (id, row) in frame.allRows where chat.showsAvatar(id) && row.maxY > frame.usableTop + 4 && row.minY < frame.edge - 4 {
        if frame.avatars[id] == nil { missing += 1 }
      }
    }
    return (worst, checked, missing)
  }

  static func expectedHeader(in frame: FrameSample, chat: LabChat) -> (y: CGFloat, title: String)? {
    let top = frame.usableTop
    let sorted = frame.allRows.sorted { $0.value.minY < $1.value.minY }
    guard let topIndex = sorted.firstIndex(where: { $0.value.maxY > top + 1 }) else { return nil }
    let topRow = sorted[topIndex]
    guard let current = chat.section(topRow.key) else { return nil }
    if let own = frame.allRows[current], own.minY >= top - 0.5 { return nil }
    var y = top
    if let next = sorted[(topIndex + 1)...].first(where: { $0.key != current && chat.section($0.key) == $0.key }) {
      y = min(top, next.value.minY - LabChat.dayHeight)
    }
    guard y + LabChat.dayHeight > top else { return nil }
    return (y, chat.row(current)?.text ?? "")
  }

  static func headerError(_ frames: [FrameSample], chat: LabChat) -> (position: Double, wrongVisibility: Int, wrongTitle: Int) {
    var worst = 0.0
    var visibility = 0
    var titles = 0
    for frame in frames {
      let expected = expectedHeader(in: frame, chat: chat)
      switch (expected, frame.header) {
        case let (e?, shown?):
          worst = max(worst, Double(abs(shown.minY - e.y)))
          if frame.headerTitle != e.title { titles += 1 }
        case (nil, nil):
          break
        case let (e?, nil):
          if !borderline(frame, chat: chat, expectedY: e.y) { visibility += 1 }
        case (nil, _?):
          if !borderline(frame, chat: chat, expectedY: nil) { visibility += 1 }
      }
    }
    return (worst, visibility, titles)
  }

  private static func borderline(_ frame: FrameSample, chat: LabChat, expectedY: CGFloat?) -> Bool {
    let top = frame.usableTop
    for (id, rect) in frame.allRows where chat.section(id) == id {
      if abs(rect.minY - top) < 1.5 || abs(rect.minY - LabChat.dayHeight - top) < 1.5 { return true }
    }
    if let expectedY, expectedY + LabChat.dayHeight - top < 1.5 { return true }
    return false
  }
}

extension Compare {
  static var stickyKinds: [String] {
    argument("--subjects")?.split(separator: ",").map(String.init) ?? ["engine-flight", "engine-coast", "nsscroll", "nsscroll-overlay"]
  }

  static func sticky() async {
    for kind in stickyKinds {
      await stickyCase(kind, "sticky.avatar-drag", count: 600, groupRun: 8) { run in
        let steps = Synth.drag(dy: 3, count: 160)
        return await run.play(steps)
      }
      await stickyCase(kind, "sticky.avatar-fling", count: 1200, groupRun: 8) { run in
        await run.play(Synth.fling(speed: 2400).steps)
      }
      await stickyCase(kind, "sticky.avatar-fling-fast", count: 3000, groupRun: 8) { run in
        await run.play(Synth.fling(speed: 8000).steps)
      }
      await stickyCase(kind, "sticky.avatar-stalls", count: 1200, groupRun: 8, rowCost: 1) { run in
        var fling = Synth.fling(speed: 2400)
        for i in 0 ..< 3 {
          fling.steps.append(Synth.Step(at: fling.lift + 0.1 + Double(i) * 0.18, label: "stall") {
            let a = CACurrentMediaTime()
            while CACurrentMediaTime() - a < 0.08 {}
          })
        }
        return await run.play(fling.steps)
      }
      await stickyCase(kind, "sticky.avatar-composer", count: 600, groupRun: 10, setup: { run in
        // An incoming group of several messages whose last row hangs below the composer.
        let chat = run.lab.chat
        let ids = chat.ids
        guard let last = ids[(ids.count / 2)...].first(where: { id in
          guard chat.showsAvatar(id), let g = chat.group(id), let a = chat.index(g.start), let b = chat.index(id) else { return false }
          return b - a >= 3
        }) else { return }
        run.lab.subject.apply(scroll: .to(last, .bottom(-30)))
        await run.wait(0.4)
      }) { run in
        let start = CACurrentMediaTime()
        run.lab.setComposerLines(5)
        await run.wait(0.5)
        run.lab.setComposerLines(1)
        await run.wait(0.5)
        return start
      }
      await stickyCase(kind, "sticky.avatar-handoff", count: 200, groupRun: 4, setup: { run in
        let chat = run.lab.chat
        chat.append("first from Sam", sender: 1)
        run.lab.subject.apply(rows: chat.ids, timing: .standard)
        await run.wait(0.6)
      }) { run in
        let start = CACurrentMediaTime()
        let chat = run.lab.chat
        chat.append("second from Sam", sender: 1)
        run.lab.subject.apply(rows: chat.ids, timing: .standard)
        await run.wait(0.6)
        return start
      }
      await stickyCase(kind, "sticky.header-drag", count: 600, groupRun: 4) { run in
        await run.play(Synth.drag(dy: -4, count: 220))
      }
      await stickyCase(kind, "sticky.header-fling", count: 1200, groupRun: 4) { run in
        await run.play(Synth.fling(speed: 2880).steps)
      }
      await stickyCase(kind, "sticky.header-fling-fast", count: 3000, groupRun: 4) { run in
        await run.play(Synth.fling(speed: 8000).steps)
      }
    }
  }

  static func stickyCase(
    _ kind: String, _ name: String, count: Int, groupRun: Int, rowCost: Double = 0,
    setup: ((Run) async -> Void)? = nil, body: (Run) async -> CFTimeInterval
  ) async {
    let run = Run(kind: kind, count: count, rowCost: rowCost, groupRun: groupRun, sticky: true)
    await run.wait(0.3)
    if let setup { await setup(run) } else { await run.centre() }
    run.recorder.recordsSticky = true
    await run.begin(screen: false)
    let start = await body(run)
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: name, from: start, lift: start, to: rest)
    let frames = run.recorder.samples.filter { $0.t >= start - 0.02 && $0.t <= rest + 0.05 }
    let bottom = run.lab.usableBottom
    if name.contains("avatar") {
      let e = StickyCheck.avatarError(frames, chat: run.lab.chat, bottom: bottom)
      n.extra["avatarError"] = e.error
      n.extra["avatarChecked"] = Double(e.checked)
      n.extra["avatarMissing"] = Double(e.missing)
      if name.hasSuffix("handoff") {
        // The group's avatar between frames: never missing, never leaping.
        let chat = run.lab.chat
        let groupStart = chat.ids.last.flatMap { chat.group($0)?.start }
        var missing = 0
        var step = 0.0
        var last: CGFloat?
        for frame in frames {
          let shown = frame.avatars.filter { chat.group($0.key)?.start == groupStart }
          guard let avatar = shown.values.max(by: { $0.maxY < $1.maxY }) else { missing += 1; continue }
          if let last { step = max(step, Double(abs(avatar.maxY - last))) }
          last = avatar.maxY
        }
        n.extra["handoffMissing"] = Double(missing)
        n.extra["handoffStep"] = step
      }
      n.notes = String(format: "avatar error worst %.2f pt over %d checks, %d frames missing an avatar; ", e.error, e.checked, e.missing)
        + n.notes
    } else {
      let e = StickyCheck.headerError(frames, chat: run.lab.chat)
      n.extra["headerError"] = e.position
      n.extra["headerVisibility"] = Double(e.wrongVisibility)
      n.extra["headerTitle"] = Double(e.wrongTitle)
      n.notes = String(format: "header position error worst %.2f pt, %d frames shown/hidden wrongly, %d wrong titles (%d frames); ",
                       e.position, e.wrongVisibility, e.wrongTitle, frames.count) + n.notes
    }
    record(n)
    run.close()
    await run.wait(0.2)
  }
}

extension Synth {
  /// A slow drag: a touch, `count` moves of `dy` at 120 Hz, the lift (no momentum).
  static func drag(dy: Double, count: Int) -> [Step] {
    var steps: [Step] = [Step(at: 0, event: trackpad(0, phase: .mayBegin), label: "mayBegin")]
    var t = 1.0 / 120
    for i in 0 ..< count {
      steps.append(Step(at: t, event: trackpad(dy, phase: i == 0 ? .began : .changed), label: "move"))
      t += 1.0 / 120
    }
    steps.append(Step(at: t, event: trackpad(0, phase: .ended), label: "lift"))
    return steps
  }
}
