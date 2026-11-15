import AppKit
import Combine
import InlineKit

protocol ComposeImplementation: AnyObject {
  var view: NSView { get }
  var messageList: (any ChatMessageListController)? { get set }

  func hostWillMove(toSuperview newSuperview: NSView?)
  func didLayout()
  func prepareForMessageSelection() -> Bool
  func setPeerUser(_ user: InlineKit.User?)
  func handleAttachments(from pasteboard: NSPasteboard) -> Bool
  func handleFileDrop(_ urls: [URL])
  func handleTextDropOrPaste(_ text: String)
  func handleImageDropOrPaste(_ image: NSImage, _ url: URL?)
  func handleVideoDropOrPaste(_ url: URL, thumbnail: NSImage?)
  func handleAnimatedImageDropOrPaste(_ url: URL)
  func focusEditor()
}

protocol ComposeAttachmentOwner: AnyObject {
  func removeImage(_ id: String)
  func removeVideo(_ id: String)
  func removeFile(_ id: String)
  /// Called when the attachment strip goes from empty to non-empty or back.
  func composeAttachmentsDidChangeStaged(_ hasAttachments: Bool)
}

final class ComposeAppKit: NSView {
  // Keep the legacy and glass implementations split while the glass layout is
  // still moving. Behavior fixes must be mirrored until a narrow shared core
  // exists; broad layout-mode conditionals already proved too fragile here.
  private let implementation: any ComposeImplementation
  private let usesGlassCompose: Bool
  let surfaceStyle: ChatViewAppearance.SurfaceStyle
  private let peerId: InlineKit.Peer
  private let dependencies: AppDependencies

  // A DM with a bot the viewer can't message shows a notice instead of the
  // editor. Only a known "no" does this; an unknown answer keeps the editor.
  private var peerUser: InlineKit.User?
  private var botAccessCancellable: AnyCancellable?
  private var noAccessBar: BotNoAccessBar?
  private var editorConstraints: [NSLayoutConstraint] = []
  private var noAccessConstraints: [NSLayoutConstraint] = []
  private(set) var isBlockedByBotAccess = false

  weak var messageList: (any ChatMessageListController)? {
    get { implementation.messageList }
    set { implementation.messageList = newValue }
  }

  init(
    peerId: InlineKit.Peer,
    messageList: any ChatMessageListController,
    chat: InlineKit.Chat?,
    peerUser: InlineKit.User?,
    dependencies: AppDependencies,
    toolbarState: ChatToolbarState? = nil,
    parentChatView: ChatViewAppKit? = nil,
    dialog: InlineKit.Dialog?,
    surfaceStyle: ChatViewAppearance.SurfaceStyle = .content
  ) {
    self.surfaceStyle = surfaceStyle
    self.peerId = peerId
    self.dependencies = dependencies
    self.peerUser = peerUser
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
    observeBotAccess()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    implementation.hostWillMove(toSuperview: newSuperview)
    super.viewWillMove(toSuperview: newSuperview)
  }

  func prepareForMessageSelection() -> Bool {
    implementation.prepareForMessageSelection()
  }

  func didLayout() {
    guard !isBlockedByBotAccess else { return }
    implementation.didLayout()
  }

  func focusEditor() {
    guard !isBlockedByBotAccess else { return }
    implementation.focusEditor()
  }

  func setPeerUser(_ user: InlineKit.User?) {
    peerUser = user
    implementation.setPeerUser(user)
    observeBotAccess()
  }

  /// Nothing reaches the editor while it is replaced: no drop, paste or selection.
  private var acceptsInput: Bool {
    !isBlockedByBotAccess && messageList?.isMessageSelectionActive != true
  }

  func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
    guard acceptsInput else { return false }
    return implementation.handleAttachments(from: pasteboard)
  }

  func handleFileDrop(_ urls: [URL]) {
    guard acceptsInput else { return }
    implementation.handleFileDrop(urls)
  }

  func handleTextDropOrPaste(_ text: String) {
    guard acceptsInput else { return }
    implementation.handleTextDropOrPaste(text)
  }

  func handleImageDropOrPaste(_ image: NSImage, _ url: URL? = nil) {
    guard acceptsInput else { return }
    implementation.handleImageDropOrPaste(image, url)
  }

  func handleVideoDropOrPaste(_ url: URL, thumbnail: NSImage? = nil) {
    guard acceptsInput else { return }
    implementation.handleVideoDropOrPaste(url, thumbnail: thumbnail)
  }

  func handleAnimatedImageDropOrPaste(_ url: URL) {
    guard acceptsInput else { return }
    implementation.handleAnimatedImageDropOrPaste(url)
  }

  // MARK: - Bot access

  /// The bot whose DM this is, when the chat is one.
  private var directBotUserID: Int64? {
    guard case let .user(id) = peerId, peerUser?.id == id, peerUser?.bot == true else { return nil }
    return id
  }

  private func observeBotAccess() {
    guard let botUserID = directBotUserID else {
      botAccessCancellable = nil
      applyBotAccess(nil)
      return
    }
    guard botAccessCancellable == nil else {
      applyBotAccess(AgentGrantStore.shared.access(botUserID: botUserID))
      return
    }
    // The stored answer arrives synchronously, so the first frame is right;
    // opening the chat also asks the server again.
    botAccessCancellable = AgentGrantStore.shared.$accessByBotUserID
      .map { $0[botUserID] }
      .removeDuplicates()
      .sink { [weak self] access in self?.applyBotAccess(access) }
    AgentGrantStore.shared.refresh(botUserID: botUserID)
  }

  private func applyBotAccess(_ access: AgentGrantAccess?) {
    let owner = access.flatMap { $0.ownerUserID > 0 ? ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user : nil }
    let notice = peerUser.flatMap { BotNoAccessNotice.make(bot: $0, access: access, owner: owner) }
    guard let notice else {
      setBlocked(false)
      return
    }
    let bar = noAccessBar ?? makeNoAccessBar()
    bar.update(notice)
    setBlocked(true)
    // The owner's name makes the notice useful; fetch it once if it isn't here.
    if notice.ownerUserID == nil, let ownerUserID = access?.ownerUserID, ownerUserID > 0 {
      Task { @MainActor [weak self] in
        await ObjectCache.shared.ensure([.user(ownerUserID)])
        guard let self, let botUserID = self.directBotUserID else { return }
        let current = AgentGrantStore.shared.access(botUserID: botUserID)
        guard current == access, ObjectCache.shared.getCachedUser(id: ownerUserID) != nil else { return }
        self.applyBotAccess(current)
      }
    }
  }

  private func makeNoAccessBar() -> BotNoAccessBar {
    let bar = BotNoAccessBar { [weak self] ownerUserID in
      self?.dependencies.openChatRoute(peer: .user(id: ownerUserID))
    }
    bar.isHidden = true
    addSubview(bar)
    noAccessConstraints = [
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    noAccessBar = bar
    return bar
  }

  private func setBlocked(_ blocked: Bool) {
    guard blocked != isBlockedByBotAccess else { return }
    isBlockedByBotAccess = blocked
    let editor = implementation.view
    if blocked {
      // Typing must not land in an editor nobody can see.
      if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: editor) {
        window?.makeFirstResponder(nil)
      }
      NSLayoutConstraint.deactivate(editorConstraints)
      NSLayoutConstraint.activate(noAccessConstraints)
    } else {
      NSLayoutConstraint.deactivate(noAccessConstraints)
      NSLayoutConstraint.activate(editorConstraints)
    }
    editor.isHidden = blocked
    noAccessBar?.isHidden = !blocked
    layoutSubtreeIfNeeded()
    if blocked {
      messageList?.updateInsetForCompose(BotNoAccessBar.height, animate: false)
    } else {
      implementation.didLayout()
      messageList?.updateInsetForCompose(frame.height, animate: false)
    }
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false

    var constraints: [NSLayoutConstraint] = []

    if usesGlassCompose {
      let backgroundView = GlassComposeBackgroundUnderlayView(surfaceStyle: surfaceStyle)
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

    // Kept apart: the no-access notice takes over the wrapper's height.
    editorConstraints = [
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]

    NSLayoutConstraint.activate(constraints + editorConstraints)
  }
}

final class GlassComposeBackgroundUnderlayView: NSView {
  private static let fadeHeight: CGFloat = 30
  private static let maxOpacity: CGFloat = 0.7
  private static let fadeStops: [CGFloat] = [0, 0.35, 0.72, 1]
  private static let fadeOpacities: [CGFloat] = [0, maxOpacity * 0.3, maxOpacity * 0.7, maxOpacity]
  private let surfaceStyle: ChatViewAppearance.SurfaceStyle

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  init(surfaceStyle: ChatViewAppearance.SurfaceStyle) {
    self.surfaceStyle = surfaceStyle
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

    let backgroundColor = surfaceStyle.backgroundColor
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

extension GlassComposeBackgroundUnderlayView: AppThemeRefreshable {
  func refreshAppTheme() {
    needsDisplay = true
  }
}
