@testable import InlineIOS
@testable import InlineKit
import Auth
import InlineIOSUI
import InlineProtocol
import InlineTheme
import Testing
import UIKit

@Suite("Custom Hold message actions", .serialized)
@MainActor
struct MessageHoldActionsTests {
  @Test("Custom Hold keeps a separate full menu without invoking a quick action",
        arguments: [MessageViewImplementation.legacy, .v2])
  func fullMenu(implementation: MessageViewImplementation) async throws {
    let fixture = try await Fixture(implementation: implementation)
    defer { fixture.close() }
    let cell = try fixture.cell()
    let beforeReply = ChatState.shared.getState(peer: fixture.peer).replyingMessageId
    cell.updateMessageHoldAction(.reply)
    cell.layoutIfNeeded()
    // Preview contexts share this cell class but must retain their normal appearance.
    #expect(!cell.contentView.subviews.contains { $0.accessibilityIdentifier == "messageActions" && !$0.isHidden })

    cell.allowsMessageActions = true
    cell.layoutIfNeeded()
    let button = try #require(cell.contentView.subviews.first { $0.accessibilityIdentifier == "messageActions" } as? UIButton)
    #expect(!button.isHidden)
    #expect(button.showsMenuAsPrimaryAction)
    #expect(button.menu != nil)
    #expect(button.accessibilityLabel == "Message actions")
    let menu = try #require(cell.messageActionsMenuProvider?(cell))
    let titles = actionTitles(menu)
    for title in ["Copy", "Reply", "Edit", "Forward", "Delete", "Reactions"] {
      #expect(titles.contains(title))
    }
    #expect(ChatState.shared.getState(peer: fixture.peer).replyingMessageId == beforeReply)
    #expect(cell.message?.reactions == fixture.message.reactions)

    let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: fixture.list)
    let indexPath = try #require(fixture.list.indexPath(for: cell))
    // A long press on the explicit menu control must not also execute custom Hold.
    let configuration = fixture.list.delegate?.collectionView?(
      fixture.list, contextMenuConfigurationForItemsAt: [indexPath], point: center
    )
    #expect(configuration == nil)
    #expect(ChatState.shared.getState(peer: fixture.peer).replyingMessageId == beforeReply)

    cell.updateMessageHoldAction(.reactionsMenu)
    cell.layoutIfNeeded()
    #expect(button.isHidden)
    cell.prepareForReuse()
    #expect(cell.messageActionsMenuProvider == nil)
    #expect(!cell.allowsMessageActions)
  }

  @Test("Failed, sending and service messages keep their native hold menu",
        arguments: ["failed", "sending", "service"])
  func recoveryMenu(kind: String) async throws {
    let fixture = try await Fixture(kind: kind)
    defer { fixture.close() }
    let cell = try fixture.cell()
    cell.updateMessageHoldAction(.reply)
    cell.allowsMessageActions = true
    cell.layoutIfNeeded()
    #expect(!cell.usesCustomHoldAction)
    let indexPath = try #require(fixture.list.indexPath(for: cell))
    let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: fixture.list)
    let configuration = fixture.list.delegate?.collectionView?(
      fixture.list, contextMenuConfigurationForItemsAt: [indexPath], point: point
    )
    #expect(configuration != nil)
    if kind != "service" {
      let titles = actionTitles(try #require(cell.messageActionsMenuProvider?(cell)))
      #expect(titles.contains(kind == "failed" ? "Resend" : "Cancel"))
      if kind == "failed" { #expect(titles.contains("Delete")) }
    }
  }

  @Test("Actions target stays inside the free gutter in both message renderers",
        arguments: [MessageViewImplementation.legacy, .v2], [false, true])
  func gutter(implementation: MessageViewImplementation, outgoing: Bool) async throws {
    let fixture = try await Fixture(implementation: implementation, outgoing: outgoing, width: 320)
    defer { fixture.close() }
    let cell = try fixture.cell()
    cell.updateMessageHoldAction(.toggleHeart)
    cell.allowsMessageActions = true
    cell.layoutIfNeeded()
    let button = try #require(cell.contentView.subviews.first { $0.accessibilityIdentifier == "messageActions" } as? UIButton)
    let view = try #require(cell.messageView)
    let bubble = view.bubbleView.convert(view.bubbleView.bounds, to: cell.contentView)
    #expect(button.bounds.width >= 32)
    #expect(button.bounds.height >= 32)
    #expect(cell.contentView.bounds.contains(button.frame))
    #expect(outgoing ? button.frame.maxX <= bubble.minX : button.frame.minX >= bubble.maxX)
    let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: cell)
    let hit = try #require(cell.hitTest(center, with: nil))
    #expect(hit === button || hit.isDescendant(of: button))
  }

  private func actionTitles(_ menu: UIMenu) -> [String] {
    menu.children.flatMap { child -> [String] in
      if let menu = child as? UIMenu { return actionTitles(menu) }
      return [child.title]
    }
  }

  @MainActor private final class Fixture {
    let window: UIWindow
    let list: MessagesCollectionView
    let model: MessagesSectionedViewModel
    let message: FullMessage
    let peer = Peer.user(id: 9_190_917)

    init(
      implementation: MessageViewImplementation = .v2,
      outgoing: Bool = true,
      width: CGFloat = 390,
      kind: String = "sent"
    ) async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.isHidden = false
      var row = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
      row.message.globalId = 9_190_917
      row.message.messageId = 10
      row.message.chatId = 9_190_917
      row.message.peerThreadId = nil
      row.message.peerUserId = 9_190_917
      row.message.fromId = Auth.shared.getCurrentUserId() ?? 0
      row.message.out = outgoing
      row.message.text = String(repeating: "Message actions remain available. ", count: 3)
      row.message.status = kind == "failed" ? .failed : kind == "sending" ? .sending : .sent
      if kind == "service" {
        row.message.contentPayload = .with {
          $0.serviceMessage = .with { $0.pinnedMessage = .with { $0.messageID = 1 } }
        }
      }
      message = row
      let database = AppDatabase.empty()
      model = MessagesSectionedViewModel(
        peer: peer, reversed: true,
        initialState: .init(messages: [row], loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: [row])),
        database: database, publisher: MessagesPublisher(database: database)
      )
      list = MessagesCollectionView(
        peerId: peer, chatId: row.message.chatId, spaceId: nil, isPreview: true,
        theme: ThemeManager.shared.snapshot(variant: .light), viewModel: model,
        messageViewImplementation: implementation
      )
      controller.view.addSubview(list)
      list.frame = CGRect(x: 0, y: 0, width: width, height: controller.view.bounds.height)
      try await Task.sleep(for: .milliseconds(100))
      list.layoutIfNeeded()
    }

    func cell() throws -> MessageCollectionViewCell {
      try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }.first)
    }

    func close() {
      window.isHidden = true
      model.dispose()
    }
  }
}
