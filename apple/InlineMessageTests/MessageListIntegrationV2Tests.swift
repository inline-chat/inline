@testable import InlineIOS
@testable import InlineKit
import InlineTheme
import Testing
import UIKit

@Suite("iOS Message V2 live-list integration", .serialized)
@MainActor
struct MessageListIntegrationV2Tests {
  @Test("Structural changes and multiple resizes settle through the live publisher")
  func structuralChangesDuringResize() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }

    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database)
    let peer = Peer.user(id: 9_007)
    let template = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    func message(_ id: Int64) -> FullMessage {
      var value = template
      value.message.globalId = 90_000 + id
      value.message.messageId = id
      value.message.chatId = 9_007
      value.message.peerThreadId = nil
      value.message.peerUserId = 9_007
      value.message.date = template.message.date.addingTimeInterval(Double(id))
      value.message.text = "Row \(id): " + String(repeating: "Message geometry. ", count: Int(id % 3) + 1)
      return value
    }
    let rows = (1 ... 30).reversed().map { message(Int64($0)) }
    let model = MessagesSectionedViewModel(
      peer: peer, reversed: true,
      // An empty database has no certified history. Keep the initial projection
      // consistent so the first text update does not also change grouping.
      initialState: .init(
        messages: rows,
        loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: rows)
      ),
      database: database, publisher: publisher
    )
    defer { model.dispose() }
    let list = MessagesCollectionView(
      peerId: peer, chatId: 9_007, spaceId: nil, isPreview: true,
      theme: ThemeManager.shared.snapshot(variant: .light),
      viewModel: model, messageViewImplementation: .v2
    )
    list.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
    controller.view.addSubview(list)
    list.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let cells = list.indexPathsForVisibleItems.sorted { $0.item < $1.item }
      .compactMap { list.cellForItem(at: $0) as? MessageCollectionViewCell }
    #expect(cells.count >= 3)
    var first = try #require(cells.first?.message)
    var second = try #require(cells.dropFirst().first?.message)
    let removed = try #require(cells.dropFirst(2).first?.message)
    let firstRenderer = try #require(cells.first?.messageView as? UIMessageView2)
    let originalHeight = firstRenderer.bubbleView.bounds.height
    let firstHandler = try #require(firstRenderer.onGeometryChange)
    var firstDidBind = false
    firstRenderer.onGeometryChange = { old, next in
      let boundsBeforeBinding = firstRenderer.bubbleView.bounds
      firstHandler(old, next)
      #expect(
        firstRenderer.bubbleView.bounds == boundsBeforeBinding,
        "Cell binding must enqueue geometry, not synchronously install the animation destination"
      )
      firstDidBind = true
    }
    first.message.text = String(repeating: "First row grows while its neighbor changes. ", count: 12)
    publisher.publisher.send(.update(.init(message: first, animated: true, peer: peer)))
    list.layoutIfNeeded()
    for _ in 0 ..< 100 where !firstDidBind {
      try await Task.sleep(for: .milliseconds(10))
      list.layoutIfNeeded()
    }
    try #require(
      firstDidBind,
      "First cell renderer retained: \(cells.first?.messageView === firstRenderer), visible: \(list.visibleCells.contains { $0 === cells.first }), cell text: \(cells.first?.message?.message.text ?? "nil")"
    )
    firstRenderer.onGeometryChange = firstHandler
    try #require(firstRenderer.fullMessage.message.text == first.message.text)
    try await Task.sleep(for: .milliseconds(80))
    let presentedHeight = try #require(firstRenderer.bubbleView.layer.presentation()).bounds.height
    let targetHeight = firstRenderer.bubbleView.bounds.height
    #expect(
      presentedHeight > originalHeight + 1 && presentedHeight < targetHeight - 1,
      "Expected an in-flight height between \(originalHeight) and \(targetHeight), got \(presentedHeight)"
    )
    let activeKeys = try #require(firstRenderer.bubbleView.layer.animationKeys())
    #expect(!activeKeys.isEmpty)
    // The cell provider calls this even when reconfiguring an ordinary visible
    // row. It must not remove the bubble's unrelated resize animations.
    cells.first?.revealSendAnimationTarget()
    #expect(firstRenderer.bubbleView.layer.animationKeys() == activeKeys)
    cells.first?.clearHighlight()
    #expect(firstRenderer.bubbleView.layer.animationKeys() == activeKeys)
    let secondRenderer = try #require(cells.dropFirst().first?.messageView as? UIMessageView2)
    let originalHandler = try #require(secondRenderer.onGeometryChange)
    var didRetarget = false
    var beforeRetargetHeight: CGFloat?
    secondRenderer.onGeometryChange = { old, next in
      beforeRetargetHeight = firstRenderer.bubbleView.layer.presentation()?.bounds.height
      originalHandler(old, next)
      didRetarget = true
    }
    second.message.text = String(repeating: "Second row retargets. ", count: 8)
    publisher.publisher.send(.update(.init(message: second, animated: true, peer: peer)))
    list.layoutIfNeeded()
    for _ in 0 ..< 100 where !didRetarget {
      try await Task.sleep(for: .milliseconds(10))
      list.layoutIfNeeded()
    }
    try #require(didRetarget)
    secondRenderer.onGeometryChange = originalHandler
    // Read an actual rendered frame after the replacement animator is committed;
    // model bounds are its destination and cannot stand in for presentation.
    try await Task.sleep(for: .milliseconds(25))
    let retargetedHeight = try #require(firstRenderer.bubbleView.layer.presentation()).bounds.height
    let previousHeight = try #require(beforeRetargetHeight)
    #expect(previousHeight < targetHeight - 1)
    #expect(
      retargetedHeight >= previousHeight - 2 && retargetedHeight < targetHeight - 1,
      "First bubble changed from \(previousHeight) to \(retargetedHeight) while retargeting toward \(targetHeight)"
    )
    let inserted = message(31)
    publisher.publisher.send(.add(.init(messages: [inserted], peer: peer)))
    publisher.publisher.send(.delete(.init(messageIds: [removed.message.messageId], peer: peer)))

    // Move into the existing loaded window while structural animations are active.
    // This exercises cell reuse without requesting history at either edge.
    list.layoutIfNeeded()
    let middle = max(0, (list.contentSize.height - list.bounds.height) / 2)
    list.setContentOffset(CGPoint(x: 0, y: middle), animated: false)
    try await Task.sleep(for: .milliseconds(500))
    list.layoutIfNeeded()
    assertSettled(list, model: model)
    list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
    try await Task.sleep(for: .milliseconds(350))
    list.layoutIfNeeded()
    assertSettled(list, model: model)
    #expect(model.messagesByID[first.id]?.message.text == first.message.text)
    #expect(model.messagesByID[second.id]?.message.text == second.message.text)
    #expect(model.messagesByID[inserted.id] != nil)
    #expect(model.messagesByID[removed.id] == nil)
    #expect(model.messages.count == 30)
    list.removeFromSuperview()
  }

  private func assertSettled(_ list: UICollectionView, model: MessagesSectionedViewModel) {
    for indexPath in list.indexPathsForVisibleItems {
      guard let cell = list.cellForItem(at: indexPath) as? MessageCollectionViewCell,
            let attributes = list.layoutAttributesForItem(at: indexPath),
            let view = cell.messageView as? UIMessageView2 else { continue }
      #expect(cell.transform == .identity)
      if let message = cell.message {
        #expect(message == model.messagesByID[message.id])
        #expect(view.fullMessage == message)
      }
      #expect(abs(cell.frame.minY - attributes.frame.minY) <= 1)
      #expect(abs(cell.frame.height - attributes.frame.height) <= 1)
      let size = view.sizeThatFits(CGSize(width: view.bounds.width, height: CGFloat.greatestFiniteMagnitude))
      #expect(abs(view.bounds.height - size.height) <= 1)
      #expect(view.bubbleView.layer.animationKeys()?.isEmpty != false)
    }
  }
}
