import AppKit
import Combine
import InlineKit
import SwiftUI

class ChatViewAppKit: NSView {
  var peerId: Peer
  var dependencies: AppDependencies

  private var messageList: MessageListAppKit
  private var compose: ComposeAppKit
  private var didInitialRefetch = false
  private var viewModel: FullChatViewModel? {
    didSet {
      guard !didInitialRefetch else { return }
      // Update message list
      viewModel?.refetchChatView()
      didInitialRefetch = true
    }
  }

  private var chat: Chat? // TODO: get rid of ?

  override var acceptsFirstResponder: Bool {
    true
  }

  private func createViews() {
    setupView()
  }

  init(peerId: Peer, dependencies: AppDependencies) {
    self.peerId = peerId
    self.dependencies = dependencies

    chat = try? Chat.getByPeerId(peerId: peerId)

    messageList = MessageListAppKit(peerId: peerId, chat: chat)
    compose = ComposeAppKit(peerId: peerId, messageList: messageList, chat: chat, dependencies: dependencies)

    super.init(frame: .zero)
    setupView()
    setupDragAndDrop()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var composeView: NSView {
    compose
  }

  private var messageListView: NSView {
    messageList.view
  }

  private func setupView() {
    // Performance
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    // Enable Auto Layout for the main view
    translatesAutoresizingMaskIntoConstraints = false
    messageListView.translatesAutoresizingMaskIntoConstraints = false
    composeView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(messageListView)
    addSubview(composeView)

    // initial height sync with msg list
    compose.updateHeight()

    NSLayoutConstraint.activate([
      // messageList
      messageListView.topAnchor.constraint(equalTo: topAnchor),
      messageListView.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageListView.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageListView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // compose
      composeView.bottomAnchor.constraint(equalTo: bottomAnchor),
      composeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  // @deprecated
  func update(messages: [FullMessage]) {}

  func update(viewModel: FullChatViewModel) {
    self.viewModel = viewModel
    // Update compose
    compose.update(viewModel: viewModel)
  }
}

// MARK: Drag

extension ChatViewAppKit {
  private func setupDragAndDrop() {
    // Register for drag types
    registerForDraggedTypes([
      .fileURL,
      .tiff,
      .png,
//      .jpeg,
      NSPasteboard.PasteboardType("public.image"), // Generic image type
      NSPasteboard.PasteboardType("public.file-url"), // Generic file URL
    ])
  }

  // Called when the drag enters the view
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    print("dragging entered")
    // Check if the drag contains acceptable types
    if checkForValidDraggedItems(sender) {
      return .copy
    }
    return []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    print("Dragging exited")
  }

//  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
//    checkForValidDraggedItems(sender) ? .copy : []
//  }

  // Called when the drag is released
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard

    // Try to get URLs first
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
      for url in urls {
        if let image = NSImage(contentsOf: url) {
          handleDroppedImage(image)
          return true
        }
        // Handle file drop
        handleDroppedFile(url)
        return true
      }
    }

    // Try to get image data
    if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let image = images.first
    {
      handleDroppedImage(image)
      return true
    }

    return false
  }

  private func checkForValidDraggedItems(_ sender: NSDraggingInfo) -> Bool {
    // Check for files
    if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) {
      return true
    }

    // Check for images
    if sender.draggingPasteboard.data(forType: .tiff) != nil ||
      sender.draggingPasteboard.data(forType: .png) != nil
    {
      return true
    }

    return false
  }

  // FILE DROPPED
  private func handleDroppedFile(_ url: URL) {
    if let image = NSImage(contentsOf: url) {
      compose.handleImageDropOrPaste(image)
    }
  }

  // IMAGE DROPPED
  private func handleDroppedImage(_ image: NSImage) {
    compose.handleImageDropOrPaste(image)
  }
}
