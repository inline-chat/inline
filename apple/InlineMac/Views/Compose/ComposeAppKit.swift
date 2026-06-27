import AppKit
import InlineKit

protocol ComposeImplementation: AnyObject {
  var view: NSView { get }
  var messageList: MessageListAppKit? { get set }

  func hostWillMove(toSuperview newSuperview: NSView?)
  func didLayout()
  func setPeerUser(_ user: InlineKit.User?)
  func handlePasteboardAttachments(_ attachments: [PasteboardAttachment])
  func handleFileDrop(_ urls: [URL])
  func handleTextDropOrPaste(_ text: String)
  func handleImageDropOrPaste(_ image: NSImage, _ url: URL?)
}

protocol ComposeAttachmentOwner: AnyObject {
  func removeImage(_ id: String)
  func removeVideo(_ id: String)
  func removeFile(_ id: String)
}

final class ComposeAppKit: NSView {
  // Keep the legacy and glass implementations split while the glass layout is
  // still moving. Behavior fixes must be mirrored until a narrow shared core
  // exists; broad layout-mode conditionals already proved too fragile here.
  private let implementation: any ComposeImplementation

  weak var messageList: MessageListAppKit? {
    get { implementation.messageList }
    set { implementation.messageList = newValue }
  }

  init(
    peerId: InlineKit.Peer,
    messageList: MessageListAppKit,
    chat: InlineKit.Chat?,
    peerUser: InlineKit.User?,
    dependencies: AppDependencies,
    toolbarState: ChatToolbarState? = nil,
    parentChatView: ChatViewAppKit? = nil,
    dialog: InlineKit.Dialog?
  ) {
    if #available(macOS 26.0, *) {
      implementation = GlassComposeAppKit(
        peerId: peerId,
        messageList: messageList,
        chat: chat,
        peerUser: peerUser,
        dependencies: dependencies,
        toolbarState: toolbarState,
        parentChatView: parentChatView,
        dialog: dialog
      )
    } else {
      implementation = LegacyComposeAppKit(
        peerId: peerId,
        messageList: messageList,
        chat: chat,
        peerUser: peerUser,
        dependencies: dependencies,
        toolbarState: toolbarState,
        parentChatView: parentChatView,
        dialog: dialog
      )
    }

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    implementation.hostWillMove(toSuperview: newSuperview)
    super.viewWillMove(toSuperview: newSuperview)
  }

  func didLayout() {
    implementation.didLayout()
  }

  func setPeerUser(_ user: InlineKit.User?) {
    implementation.setPeerUser(user)
  }

  func handlePasteboardAttachments(_ attachments: [PasteboardAttachment]) {
    implementation.handlePasteboardAttachments(attachments)
  }

  func handleFileDrop(_ urls: [URL]) {
    implementation.handleFileDrop(urls)
  }

  func handleTextDropOrPaste(_ text: String) {
    implementation.handleTextDropOrPaste(text)
  }

  func handleImageDropOrPaste(_ image: NSImage, _ url: URL? = nil) {
    implementation.handleImageDropOrPaste(image, url)
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false

    let contentView = implementation.view
    contentView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentView)

    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}
