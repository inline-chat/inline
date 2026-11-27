import AppKit
import TimelineAppKit
import TimelineCore

// Sticky avatars for minimal style (parity ledger row 24): a group's avatar keeps to the top edge, as the old list's
// avatar overlay `.top` mode does. It rests at the top of the group's first bubble; while that is above the top edge
// it is pushed down to stay 8 pt below the usable top, but never below the group's last bubble's bottom (its height
// above it), like a section header. The cases mirror the bottom avatars' (`sticky.avatar-*`).

extension StickyRules {
  /// Where a top-edge avatar of the group starting at `id` should be in `frame` (its top), nil when the group's first
  /// row is not shown.
  @MainActor static func expectedTopAvatarTop(firstRow id: Int, in frame: Frame, chat: LabChat) -> CGFloat? {
    guard let group = chat.group(id), let first = frame.bubbles[id] else { return nil }
    let restTop = first.minY
    let edge = frame.usableTop + LabChat.topPinGap
    let spanBottom = frame.bubbles[group.end]?.maxY ?? .infinity
    let room = max(0, spanBottom - LabChat.avatarSize - restTop)
    return restTop + max(0, min(edge - restTop, room))
  }

  /// The worst top-avatar error over a recording, among avatars in sight, and where it was.
  @MainActor static func topAvatarError(_ recording: Recording, chat: LabChat) -> (error: Double, checked: Int, at: String, pushed: Int) {
    var worst = 0.0
    var checked = 0
    var pushed = 0
    var at = ""
    for frame in recording.frames {
      for (id, avatar) in frame.avatars {
        guard avatar.maxY > frame.usableTop, avatar.minY < frame.usableBottom,
              let expected = expectedTopAvatarTop(firstRow: id, in: frame, chat: chat) else { continue }
        checked += 1
        if let rest = frame.bubbles[id]?.minY, expected - rest > 1 { pushed += 1 }
        let error = Double(abs(avatar.minY - expected))
        if error > worst {
          worst = error
          at = String(format: "t %.3f", frame.t) + " id \(id) shown \(fmt(Double(avatar.minY))) expected \(fmt(Double(expected)))\(frame.flinging ? " flinging" : "")\(frame.sliding ? " sliding" : "")"
        }
      }
    }
    return (worst, checked, at, pushed)
  }
}

extension SuiteCases {
  /// The first row of a long incoming group (6 rows or more) past the middle of the chat.
  @MainActor static func longGroupStart(_ b: Bench) -> Int? {
    let ids = b.chat.ids
    return ids.dropFirst(ids.count / 2).first { id in
      guard let g = b.chat.group(id), g.start == id, b.chat.showsAvatar(id), let s = b.chat.index(g.start),
            let e = b.chat.index(g.end) else { return false }
      return e - s >= 5
    }
  }

  static var topPins: [BehaviourCase] {
    let options = Bench.Options(count: 600, groupRun: 8, topPins: true)
    @MainActor func judge(_ c: Checks, _ name: String, _ r: Recording, _ b: Bench, minimum: Int = 3, limit: Double = 0.5, pushed: Int = 0) {
      let e = StickyRules.topAvatarError(Recording(frames: Array(r.frames.dropFirst())), chat: b.chat)
      c.atLeast("\(name): top avatar frames checked", Double(e.checked), Double(minimum), unit: "")
      // Avatars actually held under the top edge (pushed below their rest), so the rule is tested where it bends.
      if pushed > 0 { c.atLeast("\(name): frames with an avatar held under the top edge", Double(e.pushed), Double(pushed), unit: "") }
      c.atMost("\(name): top avatar error, worst frame", e.error, limit)
      if e.error > limit { c.note("\(name): \(e.at)") }
    }
    return [
      BehaviourCase(id: "sticky.top-rest", area: "Sticky items", behaviour: "Minimal style: an incoming group's avatar rests at its first bubble's top, or 8 pt below the top edge while the group is under it", options: options) { b, c in
        await b.goMiddle()
        await b.untilRest()
        let r = await b.record { await b.frames(3) }
        judge(c, "rest", r, b, minimum: 2)
      },
      BehaviourCase(id: "sticky.top-drag", area: "Sticky items", behaviour: "Minimal style: dragging slowly through long groups, each avatar stays under the top edge while its group is, never below the group's last bubble", options: options) { b, c in
        await b.goMiddle()
        let r = await b.record(settle: false) { await b.gesture(dy: 3, count: 160, lift: false) }
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        judge(c, "drag down", r, b, minimum: 60, pushed: 20)
        let back = await b.record(settle: false) { await b.gesture(dy: -3, count: 160, lift: false) }
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        judge(c, "drag up", back, b, minimum: 60, pushed: 20)
      },
      BehaviourCase(id: "sticky.top-fling", area: "Sticky items", behaviour: "Minimal style: during flings both ways each avatar follows the same rule on every frame (baked with the content)", options: options) { b, c in
        await b.goMiddle()
        for (name, dy) in [("fling older", 24.0), ("fling newer", -24.0)] {
          let r = await b.record { await b.gesture(dy: dy, count: 12) }
          judge(c, name, Recording(frames: r.frames.filter(\.flinging)), b, minimum: 20, pushed: 5)
        }
      },
      BehaviourCase(id: "sticky.top-insert-above", area: "Sticky items", behaviour: "Minimal style: a page landing above, at rest and mid-fling, leaves every avatar where the rule puts it", options: options) { b, c in
        await b.goMiddle()
        await b.untilRest()
        let still = await b.record { b.prependPage(40) }
        judge(c, "page above at rest", still, b)
        await b.gesture(dy: 24, count: 12)
        await b.wait(0.1)
        let flinging = await b.record { b.prependPage(40) }
        judge(c, "page above mid-fling", flinging, b, pushed: 3)
      },
      BehaviourCase(id: "sticky.top-delete", area: "Sticky items", behaviour: "Minimal style: deleting a row of the group stuck under the top edge keeps its avatar on the rule while the rows close", options: options) { b, c in
        // A long incoming group whose first row is 120 pt above the top edge: its avatar is held under it.
        guard let start = longGroupStart(b) else { return c.that("a long group", false) }
        b.list.apply(TimelineTransaction(scroll: .to(start, .top(-120))))
        await b.untilRest()
        guard let at = b.chat.index(start) else { return c.that("the group", false) }
        let victim = b.chat.ids[at + 2]
        let r = await b.record { b.delete(victim) }
        judge(c, "delete in the stuck group", r, b, pushed: 3)
      },
      BehaviourCase(id: "sticky.top-inset", area: "Sticky items", behaviour: "Minimal style: the top inset growing and shrinking moves the stuck avatar with the edge (on the change's timing) and it rests on the rule", options: options) { b, c in
        // A long incoming group whose first row is 120 pt above the top edge: its avatar is held under it.
        guard let start = longGroupStart(b) else { return c.that("a long group", false) }
        b.list.apply(TimelineTransaction(scroll: .to(start, .top(-120))))
        await b.untilRest()
        let top = b.list.topInset
        for inset in [top + 40, top] {
          let r = await b.record { b.list.setInsets(top: inset, timing: .standard) }
          judge(c, "top inset \(Int(inset)), at rest", Recording(frames: Array(r.frames.suffix(2))), b, minimum: 1, pushed: 1)
          // On the way: no jump (the edge moves on a spring).
          let stuck = r.frames.last?.avatars.keys.first { id in r.frames.allSatisfy { $0.avatars[id] != nil } }
          if let stuck {
            let tops = r.frames.compactMap { $0.avatars[stuck].map { Double($0.minY) } }
            let step = zip(tops, tops.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            c.atMost("top inset \(Int(inset)): largest avatar step", step, 12)
          }
        }
      },
      BehaviourCase(id: "sticky.top-far-slide", area: "Sticky items", behaviour: "Minimal style: a far jump's slide carries the avatars with their rows and they land on the rule", options: options) { b, c in
        await b.goMiddle()
        await b.untilRest()
        let ids = b.chat.ids
        let r = await b.record { b.list.apply(TimelineTransaction(scroll: .to(ids[ids.count / 2 + 120], .top(150)), timing: .standard)) }
        judge(c, "far jump, landed", Recording(frames: Array(r.frames.suffix(3))), b, minimum: 1)
        judge(c, "far jump, sliding", Recording(frames: r.frames.filter(\.sliding)), b, minimum: 1, limit: 1)
      },
      BehaviourCase(id: "sticky.top-bounce-oldest", area: "Sticky items", behaviour: "Minimal style: a fling into the oldest end and its bounce keep the avatars on the rule", options: options) { b, c in
        await b.goOldest()
        b.list.apply(TimelineTransaction(scroll: .by(-600)))
        await b.untilRest()
        let r = await b.record { await b.gesture(dy: 40, count: 10) }
        judge(c, "bounce at the oldest end", Recording(frames: r.frames.filter(\.flinging)), b, minimum: 10, pushed: 3)
      },
    ]
  }
}
