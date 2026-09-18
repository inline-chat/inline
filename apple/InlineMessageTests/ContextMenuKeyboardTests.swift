@testable import InlineIOS
@testable import InlineKit
import InlineTheme
import Testing
import UIKit

@Suite("Message context-menu keyboard lifecycle", .serialized)
@MainActor
struct ContextMenuKeyboardTests {
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

    init() async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.isHidden = false
      let database = AppDatabase.empty()
      let peer = Peer.user(id: 9_017)
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
        database: database, publisher: MessagesPublisher(database: database)
      )
      list = MessagesCollectionView(
        peerId: peer, chatId: 9_017, spaceId: nil, isPreview: true,
        theme: ThemeManager.shared.snapshot(variant: .light),
        viewModel: model, messageViewImplementation: .v2
      )
      controller.view.addSubview(list)
      list.frame = controller.view.bounds
      try await Task.sleep(for: .milliseconds(100))
      list.layoutIfNeeded()
      list.updateContentInsets()
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
