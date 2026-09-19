@testable import InlineIOS
@testable import InlineKit
import InlineTheme
import Testing
import UIKit

@Suite("Message context-menu keyboard lifecycle", .serialized)
@MainActor
struct ContextMenuKeyboardTests {
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
    let dismissal = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: configuration, dismissalPreviewForItemAt: indexPath
    ))
    #expect(dismissal.view === preview.view)
    #expect(dismissal.target.center == currentBubble.convert(
      CGPoint(x: currentBubble.bounds.midX, y: currentBubble.bounds.midY), to: fixture.window
    ))

    let animator = animated ? MenuAnimator() : nil
    fixture.endMenu(configuration, animator: animator)
    animator?.animate()
    if animated {
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
    #expect(imageView.image?.pngData() == originalImage)
    let dismissal = try #require(list.delegate?.collectionView?(
      list, contextMenuConfiguration: current, dismissalPreviewForItemAt: indexPath
    ))
    #expect(dismissal.view === preview.view)
    fixture.endMenu(current, animator: nil)
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
    fixture.endMenu(configuration, animator: nil)
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

    init(usesV2: Bool = true) async throws {
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
        value.message.text = String(repeating: "Keyboard lifecycle regression. ", count: 3)
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
