import Auth
@testable import InlineIOS
@testable import InlineKit
import InlineIOSUI
import InlineUI
import InlineMessageLayout
import struct InlineProtocol.Client_MessageContentPayload
import struct InlineProtocol.Client_MessageVoiceContent
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionCallback
import struct InlineProtocol.MessageActionRow
import struct InlineProtocol.MessageActions
import struct InlineProtocol.MessageReplies
import SwiftUI
import Testing
import UIKit

/// On-device lab for the next message view: hundreds of real renders, the shared animation
/// clock, the chat list bridge and cell reuse. Snapshots are attached for visual review.
@Suite("Next message view on device", .serialized)
@MainActor
struct NextMessageViewDeviceTests {
  static let strings = [
    "ok",
    "Sounds good, see you tomorrow",
    "On my way, but the train is running a little late. I'll message again when I'm close.",
    "First paragraph.\n\nSecond paragraph after a blank line.\nAnd a third line.",
    "سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود.",
    "שלום, זו הודעה בעברית עם כמה מילים.",
    "Mixed English then فارسی then English again in one line",
    "Emoji in text 😀🎉👍 should wrap like letters 🙌🏽",
    "https://inline.chat/very/long/path/that/has/no/spaces/to/break/at/all/and/keeps/going",
    "这是一条中文消息，用来测试换行和宽度。",
    "e\u{301}e\u{301} combining, Z\u{0351}\u{0352}a\u{0300}l\u{0301}g\u{0302}o, ÅÉÎ ÿ ĝ ĵ",
    "1\n2\n3\n4\n5\n6",
    "😀",
    "🎉👍🔥",
  ]
  static let categories: [UIContentSizeCategory] = [.large, .extraExtraExtraLarge, .accessibilityLarge]

  // MARK: - Lab

  @Test("Hundreds of real renders put every node where the plan says and clip no ink")
  func renderLab() throws {
    let stage = try Stage()
    defer { stage.close() }
    var failures: [String] = []
    var checked = 0
    for (stringIndex, string) in Self.strings.enumerated() {
      for outgoing in [false, true] {
        for reactionCount in [0, 2] {
          for category in Self.categories {
            for width: CGFloat in [320, stage.window.bounds.width] {
              let label = "s\(stringIndex) out=\(outgoing) r=\(reactionCount) \(category.rawValue) w=\(Int(width))"
              let message = Self.message(Int64(1_000 + checked), string, outgoing: outgoing, reactions: reactionCount)
              let (view, layout) = stage.render(message, width: width, category: category)
              failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
              failures += Self.inkProblems(view.textView, expectsInk: true).map { "\(label) text: \($0)" }
              failures += Self.inkProblems(view.timeView.subviews.compactMap { $0 as? MessageTextView }.first, expectsInk: true)
                .map { "\(label) time: \($0)" }
              if let first = layout.text?.lines.first, first.width > 2 {
                let point = view.textView.viewRect(forTextRect: CGRect(
                  x: first.frame.minX + 1, y: first.frame.midY, width: 1, height: 1
                )).origin
                if view.textView.characterIndex(at: point) == nil {
                  failures.append("\(label): first glyph not hit-testable")
                }
              }
              view.removeFromSuperview()
              checked += 1
            }
          }
        }
      }
    }
    Attachment.record("Rendered \(checked) messages.", named: "render-lab.txt")
    #expect(checked >= 300)
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(40).joined(separator: "\n"))")
  }

  @Test("Adding a reaction moves every node on one clock, and the next update retargets smoothly")
  func oneClock() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let plain = Self.message(2_000, "Sounds good, see you tomorrow", outgoing: false, reactions: 0)
    var reacted = plain
    reacted.reactions = Self.reactions(1, on: plain)
    let view = MessageView()
    stage.root.addSubview(view)
    let before = stage.apply(plain, to: view, width: stage.window.bounds.width, motion: .immediate)
    view.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(50))

    let after = stage.apply(reacted, to: view, width: stage.window.bounds.width, motion: .standard)
    #expect(after.timePlacement == .reactionsRow)
    try await Task.sleep(for: .milliseconds(90))

    let bubble = try #require(view.bubbleContentView.layer.presentation()).frame
    let timeLocal = try #require(view.timeView.layer.presentation()).frame
    let time = timeLocal.offsetBy(dx: bubble.minX, dy: bubble.minY)
    let samples = [
      progress(bubble.width, from: before.bubble.frame.width, to: after.bubble.frame.width),
      progress(bubble.height, from: before.bubble.frame.height, to: after.bubble.frame.height),
      progress(time.minY, from: try #require(before.frame(.time)).minY, to: try #require(after.frame(.time)).minY),
    ].compactMap(\.self)
    Attachment.record("progress samples: \(samples)", named: "one-clock.txt")
    #expect(samples.count == 3)
    #expect(samples.allSatisfy { $0 > 0.05 && $0 < 0.98 }, "nodes should be mid-flight: \(samples)")
    if let low = samples.min(), let high = samples.max() {
      #expect(high - low < 0.12, "nodes on different clocks: \(samples)")
    }
    let reaction = try #require(view.reactionViews.values.first?.layer.presentation())
    #expect(reaction.opacity > 0.02 && reaction.opacity < 0.98)

    // Retarget mid-flight: the bubble continues from where it is instead of jumping.
    let beforeRetarget = try #require(view.bubbleContentView.layer.presentation()).frame
    _ = stage.apply(plain, to: view, width: stage.window.bounds.width, motion: .standard)
    try await Task.sleep(for: .milliseconds(17))
    let afterRetarget = try #require(view.bubbleContentView.layer.presentation()).frame
    #expect(abs(afterRetarget.height - beforeRetarget.height) < 6, "bubble jumped on retarget")
    #expect(abs(afterRetarget.width - beforeRetarget.width) < 6, "bubble jumped on retarget")

    try await Task.sleep(for: .milliseconds(700))
    #expect(view.bubbleContentView.frame == before.bubble.frame)
    #expect(view.reactionViews.isEmpty)
  }

  @Test("List rows take their planned height and grow with their bubbles on one curve")
  func listRows() async throws {
    let fixture = try await ListFixture(count: 30)
    defer { fixture.close() }
    try await fixture.settle()
    var failures: [String] = []
    let cells = fixture.visibleCells
    #expect(cells.count >= 4)
    for cell in cells {
      guard cell.showsNextMessageView, let view = cell.nextMessageView, let layout = view.layout else {
        failures.append("\(cell.message?.id ?? 0): not drawn by the next view")
        continue
      }
      if abs(cell.bounds.height - layout.size.height) > 0.5 {
        failures.append("\(cell.message?.id ?? 0): row \(cell.bounds.height) vs plan \(layout.size.height)")
      }
      let bubble = view.bubbleView.convert(view.bubbleView.bounds, to: fixture.window)
      let row = cell.convert(cell.bounds, to: fixture.window)
      if !row.insetBy(dx: -0.5, dy: -0.5).contains(bubble) {
        failures.append("\(cell.message?.id ?? 0): bubble \(bubble) outside row \(row)")
      }
      if let geometry = cell.sendAnimationTargetGeometryInWindow() {
        if !geometry.bubbleFrame.insetBy(dx: -1, dy: -1).contains(geometry.textFrame) {
          failures.append("\(cell.message?.id ?? 0): send target text outside bubble")
        }
      } else {
        failures.append("\(cell.message?.id ?? 0): no send target")
      }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")

    // Add the first reaction to a message: the row and its bubble must move together.
    let cell = try #require(cells.filter { $0.message?.reactions.isEmpty == true && $0.showsNextMessageView }
      .max { ($0.message?.message.messageId ?? 0) < ($1.message?.message.messageId ?? 0) })
    var message = try #require(cell.message)
    let oldRow = cell.bounds.height
    let oldBubble = try #require(cell.nextMessageView?.bubbleView.frame.height)
    message.reactions = Self.reactions(1, on: message)
    fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
    try await Task.sleep(for: .milliseconds(110))
    let presentedRow = try #require(cell.layer.presentation()).bounds.height
    let presentedBubble = try #require(cell.nextMessageView?.bubbleView.layer.presentation()).bounds.height
    try await fixture.settle(milliseconds: 700)
    let newRow = cell.bounds.height
    let newBubble = try #require(cell.nextMessageView?.bubbleView.frame.height)
    let rowProgress = progress(presentedRow, from: oldRow, to: newRow)
    let bubbleProgress = progress(presentedBubble, from: oldBubble, to: newBubble)
    Attachment.record(
      "row \(oldRow)→\(newRow) presented \(presentedRow) p=\(rowProgress.map { String($0) } ?? "-"); bubble \(oldBubble)→\(newBubble) presented \(presentedBubble) p=\(bubbleProgress.map { String($0) } ?? "-")",
      named: "list-row-growth.txt"
    )
    #expect(cell.nextMessageView?.reactionViews.count == 1, "the reaction pill did not appear")
    if let view = cell.nextMessageView, let layout = view.layout {
      let problems = Self.placementProblems(view, layout)
      #expect(problems.isEmpty, "after the animated reaction: \(problems.joined(separator: "\n"))")
    }
    #expect(newRow > oldRow)
    #expect(abs(newRow - (cell.nextMessageView?.layout?.size.height ?? 0)) <= 0.5)
    if let rowProgress, let bubbleProgress {
      #expect(rowProgress > 0.02 && rowProgress < 0.98, "row did not animate: \(rowProgress)")
      #expect(abs(rowProgress - bubbleProgress) < 0.15, "row \(rowProgress) vs bubble \(bubbleProgress)")
    }
    let bubbleBottom = try #require(cell.nextMessageView).bubbleView.convert(
      try #require(cell.nextMessageView).bubbleView.bounds, to: fixture.window
    )
    let rowFrame = cell.convert(cell.bounds, to: fixture.window)
    #expect(abs(bubbleBottom.maxY - rowFrame.maxY) <= 1, "bubble not on the row's bottom edge")
  }

  @Test("Edits, streaming and status changes move smoothly, frame by frame")
  func noJumps() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let width = stage.window.bounds.width
    let view = MessageView()
    stage.root.addSubview(view)
    var message = Self.message(4_000, "On my way", outgoing: true, reactions: 0)
    stage.apply(message, to: view, width: width, motion: .immediate)
    view.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(50))

    var report: [String] = []
    var failures: [String] = []
    func run(_ name: String, motion: MessageMotion, _ change: (inout FullMessage) -> Void) async throws {
      let start = view.bubbleContentView.frame
      change(&message)
      let layout = stage.apply(message, to: view, width: width, motion: motion)
      let end = layout.bubble.frame
      var samples: [CGRect] = []
      for _ in 0 ..< 30 {
        try await Task.sleep(for: .milliseconds(16))
        if let frame = view.bubbleContentView.layer.presentation()?.frame { samples.append(frame) }
      }
      let total = max(abs(end.height - start.height), abs(end.width - start.width))
      guard total > 2 else {
        report.append("\(name): no geometry change")
        return
      }
      var previous = start
      var largestStep: CGFloat = 0
      for frame in samples {
        largestStep = max(largestStep, abs(frame.height - previous.height), abs(frame.width - previous.width))
        previous = frame
      }
      let settled = samples.last.map { close($0, end, tolerance: 0.5) } ?? false
      report.append("\(name): change \(total)pt, largest frame step \(largestStep)pt, settled \(settled)")
      if largestStep > total * 0.5 { failures.append("\(name) jumped \(largestStep) of \(total)pt in one frame") }
      if !settled { failures.append("\(name) did not settle on its plan") }
    }

    try await run("edit to three lines", motion: .standard) {
      $0.message.text = "On my way, but the train is running a little late. I'll message again when I'm close."
    }
    try await run("first reaction", motion: .standard) { $0.reactions = Self.reactions(1, on: $0) }
    try await run("wrap reactions", motion: .standard) { $0.reactions = Self.reactions(6, on: $0) }
    try await run("drop reactions", motion: .standard) { $0.reactions = [] }
    try await run("edit back to one line", motion: .standard) { $0.message.text = "On my way" }
    try await run("failed status", motion: .standard) { $0.message.status = .failed }

    // Streaming: words arrive faster than the line animation; the bubble only ever grows.
    message.message.text = "Streaming"
    stage.apply(message, to: view, width: width, motion: .immediate)
    let words = "Here is a streamed answer that arrives a few words at a time and keeps growing line by line".split(separator: " ")
    var heights: [CGFloat] = []
    for count in 1 ... words.count {
      message.message.text = words.prefix(count).joined(separator: " ")
      let layout = stage.apply(message, to: view, width: width, motion: .streamingLine)
      if view.timeView.alpha > 0.01, layout.hiddenNodes.isEmpty == false { failures.append("time visible while streaming") }
      try await Task.sleep(for: .milliseconds(40))
      if let height = view.bubbleContentView.layer.presentation()?.frame.height { heights.append(height) }
    }
    let shrinks = zip(heights, heights.dropFirst()).filter { $1 < $0 - 0.5 }.count
    report.append("stream: \(heights.count) samples, \(shrinks) shrinking steps, final \(heights.last ?? 0)")
    if shrinks > 0 { failures.append("bubble shrank \(shrinks) times while streaming") }

    Attachment.record(report.joined(separator: "\n"), named: "no-jumps.txt")
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test("A newer message takes the tail, Dynamic Type re-plans rows, and bubbles never overlap")
  func listTransitions() async throws {
    let fixture = try await ListFixture(count: 12)
    defer { fixture.close() }
    try await fixture.settle()
    var failures: [String] = []
    func checkRows(_ stage: String) {
      let cells = fixture.visibleCells.filter(\.showsNextMessageView)
      let bubbles = cells.compactMap { cell -> (Int64, CGRect)? in
        guard let view = cell.nextMessageView, let message = cell.message else { return nil }
        if abs(cell.bounds.height - (view.layout?.size.height ?? -1)) > 0.5 {
          failures.append("\(stage): \(message.id) height \(cell.bounds.height) vs plan \(view.layout?.size.height ?? -1)")
        }
        return (message.id, view.bubbleView.convert(view.bubbleView.bounds, to: fixture.window))
      }
      for (index, a) in bubbles.enumerated() {
        for b in bubbles[(index + 1)...] where a.1.insetBy(dx: 0, dy: 0.5).intersects(b.1) {
          failures.append("\(stage): bubbles \(a.0) and \(b.0) overlap")
        }
      }
    }
    checkRows("initial")

    // A newer outgoing message after an outgoing one takes its tail.
    var previous = try #require(fixture.model.messages.first)
    previous.message.out = true
    previous.message.status = .sent
    fixture.publisher.publisher.send(.update(.init(message: previous, animated: false, peer: fixture.peer)))
    try await fixture.settle()
    var next = previous
    next.message.messageId += 100
    next.message.globalId = (previous.message.globalId ?? 0) + 100
    next.message.date = previous.message.date.addingTimeInterval(5)
    next.message.text = "A newer message in the same group"
    next.reactions = []
    fixture.publisher.publisher.send(.add(.init(messages: [next], peer: fixture.peer)))
    try await fixture.settle(milliseconds: 700)
    let previousCell = fixture.visibleCells.first { $0.message?.id == previous.id }
    let newCell = fixture.visibleCells.first { $0.message?.id == next.id }
    #expect(newCell?.showsNextMessageView == true, "new message not drawn by the next view")
    #expect(previousCell?.nextMessageView?.layout?.bubble.tail == BubbleTailSide.none, "previous bubble kept its tail")
    #expect(newCell?.nextMessageView?.layout?.bubble.tail == .trailing, "new bubble has no tail")
    checkRows("after arrival")

    // Larger text: every visible row re-plans to its new height.
    fixture.list.window?.rootViewController?.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
    try await fixture.settle(milliseconds: 600)
    checkRows("accessibility text")
    let sizes = fixture.visibleCells.compactMap { $0.nextMessageView?.content?.context.contentSizeCategory }
    if sizes.contains(where: { $0 != .accessibilityLarge }) {
      failures.append("rows kept the old text size: \(Set(sizes.map(\.rawValue)))")
    }
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("The context menu lifts the bubble in place, holds updates, and the reaction animates in after")
  func contextMenuReaction() async throws {
    let fixture = try await ListFixture(count: 12)
    defer { fixture.close() }
    try await fixture.settle()
    let list = fixture.list
    let cell = try #require(fixture.visibleCells.filter { $0.message?.reactions.isEmpty == true && $0.showsNextMessageView }
      .min { ($0.nextMessageView?.layout?.bubble.frame.width ?? 0) < ($1.nextMessageView?.layout?.bubble.frame.width ?? 0) })
    let indexPath = try #require(list.indexPath(for: cell))
    let view = try #require(cell.nextMessageView)
    let container = view.bubbleContentView
    let bubbleInWindow = container.convert(container.bounds, to: fixture.window)
    let point = container.convert(CGPoint(x: container.bounds.midX, y: container.bounds.midY), to: list)
    let configuration = try #require(list.delegate?.collectionView?(list, contextMenuConfigurationForItemsAt: [indexPath], point: point))
    let highlight = try #require(list.delegate?.collectionView?(list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath))
    #expect(highlight.view === container, "the lift should use the bubble-sized container")
    #expect(abs(highlight.view.bounds.width - bubbleInWindow.width) < 0.5)
    let liftCenter = highlight.target.container.convert(highlight.target.center, to: fixture.window)
    #expect(abs(liftCenter.x - bubbleInWindow.midX) < 0.5 && abs(liftCenter.y - bubbleInWindow.midY) < 0.5, "lift is off the bubble")

    // A reaction lands while the menu is up: the bubble must not move under UIKit's preview.
    list.delegate?.collectionView?(list, willDisplayContextMenu: configuration, animator: nil)
    var message = try #require(cell.message)
    let before = container.frame
    message.reactions = Self.reactions(1, on: message)
    fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
    try await fixture.settle(milliseconds: 200)
    #expect(container.frame == before, "bubble changed under the context menu")
    #expect(cell.nextMessageView?.reactionViews.isEmpty == true)

    let dismissal = try #require(list.delegate?.collectionView?(list, contextMenuConfiguration: configuration, dismissalPreviewForItemAt: indexPath))
    #expect(dismissal.view === container)
    let animator = MenuAnimator()
    list.delegate?.collectionView?(list, willEndContextMenuInteraction: configuration, animator: animator)
    animator.animate()
    animator.complete()
    try await fixture.settle(milliseconds: 700)
    let after = try #require(cell.nextMessageView?.layout)
    #expect(cell.nextMessageView?.reactionViews.count == 1, "reaction never arrived after the menu")
    #expect(container.frame == after.bubble.frame, "bubble not where its plan says after the menu")
    #expect(!container.isHidden)
    #expect(abs(cell.bounds.height - after.size.height) <= 0.5)
    #expect(container.transform == .identity && container.superview === view)
    let problems = Self.placementProblems(view, after)
    #expect(problems.isEmpty, "after the menu: \(problems.joined(separator: "\n"))")
  }

  @Test("A tap anywhere on your own reaction reaches the pill, in the list, after it animates in")
  func ownReactionHitTest() async throws {
    let fixture = try await ListFixture(count: 8)
    defer { fixture.close() }
    try await fixture.settle()
    let cell = try #require(fixture.visibleCells.first { $0.showsNextMessageView && $0.message?.message.out == true })
    var message = try #require(cell.message)
    let me = Auth.shared.getCurrentUserId() ?? 0
    message.reactions = ["💯", "🫡"].enumerated().map { index, emoji in
      FullReaction(
        reaction: Reaction(messageId: message.message.messageId, userId: me, emoji: emoji, date: message.message.date, chatId: message.message.chatId),
        userInfo: index == 0 ? nil : UserInfo(user: Self.reactor)
      )
    }
    fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
    try await fixture.settle(milliseconds: 700)
    let view = try #require(cell.nextMessageView)
    let layout = try #require(view.layout)
    #expect(view.reactionViews.count == 2)
    for (emoji, pill) in view.reactionViews {
      #expect(pill.model?.byCurrentUser == true)
      #expect(pill.allTargets.isEmpty == false)
      for target in Self.tapTargets(in: pill) {
        let point = pill.convert(target.point, to: fixture.window)
        let hit = fixture.window.hitTest(point, with: nil)
        #expect(hit === pill, "\(emoji) \(target.name): tap lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
      }
    }
    let problems = Self.placementProblems(view, layout)
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
  }

  @Test("Hundreds of reaction toggles, many mid-flight, always settle where the plan says and stay tappable")
  func reactionChurn() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let width = stage.window.bounds.width
    let me = Auth.shared.getCurrentUserId() ?? 0
    let texts = [
      "نن", "من", "ok", "Sounds good, see you tomorrow",
      "On my way, but the train is running a little late. I'll message again when I'm close.",
      "سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود.", "😀",
    ]
    let emojis = ["👍", "💯", "🫡", "❤️", "😂", "🎉", "🔥", "👀"]
    var random = SeededRandom(seed: 0x5EED)
    var failures: [String] = []
    var steps = 0
    for (textIndex, text) in texts.enumerated() {
      for outgoing in [true, false] {
        let view = MessageView()
        stage.root.addSubview(view)
        defer { view.removeFromSuperview() }
        var message = Self.message(Int64(5_000 + textIndex * 2 + (outgoing ? 1 : 0)), text, outgoing: outgoing, reactions: 0)
        stage.apply(message, to: view, width: width, motion: .immediate)
        for _ in 0 ..< 24 {
          let emoji = emojis[random.next(below: emojis.count)]
          let user = random.next(below: 2) == 0 ? me : Self.reactor.id
          if let index = message.reactions.firstIndex(where: { $0.reaction.emoji == emoji && $0.reaction.userId == user }) {
            message.reactions.remove(at: index)
          } else {
            message.reactions.append(FullReaction(
              reaction: Reaction(messageId: message.message.messageId, userId: user, emoji: emoji, date: message.message.date, chatId: message.message.chatId),
              userInfo: UserInfo(user: user == me ? Self.sender : Self.reactor)
            ))
          }
          let layout = stage.apply(message, to: view, width: width, motion: .standard)
          steps += 1
          let label = "\(outgoing ? "out" : "in") \(text.prefix(10)) step \(steps)"
          failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
          let wait = [0, 16, 60, 140, 420][random.next(below: 5)]
          if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
        }
        try await Task.sleep(for: .milliseconds(600))
        let pills = view.bubbleContentView.subviews.filter { $0 is MessageReactionPillView }
        if pills.count != view.layout?.reactionOrder.count {
          failures.append("\(text.prefix(10)): \(pills.count) pill views left for \(view.layout?.reactionOrder.count ?? 0) reactions")
        }
        if pills.contains(where: { $0.alpha < 1 || $0.transform != .identity }) {
          failures.append("\(text.prefix(10)): a pill settled faded or scaled")
        }
      }
    }
    Attachment.record("\(steps) reaction toggles", named: "reaction-churn.txt")
    #expect(steps >= 300)
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Voice messages keep their first width; nothing resizes after the first frame")
  func voiceWidth() async throws {
    // Voice rows draw with the next view now; this guards the current view's fix.
    let fixture = try await ListFixture(count: 12, implementation: .legacy) { index, message in
      guard index.isMultiple(of: 2) else { return }
      var voice = Client_MessageVoiceContent()
      voice.duration = Int32(3 + index)
      voice.waveform = Data((0 ..< 48).map { UInt8(($0 * 37 + index * 11) % 255) })
      var payload = Client_MessageContentPayload()
      payload.voice = voice
      message.message.contentPayload = payload
      message.message.text = index.isMultiple(of: 4) ? nil : "Voice note with a caption"
    }
    defer { fixture.close() }
    // The first frame the list ever shows, before SwiftUI's hosted content reports its size.
    fixture.list.layoutIfNeeded()
    CATransaction.flush()
    func widths() -> [Int64: CGFloat] {
      var result: [Int64: CGFloat] = [:]
      for cell in fixture.visibleCells where cell.message?.message.hasVoice == true {
        guard let id = cell.message?.id, let view = cell.messageView else { continue }
        result[id] = view.bubbleView.bounds.width
      }
      return result
    }
    let first = widths()
    try await fixture.settle(milliseconds: 800)
    var failures: [String] = []
    // Playback and download state make the hosted SwiftUI view report a new size; the row must
    // re-solve to the same width, so its width must not hinge on a priority tie.
    for cell in fixture.visibleCells where cell.message?.message.hasVoice == true {
      guard let hosted = cell.messageView?.voiceMessageViewController.view else { continue }
      hosted.invalidateIntrinsicContentSize()
      cell.setNeedsLayout()
      cell.layoutIfNeeded()
      if hosted.hasAmbiguousLayout {
        failures.append("voice \(cell.message?.id ?? 0): ambiguous width (intrinsic \(hosted.intrinsicContentSize))")
      }
    }
    try await fixture.settle(milliseconds: 300)
    let settled = widths()
    #expect(first.count >= 2, "no voice rows were drawn")
    for (id, width) in first {
      guard let after = settled[id] else { continue }
      if abs(after - width) > 0.5 { failures.append("voice \(id): \(width) → \(after)") }
      if after < 200 { failures.append("voice \(id) settled at \(after), narrower than its 240 pt surface") }
    }
    Attachment.record("first \(first)\nsettled \(settled)", named: "voice-width.txt")
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test("The native avatar draws like the SwiftUI avatar it replaces")
  func avatarParity() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let users = [
      Self.sender,
      Self.reactor,
      User(id: 8_103, email: nil, firstName: "دنا", lastName: "سهرابی"),
      User(id: 8_104, email: nil, firstName: nil),
      User(id: 8_105, email: "kim@example.com", firstName: nil, username: "kim"),
    ]
    var failures: [String] = []
    var tiles: [(UIImage, UIImage)] = []
    for size in [26.0, 40.0] as [CGFloat] {
      for user in users {
        let info = UserInfo(user: user)
        let frame = CGRect(x: 20, y: 120, width: size, height: size)
        let native = UserAvatarLayerView(frame: frame)
        native.configure(with: info, size: size)
        let hosted = UIHostingController(rootView: UserAvatar(userInfo: info, size: size))
        hosted.safeAreaRegions = []
        hosted.view.backgroundColor = .clear
        hosted.view.frame = frame.offsetBy(dx: 80, dy: 0)
        stage.root.addSubview(native)
        stage.root.addSubview(hosted.view)
        stage.root.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        func image(_ view: UIView) -> UIImage {
          let format = UIGraphicsImageRendererFormat()
          format.scale = stage.window.screen.scale
          return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
          }
        }
        let a = image(native)
        let b = image(hosted.view)
        tiles.append((a, b))
        let difference = Self.meanDifference(a, b)
        if difference > 0.03 {
          failures.append("\(user.firstName ?? user.username ?? "no name") at \(Int(size)) pt differs by \(String(format: "%.3f", difference))")
        }
        native.removeFromSuperview()
        hosted.view.removeFromSuperview()
      }
    }
    let side: CGFloat = 40
    let sheet = UIGraphicsImageRenderer(size: CGSize(width: side * 2 + 24, height: CGFloat(tiles.count) * (side + 8) + 8)).image { _ in
      for (index, tile) in tiles.enumerated() {
        let y = 8 + CGFloat(index) * (side + 8)
        tile.0.draw(in: CGRect(x: 8, y: y, width: tile.0.size.width, height: tile.0.size.height))
        tile.1.draw(in: CGRect(x: 16 + side, y: y, width: tile.1.size.width, height: tile.1.size.height))
      }
    }
    Attachment.record(Array(try #require(sheet.pngData())), named: "avatar-parity.png")
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }

  @Test("Every message kind draws in the next view where the plan says")
  func kindsLab() async throws {
    let stage = try Stage()
    defer { stage.close() }
    var failures: [String] = []
    var checked = 0
    for outgoing in [false, true] {
      for (name, message) in Self.kinds(outgoing: outgoing) {
        if !MessageViewContent.supports(message, displayMode: .normal) {
          failures.append("\(name): not supported by the next view")
          continue
        }
        for width in [320, 375] as [CGFloat] {
          for category in [UIContentSizeCategory.large, .accessibilityLarge] {
            let (view, layout) = stage.render(message, width: width, category: category)
            failures += Self.placementProblems(view, layout).map { "\(name) \(outgoing ? "out" : "in") \(Int(width)) \(category.rawValue): \($0)" }
            view.removeFromSuperview()
            checked += 1
          }
        }
      }
    }
    Attachment.record("checked \(checked) renders", named: "kinds-lab.txt")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Link previews measure their full height at every width, text size and side")
  func previewProbe() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let link = try #require(Self.kinds(outgoing: false).first { $0.0 == "link preview" }?.1)
    let attachment = try #require(link.attachments.first)
    let preview = try #require(attachment.urlPreview)
    let view = URLPreviewView()
    view.configure(with: preview, photoInfo: nil, parentViewController: nil, outgoing: false,
                   mode: URLPreviewView.preferredMode(for: preview, photoInfo: nil))
    let fitted = view.systemLayoutSizeFitting(
      CGSize(width: 300, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    )
    stage.root.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 300), view.topAnchor.constraint(equalTo: stage.root.topAnchor, constant: 100), view.leadingAnchor.constraint(equalTo: stage.root.leadingAnchor)])
    stage.root.layoutIfNeeded()
    func dump(_ v: UIView, _ depth: Int) -> String {
      var line = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)"
      if let label = v as? UILabel { line += " text=\(label.text ?? "nil")" }
      return ([line] + v.subviews.map { dump($0, depth + 1) }).joined(separator: "\n")
    }
    var sequence: [String] = []
    for width in [249.0, 299.0, 249.0, 299.0] as [CGFloat] {
      for category in [UIContentSizeCategory.large, .accessibilityLarge] {
        for outgoing in [false, true] {
          let traits = stage.root.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = category }
          let height = MessageBlockMeasure.height(of: .preview, attachment: attachment, width: width, outgoing: outgoing, traits: traits)
          sequence.append("w=\(Int(width)) \(category.rawValue.suffix(6)) out=\(outgoing): \(height)")
        }
      }
    }
    Attachment.record("mode \(URLPreviewView.preferredMode(for: preview, photoInfo: nil)) fitted \(fitted)\n\(sequence.joined(separator: "\n"))\n\(dump(view, 0))", named: "preview-probe.txt")
    let heights = sequence.compactMap { $0.split(separator: ":").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    #expect(heights.count == sequence.count && heights.allSatisfy { $0 >= 30 }, "collapsed preview: \(sequence)")
    view.removeFromSuperview()
  }

  @Test("Catalog of message kinds for review", arguments: [UIUserInterfaceStyle.light, .dark])
  func kindsCatalog(style: UIUserInterfaceStyle) async throws {
    let stage = try Stage(style: style)
    defer { stage.close() }
    let width = stage.window.bounds.width
    stage.root.backgroundColor = style == .dark ? .black : .white
    // Each row is drawn on screen, where snapshots include hosted SwiftUI, then stacked.
    var rows: [UIImage] = []
    for (index, entry) in (Self.kinds(outgoing: false) + Self.kinds(outgoing: true)).enumerated() {
      let view = MessageView()
      stage.root.addSubview(view)
      var message = entry.1
      message.message.messageId += Int64(index) * 1_000
      let layout = stage.apply(message, to: view, width: width, motion: .immediate)
      view.frame = CGRect(x: 0, y: 40, width: width, height: layout.size.height)
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(120))
      rows.append(UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
      })
      view.removeFromSuperview()
    }
    let height = rows.reduce(0) { $0 + $1.size.height } + 16
    let sheet = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
      (style == .dark ? UIColor.black : UIColor.white).setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      var y: CGFloat = 8
      for row in rows {
        row.draw(at: CGPoint(x: 0, y: y))
        y += row.size.height
      }
    }
    Attachment.record(Array(try #require(sheet.pngData())), named: "kinds-\(style == .dark ? "dark" : "light").png")
  }

  @Test("A file with a caption animates its reaction in the list like a text row")
  func fileReactionInList() async throws {
    let kinds = Self.kinds(outgoing: false)
    let fixture = try await ListFixture(count: 10) { index, message in
      // Every row is another kind, newest first.
      let kind = kinds[index % kinds.count].1
      let identity = message.message
      message = kind
      message.message.messageId = identity.messageId
      message.message.globalId = identity.globalId
      message.message.chatId = identity.chatId
      message.message.peerUserId = identity.peerUserId
      message.message.date = identity.date
      message.message.out = index.isMultiple(of: 2)
      message.message.status = index.isMultiple(of: 2) ? .sent : nil
    }
    defer { fixture.close() }
    try await fixture.settle()
    var failures: [String] = []
    for cell in fixture.visibleCells {
      guard cell.showsNextMessageView, let view = cell.nextMessageView, let layout = view.layout else {
        failures.append("\(cell.message?.id ?? 0): drawn by the old view")
        continue
      }
      if abs(cell.bounds.height - layout.size.height) > 0.5 {
        failures.append("\(cell.message?.id ?? 0): row \(cell.bounds.height) vs plan \(layout.size.height)")
      }
      failures += Self.placementProblems(view, layout).map { "\(cell.message?.id ?? 0): \($0)" }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")

    let cell = try #require(fixture.visibleCells.first {
      $0.message?.documentInfo != nil && $0.message?.message.text?.isEmpty == false && $0.showsNextMessageView
    })
    var message = try #require(cell.message)
    let oldRow = cell.bounds.height
    let oldBubble = try #require(cell.nextMessageView?.bubbleContentView.frame.height)
    message.reactions = Self.reactions(1, on: message)
    fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
    try await Task.sleep(for: .milliseconds(110))
    let presentedRow = try #require(cell.layer.presentation()).bounds.height
    let presentedBubble = try #require(cell.nextMessageView?.bubbleContentView.layer.presentation()).bounds.height
    try await fixture.settle(milliseconds: 700)
    let newRow = cell.bounds.height
    let newBubble = try #require(cell.nextMessageView?.bubbleContentView.frame.height)
    let rowProgress = progress(presentedRow, from: oldRow, to: newRow)
    let bubbleProgress = progress(presentedBubble, from: oldBubble, to: newBubble)
    Attachment.record(
      "row \(oldRow)→\(newRow) p=\(rowProgress.map { String($0) } ?? "-"); bubble \(oldBubble)→\(newBubble) p=\(bubbleProgress.map { String($0) } ?? "-")",
      named: "file-reaction.txt"
    )
    #expect(cell.nextMessageView?.reactionViews.count == 1)
    #expect(newRow > oldRow)
    if let rowProgress, let bubbleProgress {
      #expect(rowProgress > 0.02 && rowProgress < 0.98, "row did not animate: \(rowProgress)")
      #expect(abs(rowProgress - bubbleProgress) < 0.15, "row \(rowProgress) vs bubble \(bubbleProgress)")
    } else {
      Issue.record("no measurable growth")
    }
    if let view = cell.nextMessageView, let layout = view.layout {
      let problems = Self.placementProblems(view, layout)
      #expect(problems.isEmpty, "after the reaction: \(problems.joined(separator: "\n"))")
    }
  }

  @Test("Scrolling through hundreds of rows never shows another message's content")
  func reuse() async throws {
    let fixture = try await ListFixture(count: 200)
    defer { fixture.close() }
    try await fixture.settle()
    var failures: [String] = []
    var checkedCells = 0
    let list = fixture.list
    let maxOffset = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
    var offset = -list.adjustedContentInset.top
    while offset < maxOffset {
      list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      list.layoutIfNeeded()
      for cell in fixture.visibleCells where cell.showsNextMessageView {
        checkedCells += 1
        guard let message = cell.message, let view = cell.nextMessageView else { continue }
        if view.content?.message.id != message.id {
          failures.append("cell \(message.id) shows \(view.content?.message.id ?? 0)")
        }
        if view.textView.layout.text.string != message.displayText {
          failures.append("cell \(message.id) draws stale text")
        }
        if view.reactionViews.count != message.groupedReactions.count {
          failures.append("cell \(message.id) has \(view.reactionViews.count) pills for \(message.groupedReactions.count)")
        }
        if abs(cell.bounds.height - (view.layout?.size.height ?? -1)) > 0.5 {
          failures.append("cell \(message.id) height \(cell.bounds.height) vs plan \(view.layout?.size.height ?? -1)")
        }
      }
      offset += list.bounds.height * 0.7
    }
    Attachment.record("checked \(checkedCells) visible cells while scrolling", named: "reuse.txt")
    #expect(checkedCells > 100)
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Catalog snapshots for review", arguments: [UIUserInterfaceStyle.light, .dark])
  func catalog(style: UIUserInterfaceStyle) async throws {
    let stage = try Stage(style: style)
    defer { stage.close() }
    let width = stage.window.bounds.width
    var y: CGFloat = 8
    var views: [MessageView] = []
    let shapes: [(String, Bool, Int)] = [
      ("Sounds good, see you tomorrow", false, 0),
      ("Sounds good, see you tomorrow", false, 1),
      ("On my way", true, 0),
      ("On my way, but the train is running a little late. I'll message again when I'm close.", true, 0),
      ("سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود.", false, 0),
      ("Emoji in text 😀🎉👍 should wrap like letters 🙌🏽", true, 2),
      ("😀", true, 1),
      ("Many reactions wrap onto more rows inside the bubble.", false, 6),
    ]
    for (index, shape) in shapes.enumerated() {
      let view = MessageView()
      stage.root.addSubview(view)
      let layout = stage.apply(
        Self.message(Int64(3_000 + index), shape.0, outgoing: shape.1, reactions: shape.2),
        to: view,
        width: width,
        motion: .immediate
      )
      view.frame = CGRect(x: 0, y: y, width: width, height: layout.size.height)
      y += layout.size.height
      views.append(view)
    }
    stage.root.backgroundColor = style == .dark ? .black : .white
    stage.root.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(100))
    let bounds = CGRect(x: 0, y: 0, width: width, height: y + 8)
    let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
      stage.root.layer.render(in: context.cgContext)
    }
    Attachment.record(Array(try #require(image.pngData())), named: "catalog-\(style == .dark ? "dark" : "light").png")
    views.forEach { $0.removeFromSuperview() }
  }

  @Test("Profile: prepare, plan, apply and draw per message, and list scrolling against the current view")
  func profile() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let width = stage.window.bounds.width
    let clock = ContinuousClock()
    let context = MessageRowContext(
      rowWidth: width,
      isFirstInGroup: true,
      isLastInGroup: true,
      showsName: false,
      avatar: .none,
      theme: ThemeManager.shared.snapshot(variant: .light),
      traits: stage.root.traitCollection
    )
    let messages = Self.strings.enumerated().flatMap { index, text in
      [false, true].flatMap { outgoing in
        [0, 3].map { reactions in
          Self.message(Int64(6_000 + index * 4 + (outgoing ? 2 : 0) + reactions), text, outgoing: outgoing, reactions: reactions)
        }
      }
    }
    var phases: [String: [Double]] = [:]
    func record(_ name: String, _ duration: Duration) {
      phases[name, default: []].append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3)
    }
    let sharedCache = TextLayoutCache()
    for round in 0 ..< 8 {
      for message in messages {
        var content: MessageViewContent?
        record(round == 0 ? "content (first sight)" : "content (cached body)", clock.measure {
          content = MessageViewContent.make(message, context: context)
        })
        let prepared = try #require(content)
        record("plan (new text)", clock.measure { _ = MessageLayoutPlanner.layout(prepared.input, cache: TextLayoutCache()) })
        var planned: MessageLayout?
        record("plan (cached text)", clock.measure { planned = MessageLayoutPlanner.layout(prepared.input, cache: sharedCache) })
        let layout = try #require(planned)
        let view = MessageView()
        view.frame = CGRect(x: 0, y: 0, width: width, height: layout.size.height)
        stage.root.addSubview(view)
        CATransaction.flush()
        record(message.reactions.isEmpty ? "apply, new view (no reactions)" : "apply, new view (3 reactions)", clock.measure {
          view.apply(prepared, layout: layout, motion: .immediate)
          view.layoutIfNeeded()
        })
        record("draw and commit", clock.measure { CATransaction.flush() })
        record("re-apply, same view", clock.measure {
          view.apply(prepared, layout: layout, motion: .immediate)
          view.layoutIfNeeded()
        })
        view.removeFromSuperview()
      }
    }

    // Scrolling: the same 200 rows in both views, 24 pt per step (a fast fling at 60 Hz).
    var scrolling: [String: [Double]] = [:]
    for implementation in [MessageViewImplementation.next, .legacy] {
      let fixture = try await ListFixture(count: 200, implementation: implementation)
      defer { fixture.close() }
      try await fixture.settle()
      let list = fixture.list
      let maxOffset = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
      for pass in ["first pass", "second pass"] {
        var offset = -list.adjustedContentInset.top
        list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        list.layoutIfNeeded()
        CATransaction.flush()
        while offset < maxOffset {
          offset += 24
          scrolling["\(implementation) \(pass)", default: []].append({
            let duration = clock.measure {
              list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
              list.layoutIfNeeded()
              CATransaction.flush()
            }
            return Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3
          }())
        }
      }
    }

    func summary(_ values: [Double]) -> String {
      let sorted = values.sorted()
      func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
      return String(
        format: "n=%d median %.3f ms, p95 %.3f ms, max %.3f ms",
        sorted.count, percentile(0.5), percentile(0.95), sorted.last ?? 0
      )
    }
    var report = "Per message (\(messages.count) shapes × 8 rounds, \(UIDevice.current.model), \(Int(width)) pt):\n"
    for name in ["content (first sight)", "content (cached body)", "plan (new text)", "plan (cached text)", "apply, new view (no reactions)", "apply, new view (3 reactions)", "draw and commit", "re-apply, same view"] {
      report += "  \(name): \(summary(phases[name] ?? [0]))\n"
    }
    report += "Scrolling, 24 pt steps (layout + commit per step):\n"
    for name in scrolling.keys.sorted() {
      let values = scrolling[name] ?? [0]
      report += "  \(name): \(summary(values)); over 8.3 ms: \(values.filter { $0 > 8.33 }.count), over 16.7 ms: \(values.filter { $0 > 16.7 }.count)\n"
    }
    Attachment.record(report, named: "profile.txt")
    let warmApply = (phases["re-apply, same view"] ?? []).sorted()
    #expect(warmApply.isEmpty == false)
  }

  // MARK: - Checks

  static func placementProblems(_ view: MessageView, _ layout: MessageLayout) -> [String] {
    var problems: [String] = []
    func check(_ name: String, _ actual: CGRect?, _ expected: CGRect?) {
      guard let expected else { return }
      guard let actual, close(actual, expected, tolerance: 0.01) else {
        problems.append("\(name) at \(actual.map { "\($0)" } ?? "nil"), planned \(expected)")
        return
      }
    }
    let container = view.bubbleContentView
    check("container", container.frame, layout.bubble.frame)
    check("text", container.convert(view.textView.textFrame, to: view), layout.frame(.text))
    check("time", container.convert(view.timeView.frame, to: view), layout.frame(.time))
    if layout.bubble.isVisible { check("bubble", container.convert(view.bubbleView.frame, to: view), layout.bubble.frame) }
    for id in layout.reactionOrder {
      guard let pill = view.reactionViews[id] else { continue }
      // Model values, not presentation: what the pill settles at once any animation ends.
      check("reaction \(id)", container.convert(pill.untransformedFrame, to: view), layout.frame(.reaction(id)))
      if pill.transform != .identity { problems.append("reaction \(id) left transformed: \(pill.transform)") }
      if pill.bounds.origin != .zero { problems.append("reaction \(id) bounds origin \(pill.bounds.origin)") }
      if !container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(pill.frame) {
        problems.append("reaction \(id) at \(pill.frame) sticks out of the bubble \(container.bounds), where taps miss it")
      }
      for target in tapTargets(in: pill) where pill.hitTest(target.point, with: nil) !== pill {
        problems.append("tap on reaction \(id) \(target.name) lands on \(pill.hitTest(target.point, with: nil).map { "\(type(of: $0))" } ?? "nothing")")
      }
    }
    if view.reactionViews.count != layout.reactionOrder.count {
      problems.append("\(view.reactionViews.count) pills for \(layout.reactionOrder.count) reactions")
    }
    for id in layout.blockOrder {
      guard let host = view.blockViews[id] else {
        problems.append("block \(id) not drawn")
        continue
      }
      check("block \(id)", (host.superview ?? container).convert(host.untransformedFrame, to: view), layout.frame(.block(id)))
      host.layoutIfNeeded()
      // The content view must draw exactly the planned size: its own size rule and the plan agree.
      if [.preview, .task].contains(host.kind), host.bounds.height < 30 {
        problems.append("block \(id) collapsed to \(host.bounds.height) pt")
      }
      if host.kind != .forward, let content = host.contentView,
         abs(content.frame.width - host.bounds.width) > 0.5 || abs(content.frame.height - host.bounds.height) > 0.5
      {
        problems.append("block \(id) draws \(content.frame.size) in its planned \(host.bounds.size)")
      }
    }
    if view.blockViews.count != layout.blockOrder.count {
      problems.append("\(view.blockViews.count) block views for \(layout.blockOrder.count) blocks")
    }
    return problems
  }

  /// Points a finger would aim at on a pill: the emoji, the count or avatars, and the middle.
  static func tapTargets(in pill: MessageReactionPillView) -> [(name: String, point: CGPoint)] {
    guard let model = pill.model else { return [] }
    typealias Metrics = MessageReactionPillView.Metrics
    let size = pill.bounds.size
    let emoji = model.emojiLayout.size
    var targets: [(String, CGPoint)] = [
      ("emoji", CGPoint(x: Metrics.padding + emoji.width / 2, y: size.height / 2)),
      ("middle", CGPoint(x: size.width / 2, y: size.height / 2)),
    ]
    let trailingX = Metrics.padding + emoji.width + Metrics.spacing
    if !model.avatars.isEmpty {
      targets.append(("avatar", CGPoint(x: trailingX + Metrics.avatarSize / 2, y: size.height / 2)))
    } else if let count = model.countLayout?.size {
      targets.append(("count", CGPoint(x: trailingX + count.width / 2, y: size.height / 2)))
    }
    return targets
  }

  /// Mean per-channel difference of two same-size images, 0...1.
  static func meanDifference(_ a: UIImage, _ b: UIImage) -> Double {
    guard let ca = a.cgImage, let cb = b.cgImage, ca.width == cb.width, ca.height == cb.height else { return 1 }
    func pixels(_ image: CGImage) -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
      let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return bytes
    }
    let pa = pixels(ca)
    let pb = pixels(cb)
    var total = 0
    for index in pa.indices { total += abs(Int(pa[index]) - Int(pb[index])) }
    return Double(total) / Double(pa.count * 255)
  }

  /// Renders a text view and reports missing ink or ink touching its outer pixel ring (clipping).
  static func inkProblems(_ view: MessageTextView?, expectsInk: Bool) -> [String] {
    guard let view, view.bounds.width > 0, view.bounds.height > 0 else {
      return expectsInk ? ["no text view"] : []
    }
    view.layer.displayIfNeeded()
    let scale = view.window?.screen.scale ?? 2
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
      view.layer.render(in: context.cgContext)
    }
    guard let cgImage = image.cgImage else { return ["no image"] }
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return ["no context"] }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var ink = 0
    var edge = 0
    for y in 0 ..< height {
      for x in 0 ..< width where bytes[(y * width + x) * 4 + 3] > 24 {
        ink += 1
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 { edge += 1 }
      }
    }
    var problems: [String] = []
    if expectsInk, ink == 0 { problems.append("drew nothing") }
    if edge > 0 { problems.append("\(edge) ink pixels on the edge (clipped)") }
    return problems
  }

  // MARK: - Fixtures

  static let sender = User(id: 8_101, email: "ava@example.com", firstName: "Ava", lastName: "Lin")
  static let reactor = User(id: 8_102, email: "sam@example.com", firstName: "Sam", lastName: "Rivera")

  static func message(_ id: Int64, _ text: String, outgoing: Bool, reactions: Int) -> FullMessage {
    var model = Message(
      messageId: id,
      fromId: sender.id,
      date: Date(timeIntervalSince1970: 1_787_816_400 + Double(id)),
      text: text,
      peerUserId: 9_018,
      peerThreadId: nil,
      chatId: 9_018,
      out: outgoing,
      status: outgoing ? .sent : nil
    )
    model.globalId = 920_000 + id
    var full = FullMessage(
      senderInfo: UserInfo(user: sender),
      message: model,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
    full.reactions = Self.reactions(reactions, on: full)
    return full
  }

  /// One message of each kind the next view draws beside plain text.
  static func kinds(outgoing: Bool) -> [(String, FullMessage)] {
    func base(_ id: Int64, _ text: String?) -> FullMessage {
      var message = Self.message(id, text ?? "", outgoing: outgoing, reactions: 0)
      if text == nil { message.message.text = nil }
      return message
    }
    func photo(_ width: Int, _ height: Int) -> PhotoInfo {
      PhotoInfo(photo: Photo(id: 41, photoId: 4_100, format: .jpeg), sizes: [PhotoSize(photoId: 41, type: "f", width: width, height: height)])
    }
    var kinds: [(String, FullMessage)] = []

    var forward = base(7_001, "Forwarded text that is long enough to wrap onto a second line")
    forward.message.forwardFromUserId = reactor.id
    forward.message.forwardFromPeerUserId = reactor.id
    forward.message.forwardFromMessageId = 12
    forward.forwardFromUserInfo = UserInfo(user: reactor)
    kinds.append(("forward", forward))

    var reply = base(7_002, "ok")
    reply.message.repliedToMessageId = 99
    reply.repliedToMessage = EmbeddedMessage(
      message: Self.message(99, "The message being answered, long enough to truncate inside the quote", outgoing: false, reactions: 0).message,
      senderInfo: UserInfo(user: reactor)
    )
    kinds.append(("reply", reply))

    var bare = base(7_003, nil)
    bare.message.photoId = 4_100
    bare.photoInfo = photo(1_600, 1_200)
    kinds.append(("photo", bare))

    var captioned = base(7_004, "A caption under a tall photo that wraps to the photo's width")
    captioned.message.photoId = 4_100
    captioned.photoInfo = photo(900, 1_600)
    kinds.append(("photo caption", captioned))

    var reacted = base(7_005, nil)
    reacted.message.photoId = 4_100
    reacted.photoInfo = photo(1_200, 1_200)
    reacted.reactions = Self.reactions(2, on: reacted)
    kinds.append(("photo reactions", reacted))

    var video = base(7_006, nil)
    video.message.videoId = 4_200
    video.videoInfo = VideoInfo(video: Video(id: 42, videoId: 4_200, date: Date(), width: 1_920, height: 1_080, duration: 12))
    kinds.append(("video", video))

    var file = base(7_007, nil)
    file.message.documentId = 4_300
    file.documentInfo = DocumentInfo(document: Document(id: 43, documentId: 4_300, date: Date(), fileName: "Quarterly report final v3.pdf", mimeType: "application/pdf", size: 2_400_000))
    kinds.append(("file", file))

    var fileCaption = base(7_008, "Here's the file we talked about.\nIt has the numbers from the last two quarters, and the notes.")
    fileCaption.message.documentId = 4_300
    fileCaption.documentInfo = file.documentInfo
    kinds.append(("file caption", fileCaption))

    var voice = base(7_009, nil)
    var content = Client_MessageVoiceContent()
    content.duration = 7
    content.waveform = Data((0 ..< 48).map { UInt8(($0 * 41) % 255) })
    var payload = Client_MessageContentPayload()
    payload.voice = content
    voice.message.contentPayload = payload
    kinds.append(("voice", voice))

    var link = base(7_010, "Read this before the review https://inline.chat/blog/thread-first-chat")
    link.attachments = [FullAttachment(
      attachment: Attachment(messageId: 7_010, externalTaskId: nil, urlPreviewId: 51, attachmentId: 52),
      urlPreview: UrlPreview(
        id: 51,
        url: "https://inline.chat/blog/thread-first-chat",
        siteName: "Inline",
        title: "Thread-first chat for teams that ship",
        description: "Why we built Inline around threads, and what changes when every conversation has a home.",
        photoId: nil,
        duration: nil
      )
    )]
    kinds.append(("link preview", link))

    var thread = base(7_011, "Kicking off the launch checklist here")
    var replies = MessageReplies()
    replies.chatID = 88
    replies.replyCount = 14
    replies.hasUnread_p = true
    replies.recentReplierUserIds = [reactor.id, sender.id]
    var threadPayload = Client_MessageContentPayload()
    threadPayload.replies = replies
    thread.message.contentPayload = threadPayload
    kinds.append(("thread summary", thread))

    var bot = base(7_012, "Deploy staging build 2026.10.25?")
    func button(_ id: String, _ text: String) -> MessageAction {
      var action = MessageAction()
      action.actionID = id
      action.text = text
      action.action = .callback(MessageActionCallback())
      return action
    }
    var first = MessageActionRow()
    first.actions = [button("yes", "Deploy"), button("no", "Cancel")]
    var second = MessageActionRow()
    second.actions = [button("logs", "Show logs")]
    var actions = MessageActions()
    actions.rows = [first, second]
    bot.message.actions = actions
    kinds.append(("buttons", bot))
    return kinds
  }

  static func reactions(_ count: Int, on message: FullMessage) -> [FullReaction] {
    let emojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "✅", "🙏"]
    return (0 ..< count).map { index in
      FullReaction(
        reaction: Reaction(
          messageId: message.message.messageId,
          userId: index.isMultiple(of: 2) ? reactor.id : sender.id,
          emoji: emojis[index % emojis.count],
          date: message.message.date.addingTimeInterval(Double(index)),
          chatId: message.message.chatId
        ),
        userInfo: UserInfo(user: index.isMultiple(of: 2) ? reactor : sender)
      )
    }
  }

  @MainActor final class Stage {
    let window: UIWindow
    let root: UIView
    private let style: UIUserInterfaceStyle

    init(style: UIUserInterfaceStyle = .light) throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.overrideUserInterfaceStyle = style
      window.isHidden = false
      root = controller.view
      self.style = style
    }

    func close() {
      window.isHidden = true
    }

    @discardableResult
    func apply(
      _ message: FullMessage,
      to view: MessageView,
      width: CGFloat,
      motion: MessageMotion,
      category: UIContentSizeCategory = .large
    ) -> MessageLayout {
      let traits = root.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = category }
      let theme = ThemeManager.shared.snapshot(variant: style == .dark ? .dark : .light)
      let context = MessageRowContext(
        rowWidth: width,
        isFirstInGroup: true,
        isLastInGroup: true,
        showsName: false,
        avatar: .none,
        theme: theme,
        traits: traits
      )
      let content = MessageViewContent.make(message, context: context)!
      let layout = MessageLayoutPlanner.layout(content.input)
      if view.frame.width != width {
        view.frame = CGRect(x: 0, y: 0, width: width, height: layout.size.height)
      }
      view.apply(content, layout: layout, motion: motion)
      return layout
    }

    func render(_ message: FullMessage, width: CGFloat, category: UIContentSizeCategory) -> (MessageView, MessageLayout) {
      let view = MessageView()
      root.addSubview(view)
      let layout = apply(message, to: view, width: width, motion: .immediate, category: category)
      view.layoutIfNeeded()
      return (view, layout)
    }
  }

  @MainActor final class ListFixture {
    let window: UIWindow
    let list: MessagesCollectionView
    let model: MessagesSectionedViewModel
    let publisher: MessagesPublisher
    let peer = Peer.user(id: 9_019)

    init(
      count: Int,
      implementation: MessageViewImplementation = .next,
      customize: (Int, inout FullMessage) -> Void = { _, _ in }
    ) async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.isHidden = false
      let database = AppDatabase.empty()
      publisher = MessagesPublisher(database: database)
      let strings = NextMessageViewDeviceTests.strings
      let rows = (1 ... count).reversed().map { index -> FullMessage in
        var value = NextMessageViewDeviceTests.message(
          Int64(index),
          strings[index % strings.count],
          outgoing: index.isMultiple(of: 3),
          reactions: index.isMultiple(of: 5) ? 2 : 0
        )
        value.message.chatId = 9_019
        value.message.peerUserId = 9_019
        value.message.globalId = 930_000 + Int64(index)
        customize(index, &value)
        return value
      }
      model = MessagesSectionedViewModel(
        peer: peer, reversed: true,
        initialState: .init(
          messages: rows,
          loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: rows)
        ),
        database: database, publisher: publisher
      )
      list = MessagesCollectionView(
        peerId: peer, chatId: 9_019, spaceId: nil, isPreview: true,
        theme: ThemeManager.shared.snapshot(variant: .light),
        viewModel: model, messageViewImplementation: implementation
      )
      controller.view.addSubview(list)
      list.frame = controller.view.bounds
    }

    var visibleCells: [MessageCollectionViewCell] {
      list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
    }

    func settle(milliseconds: Int = 250) async throws {
      try await Task.sleep(for: .milliseconds(milliseconds))
      list.layoutIfNeeded()
    }

    func close() {
      window.isHidden = true
      model.dispose()
    }
  }
}

@MainActor private final class MenuAnimator: NSObject, UIContextMenuInteractionAnimating {
  var previewViewController: UIViewController? { nil }
  private var animations: [() -> Void] = []
  private var completions: [() -> Void] = []
  func addAnimations(_ animations: @escaping () -> Void) { self.animations.append(animations) }
  func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
  func animate() { animations.forEach { $0() } }
  func complete() { completions.forEach { $0() } }
}

/// SplitMix64, so lab runs repeat exactly.
private struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next(below bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(bound))
  }
}

private func progress(_ value: CGFloat, from: CGFloat, to: CGFloat) -> Double? {
  guard abs(to - from) > 1 else { return nil }
  return Double((value - from) / (to - from))
}

private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
  abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}
