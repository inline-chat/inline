@testable import InlineIOS
@testable import InlineKit
import InlineTheme
import Testing
import UIKit
import Vision

@Suite("Message context-menu keyboard lifecycle", .serialized)
@MainActor
struct ContextMenuKeyboardTests {
  @Test("More reactions opens immediately over the live menu and can reopen after dismissal")
  func reactionSheetKeepsNativeMenu() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    fixture.window.makeKeyAndVisible()
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    cell.updateMessageHoldAction(.reactionsMenu)
    let source = try #require(cell.messageView?.bubbleView)
    let rect = source.convert(source.bounds, to: list).intersection(list.bounds)
    let interaction = try #require(list.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
    let selector = NSSelectorFromString("_presentMenuAtLocation:")
    let method = try #require(class_getInstanceMethod(type(of: interaction), selector))
    typealias PresentMenu = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    let present = unsafeBitCast(method_getImplementation(method), to: PresentMenu.self)
    present(interaction, selector, CGPoint(x: rect.midX, y: rect.midY))
    defer { interaction.dismissMenu() }
    try await Task.sleep(for: .seconds(1))
    #expect(list.isContextMenuInteractionActive)
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    let plus = try #require(descendants(fixture.window).compactMap { $0 as? UIButton }.first {
      $0.accessibilityIdentifier == "moreReactions"
    })
    let scene = try #require(fixture.window.windowScene)
    let originalWindows = Set(scene.windows.map(ObjectIdentifier.init))
    var menuDismissals = 0
    list.onContextMenuDidEnd = { menuDismissals += 1 }
    defer { list.onContextMenuDidEnd = nil }

    for attempt in 0 ..< 2 {
      let start = CACurrentMediaTime()
      plus.sendActions(for: .touchUpInside)
      let presentationMilliseconds = (CACurrentMediaTime() - start) * 1_000
      // Presentation must start in this event, without waiting for the menu's
      // dismissal animation or a delayed dispatch to the main queue.
      let overlay = try #require(scene.windows.first {
        !originalWindows.contains(ObjectIdentifier($0)) && !$0.isHidden
      })
      defer { overlay.isHidden = true }
      let presenter = try #require(overlay.rootViewController)
      let sheet = try #require(presenter.presentedViewController)
      Attachment.record(
        "Tap to presentation request: \(presentationMilliseconds) ms (excludes the native sheet animation).",
        named: "reaction-sheet-presentation-\(attempt).txt"
      )
      #expect(sheet.sheetPresentationController != nil)
      #expect(list.isContextMenuInteractionActive)
      #expect(menuDismissals == 0)
      try await Task.sleep(for: .seconds(1))
      if attempt == 0 {
        let image = UIGraphicsImageRenderer(size: fixture.window.bounds.size).image { _ in
          fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
          overlay.drawHierarchy(in: overlay.bounds, afterScreenUpdates: false)
        }
        Attachment.record(Array(try #require(image.pngData())), named: "reaction-sheet-over-menu.png")
      }
      #expect(overlay.isKeyWindow)
      let search = try #require(descendants(sheet.view).compactMap { $0 as? UISearchTextField }.first)
      #expect(search.becomeFirstResponder())
      try await Task.sleep(for: .milliseconds(400))
      #expect(list.isContextMenuInteractionActive)
      #expect(menuDismissals == 0)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        presenter.dismiss(animated: false) { continuation.resume() }
      }
      #expect(overlay.isHidden)
      #expect(overlay.rootViewController == nil)
      #expect(fixture.window.isKeyWindow)
      #expect(list.isContextMenuInteractionActive)
      #expect(menuDismissals == 0)
    }
  }

  @Test("Native menu displays the bubble before and after arrivals", arguments: [false, true], [false, true])
  func nativePresentation(outgoing: Bool, usesV2: Bool) async throws {
    try await checkNativePresentation(outgoing: outgoing, usesV2: usesV2)
  }

  @Test("Long messages retain the full image in the shaped native preview", arguments: [false, true])
  func longNativePresentation(usesV2: Bool) async throws {
    try await checkNativePresentation(outgoing: true, usesV2: usesV2, repetitions: 60)
  }

  private func checkNativePresentation(outgoing: Bool, usesV2: Bool, repetitions: Int = 3) async throws {
    let fixture = try await Fixture(usesV2: usesV2, outgoing: outgoing, repetitions: repetitions)
    defer { fixture.close() }
    fixture.window.makeKeyAndVisible()
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    cell.updateMessageHoldAction(.reactionsMenu)
    let source = try #require(cell.messageView?.bubbleView)
    cell.messageView?.updateBubbleTail(side: outgoing ? .trailing : .leading, animated: false)
    let expectedBubblePath = source.visiblePath().cgPath
    let visibleRect = source.convert(source.bounds, to: list).intersection(list.bounds)
    let point = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
    let interaction = try #require(list.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
    let selector = NSSelectorFromString("_presentMenuAtLocation:")
    let method = try #require(class_getInstanceMethod(type(of: interaction), selector))
    typealias PresentMenu = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    let present = unsafeBitCast(method_getImplementation(method), to: PresentMenu.self)
    let opening = OpeningPreviewObserver(window: fixture.window)
    let displayLink = CADisplayLink(target: opening, selector: #selector(OpeningPreviewObserver.tick))
    displayLink.add(to: .main, forMode: .common)
    defer { displayLink.invalidate() }
    present(interaction, selector, point)
    try await Task.sleep(for: .seconds(1))
    displayLink.invalidate()
    #expect(!opening.frames.isEmpty)
    for frame in opening.frames {
      #expect(frame.unmasked)
      let visiblePath = try #require(frame.visiblePath)
      let displayedPath = try #require(frame.displayedPath)
      // A rounded rectangle has no tail subpath. Inspect every opening frame,
      // including the presentation layer while UIKit's animation is running.
      let expected = normalizedElements(expectedBubblePath)
      for path in [visiblePath, displayedPath] {
        let displayed = normalizedElements(path)
        #expect(displayed.count == expected.count)
        for (actual, target) in zip(displayed, expected) {
          #expect(actual.0 == target.0)
          for (point, expectedPoint) in zip(actual.1, target.1) {
            #expect(abs(point.x - expectedPoint.x) < 0.001)
            #expect(abs(point.y - expectedPoint.y) < 0.001)
          }
        }
      }
    }
    #expect(list.isContextMenuInteractionActive)
    #expect(source.isHidden)
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    let platter = try #require(descendants(fixture.window).first {
      String(describing: type(of: $0)) == "_UIContentPlatterView"
    })
    let expanded = try #require(platter.value(forKey: "expandedPreview") as? UITargetedPreview)
    #expect(expanded.value(forKey: "prefersUnmaskedPlatterStyle") as? Bool == true)
    let mask = try #require(expanded.parameters.visiblePath)
    #expect(mask.bounds.width > 0)
    if repetitions > 3 {
      let image = try #require((expanded.view as? UIImageView)?.image)
      #expect(image.size.height > fixture.window.bounds.height)
    }
    #expect(expanded.view.bounds.contains(mask.bounds))
    // Check UIKit's rendered mask before any snapshot or gesture can refresh it.
    let shapeLayer = try #require(platter.value(forKey: "shapeLayer") as? CAShapeLayer)
    let renderedPath = try #require(shapeLayer.path)
    // UIKit fits the outline into pixel-rounded platter bounds. Compare the
    // normalized segments so that rounding cannot hide a missing tail or mask.
    func normalizedElements(_ path: CGPath) -> [(CGPathElementType, [CGPoint])] {
      let bounds = path.boundingBoxOfPath
      var elements: [(CGPathElementType, [CGPoint])] = []
      path.applyWithBlock { pointer in
        let element = pointer.pointee
        let count: Int
        switch element.type {
        case .moveToPoint, .addLineToPoint: count = 1
        case .addQuadCurveToPoint: count = 2
        case .addCurveToPoint: count = 3
        case .closeSubpath: count = 0
        @unknown default: count = 0
        }
        let points = (0 ..< count).map { index in
          CGPoint(
            x: (element.points[index].x - bounds.minX) / bounds.width,
            y: (element.points[index].y - bounds.minY) / bounds.height
          )
        }
        elements.append((element.type, points))
      }
      return elements
    }
    let renderedElements = normalizedElements(renderedPath)
    let expectedElements = normalizedElements(mask.cgPath)
    #expect(renderedElements.count == expectedElements.count)
    for (rendered, expected) in zip(renderedElements, expectedElements) {
      #expect(rendered.0 == expected.0)
      for (actual, target) in zip(rendered.1, expected.1) {
        #expect(abs(actual.x - target.x) < 0.000_001)
        #expect(abs(actual.y - target.y) < 0.000_001)
      }
    }
    func capture(_ label: String) async throws {
      // The native preview uses a render-server replica. Capture the window,
      // then crop it; drawing the platter by itself cannot render that replica.
      // Hide list pixels so OCR cannot mistake the original cell for the preview.
      let opacity = list.layer.opacity
      list.layer.opacity = 0
      defer { list.layer.opacity = opacity }
      // Let the render server hide the list before capturing its pixels. The
      // opening-frame assertions above run before this extra render transaction.
      try await Task.sleep(for: .milliseconds(50))
      let screen = UIGraphicsImageRenderer(size: fixture.window.bounds.size).image { _ in
        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
      }
      let rect = platter.convert(platter.bounds, to: fixture.window)
        .applying(CGAffineTransform(scaleX: screen.scale, y: screen.scale))
      let pixels = try #require(screen.cgImage?.cropping(to: rect))
      let image = UIImage(cgImage: pixels, scale: screen.scale, orientation: .up)
      Attachment.record(Array(try #require(image.pngData())), named: "platter-\(outgoing)-\(usesV2)-\(label).png")
      let recognition = VNRecognizeTextRequest()
      recognition.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: pixels).perform([recognition])
      let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
      #expect(text.contains("Keyboard lifecycle regression"))
      Attachment.record(Array(try #require(screen.pngData())), named: "menu-\(outgoing)-\(usesV2)-\(label).png")
    }
    try await capture("before")
    let count = fixture.displayedMessageCount
    _ = try fixture.addMessage(id: 31)
    try await fixture.settleUpdates()
    #expect(fixture.displayedMessageCount == count + 1)
    #expect(list.isContextMenuInteractionActive)
    try await capture("after")
    interaction.dismissMenu()
    // Wait for UIKit's completion rather than assuming a fixed spring duration.
    for _ in 0 ..< 60 {
      if !list.isContextMenuInteractionActive { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!list.isContextMenuInteractionActive)
    // Arrivals can replace or move the original cell offscreen. Validate the
    // live rows; retained offscreen cells reset on redisplay or reuse.
    for case let visibleCell as MessageCollectionViewCell in list.visibleCells {
      #expect(!visibleCell.isContextMenuSourceHidden)
      #expect(visibleCell.messageView?.bubbleView.isHidden == false)
    }
  }

  @Test("Expanded preview shaping leaves ordinary previews unchanged")
  func leavesOrdinaryPreviewsUnchanged() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
    let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
      UIColor.systemBlue.setFill()
      context.fill(bounds)
    }
    _ = MessageContextMenuPreviewView(image: image, visiblePath: UIBezierPath(rect: bounds))
    let platterType = try #require(NSClassFromString("_UIContentPlatterView") as? UIView.Type)
    let platter = platterType.init()
    let preview = UITargetedPreview(
      view: UIImageView(image: image),
      parameters: UIPreviewParameters(),
      target: UIPreviewTarget(container: fixture.window, center: fixture.window.center)
    )
    platter.setValue(preview, forKey: "expandedPreview")
    #expect((platter.value(forKey: "expandedPreview") as? UITargetedPreview) === preview)
    platter.setValue(nil, forKey: "expandedPreview")
    #expect(platter.value(forKey: "expandedPreview") == nil)
  }

  @MainActor
  private final class OpeningPreviewObserver: NSObject {
    struct Frame {
      let unmasked: Bool
      let visiblePath: CGPath?
      let displayedPath: CGPath?
    }

    weak var window: UIWindow?
    var frames: [Frame] = []

    init(window: UIWindow) {
      self.window = window
    }

    @objc func tick() {
      guard let window else { return }
      func findPlatter(_ view: UIView) -> UIView? {
        if String(describing: type(of: view)) == "_UIContentPlatterView" { return view }
        return view.subviews.lazy.compactMap(findPlatter).first
      }
      guard let platter = findPlatter(window),
            let expanded = platter.value(forKey: "expandedPreview") as? UITargetedPreview,
            let layer = platter.value(forKey: "shapeLayer") as? CAShapeLayer,
            !layer.bounds.isEmpty else { return }
      frames.append(Frame(
        unmasked: expanded.value(forKey: "prefersUnmaskedPlatterStyle") as? Bool == true,
        visiblePath: expanded.parameters.visiblePath?.cgPath,
        displayedPath: (layer.presentation() ?? layer).path
      ))
    }
  }

  @Test("The preview preserves both tails without a rounded rectangular mask", arguments: [false, true])
  func preservesTailExtent(outgoing: Bool) async throws {
    let fixture = try await Fixture(outgoing: outgoing)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    let source = try #require(cell.messageView?.bubbleView)
    let side: MessageBubbleTailSide = outgoing ? .trailing : .leading
    cell.messageView?.updateBubbleTail(side: side, animated: false)
    source.layoutIfNeeded()
    let path = source.visiblePath()
    let extent = source.bounds.union(path.bounds)
    let configuration = fixture.beginMenu()
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    let bitmap = try #require((preview.view as? UIImageView)?.image)
    let visiblePath = try #require(preview.parameters.visiblePath)
    #expect(preview.view.bounds.width >= extent.width)
    #expect(preview.view.bounds.height >= extent.height)
    #expect(preview.view.bounds.width - extent.width < 1 / fixture.window.screen.scale + 0.001)
    #expect(preview.view.bounds.height - extent.height < 1 / fixture.window.screen.scale + 0.001)
    #expect(preview.view.bounds.contains(visiblePath.bounds))
    #expect(bitmap.size == preview.view.bounds.size)
    #expect(preview.value(forKey: "prefersUnmaskedPlatterStyle") as? Bool == true)
    Attachment.record(Array(try #require(bitmap.pngData())), named: outgoing ? "trailing-tail.png" : "leading-tail.png")
    fixture.endMenu(configuration, animator: nil)
  }

  @Test("Menu captures visible pixels before UIKit hides the source", arguments: [false, true])
  func capturesBeforeHighlight(usesV2: Bool) async throws {
    let fixture = try await Fixture(usesV2: usesV2)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    cell.updateMessageHoldAction(.reactionsMenu)
    let source = try #require(cell.messageView?.bubbleView)
    let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: list)
    let configuration = try #require(list.delegate?.collectionView?(
      list, contextMenuConfigurationForItemsAt: [indexPath], point: point
    ))
    // UIKit may suppress the source while preparing the lifted presentation.
    // Capture must already exist; producing PNG data alone does not prove pixels.
    let wasHidden = source.isHidden
    source.isHidden = true
    defer { source.isHidden = wasHidden }
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    let image = try #require((preview.view as? UIImageView)?.image)
    let sample = try #require(image.sendAnimationVisibleAlphaSample())
    #expect(sample.coverage > 0.1)
    #expect(preview.view !== source)
    list.delegate?.collectionView?(list, willDisplayContextMenu: configuration, animator: nil)
    fixture.endMenu(configuration, animator: nil)
  }

  @Test("Native lift uses the touched bubble and restores it with dismissal", arguments: [false, true])
  func highlightsTouchedBubble(usesV2: Bool) async throws {
    let fixture = try await Fixture(usesV2: usesV2)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    cell.updateMessageHoldAction(.reactionsMenu)
    let bubble = try #require(cell.messageView?.bubbleView)
    let point = bubble.convert(CGPoint(x: bubble.bounds.midX, y: bubble.bounds.midY), to: list)
    let configuration = try #require(list.delegate?.collectionView?(
      list, contextMenuConfigurationForItemsAt: [indexPath], point: point
    ))
    let highlight = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    #expect(highlight.view === bubble)
    #expect(highlight.view.window === fixture.window)
    #expect(!bubble.isHidden)
    list.delegate?.collectionView?(list, willDisplayContextMenu: configuration, animator: nil)
    let dismissal = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, dismissalPreviewForItemAt: indexPath
    ))
    #expect(dismissal.view === bubble)
    #expect(!bubble.isHidden)
    let animator = MenuAnimator()
    fixture.endMenu(configuration, animator: animator)
    #expect(!bubble.isHidden)
    animator.animate()
    // The source must be back while UIKit finishes the interaction; waiting
    // for completion leaves a visible hole after the menu has disappeared.
    #expect(!bubble.isHidden)
    #expect(list.isContextMenuInteractionActive)
    animator.complete()
    #expect(!bubble.isHidden)
  }

  @Test("Arrivals remain visible while the menu snapshot stays intact", arguments: [false, true], [false, true])
  func arrivalsWhileHoldingMenu(animated: Bool, usesV2: Bool) async throws {
    let fixture = try await Fixture(usesV2: usesV2)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    let renderer = try #require(cell.messageView)
    let messageID = try #require(cell.message?.id)
    let originalCount = fixture.displayedMessageCount
    let configuration = fixture.beginMenu()
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    #expect(preview.view !== renderer.bubbleView)
    let imageView = try #require(preview.view as? UIImageView)
    let originalImage = try #require(imageView.image?.pngData())
    let pixels = try #require(imageView.image?.sendAnimationVisibleAlphaSample())
    #expect(pixels.visible > 0)
    #expect(renderer.bubbleView.isHidden)

    let first = try fixture.addMessage(id: 31)
    try await fixture.settleUpdates()
    #expect(fixture.model.messagesByID[first.id] != nil)
    #expect(fixture.displayedMessageCount == originalCount + 1)
    #expect(list.visibleCells.contains { ($0 as? MessageCollectionViewCell)?.message?.id == first.id })
    #expect(imageView.image?.pngData() == originalImage)
    let repeatedPreview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    #expect(repeatedPreview.view === preview.view)

    let currentCell = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .first { $0.message?.id == messageID })
    let currentBubble = try #require(currentCell.messageView?.bubbleView)
    #expect(currentBubble.isHidden)
    let arrivingCell = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .first { $0.message?.id == first.id })
    #expect(arrivingCell.messageView?.bubbleView.isHidden == false)
    let dismissal = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, dismissalPreviewForItemAt: indexPath
    ))
    #expect(dismissal.view === currentBubble)
    let expectedCenter = currentBubble.convert(
      CGPoint(x: currentBubble.bounds.midX, y: currentBubble.bounds.midY), to: fixture.window
    )
    #expect(abs(dismissal.target.center.x - expectedCenter.x) <= 1 / fixture.window.screen.scale)
    #expect(abs(dismissal.target.center.y - expectedCenter.y) <= 1 / fixture.window.screen.scale)

    let animator = animated ? MenuAnimator() : nil
    fixture.endMenu(configuration, animator: animator)
    animator?.animate()
    if animated {
      #expect(!currentBubble.isHidden)
      // A new day exercises section changes during dismissal too.
      _ = try fixture.addMessage(id: 32, nextDay: true)
      try await fixture.settleUpdates()
      #expect(fixture.displayedMessageCount == originalCount + 2)
      #expect(imageView.image?.pngData() == originalImage)
    }
    animator?.complete()
    try await fixture.settleUpdates()
    #expect(fixture.displayedMessageCount == originalCount + (animated ? 2 : 1))
    #expect(!list.isContextMenuInteractionActive)
    let restoredCell = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .first { $0.message?.id == messageID })
    #expect(restoredCell.messageView?.bubbleView.isHidden == false)
  }

  @Test("A stale dismissal cannot discard the reopened menu snapshot")
  func liveUpdatesAcrossReopen() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    var edited = try #require(cell.message)
    let originalCount = fixture.displayedMessageCount
    let old = fixture.beginMenu()
    _ = list.delegate?.collectionView?(
      list, contextMenuConfiguration: old, highlightPreviewForItemAt: indexPath
    )
    let animator = MenuAnimator()
    fixture.endMenu(old, animator: animator)
    let current = fixture.beginMenu()
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: current, highlightPreviewForItemAt: indexPath
    ))
    let imageView = try #require(preview.view as? UIImageView)
    let originalImage = try #require(imageView.image?.pngData())
    let pixels = try #require(imageView.image?.sendAnimationVisibleAlphaSample())
    #expect(pixels.visible > 0)
    let inserted = try fixture.addMessage(id: 31)
    edited.message.text = "Updated while the menu is open."
    fixture.publisher.publisher.send(.update(.init(message: edited, animated: true, peer: fixture.peer)))
    try await fixture.settleUpdates()
    fixture.publisher.publisher.send(.delete(.init(messageIds: [inserted.message.messageId], peer: fixture.peer)))
    try await fixture.settleUpdates()
    animator.animate()
    animator.complete()
    #expect(list.isContextMenuInteractionActive)
    #expect(fixture.displayedMessageCount == originalCount)
    #expect(fixture.model.messagesByID[inserted.id] == nil)
    let updatedCell = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .first { $0.message?.id == edited.id })
    #expect(updatedCell.messageView?.fullMessage.displayText == edited.displayText)
    #expect(updatedCell.messageView?.bubbleView.isHidden == true)
    #expect(imageView.image?.pngData() == originalImage)
    let dismissal = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: current, dismissalPreviewForItemAt: indexPath
    ))
    #expect(dismissal.view === updatedCell.messageView?.bubbleView)
    fixture.endMenu(current, animator: nil)
    #expect(updatedCell.messageView?.bubbleView.isHidden == false)
  }

  @Test("Deleting the menu message keeps its snapshot and does not target a different row")
  func deletingPreviewedMessage() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    let message = try #require(cell.message)
    let originalCount = fixture.displayedMessageCount
    let configuration = fixture.beginMenu()
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    let imageView = try #require(preview.view as? UIImageView)
    let originalImage = try #require(imageView.image?.pngData())
    let pixels = try #require(imageView.image?.sendAnimationVisibleAlphaSample())
    #expect(pixels.visible > 0)
    fixture.publisher.publisher.send(.delete(.init(messageIds: [message.message.messageId], peer: fixture.peer)))
    try await fixture.settleUpdates()
    #expect(fixture.displayedMessageCount == originalCount - 1)
    #expect(imageView.image?.pngData() == originalImage)
    let dismissal = list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, dismissalPreviewForItemAt: indexPath
    )
    #expect(dismissal == nil)
    #expect(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .allSatisfy { $0.messageView?.bubbleView.isHidden == false })
    fixture.endMenu(configuration, animator: nil)
  }

  @Test("Reusing a menu source cell restores its original bubble", arguments: [false, true])
  func restoresReusedSource(usesV2: Bool) async throws {
    let fixture = try await Fixture(usesV2: usesV2)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    let configuration = fixture.beginMenu()
    _ = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath
    ))
    let bubble = try #require(cell.messageView?.bubbleView)
    #expect(bubble.isHidden)
    cell.prepareForReuse()
    #expect(!cell.isContextMenuSourceHidden)
    #expect(!bubble.isHidden)
    fixture.endMenu(configuration, animator: nil)
  }

  @Test("Preparing and reopening a real menu preserves source visibility", arguments: [false, true])
  func sourceVisibilityAcrossConfigurations(usesV2: Bool) async throws {
    let fixture = try await Fixture(usesV2: usesV2)
    defer { fixture.close() }
    let list = fixture.list
    let indexPath = try #require(list.indexPathsForVisibleItems.sorted().first)
    let cell = try #require(list.cellForItem(at: indexPath) as? MessageCollectionViewCell)
    cell.updateMessageHoldAction(.reactionsMenu)
    let source = try #require(cell.messageView?.bubbleView)
    let point = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: list)
    func configuration() throws -> UIContextMenuConfiguration {
      try #require(list.delegate?.collectionView?(
        list, contextMenuConfigurationForItemsAt: [indexPath], point: point
      ))
    }
    let first = try configuration()
    #expect(!source.isHidden)
    list.delegate?.collectionView?(list, willDisplayContextMenu: first, animator: nil)
    #expect(source.isHidden)
    let animator = MenuAnimator()
    fixture.endMenu(first, animator: animator)
    let reopened = try configuration()
    #expect(source.isHidden)
    let preview = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: reopened, highlightPreviewForItemAt: indexPath
    ))
    let pixels = try #require((preview.view as? UIImageView)?.image?.sendAnimationVisibleAlphaSample())
    #expect(pixels.visible > 0)
    list.delegate?.collectionView?(list, willDisplayContextMenu: reopened, animator: nil)
    animator.animate()
    animator.complete()
    #expect(source.isHidden)
    fixture.endMenu(reopened, animator: nil)
    #expect(!source.isHidden)
  }

  @Test("Dismissal replays a hidden keyboard before completion", arguments: [false, true])
  func replaysDeferredInsets(animated: Bool) async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let list = fixture.list
    let closedInset = list.contentInset.top
    fixture.keyboard(height: 300)
    #expect(list.contentInset.top > closedInset)
    let openInset = list.contentInset.top
    let configuration = fixture.beginMenu()
    fixture.keyboard(height: 0)
    #expect(list.contentInset.top == openInset)

    let animator = animated ? MenuAnimator() : nil
    fixture.endMenu(configuration, animator: animator)
    animator?.animate()
    #expect(abs(list.contentInset.top - closedInset) < 0.5)
    #expect(list.isContextMenuInteractionActive == animated)
    animator?.complete()
    #expect(!list.isContextMenuInteractionActive)
    #expect(list.contentOffset.y >= -list.adjustedContentInset.top)
  }

  @Test("Keyboard returning during dismissal preserves the message position")
  func restoresKeyboardWithoutScrolling() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    fixture.keyboard(height: 300)
    let list = fixture.list
    let offset = CGPoint(x: 0, y: -list.contentInset.top + 20)
    list.setContentOffset(offset, animated: false)
    let configuration = fixture.beginMenu()
    fixture.keyboard(height: 0)
    #expect(list.contentOffset == offset)
    let animator = MenuAnimator()
    fixture.endMenu(configuration, animator: animator)
    animator.animate()
    fixture.keyboard(height: 300)
    animator.complete()
    #expect(list.contentOffset == offset)
    #expect(list.keyboardHeight == 300)
  }

  @Test("A stale dismissal cannot finish a newly opened menu")
  func rapidReopen() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    var completions = 0
    fixture.list.onContextMenuDidEnd = { completions += 1 }
    let old = fixture.beginMenu()
    let animator = MenuAnimator()
    fixture.endMenu(old, animator: animator)
    let current = fixture.beginMenu()
    animator.animate()
    animator.complete()
    #expect(fixture.list.isContextMenuInteractionActive)
    #expect(completions == 0)
    fixture.endMenu(current, animator: nil)
    #expect(!fixture.list.isContextMenuInteractionActive)
    #expect(completions == 1)
  }

  @Test("A keyboard notification after menu completion restores the original viewport")
  func delayedKeyboardRestoration() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    fixture.keyboard(height: 300)
    let list = fixture.list
    let offset = CGPoint(x: 0, y: -list.contentInset.top + 20)
    list.setContentOffset(offset, animated: false)
    list.onContextMenuDidEnd = { list.preserveContextMenuViewportForKeyboardRestoration() }
    defer { list.onContextMenuDidEnd = nil }
    let configuration = fixture.beginMenu()
    fixture.keyboard(height: 0)
    fixture.endMenu(configuration, animator: nil)
    #expect(!list.isContextMenuInteractionActive)
    fixture.keyboard(height: 300)
    #expect(list.contentOffset == offset)
  }

  @Test("Offscreen and floating keyboard frames do not reserve keyboard space")
  func ignoresNonDockedFrames() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    fixture.keyboard(height: 300)
    #expect(fixture.list.isKeyboardVisible)
    fixture.keyboard(height: 300, floating: true)
    #expect(fixture.list.keyboardHeight == 0)
    fixture.keyboard(height: 0)
    #expect(!fixture.list.isKeyboardVisible)
  }

  @MainActor private final class Fixture {
    let window: UIWindow
    let list: MessagesCollectionView
    let model: MessagesSectionedViewModel
    let publisher: MessagesPublisher
    let peer = Peer.user(id: 9_017)

    init(usesV2: Bool = true, outgoing: Bool? = nil, repetitions: Int = 3) async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.isHidden = false
      let database = AppDatabase.empty()
      publisher = MessagesPublisher(database: database)
      let template = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
      let rows = (1 ... 30).reversed().map { index -> FullMessage in
        var value = template
        value.message.globalId = 91_000 + Int64(index)
        value.message.messageId = Int64(index)
        value.message.chatId = 9_017
        value.message.peerThreadId = nil
        value.message.peerUserId = 9_017
        value.message.text = String(repeating: "Keyboard lifecycle regression. ", count: repetitions)
        if let outgoing { value.message.out = outgoing }
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
        peerId: peer, chatId: 9_017, spaceId: nil, isPreview: true,
        theme: ThemeManager.shared.snapshot(variant: .light),
        viewModel: model, messageViewImplementation: usesV2 ? .v2 : .legacy
      )
      controller.view.addSubview(list)
      list.frame = controller.view.bounds
      try await Task.sleep(for: .milliseconds(100))
      list.layoutIfNeeded()
      list.updateContentInsets()
    }

    var displayedMessageCount: Int {
      (0 ..< list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    }

    @discardableResult
    func addMessage(id: Int64, nextDay: Bool = false) throws -> FullMessage {
      var value = try #require(model.messages.first)
      value.message.globalId = 91_000 + id
      value.message.messageId = id
      value.message.date = value.message.date.addingTimeInterval(nextDay ? 86_400 : 1)
      value.message.text = "New message while holding the menu: \(id)"
      publisher.publisher.send(.add(.init(messages: [value], peer: peer)))
      return value
    }

    func settleUpdates() async throws {
      try await Task.sleep(for: .milliseconds(250))
      list.layoutIfNeeded()
    }

    func close() {
      window.isHidden = true
      model.dispose()
    }

    func keyboard(height: CGFloat, floating: Bool = false) {
      let viewport = list.convert(list.bounds, to: window)
      let frame = CGRect(
        x: viewport.minX, y: viewport.maxY - height - (floating ? 100 : 0),
        width: viewport.width, height: height == 0 ? 300 : height
      )
      NotificationCenter.default.post(
        name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
        userInfo: [
          UIResponder.keyboardFrameEndUserInfoKey: window.convert(frame, to: window.screen.coordinateSpace),
          UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ]
      )
    }

    func beginMenu() -> UIContextMenuConfiguration {
      let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu() }
      list.delegate?.collectionView?(list, willDisplayContextMenu: configuration, animator: nil)
      return configuration
    }

    func endMenu(_ configuration: UIContextMenuConfiguration, animator: MenuAnimator?) {
      list.delegate?.collectionView?(list, willEndContextMenuInteraction: configuration, animator: animator)
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
}
