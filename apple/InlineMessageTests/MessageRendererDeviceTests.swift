@testable import InlineIOS
import InlineKit
import InlineProtocol
import InlineTheme
import Testing
import UIKit

@Suite("iOS message renderer on device", .serialized)
@MainActor
struct MessageRendererDeviceTests {
  @Test("Entity-only edits refresh a retained rich surface")
  func entityOnlyUpdate() throws {
    var full = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    full.message.text = "Read guide"
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [.with { $0.paragraph.length = 10 }]
    }))
    var link = MessageEntity.with {
      $0.type = .textURL
      $0.offset = 5
      $0.length = 5
      $0.textURL.url = "https://example.com/one"
    }
    full.message.entities = .with { $0.entities = [link] }
    let view = UIMessageView2(
      fullMessage: full, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    func layout() {
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      view.layoutIfNeeded()
    }
    layout()
    let surface = try #require(visibleTextViews(in: view).first)
    #expect((surface.attributedText.attribute(.link, at: 5, effectiveRange: nil) as? URL)?.absoluteString == link
      .textURL.url)
    link.textURL.url = "https://example.com/two"
    full.message.entities = .with { $0.entities = [link] }
    view.applySnapshot(full)
    layout()
    #expect(visibleTextViews(in: view).first === surface)
    #expect((surface.attributedText.attribute(.link, at: 5, effectiveRange: nil) as? URL)?.absoluteString == link
      .textURL.url)
    full.message.entities = nil
    view.applySnapshot(full)
    layout()
    #expect(surface.attributedText.attribute(.link, at: 5, effectiveRange: nil) == nil)
    #expect(surface.superview?.accessibilityCustomActions?.isEmpty != false)
    view.cancelPendingGeometryTransitions()
  }

  @Test("Rich planning binds only the visible text projection, including fallback")
  func visibleTextProjection() throws {
    let scenario = try #require(MessageView2PlaygroundFixtures.scenarios.first { $0.id == 10_006 })
    var full = scenario.message
    let view = UIMessageView2(
      fullMessage: full, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    func layout() {
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      view.layoutIfNeeded()
    }
    layout()
    #expect(view.messageLabel.textStorage.length == 0)
    #expect(view.messageLabel.alpha == 0)

    full.message.blockContentPayload = nil
    full.message.text = "سلام، این متن باید در اولین نمایش دیده شود.\n"
    view.applySnapshot(full)
    layout()
    #expect(view.messageLabel.text == full.message.text)
    #expect(view.messageLabel.alpha == 1)
    assertGlyphsFit(view.messageLabel, fixtureID: scenario.id)
    let edits = TextStorageEdits()
    view.messageLabel.textStorage.delegate = edits
    full.message.editDate = full.message.date.addingTimeInterval(1)
    view.applySnapshot(full)
    layout()
    #expect(edits.count == 0)
    view.messageLabel.textStorage.delegate = nil

    // A malformed range is representable in the payload but rejected by the
    // bounded planner. Its canonical text must be ready in that same layout.
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [.with { $0.paragraph.offset = 99_999
        $0.paragraph.length = 10
      }]
    }))
    view.applySnapshot(full)
    layout()
    #expect(view.messageLabel.text == full.message.text)
    #expect(view.messageLabel.alpha == 1)
    assertGlyphsFit(view.messageLabel, fixtureID: scenario.id)

    full.message.text = scenario.message.message.text
    full.message.blockContentPayload = scenario.message.message.blockContentPayload
    view.applySnapshot(full)
    layout()
    #expect(view.messageLabel.textStorage.length == 0)
    #expect(view.messageLabel.alpha == 0)
    #expect(!visibleTextViews(in: view).isEmpty)
    view.cancelPendingGeometryTransitions()
  }

  @Test("Larger Dynamic Type renders every catalog text surface", arguments: [
    UIContentSizeCategory.extraExtraExtraLarge,
    .accessibilityExtraExtraExtraLarge,
  ])
  func dynamicTypeCatalog(category: UIContentSizeCategory) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    controller.traitOverrides.preferredContentSizeCategory = category
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    for scenario in MessageView2PlaygroundFixtures.scenarios {
      let view = UIMessageView2(
        fullMessage: scenario.message, spaceId: 9_001, displayMode: .normal,
        bubbleTailSide: scenario.outgoing ? .trailing : .leading,
        maximumBubbleContentWidth: 297.5,
        theme: ThemeManager.shared.snapshot(variant: .light)
      )
      controller.view.addSubview(view)
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      view.layoutIfNeeded()
      #expect(view.traitCollection.preferredContentSizeCategory == category)
      for text in visibleTextViews(in: view) {
        assertGlyphsFit(text, fixtureID: scenario.id)
      }
      view.cancelPendingGeometryTransitions()
      view.removeFromSuperview()
    }
  }

  @Test("Catalog renders without clipping native text", arguments: [false, true])
  func renderedCatalog(dark: Bool) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.isHidden = false
    defer { window.isHidden = true }
    let width: CGFloat = 350
    var timings: [String] = []

    for scenario in MessageView2PlaygroundFixtures.scenarios {
      let start = CACurrentMediaTime()
      let view = UIMessageView2(
        fullMessage: scenario.message,
        spaceId: 9_001,
        displayMode: .normal,
        bubbleTailSide: scenario.outgoing ? .trailing : .leading,
        maximumBubbleContentWidth: width * 0.85,
        theme: ThemeManager.shared.snapshot(variant: dark ? .dark : .light)
      )
      controller.view.addSubview(view)
      var size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      #expect(size.height.isFinite && size.height > 0)
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutIfNeeded()
      timings.append("fixture \(scenario.id) create/measure/layout ms: \((CACurrentMediaTime() - start) * 1_000)")

      for textView in visibleTextViews(in: view) {
        assertGlyphsFit(textView, fixtureID: scenario.id)
      }

      // Let bounded code/math preparation resolve before recording the fixture.
      try await Task.sleep(for: .milliseconds(150))
      size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      view.frame.size = size
      view.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        (dark ? UIColor.black : UIColor.white).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        view.layer.render(in: context.cgContext)
      }
      try Attachment.record(
        Array(#require(image.pngData())),
        named: "message-v2-\(scenario.id)-\(dark ? "dark" : "light").png"
      )
      view.cancelPendingGeometryTransitions()
      view.removeFromSuperview()
    }
    Attachment.record(timings.joined(separator: "\n"), named: "message-v2-layout-timings.txt")
  }

  @Test("A streaming update retargets from visible bubble geometry")
  func interruptedStreaming() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.isHidden = false
    defer { window.isHidden = true }
    let scenario = try #require(MessageView2PlaygroundFixtures.scenarios.first)
    let view = UIMessageView2(
      fullMessage: scenario.message, spaceId: 9_001, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    try #require(window.rootViewController).view.addSubview(view)
    view.frame = CGRect(
      origin: .zero,
      size: view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    )
    view.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(30))

    var animator: UIViewPropertyAnimator?
    var retargetedHeight: CGFloat?
    view.onGeometryChange = { old, next in
      let generation = view.geometryTransitionGeneration
      view.prepareGeometryTransition(from: old, generation: generation)
      if let animator {
        animator.stopAnimation(false)
        animator.finishAnimation(at: .current)
        retargetedHeight = view.bubbleView.bounds.height
      }
      let nextAnimator = UIViewPropertyAnimator(duration: 0.4, curve: .linear) {
        view.frame.size = next.size
        view.applyGeometryTransition(to: next, generation: generation)
        view.layoutIfNeeded()
      }
      nextAnimator.addCompletion { _ in view.finishGeometryTransition(generation: generation) }
      animator = nextAnimator
      nextAnimator.startAnimation()
    }
    defer {
      if animator?.state == .active { animator?.stopAnimation(true) }
      view.onGeometryChange = nil
      view.cancelPendingGeometryTransitions()
    }

    var next = scenario.message
    next.message.text = String(repeating: "Streaming text fills another line. ", count: 12)
    view.applySnapshot(next)
    try await Task.sleep(for: .milliseconds(100))
    let visibleHeight = try #require(view.bubbleView.layer.presentation()).bounds.height
    next.message.text = String(repeating: "A second update adds content. ", count: 20)
    view.applySnapshot(next)
    #expect(try abs(#require(retargetedHeight) - visibleHeight) <= 2)
    try await Task.sleep(for: .milliseconds(500))
    let final = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    #expect(abs(view.bounds.height - final.height) <= 1)
    #expect(view.bubbleView.layer.animationKeys()?.isEmpty != false)
  }

  @Test("Retained rich updates provide a physical-device profiling workload")
  func retainedRichUpdates() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let scenarios = MessageView2PlaygroundFixtures.scenarios.filter {
      [10_001, 10_005, 10_006, 10_007, 10_009, 10_010, 10_011, 10_012].contains($0.id)
    }
    let first = try #require(scenarios.first)
    let view = UIMessageView2(
      fullMessage: first.message, spaceId: 9_001, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    controller.view.addSubview(view)
    view.frame = CGRect(x: 0, y: 60, width: 350, height: 400)
    view.layoutIfNeeded()
    defer { view.cancelPendingGeometryTransitions() }
    var timings: [String] = []
    for iteration in 0 ..< 240 {
      var next = scenarios[iteration % scenarios.count].message
      next.message.globalId = first.message.id
      next.message.messageId = first.message.message.messageId
      let start = CACurrentMediaTime()
      view.applySnapshot(next)
      let bound = CACurrentMediaTime()
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      let measured = CACurrentMediaTime()
      view.layoutIfNeeded()
      let laidOut = CACurrentMediaTime()
      timings
        .append(
          "\(iteration),\(scenarios[iteration % scenarios.count].id),\((laidOut - start) * 1_000),\((bound - start) * 1_000),\((measured - bound) * 1_000),\((laidOut - measured) * 1_000)"
        )
      #expect(view.bounds.height.isFinite && view.bounds.height > 0)
      try await Task.sleep(for: .milliseconds(125))
    }
    Attachment.record(timings.joined(separator: "\n"), named: "message-v2-retained-update-ms.csv")
  }

  @Test("Metadata updates retain rich text storage")
  func metadataUpdates() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let scenario = try #require(MessageView2PlaygroundFixtures.scenarios.first { $0.id == 10_006 })
    let view = UIMessageView2(
      fullMessage: scenario.message, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    controller.view.addSubview(view)
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    view.layoutIfNeeded()
    let surfaces = visibleTextViews(in: view)
    let edits = TextStorageEdits()
    for text in surfaces {
      text.textStorage.delegate = edits
    }
    defer {
      for text in surfaces {
        text.textStorage.delegate = nil
      }
      view.cancelPendingGeometryTransitions()
    }
    var durations: [Double] = []
    for iteration in 0 ..< 40 {
      var next = scenario.message
      next.message.editDate = scenario.message.message.date.addingTimeInterval(Double(iteration + 1))
      let start = CACurrentMediaTime()
      view.applySnapshot(next)
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      view.layoutIfNeeded()
      durations.append((CACurrentMediaTime() - start) * 1_000)
    }
    #expect(edits.count == 0)
    #expect(visibleTextViews(in: view).map(ObjectIdentifier.init) == surfaces.map(ObjectIdentifier.init))
    Attachment.record(
      durations.map(String.init(describing:)).joined(separator: "\n"),
      named: "message-v2-metadata-update-ms.txt"
    )
  }

  @Test("Streaming a paragraph retains an unchanged rich prefix", arguments: [false, true])
  func incrementalRichStreaming(arabicPrefix: Bool) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let scenario = try #require(MessageView2PlaygroundFixtures.scenarios.first { $0.id == 10_006 })
    var template = scenario.message
    if arabicPrefix {
      // Replace ASCII letters one-for-one, preserving every canonical block
      // range while exercising UIKit's fallback-font attribute normalization.
      template.message.text = template.message.text?.map { $0.isLetter ? "ا" : String($0) }.joined()
    }
    let prefix = try #require(template.message.text) + "\n"
    let content = try #require(template.message.blockContentPayload).content
    let view = UIMessageView2(
      fullMessage: template, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    controller.view.addSubview(view)
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    view.layoutIfNeeded()
    let prefixSurfaces = visibleTextViews(in: view)
    let edits = TextStorageEdits()
    for text in prefixSurfaces {
      text.textStorage.delegate = edits
    }
    defer {
      for text in prefixSurfaces {
        text.textStorage.delegate = nil
      }
      view.cancelPendingGeometryTransitions()
    }
    var durations: [Double] = []
    let iterations = ProcessInfo.processInfo.arguments.contains("--message-v2-stream-profile") ? 240 : 60
    for iteration in 1 ... iterations {
      let suffix = String(repeating: "Text arrives in small pieces. ", count: iteration)
      var next = template
      next.message.text = prefix + suffix
      var blocks = content
      blocks.blocks.append(.with {
        $0.paragraph.offset = Int64(prefix.utf16.count)
        $0.paragraph.length = Int64(suffix.utf16.count)
      })
      next.message.blockContentPayload = try #require(BlockContentPayload(blocks))
      let start = CACurrentMediaTime()
      view.applySnapshot(next)
      view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
      view.layoutIfNeeded()
      durations.append((CACurrentMediaTime() - start) * 1_000)
      let surfaces = visibleTextViews(in: view)
      #expect(view.messageLabel.textStorage.length == 0)
      if iteration == 1, let text = surfaces.last {
        Attachment.record(
          "bounds=\(text.bounds), container=\(text.textContainer.size), widthTracks=\(text.textContainer.widthTracksTextView), heightTracks=\(text.textContainer.heightTracksTextView)",
          named: "message-v2-text-container.txt"
        )
      }
      #expect(surfaces.prefix(prefixSurfaces.count).map(ObjectIdentifier.init) == prefixSurfaces
        .map(ObjectIdentifier.init))
      for text in surfaces {
        assertGlyphsFit(text, fixtureID: scenario.id)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(edits.count == 0, "Appending text rewrote unchanged rich prefix storage \(edits.count) times")
    Attachment.record(
      durations.map(String.init(describing:)).joined(separator: "\n"),
      named: "message-v2-incremental-stream-\(arabicPrefix ? "arabic" : "latin")-ms.txt"
    )
  }

  private final class TextStorageEdits: NSObject, NSTextStorageDelegate {
    var count = 0
    func textStorage(
      _ textStorage: NSTextStorage,
      didProcessEditing editedMask: NSTextStorage.EditActions,
      range editedRange: NSRange,
      changeInLength delta: Int
    ) {
      count += 1
    }
  }

  private func visibleTextViews(in view: UIView) -> [UITextView] {
    guard !view.isHidden, view.alpha > 0.01 else { return [] }
    if let text = view as? UITextView { return [text] }
    return view.subviews.flatMap { visibleTextViews(in: $0) }
  }

  private func assertGlyphsFit(_ text: UITextView, fixtureID: Int64) {
    if text is CodeBlockTextView, !text.isSelectable {
      #expect(!text.panGestureRecognizer.isEnabled)
      #expect(!text.scrollsToTop)
    }
    let manager = text.layoutManager
    let container = text.textContainer
    manager.ensureLayout(for: container)
    var height = manager.usedRect(for: container).maxY
    if manager.extraLineFragmentTextContainer === container {
      height = max(height, manager.extraLineFragmentRect.maxY)
    }
    #expect(manager.glyphRange(for: container).length == manager.numberOfGlyphs)
    #expect(
      height <= text.bounds.height + 1,
      "Fixture \(fixtureID): \(text.text.prefix(80)), glyph height \(height), bounds \(text.bounds)"
    )
  }
}
