import Auth
@testable import InlineIOS
@testable import InlineKit
import InlineIOSUI
import InlineUI
import InlineTheme
import InlineMessageLayout
import struct InlineProtocol.Client_MessageContentPayload
import struct InlineProtocol.Client_MessageVoiceContent
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionCallback
import struct InlineProtocol.MessageActionRow
import struct InlineProtocol.MessageActions
import struct InlineProtocol.MessageReplies
import struct InlineProtocol.Block
import struct InlineProtocol.BlockCode
import struct InlineProtocol.BlockContent
import struct InlineProtocol.BlockDisclosure
import struct InlineProtocol.BlockHeading
import struct InlineProtocol.BlockList
import struct InlineProtocol.BlockListItem
import struct InlineProtocol.BlockQuote
import struct InlineProtocol.BlockTable
import struct InlineProtocol.BlockTableRow
import struct InlineProtocol.BlockText
import struct InlineProtocol.MessageEntities
import struct InlineProtocol.MessageEntity
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

    // A reaction lands while UIKit still presents the menu (its animator hasn't completed): the
    // bubble must not move under UIKit's lifted preview.
    let presenting = MenuAnimator()
    list.delegate?.collectionView?(list, willDisplayContextMenu: configuration, animator: presenting)
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

  @Test("Rich messages draw every node where the rich plan says, with no clipped ink")
  func richLab() async throws {
    let stage = try Stage()
    defer { stage.close() }
    var failures: [String] = []
    var nodes = 0
    for outgoing in [false, true] {
      for expanded in [false, true] {
        for (name, message) in Self.richKinds(outgoing: outgoing, expanded: expanded) {
          for width in [320, 375] as [CGFloat] {
            for category in [UIContentSizeCategory.large, .accessibilityLarge] {
              let label = "\(name) \(outgoing ? "out" : "in") open=\(expanded) \(Int(width)) \(category.rawValue.suffix(6))"
              let (view, layout) = stage.render(message, width: width, category: category)
              defer { view.removeFromSuperview() }
              guard let rich = layout.rich, let richView = view.subviews(of: MessageRichView.self).first else {
                failures.append("\(label): no rich layout")
                continue
              }
              failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
              if let frame = layout.frame(.text), abs(richView.frame.minY - (frame.minY - layout.bubble.frame.minY)) > 0.5 {
                failures.append("\(label): rich view at \(richView.frame), planned \(frame)")
              }
              for placed in rich.nodes {
                nodes += 1
                guard let node = richView.nodeView(at: placed.path) else {
                  failures.append("\(label): node \(placed.path) not drawn")
                  continue
                }
                let actual = (node as? MessageTextView)?.textFrame ?? node.frame
                if abs(actual.minX - placed.frame.minX) > 0.5 || abs(actual.minY - placed.frame.minY) > 0.5
                  || abs(actual.width - placed.frame.width) > 0.5 || abs(actual.height - placed.frame.height) > 0.5
                {
                  failures.append("\(label): node \(placed.path) at \(actual), planned \(placed.frame)")
                }
                if let textView = node as? MessageTextView {
                  failures += Self.inkProblems(textView, expectsInk: true).map { "\(label) node \(placed.path): \($0)" }
                }
              }
            }
          }
        }
      }
    }
    Attachment.record("checked \(nodes) rich nodes", named: "rich-lab.txt")
    #expect(nodes > 200)
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Catalog of rich messages for review", arguments: [UIUserInterfaceStyle.light, .dark])
  func richCatalog(style: UIUserInterfaceStyle) async throws {
    let stage = try Stage(style: style)
    defer { stage.close() }
    let width = stage.window.bounds.width
    stage.root.backgroundColor = style == .dark ? .black : .white
    var rows: [UIImage] = []
    let entries = Self.richKinds(outgoing: false, expanded: true) + Self.richKinds(outgoing: true)
    for (index, entry) in entries.enumerated() {
      let view = MessageView()
      stage.root.addSubview(view)
      var message = entry.1
      message.message.messageId += Int64(index) * 1_000
      let layout = stage.apply(message, to: view, width: width, motion: .immediate)
      view.frame = CGRect(x: 0, y: 20, width: width, height: layout.size.height)
      view.layoutIfNeeded()
      // Syntax colors arrive from the shared highlighter after the first frame.
      try await Task.sleep(for: .milliseconds(500))
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
    Attachment.record(Array(try #require(sheet.pngData())), named: "rich-\(style == .dark ? "dark" : "light").png")
  }

  @Test("Opening a disclosure grows the row and its bubble on one curve")
  func disclosureToggle() async throws {
    let rich = Self.richKinds(outgoing: false)[0].1
    let fixture = try await ListFixture(count: 3) { index, message in
      guard index == 1 else { return }
      let identity = message.message
      message = rich
      message.message.messageId = identity.messageId
      message.message.globalId = identity.globalId
      message.message.chatId = identity.chatId
      message.message.peerUserId = identity.peerUserId
      message.message.date = identity.date
    }
    defer { fixture.close() }
    try await fixture.settle()
    let cell = try #require(fixture.visibleCells.first { $0.nextMessageView?.layout?.rich != nil })
    let view = try #require(cell.nextMessageView)
    let richView = try #require(view.subviews(of: MessageRichView.self).first)
    let toggle = try #require(richView.subviews.compactMap { $0 as? UIControl }.first)
    let oldRow = cell.bounds.height
    let oldBubble = view.bubbleContentView.frame.height
    let oldNodes = view.layout?.rich?.nodes.count ?? 0
    toggle.sendActions(for: .touchUpInside)
    try await Task.sleep(for: .milliseconds(110))
    let presentedRow = try #require(cell.layer.presentation()).bounds.height
    let presentedBubble = try #require(view.bubbleContentView.layer.presentation()).bounds.height
    try await fixture.settle(milliseconds: 700)
    let newRow = cell.bounds.height
    let newBubble = view.bubbleContentView.frame.height
    #expect((view.layout?.rich?.nodes.count ?? 0) > oldNodes, "the disclosure's children did not appear")
    #expect(newRow > oldRow)
    let rowProgress = progress(presentedRow, from: oldRow, to: newRow)
    let bubbleProgress = progress(presentedBubble, from: oldBubble, to: newBubble)
    Attachment.record("row \(oldRow)→\(newRow) p=\(rowProgress.map { String($0) } ?? "-"); bubble \(oldBubble)→\(newBubble) p=\(bubbleProgress.map { String($0) } ?? "-")", named: "disclosure-toggle.txt")
    if let rowProgress, let bubbleProgress {
      #expect(rowProgress > 0.02 && rowProgress < 0.98, "row did not animate: \(rowProgress)")
      #expect(abs(rowProgress - bubbleProgress) < 0.15)
    }
    if let layout = view.layout {
      let problems = Self.placementProblems(view, layout)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
  }

  @Test("Streaming edits reveal at a paced rate, grow the row a line at a time, and show the time when idle")
  func streamingReveal() async throws {
    let fixture = try await ListFixture(count: 4)
    defer { fixture.close() }
    try await fixture.settle()
    let cell = try #require(fixture.visibleCells.first { $0.showsNextMessageView && $0.message?.message.out == false })
    var message = try #require(cell.message)
    let words = "This answer streams in word by word, the way a bot edits its message while it works through a long reply about the release."
      .split(separator: " ").map(String.init)
    // Start from the first word, then stream the rest as appends.
    var text = words[0]
    message.message.text = text
    fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
    try await fixture.settle(milliseconds: 600)

    var heights: [CGFloat] = []
    var timeShown = false
    var partialFrames = 0
    for word in words.dropFirst() {
      text += " " + word
      message.message.text = text
      fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
      for _ in 0 ..< 4 {
        try await Task.sleep(for: .milliseconds(20))
        heights.append(cell.bounds.height)
        guard let view = cell.nextMessageView else { continue }
        if view.timeView.alpha > 0.5 { timeShown = true }
        if let revealed = view.textView.revealedLength, revealed < (text as NSString).length { partialFrames += 1 }
      }
    }
    Attachment.record("heights \(heights)\npartial frames \(partialFrames)", named: "streaming.txt")
    #expect(!timeShown, "the time showed while the message streamed")
    #expect(heights == heights.sorted(), "the row shrank while streaming")
    #expect(Set(heights).count > 1, "the row never grew")
    #expect(partialFrames > 0, "text never revealed partially")

    try await Task.sleep(for: .milliseconds(2_500))
    let view = try #require(cell.nextMessageView)
    #expect(view.textView.revealedLength == nil, "the stream never finished")
    #expect(view.timeView.alpha > 0.99, "the time did not return")
    #expect(abs(cell.bounds.height - (view.layout?.size.height ?? 0)) <= 0.5)
    if let layout = view.layout {
      let problems = Self.placementProblems(view, layout)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
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

  // MARK: - Every kind × interaction

  @Test("A real context menu over every kind closes without leaving a preview, a hidden bubble or a moved row")
  func realContextMenu() async throws {
    let present = NSSelectorFromString("_presentMenuAtLocation:")
    typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    let entries = Self.everyKind()
    var failures: [String] = []
    var report: [String] = []
    var rows = 0
    // UIKit's own timing: the same open and dismiss on a plain view with a stock menu.
    let plainDismissal: Int
    do {
      let stage = try Stage()
      defer { stage.close() }
      let target = UIView(frame: CGRect(x: 40, y: 200, width: 200, height: 44))
      target.backgroundColor = .systemGray5
      stage.root.addSubview(target)
      let delegate = PlainMenuDelegate()
      let plain = UIContextMenuInteraction(delegate: delegate)
      target.addInteraction(plain)
      let open = unsafeBitCast(plain.method(for: present), to: Present.self)
      var samples: [Int] = []
      for _ in 0 ..< 3 {
        open(plain, present, CGPoint(x: 100, y: 22))
        try await Task.sleep(for: .milliseconds(700))
        plain.dismissMenu()
        if let gone = try await Self.menuDismissal(baseline: 0, isActive: { false }) { samples.append(gone) }
        try await Task.sleep(for: .milliseconds(200))
      }
      plainDismissal = samples.max() ?? 600
      report.append("plain UIKit menu gone after \(samples) ms")
    }
    for chunk in Self.chunks(entries, 3) {
      let fixture = try await ListFixture(rows: chunk.map(\.1))
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 400)
      let list = fixture.list
      let interaction = try #require(list.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
      try #require(interaction.responds(to: present), "UIKit has no menu presentation hook")
      let open = unsafeBitCast(interaction.method(for: present), to: Present.self)
      try await fixture.eachRow { cell in
        guard let id = cell.message?.message.messageId, let view = cell.nextMessageView, cell.showsNextMessageView else {
          failures.append("\(cell.message?.id ?? 0): not drawn by the next view")
          return
        }
        let name = chunk[Int(id) - 1].0
        let variant = ["plain", "reaction under the menu", "quick close", "reopen while closing"][rows % 4]
        rows += 1
        let label = "\(name) (\(variant))"
        let container = view.bubbleContentView
        // Hold the first word, like a person would: links and blocks such as the thread summary
        // own their own menus.
        let point: CGPoint
        if let text = view.layout?.frame(.text) {
          point = view.convert(CGPoint(x: text.minX + 8, y: text.minY + 8), to: list)
        } else {
          point = container.convert(CGPoint(x: container.bounds.midX, y: container.bounds.midY), to: list)
        }
        let baseline = Self.menuArtifacts().count
        let rowBefore = cell.convert(cell.bounds, to: fixture.window)

        open(interaction, present, point)
        try await Task.sleep(for: .milliseconds(variant == "quick close" ? 60 : 700))
        let during = Self.menuArtifacts().count
        if variant != "quick close", during <= baseline || !list.isContextMenuInteractionActive {
          failures.append("\(label): the menu never opened (\(during) menu views, active \(list.isContextMenuInteractionActive))")
        }
        if variant == "reaction under the menu", var message = cell.message {
          message.reactions = Self.reactions(1, on: message)
          fixture.publisher.publisher.send(.update(.init(message: message, animated: true, peer: fixture.peer)))
          try await Task.sleep(for: .milliseconds(200))
        }
        interaction.dismissMenu()
        if variant == "reopen while closing" {
          try await Task.sleep(for: .milliseconds(80))
          open(interaction, present, point)
          try await Task.sleep(for: .milliseconds(700))
          interaction.dismissMenu()
        }
        let gone = try await Self.menuDismissal(baseline: baseline) { list.isContextMenuInteractionActive }
        try await Task.sleep(for: .milliseconds(100))
        list.layoutIfNeeded()

        let left = Self.menuArtifacts()
        report.append("\(label): menu views \(baseline) → \(during) → \(left.count), gone after \(gone.map { "\($0) ms" } ?? "never")")
        if let gone, gone > plainDismissal + 250 {
          failures.append("\(label): the preview stayed \(gone) ms after dismissal; a plain UIKit menu leaves in \(plainDismissal) ms")
        }
        if left.count > baseline { failures.append("\(label): menu left \(left.count - baseline) views on screen: \(left)") }
        if list.isContextMenuInteractionActive { failures.append("\(label): the list still thinks a menu is open") }
        for other in fixture.visibleCells {
          if other.nextMessageView?.bubbleContentView.isHidden == true || other.messageView?.bubbleView.isHidden == true {
            failures.append("\(label): row \(other.message?.id ?? 0) stayed hidden after the menu")
          }
        }
        guard let current = cell.nextMessageView, let layout = current.layout else {
          failures.append("\(label): the row lost its view")
          return
        }
        if current.bubbleContentView.alpha < 1 || current.bubbleContentView.transform != .identity
          || current.bubbleContentView.superview !== current
        {
          failures.append("\(label): bubble left lifted (alpha \(current.bubbleContentView.alpha), transform \(current.bubbleContentView.transform))")
        }
        if variant == "reaction under the menu", current.reactionViews.isEmpty {
          failures.append("\(label): the reaction never arrived after the menu")
        }
        let rowAfter = cell.convert(cell.bounds, to: fixture.window)
        if variant != "reaction under the menu", !close(rowBefore, rowAfter, tolerance: 0.5) {
          failures.append("\(label): row moved \(rowBefore) → \(rowAfter)")
        }
        if abs(cell.bounds.height - layout.size.height) > 0.5 {
          failures.append("\(label): row \(cell.bounds.height) vs plan \(layout.size.height)")
        }
        failures += Self.placementProblems(current, layout).map { "\(label): \($0)" }
      }
    }
    Attachment.record(report.joined(separator: "\n"), named: "real-context-menu.txt")
    #expect(rows == entries.count, "checked \(rows) of \(entries.count) rows")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("A reaction picked in a real context menu is on its row before the preview flies back")
  func menuReactionLandsWithPreview() async throws {
    let present = NSSelectorFromString("_presentMenuAtLocation:")
    typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    var report: [String] = []
    var failures: [String] = []
    for outgoing in [false, true] {
      let rows = (1 ... 5).map { Self.message(Int64($0), Self.strings[$0 % 3], outgoing: outgoing == ($0 == 3), reactions: 0) }
      let fixture = try await ListFixture(rows: rows)
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 400)
      let list = fixture.list
      let interaction = try #require(list.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
      let open = unsafeBitCast(interaction.method(for: present), to: Present.self)
      let label = outgoing ? "outgoing" : "incoming"
      guard let cell = fixture.visibleCells.first(where: { $0.message?.message.messageId == 3 }),
            let view = cell.nextMessageView, let text = view.layout?.frame(.text), var message = cell.message
      else {
        failures.append("\(label): no row")
        continue
      }
      open(interaction, present, view.convert(CGPoint(x: text.minX + 8, y: text.minY + 8), to: list))
      // After UIKit has let go of the lifted bubble; earlier picks wait for it (see below).
      try await Task.sleep(for: .milliseconds(1_300))
      guard list.isContextMenuInteractionActive else {
        failures.append("\(label): the menu never opened")
        continue
      }
      message.reactions = Self.reactions(1, on: message)
      let update = message
      let sampler = MenuFrameSampler(window: fixture.window) {
        guard let current = cell.nextMessageView else { return nil }
        return (current, current.reactionViews.values.first)
      }
      sampler.start()
      // The optimistic write reaches the list a few milliseconds after the tap.
      list.reactFromContextMenu(messageStableId: message.id) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
          fixture.publisher.publisher.send(.update(.init(message: update, animated: true, peer: fixture.peer)))
        }
      }
      let gone = try await Self.menuDismissal(baseline: 0) { list.isContextMenuInteractionActive }
      try await Task.sleep(for: .milliseconds(400))
      sampler.stop()
      let summary = sampler.summary()
      report.append("\(label): menu gone \(gone.map { "\($0) ms" } ?? "never"); \(summary.text)")
      if let added = summary.pillAddedMs, let back = summary.bubbleBackMs, let shown = summary.pillShownMs {
        if back < added {
          failures.append("\(label): the menu began closing (\(back) ms) before the row had the reaction (\(added) ms)")
        }
        if shown > 450 { failures.append("\(label): the reaction was fully shown only after \(shown) ms") }
      } else {
        failures.append("\(label): the reaction never showed")
      }
      if gone == nil { failures.append("\(label): the menu never closed") }
      if let layout = cell.nextMessageView?.layout, abs(cell.bounds.height - layout.size.height) > 0.5 {
        failures.append("\(label): row \(cell.bounds.height) vs plan \(layout.size.height)")
      }
      if let current = cell.nextMessageView, let layout = current.layout {
        failures += Self.placementProblems(current, layout).map { "\(label): \($0)" }
      }
    }
    Attachment.record(report.joined(separator: "\n"), named: "menu-reaction.txt")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(20).joined(separator: "\n"))")
  }

  @Test("A menu reaction never changes the row while UIKit holds the bubble, however early it's picked")
  func menuReactionWaitsForUIKit() async throws {
    let present = NSSelectorFromString("_presentMenuAtLocation:")
    typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    var report: [String] = []
    var failures: [String] = []
    // A reaction picked early (UIKit still holds the lifted bubble) and late; for the late one, a
    // second update (the server's echo) racing the dismissal.
    for (tap, echo) in [(450, -1), (650, -1), (1_300, 0), (1_300, 40), (1_300, 120)] {
      let rows = (1 ... 5).map { Self.message(Int64($0), Self.strings[$0 % 3], outgoing: $0 != 3, reactions: 0) }
      let fixture = try await ListFixture(rows: rows)
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 400)
      let list = fixture.list
      let interaction = try #require(list.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
      let open = unsafeBitCast(interaction.method(for: present), to: Present.self)
      guard let cell = fixture.visibleCells.first(where: { $0.message?.message.messageId == 3 }),
            let view = cell.nextMessageView, let text = view.layout?.frame(.text), var message = cell.message,
            let before = view.layout?.size
      else {
        failures.append("tap \(tap): no row")
        continue
      }
      let label = "tap \(tap) ms\(echo >= 0 ? ", echo +\(echo) ms" : "")"
      let start = CACurrentMediaTime()
      func now() -> Int { Int((CACurrentMediaTime() - start) * 1_000) }
      var events: [String] = []
      var sizes: [String: CGSize] = [:]
      list.onContextMenuEvent = { event in
        let size = cell.nextMessageView?.layout?.size ?? .zero
        events.append("\(event)@\(now()) h=\(Int(size.height))")
        sizes[event] = size
      }
      open(interaction, present, view.convert(CGPoint(x: text.minX + 8, y: text.minY + 8), to: list))
      try await Task.sleep(for: .milliseconds(tap))
      message.reactions = Self.reactions(1, on: message)
      let first = message
      var second = message
      second.reactions = Self.reactions(3, on: message)
      list.reactFromContextMenu(messageStableId: message.id) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
          fixture.publisher.publisher.send(.update(.init(message: first, animated: true, peer: fixture.peer)))
          events.append("update@\(now())")
          guard echo >= 0 else { return }
          DispatchQueue.main.asyncAfter(deadline: .now() + Double(echo) / 1_000) {
            fixture.publisher.publisher.send(.update(.init(message: second, animated: true, peer: fixture.peer)))
            events.append("echo@\(now())")
          }
        }
      }
      _ = try await Self.menuDismissal(baseline: 0) { list.isContextMenuInteractionActive }
      try await Task.sleep(for: .milliseconds(400))
      list.onContextMenuEvent = nil
      report.append("\(label): \(events.joined(separator: ", "))")
      // UIKit lets go of the lifted bubble when its present animation completes. Until then, and
      // from the dismissal preview until the menu's completion, the row must keep its shape.
      guard let presented = sizes["presented"], let held = sizes["dismissalPreview"], let done = sizes["completion"] else {
        failures.append("\(label): missing menu events: \(events)")
        continue
      }
      if presented != before { failures.append("\(label): the row changed before UIKit let go of the bubble") }
      if held == before { failures.append("\(label): the menu closed before the row had the reaction") }
      if done != held { failures.append("\(label): the row changed while the preview flew back") }
      if cell.nextMessageView?.reactionViews.isEmpty != false { failures.append("\(label): no reaction on the row") }
    }
    Attachment.record(report.joined(separator: "\n"), named: "menu-reaction-timing.txt")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.joined(separator: "\n"))\n\(report.joined(separator: "\n"))")
  }

  @Test("A thread's parent draws with the next view, without its thread summary, and animates reactions in place")
  func threadAnchor() async throws {
    var failures: [String] = []
    for outgoing in [false, true] {
      var parent = try #require(Self.kinds(outgoing: outgoing).first { $0.0 == "thread summary" }?.1)
      parent.message.messageId = 500
      parent.message.chatId = 9_019
      parent.message.peerUserId = 9_019
      let fixture = try await ListFixture(count: 3, anchor: parent)
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 400)
      let label = outgoing ? "outgoing" : "incoming"
      let cells = { fixture.list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }.filter { $0.displayMode == .threadAnchor } }
      guard let cell = cells().first else {
        // The anchor sits above the newest rows; bring it into view.
        failures.append("\(label): no anchor row on screen")
        continue
      }
      guard cell.showsNextMessageView, let view = cell.nextMessageView, let layout = view.layout else {
        failures.append("\(label): the anchor still uses the current view")
        continue
      }
      if view.blockViews["thread"] != nil || layout.frame(.block("thread")) != nil {
        failures.append("\(label): the anchor shows its own thread summary")
      }
      failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
      var update = parent
      update.reactions = Self.reactions(2, on: parent)
      let before = cell.bounds.height
      fixture.publisher.publisher.send(.update(.init(message: update, animated: true, peer: fixture.peer)))
      try await fixture.settle(milliseconds: 600)
      guard let after = cell.nextMessageView, let planned = after.layout else {
        failures.append("\(label): the anchor lost its view")
        continue
      }
      if after.reactionViews.count != 2 { failures.append("\(label): \(after.reactionViews.count) pills after the update") }
      if cell.bounds.height <= before { failures.append("\(label): the row didn't grow (\(before) → \(cell.bounds.height))") }
      if abs(cell.bounds.height - planned.size.height) > 0.5 {
        failures.append("\(label): row \(cell.bounds.height) vs plan \(planned.size.height)")
      }
      failures += Self.placementProblems(after, planned).map { "\(label): \($0)" }
    }
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.joined(separator: "\n"))")
  }

  @Test("A reaction pill pops in, slides its avatars, rolls its count and recolors on the row's curve")
  func reactionPillMotion() async throws {
    let stage = try Stage()
    defer { stage.close() }
    let width = stage.window.bounds.width
    let me = Auth.shared.getCurrentUserId() ?? 0
    let people = (0 ..< 5).map { User(id: 8_200 + Int64($0), email: "p\($0)@example.com", firstName: "P\($0)", lastName: "Lane") }
    var message = Self.message(9_100, "Sounds good, see you tomorrow", outgoing: false, reactions: 0)
    func react(_ users: [(Int64, User)]) {
      message.reactions = users.enumerated().map { index, entry in
        FullReaction(
          reaction: Reaction(
            messageId: message.message.messageId, userId: entry.0, emoji: "👍",
            date: message.message.date.addingTimeInterval(Double(index)), chatId: message.message.chatId
          ),
          userInfo: UserInfo(user: entry.1)
        )
      }
    }
    func others(_ indices: Range<Int>) -> [(Int64, User)] { indices.map { (people[$0].id, people[$0]) } }
    let view = MessageView()
    stage.root.addSubview(view)
    var failures: [String] = []
    var report: [String] = []
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(900))
      if let layout = view.layout { failures += Self.placementProblems(view, layout) }
    }

    // A new pill overshoots, then settles at full size.
    stage.apply(message, to: view, width: width, motion: .immediate)
    view.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(50))
    react(others(0 ..< 1))
    stage.apply(message, to: view, width: width, motion: .standard)
    let pill = try #require(view.reactionViews["👍"])
    var scales: [CGFloat] = []
    for _ in 0 ..< 30 {
      try await Task.sleep(for: .milliseconds(16))
      if let transform = pill.layer.presentation()?.transform { scales.append(transform.m11) }
    }
    report.append("pop scales \(scales.map { String(format: "%.2f", $0) }.joined(separator: " "))")
    if (scales.max() ?? 0) < 1.02 { failures.append("the new pill never overshot (max \(scales.max() ?? 0))") }
    try await settle()

    // A second reactor: the first avatar slides over on the pill's curve while the new one pops in.
    let first = try #require(pill.avatarViews[people[0].id])
    let firstFrom = first.center.x
    let pillFrom = pill.bounds.width
    react(others(0 ..< 2))
    stage.apply(message, to: view, width: width, motion: .standard)
    let second = try #require(pill.avatarViews[people[1].id])
    try await Task.sleep(for: .milliseconds(90))
    let slide = progress(first.layer.presentation()?.position.x ?? 0, from: firstFrom, to: first.center.x)
    let grow = progress(pill.layer.presentation()?.bounds.width ?? 0, from: pillFrom, to: pill.bounds.width)
    let secondOpacity = second.layer.presentation()?.opacity ?? 1
    let secondScale = second.layer.presentation()?.transform.m11 ?? 1
    report.append("second reactor: slide \(slide ?? -1), pill width \(grow ?? -1), new avatar opacity \(secondOpacity) scale \(secondScale)")
    if let slide, let grow {
      if !(0.02 ... 0.98).contains(slide) { failures.append("the first avatar did not slide (\(slide))") }
      if abs(slide - grow) > 0.15 { failures.append("avatar \(slide) and pill width \(grow) on different clocks") }
    } else {
      failures.append("no measurable slide or growth")
    }
    if !(0.02 ... 0.98).contains(Double(secondOpacity)) || secondScale >= 0.999 {
      failures.append("the new avatar did not pop in (opacity \(secondOpacity), scale \(secondScale))")
    }
    try await settle()
    if second.transform != .identity || second.alpha < 1 { failures.append("the new avatar settled at \(second.transform), alpha \(second.alpha)") }

    // Removing the first reactor keeps the second reactor's avatar and slides it back.
    react(others(1 ..< 2))
    stage.apply(message, to: view, width: width, motion: .standard)
    if pill.avatarViews[people[1].id] !== second { failures.append("the remaining reactor's avatar was replaced") }
    try await Task.sleep(for: .milliseconds(90))
    let leavingOpacity = first.layer.presentation()?.opacity ?? 0
    if !(0.02 ... 0.98).contains(Double(leavingOpacity)) { failures.append("the leaving avatar did not fade (\(leavingOpacity))") }
    try await settle()
    let avatarsLeft = pill.subviews.filter { $0 is UserAvatarLayerView }.count
    if avatarsLeft != 1 { failures.append("\(avatarsLeft) avatar views left for one reactor") }

    // Four reactors show a count; a fifth rolls it up.
    react(others(0 ..< 4))
    stage.apply(message, to: view, width: width, motion: .immediate)
    view.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(50))
    if !pill.avatarViews.isEmpty { failures.append("four reactors still show avatars") }
    let oldY = pill.countView.center.y
    react(others(0 ..< 5))
    stage.apply(message, to: view, width: width, motion: .standard)
    try await Task.sleep(for: .milliseconds(90))
    let leaving = pill.leavingCountViews.last?.view.layer.presentation()
    let arriving = pill.countView.layer.presentation()
    let rollOut = leaving.map { (oldY - $0.position.y) / MessageReactionPillView.Metrics.rollDistance } ?? 0
    report.append("count roll: old \(leaving?.opacity ?? -1) moved \(rollOut), new \(arriving?.opacity ?? -1)")
    if !(0.02 ... 0.98).contains(Double(leaving?.opacity ?? 0)) || !(0.02 ... 0.98).contains(Double(arriving?.opacity ?? 0)) {
      failures.append("the count did not crossfade (old \(leaving?.opacity ?? -1), new \(arriving?.opacity ?? -1))")
    }
    if !(0.02 ... 0.98).contains(Double(rollOut)) { failures.append("the old count did not roll up (\(rollOut))") }
    try await settle()
    if pill.countView.layout.text.string != "5" { failures.append("count shows \(pill.countView.layout.text.string)") }
    if !pill.leavingCountViews.isEmpty { failures.append("\(pill.leavingCountViews.count) old counts left behind") }

    // Your own reaction recolors the pill on the row's curve instead of snapping.
    react(others(0 ..< 1) + [(me, Self.sender)])
    stage.apply(message, to: view, width: width, motion: .immediate)
    try await Task.sleep(for: .milliseconds(50))
    react(others(0 ..< 1))
    stage.apply(message, to: view, width: width, motion: .standard)
    let recolors = pill.subviews.contains { $0.layer.animationKeys()?.contains("backgroundColor") == true }
    if !recolors { failures.append("the pill's color snapped") }
    try await settle()

    Attachment.record(report.joined(separator: "\n"), named: "reaction-pill-motion.txt")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Rows own their layout: no stack views or constraints outside hosted blocks, and layout passes move nothing")
  func layoutOwnership() async throws {
    let entries = Self.everyKind()
    var failures: [String] = []
    var rows = 0
    var views = 0
    for chunk in Self.chunks(entries, 3) {
      let fixture = try await ListFixture(rows: chunk.map(\.1))
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 500)
      try await fixture.eachRow { cell in
        guard let id = cell.message?.message.messageId, let view = cell.nextMessageView, let layout = view.layout,
              cell.showsNextMessageView
        else {
          failures.append("\(cell.message?.id ?? 0): not drawn by the next view")
          return
        }
        rows += 1
        let name = chunk[Int(id) - 1].0
        for owned in Self.ownedViews(of: view) {
          views += 1
          let kind = String(describing: type(of: owned))
          if owned is UIStackView { failures.append("\(name): stack view \(kind)") }
          let constraints = owned.constraints.filter { type(of: $0) == NSLayoutConstraint.self }
          if !constraints.isEmpty { failures.append("\(name): \(kind) carries \(constraints.count) constraints") }
          if !owned.translatesAutoresizingMaskIntoConstraints { failures.append("\(name): \(kind) is laid out by Auto Layout") }
        }
        // Hosted block content may use Auto Layout inside its planned frame, but never ambiguously.
        for host in view.blockViews.values {
          for inner in host.subviews(of: UIView.self) where inner.hasAmbiguousLayout && Self.isOnScreen(inner) {
            failures.append("\(name): \(type(of: inner)) inside the \(host.kind) block is ambiguous")
          }
        }

        // Layout passes, intrinsic-size invalidation and a self-sizing query must not move anything.
        let before = Self.frames(in: cell)
        for _ in 0 ..< 3 {
          cell.setNeedsLayout()
          cell.layoutIfNeeded()
        }
        for inner in cell.subviews(of: UIView.self) {
          inner.invalidateIntrinsicContentSize()
          inner.setNeedsLayout()
        }
        cell.layoutIfNeeded()
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        if abs(fitted.frame.height - layout.size.height) > 0.5 {
          failures.append("\(name): self-sizing reports \(fitted.frame.height), plan \(layout.size.height)")
        }
        try await Task.sleep(for: .milliseconds(120))
        cell.layoutIfNeeded()
        let after = Self.frames(in: cell)
        for (key, old) in before {
          guard let new = after[key] else { continue }
          if !close(old.frame, new.frame, tolerance: 0.01) {
            failures.append("\(name): \(old.kind) moved \(old.frame) → \(new.frame) after a layout pass")
          }
        }
        failures += Self.placementProblems(view, layout).map { "\(name): \($0)" }
      }
      // Re-running the list layout keeps every row where it was.
      let rowFrames = Dictionary(fixture.visibleCells.map { ($0.message?.id ?? 0, $0.frame) }, uniquingKeysWith: { a, _ in a })
      fixture.list.collectionViewLayout.invalidateLayout()
      try await fixture.settle(milliseconds: 300)
      for cell in fixture.visibleCells {
        if let old = rowFrames[cell.message?.id ?? 0], !close(old, cell.frame, tolerance: 0.5) {
          failures.append("row \(cell.message?.id ?? 0) moved \(old) → \(cell.frame) after the list re-laid out")
        }
      }
    }
    Attachment.record("checked \(views) views in \(rows) rows", named: "layout-ownership.txt")
    #expect(rows == entries.count, "checked \(rows) of \(entries.count) rows")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Adding and removing a reaction animates the row, the bubble and the pill together on every kind")
  func reactionEveryKind() async throws {
    var failures: [String] = []
    var report: [String] = []
    let me = Auth.shared.getCurrentUserId() ?? 0
    for (name, entry) in Self.everyKind() {
      let fixture = try await ListFixture(rows: [entry])
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 400)
      guard let cell = fixture.visibleCells.first, cell.showsNextMessageView, let view = cell.nextMessageView,
            var message = cell.message
      else {
        failures.append("\(name): not drawn by the next view")
        continue
      }
      let original = message
      message.reactions.append(FullReaction(
        reaction: Reaction(messageId: message.message.messageId, userId: me, emoji: "🫡", date: message.message.date, chatId: message.message.chatId),
        userInfo: UserInfo(user: Self.sender)
      ))

      for (step, next) in [("add", message), ("remove", original)] {
        let oldRow = cell.bounds.height
        let oldBubble = view.bubbleContentView.frame
        fixture.publisher.publisher.send(.update(.init(message: next, animated: true, peer: fixture.peer)))
        try await Task.sleep(for: .milliseconds(110))
        let presentedRow = cell.layer.presentation()?.bounds.height ?? cell.bounds.height
        let presentedBubble = view.bubbleContentView.layer.presentation()?.frame ?? view.bubbleContentView.frame
        let pill = view.reactionViews["🫡"]?.layer.presentation()
        try await fixture.settle(milliseconds: 700)
        let newRow = cell.bounds.height
        let newBubble = view.bubbleContentView.frame
        let samples = [
          ("row", progress(presentedRow, from: oldRow, to: newRow)),
          ("bubble height", progress(presentedBubble.height, from: oldBubble.height, to: newBubble.height)),
          ("bubble width", progress(presentedBubble.width, from: oldBubble.width, to: newBubble.width)),
        ].compactMap { label, value in value.map { (label, $0) } }
        report.append("\(name) \(step): " + samples.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", ")
          + (pill.map { ", pill opacity \(String(format: "%.2f", $0.opacity))" } ?? ""))
        let label = "\(name) \(step)"
        if samples.isEmpty, step == "add", pill == nil { failures.append("\(label): nothing changed and no pill appeared") }
        for (part, value) in samples where !(0.02 ... 0.98).contains(value) {
          failures.append("\(label): \(part) did not animate (\(String(format: "%.2f", value)))")
        }
        if let low = samples.map(\.1).min(), let high = samples.map(\.1).max(), high - low > 0.15 {
          failures.append("\(label): parts on different clocks \(samples)")
        }
        if step == "add", let pill, !(0.02 ... 0.98).contains(Double(pill.opacity)) {
          failures.append("\(label): the pill did not fade in (opacity \(pill.opacity))")
        }
        let pills = view.bubbleContentView.subviews.filter { $0 is MessageReactionPillView }
        if pills.count != (view.layout?.reactionOrder.count ?? 0) {
          failures.append("\(label): \(pills.count) pill views for \(view.layout?.reactionOrder.count ?? 0) reactions")
        }
        if let layout = view.layout {
          if abs(cell.bounds.height - layout.size.height) > 0.5 { failures.append("\(label): row \(cell.bounds.height) vs plan \(layout.size.height)") }
          failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
        }
      }
    }
    Attachment.record(report.joined(separator: "\n"), named: "reaction-every-kind.txt")
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Switching between light and dark recolors every row in place without moving anything")
  func themeSwitch() async throws {
    var failures: [String] = []
    var sheets = 0
    for chunk in Self.chunks(Self.everyKind(), 4) {
      let fixture = try await ListFixture(rows: chunk.map(\.1))
      defer { fixture.close() }
      try await fixture.settle(milliseconds: 600)
      func state() -> [Int64: [ObjectIdentifier: (kind: String, frame: CGRect)]] {
        Dictionary(fixture.visibleCells.map { ($0.message?.id ?? 0, Self.frames(in: $0)) }, uniquingKeysWith: { a, _ in a })
      }
      func image() -> UIImage {
        UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
          fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
      }
      let light = state()
      let lightImage = image()
      let lightBubbles = Dictionary(fixture.visibleCells.compactMap { cell in
        cell.nextMessageView?.content.map { (cell.message?.id ?? 0, $0.bubbleColor) }
      }, uniquingKeysWith: { a, _ in a })
      for (style, variant) in [(UIUserInterfaceStyle.dark, ThemeAppearanceVariant.dark), (.light, .light)] {
        fixture.window.overrideUserInterfaceStyle = style
        fixture.list.applyTheme(ThemeManager.shared.snapshot(variant: variant))
        try await fixture.settle(milliseconds: 600)
        let now = state()
        for (id, frames) in light {
          for (key, old) in frames {
            guard let new = now[id]?[key] else { continue }
            if !close(old.frame, new.frame, tolerance: 0.01) {
              failures.append("\(style == .dark ? "dark" : "light again") row \(id): \(old.kind) moved \(old.frame) → \(new.frame)")
            }
          }
        }
        for cell in fixture.visibleCells where cell.showsNextMessageView {
          if cell.nextMessageView?.content?.context.theme != ThemeManager.shared.snapshot(variant: variant) {
            failures.append("row \(cell.message?.id ?? 0) kept the old theme")
          }
        }
        let current = image()
        let difference = Self.meanDifference(lightImage, current)
        for cell in fixture.visibleCells where cell.message?.message.out != true {
          guard let color = cell.nextMessageView?.content?.bubbleColor, let id = cell.message?.id else { continue }
          if let old = lightBubbles[id], style == .dark, old == color, old.cgColor.alpha > 0 {
            failures.append("row \(id): incoming bubble kept its light color")
          }
        }
        if style == .dark {
          Attachment.record(Array(try #require(current.pngData())), named: "theme-dark-\(sheets).png")
        } else if difference > 0.02 {
          Attachment.record(Array(try #require(current.pngData())), named: "theme-light-again-\(sheets).png")
          failures.append("light after dark differs from the first light frame (difference \(difference))")
        }
      }
      sheets += 1
    }
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  @Test("Every kind combines with replies, forwards, reactions, names, avatars and status in both themes")
  func combinationsLab() async throws {
    var failures: [String] = []
    var checked = 0
    for style in [UIUserInterfaceStyle.light, .dark] {
      let stage = try Stage(style: style)
      defer { stage.close() }
      for (name, base) in Self.everyKind() {
        for variant in 0 ..< 8 {
          var message = base
          var parts: [String] = []
          if variant & 1 != 0, message.repliedToMessage == nil {
            message.message.repliedToMessageId = 99
            message.repliedToMessage = EmbeddedMessage(
              message: Self.message(99, "The message being answered, long enough to truncate inside the quote", outgoing: false, reactions: 0).message,
              senderInfo: UserInfo(user: Self.reactor)
            )
            parts.append("reply")
          }
          if variant & 2 != 0, message.forwardFromUserInfo == nil {
            message.message.forwardFromUserId = Self.reactor.id
            message.message.forwardFromPeerUserId = Self.reactor.id
            message.message.forwardFromMessageId = 12
            message.forwardFromUserInfo = UserInfo(user: Self.reactor)
            parts.append("forward")
          }
          if variant & 4 != 0 {
            message.reactions = Self.reactions(1 + variant % 5, on: message)
            parts.append("\(message.reactions.count) reactions")
          }
          if message.message.out == true {
            message.message.status = [MessageSendingStatus.sent, .sending, .failed][variant % 3]
            parts.append("\(message.message.status.map { "\($0)" } ?? "")")
          }
          let category: UIContentSizeCategory = variant.isMultiple(of: 3) ? .accessibilityLarge : .large
          let groups: [(Bool, MessageLayoutInput.Avatar)] = message.message.out == true ? [(false, .none)] : [(false, .none), (true, .visible), (false, .reserved)]
          for (showsName, avatar) in groups {
            for width in [320, 375] as [CGFloat] {
              let label = "\(style == .dark ? "dark" : "light") \(name) [\(parts.joined(separator: ", "))] name=\(showsName) avatar=\(avatar) \(Int(width)) \(category.rawValue.suffix(6))"
              let view = MessageView()
              stage.root.addSubview(view)
              defer { view.removeFromSuperview() }
              let layout = stage.apply(message, to: view, width: width, motion: .immediate, category: category, showsName: showsName, avatar: avatar)
              view.layoutIfNeeded()
              checked += 1
              failures += Self.placementProblems(view, layout).map { "\(label): \($0)" }
              if !CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.5, dy: -0.5).contains(layout.bubble.frame) {
                failures.append("\(label): bubble \(layout.bubble.frame) outside the row \(layout.size)")
              }
              if showsName, let nameFrame = layout.frame(.name), nameFrame.intersects(layout.bubble.frame.insetBy(dx: 0, dy: 0.5)) {
                failures.append("\(label): name \(nameFrame) overlaps the bubble \(layout.bubble.frame)")
              }
              if layout.rich == nil, !(message.message.text ?? "").isEmpty, layout.frame(.text) != nil {
                failures += Self.inkProblems(view.textView, expectsInk: true).map { "\(label): \($0)" }
              }
            }
          }
        }
      }
    }
    Attachment.record("checked \(checked) combinations", named: "combinations.txt")
    #expect(checked > 1_000)
    #expect(failures.isEmpty, "\(failures.count) problems:\n\(failures.prefix(30).joined(separator: "\n"))")
  }

  /// Every kind on both sides, plus rich messages and plain text.
  static func everyKind() -> [(String, FullMessage)] {
    var entries: [(String, FullMessage)] = []
    for outgoing in [false, true] {
      let side = outgoing ? "out" : "in"
      entries += (kinds(outgoing: outgoing) + richKinds(outgoing: outgoing)).map { ("\($0.0) \(side)", $0.1) }
      entries.append(("text \(side)", message(outgoing ? 7_201 : 7_200, "Sounds good, see you tomorrow", outgoing: outgoing, reactions: 0)))
    }
    return entries
  }

  static func chunks<Element>(_ elements: [Element], _ size: Int) -> [[Element]] {
    stride(from: 0, to: elements.count, by: size).map { Array(elements[$0 ..< min($0 + size, elements.count)]) }
  }

  /// Views the next view lays out itself. Block hosts (which pin their hosted content), controls
  /// and UIKit's private views are skipped; placement checks cover their frames.
  static func ownedViews(of view: UIView) -> [UIView] {
    var result: [UIView] = [view]
    for sub in view.subviews where !String(describing: type(of: sub)).hasPrefix("_") {
      if sub is MessageBlockHostView || sub is UIControl { continue }
      result += ownedViews(of: sub)
    }
    return result
  }

  static func isOnScreen(_ view: UIView) -> Bool {
    var current: UIView? = view
    while let next = current {
      if next.isHidden || next.alpha < 0.01 { return false }
      current = next.superview
    }
    return view.window != nil
  }

  /// Every view's frame in the cell's space, keyed by identity.
  static func frames(in cell: UIView) -> [ObjectIdentifier: (kind: String, frame: CGRect)] {
    var result: [ObjectIdentifier: (kind: String, frame: CGRect)] = [:]
    for view in cell.subviews(of: UIView.self) where view.window != nil && !view.isHidden {
      // UIKit's own pieces, such as scroll indicators, come and go on their own schedule.
      let ancestors = sequence(first: view, next: \.superview).prefix(while: { $0 !== cell })
      if ancestors.contains(where: { String(describing: type(of: $0)).hasPrefix("_") }) { continue }
      var chain: [String] = []
      var current: UIView? = view
      while let next = current, next !== cell, chain.count < 4 {
        chain.append(String(describing: type(of: next)))
        current = next.superview
      }
      result[ObjectIdentifier(view)] = (chain.joined(separator: " < "), view.convert(view.bounds, to: cell))
    }
    return result
  }

  /// Milliseconds until the menu's views leave the screen and `isActive` turns false, or nil after 3 s.
  static func menuDismissal(baseline: Int, isActive: () -> Bool) async throws -> Int? {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < .seconds(3) {
      if menuArtifacts().count <= baseline, !isActive() {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }

  /// Visible views UIKit adds for a context menu: its container, platters, portals and previews.
  static func menuArtifacts() -> [String] {
    var found: [String] = []
    func visit(_ view: UIView, visible: Bool) {
      let shown = visible && !view.isHidden && view.alpha > 0.01
      let kind = String(describing: type(of: view))
      if shown, kind.hasPrefix("_UI") || kind == "MessageContextMenuPreviewView",
         ["ContextMenu", "Platter", "Portal", "PreviewView"].contains(where: kind.contains)
      {
        found.append(kind)
      }
      view.subviews.forEach { visit($0, visible: shown) }
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    windows.filter { !$0.isHidden }.forEach { visit($0, visible: true) }
    return found
  }

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
    if layout.rich == nil {
      check("text", container.convert(view.textView.textFrame, to: view), layout.frame(.text))
    } else if let rich = view.subviews(of: MessageRichView.self).first {
      check("rich", container.convert(rich.frame, to: view), layout.frame(.text))
    } else {
      problems.append("rich layout without a rich view")
    }
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

  /// Codex-style rich messages: block content with every block kind, and a plain message with
  /// a code fence.
  static func richKinds(outgoing: Bool, expanded: Bool = false) -> [(String, FullMessage)] {
    var text = ""
    func add(_ string: String) -> BlockText {
      let start = (text as NSString).length
      text += string + "\n"
      var range = BlockText()
      range.offset = Int64(start)
      range.length = Int64((string as NSString).length)
      return range
    }
    func block(_ kind: Block.OneOf_Kind) -> Block {
      var block = Block()
      block.kind = kind
      return block
    }
    var heading = BlockHeading()
    heading.level = 2
    heading.text = add("Plan for the release")
    let intro = add("Here's what changed since yesterday, and what's left before we ship it.")
    var list = BlockList()
    list.kind = .ordered
    for item in ["Fix the reaction pills", "Profile the list against the current view", "Port rich blocks"] {
      var listItem = BlockListItem()
      listItem.children = [block(.paragraph(add(item)))]
      list.items.append(listItem)
    }
    var code = BlockCode()
    code.language = "swift"
    code.text = add("let layout = MessageLayoutPlanner.layout(input, cache: cache)\nview.apply(content, layout: layout, motion: .standard)")
    var table = BlockTable()
    for row in [["Step", "Status"], ["Planner", "Done"], ["Views", "In progress"]] {
      var tableRow = BlockTableRow()
      tableRow.cells = row.map(add)
      table.rows.append(tableRow)
    }
    var quote = BlockQuote()
    quote.children = [block(.paragraph(add("Layout stability beats tail animation.")))]
    var disclosure = BlockDisclosure()
    disclosure.summary = add("Worked for 2m 14s")
    disclosure.kind = .progress
    disclosure.activityKind = .read
    disclosure.initiallyOpen = expanded
    disclosure.children = [block(.paragraph(add("Read 3 files and ran the package tests.")))]
    let closing = add("Shipping today.")
    var content = BlockContent()
    content.blocks = [
      block(.heading(heading)), block(.paragraph(intro)), block(.list(list)), block(.code(code)),
      block(.table(table)), block(.quote(quote)), block(.disclosure(disclosure)), block(.paragraph(closing)),
    ]
    var rich = Self.message(outgoing ? 7_101 : 7_102, text, outgoing: outgoing, reactions: 0)
    rich.message.blockContentPayload = BlockContentPayload(content)

    let fenceText = "Run this before you push:\nbun run typecheck && bun test\nThen ping me."
    let fence = (fenceText as NSString).range(of: "bun run typecheck && bun test")
    var entity = MessageEntity()
    entity.type = .pre
    entity.offset = Int64(fence.location)
    entity.length = Int64(fence.length)
    var pre = MessageEntity.MessageEntityPre()
    pre.language = "bash"
    entity.entity = .pre(pre)
    var entities = MessageEntities()
    entities.entities = [entity]
    var fenced = Self.message(outgoing ? 7_103 : 7_104, fenceText, outgoing: outgoing, reactions: 0)
    fenced.message.entities = entities
    return [("rich", rich), ("code fence", fenced)]
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
      category: UIContentSizeCategory = .large,
      showsName: Bool = false,
      avatar: MessageLayoutInput.Avatar = .none
    ) -> MessageLayout {
      let traits = root.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = category }
      let theme = ThemeManager.shared.snapshot(variant: style == .dark ? .dark : .light)
      let context = MessageRowContext(
        rowWidth: width,
        isFirstInGroup: true,
        isLastInGroup: true,
        showsName: showsName,
        avatar: avatar,
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
      anchor: FullMessage? = nil,
      customize: (Int, inout FullMessage) -> Void = { _, _ in }
    ) async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      controller.view.backgroundColor = .systemBackground
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
          threadAnchor: .resolved(anchor),
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

    /// A list of exactly `rows`, oldest first, each keeping a fresh list identity (message id = position).
    convenience init(rows: [FullMessage]) async throws {
      try await self.init(count: rows.count) { index, message in
        let identity = message.message
        message = rows[index - 1]
        message.message.messageId = identity.messageId
        message.message.globalId = identity.globalId
        message.message.chatId = identity.chatId
        message.message.peerUserId = identity.peerUserId
        message.message.date = identity.date
        message.reactions = message.reactions.map {
          var reaction = $0
          reaction.reaction.messageId = identity.messageId
          reaction.reaction.chatId = identity.chatId
          return reaction
        }
      }
    }

    var visibleCells: [MessageCollectionViewCell] {
      list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
    }

    /// Scrolls each message row to the middle in turn and hands over its cell.
    func eachRow(_ body: (MessageCollectionViewCell) async throws -> Void) async throws {
      for section in 0 ..< list.numberOfSections {
        for item in 0 ..< list.numberOfItems(inSection: section) {
          let path = IndexPath(item: item, section: section)
          list.scrollToItem(at: path, at: .centeredVertically, animated: false)
          list.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(80))
          guard let cell = list.cellForItem(at: path) as? MessageCollectionViewCell, cell.message != nil else { continue }
          try await body(cell)
        }
      }
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

/// Samples, every frame, UIKit's menu views and the row's bubble and pill as they appear on screen.
@MainActor private final class MenuFrameSampler: NSObject {
  struct Sample {
    let ms: Int
    let menu: [(kind: String, frame: CGRect, opacity: Float)]
    let bubble: CGRect?
    let bubbleShown: Bool
    let pillOpacity: Float?
  }

  private let window: UIWindow
  private let source: () -> (MessageView, MessageReactionPillView?)?
  private var link: CADisplayLink?
  private var startTime = CACurrentMediaTime()
  private(set) var samples: [Sample] = []

  init(window: UIWindow, source: @escaping () -> (MessageView, MessageReactionPillView?)?) {
    self.window = window
    self.source = source
  }

  func start() {
    startTime = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  private func screenFrame(_ layer: CALayer) -> (CGRect, Float)? {
    let shown = layer.presentation() ?? layer
    guard let windowLayer = layer.windowRoot?.presentation() ?? layer.windowRoot else { return nil }
    var opacity = shown.opacity
    var parent = shown.superlayer
    while let p = parent { opacity *= p.opacity; if p.isHidden { opacity = 0 }; parent = p.superlayer }
    if shown.isHidden { opacity = 0 }
    return (shown.convert(shown.bounds, to: windowLayer), opacity)
  }

  @objc private func tick() {
    let ms = Int((CACurrentMediaTime() - startTime) * 1_000)
    var menu: [(String, CGRect, Float)] = []
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    func visit(_ view: UIView) {
      let kind = String(describing: type(of: view))
      if kind == "MessageContextMenuPreviewView" || (kind.hasPrefix("_UI") && ["Portal", "PreviewPlatter", "MorphingPlatter"].contains(where: kind.contains)) {
        if let (frame, opacity) = screenFrame(view.layer) { menu.append((kind, frame, opacity)) }
      }
      view.subviews.forEach(visit)
    }
    windows.filter { !$0.isHidden }.forEach(visit)
    let row = source()
    let bubble = row.flatMap { screenFrame($0.0.bubbleContentView.layer) }
    let pill = row?.1.flatMap { screenFrame($0.layer) }
    samples.append(Sample(
      ms: ms, menu: menu.map { (kind: $0.0, frame: $0.1, opacity: $0.2) },
      bubble: bubble?.0, bubbleShown: (bubble?.1 ?? 0) > 0.01 && row?.0.bubbleContentView.isHidden == false,
      pillOpacity: pill?.1
    ))
  }

  /// When the row got its pill, when the source bubble came back (the menu began closing), and
  /// when the pill was fully shown on the visible bubble; milliseconds after `start()`.
  func summary() -> (text: String, pillAddedMs: Int?, bubbleBackMs: Int?, pillShownMs: Int?) {
    let added = samples.first { $0.pillOpacity != nil }?.ms
    let back = samples.first { $0.bubbleShown }?.ms
    let shown = samples.first { $0.bubbleShown && ($0.pillOpacity ?? 0) >= 0.95 }?.ms
    let menu = samples.last { $0.menu.contains { $0.opacity > 0.05 } }?.ms
    func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "never" }
    return (
      "pill added \(ms(added)), menu closing \(ms(back)), pill shown \(ms(shown)), menu views until \(ms(menu))",
      added, back, shown
    )
  }

}

private extension CALayer {
  var windowRoot: CALayer? {
    var layer: CALayer = self
    while let parent = layer.superlayer { layer = parent }
    return layer
  }
}

@MainActor private final class PlainMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
  func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: [UIAction(title: "Copy") { _ in }]) })
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

private extension UIView {
  func subviews<View: UIView>(of type: View.Type) -> [View] {
    subviews.flatMap { ($0 as? View).map { [$0] } ?? [] } + subviews.flatMap { $0.subviews(of: type) }
  }
}
