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
  private let usesGlassCompose: Bool

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
      usesGlassCompose = true
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
      usesGlassCompose = false
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

    var constraints: [NSLayoutConstraint] = []

    if usesGlassCompose {
      let backgroundView = GlassComposeBackgroundUnderlayView()
      backgroundView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(backgroundView)

      constraints.append(contentsOf: [
        backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
        backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
        backgroundView.topAnchor.constraint(equalTo: topAnchor),
        backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    let contentView = implementation.view
    contentView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentView)

    constraints.append(contentsOf: [
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    NSLayoutConstraint.activate(constraints)
  }
}

private final class GlassComposeBackgroundUnderlayView: NSView {
  private static let fadeHeight: CGFloat = 30
  private static let maxOpacity: CGFloat = 0.7
  private static let fadeStops: [CGFloat] = [0, 0.35, 0.72, 1]
  private static let fadeOpacities: [CGFloat] = [0, maxOpacity * 0.3, maxOpacity * 0.7, maxOpacity]

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  init() {
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else { return }
    guard bounds.width > 0, bounds.height > 0 else { return }

    let backgroundColor = Theme.windowContentBackgroundColor
      .resolvedColor(with: effectiveAppearance)
    let maxColor = backgroundColor.withAlphaComponent(Self.maxOpacity).cgColor
    let fadeHeight = min(Self.fadeHeight, bounds.height)
    let solidRect = CGRect(
      x: bounds.minX,
      y: bounds.minY + fadeHeight,
      width: bounds.width,
      height: max(0, bounds.height - fadeHeight)
    )

    if solidRect.height > 0 {
      context.setFillColor(maxColor)
      context.fill(solidRect)
    }

    let colors = Self.fadeOpacities.map { opacity in
      backgroundColor.withAlphaComponent(opacity).cgColor
    } as CFArray

    guard let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors,
      locations: Self.fadeStops
    ) else {
      return
    }

    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: bounds.midX, y: bounds.minY),
      end: CGPoint(x: bounds.midX, y: bounds.minY + fadeHeight),
      options: []
    )
  }
}
