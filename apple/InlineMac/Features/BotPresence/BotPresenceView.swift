import AppKit
import Combine
import CryptoKit
import ImageIO
import InlineProtocol
import SwiftUI

enum BotPresenceLayout {
  static let windowSize = NSSize(width: 220, height: 192)
  static let avatarSize = CGSize(width: 108, height: 116)
  static let bubbleMaxWidth: CGFloat = 184
  static let bubbleBottomSpacing: CGFloat = avatarSize.height + 2
  static let commentVisibleDuration: Duration = .seconds(8)

  static func characterRect(in bounds: NSRect, flipped: Bool) -> NSRect {
    NSRect(
      x: bounds.minX + (bounds.width - avatarSize.width) / 2,
      y: flipped ? bounds.maxY - avatarSize.height : bounds.minY,
      width: avatarSize.width,
      height: avatarSize.height
    )
  }
}

enum BotPresenceInteractionRole {
  case character
  case bubble
}

enum BotPresenceLocalAnimation: Equatable {
  case jumping
  case runningLeft
  case runningRight
}

enum BotPresenceRenderAnimation: Equatable {
  case state(InlineProtocol.BotPresenceState.Kind)
  case local(BotPresenceLocalAnimation)

  var key: String {
    switch self {
      case let .state(kind):
        "state:\(kind.rawValue)"
      case let .local(animation):
        "local:\(animation)"
    }
  }
}

@MainActor
final class BotPresenceSurfaceModel: ObservableObject {
  @Published private(set) var avatar: InlineProtocol.BotAvatar
  @Published private(set) var state: InlineProtocol.BotPresenceState
  @Published private(set) var visibleComment: String?
  @Published private(set) var localAnimation: BotPresenceLocalAnimation?

  private var onClick: (@MainActor () -> Void)?
  private var onClose: (@MainActor () -> Void)?
  private var onJump: (@MainActor () -> Void)?
  private var onDragEnd: (@MainActor () -> Void)?
  private var commentHideTask: Task<Void, Never>?
  private var localAnimationTask: Task<Void, Never>?

  init(
    avatar: InlineProtocol.BotAvatar,
    state: InlineProtocol.BotPresenceState,
    onClick: (@escaping @MainActor () -> Void),
    onClose: (@escaping @MainActor () -> Void),
    onJump: (@escaping @MainActor () -> Void),
    onDragEnd: (@escaping @MainActor () -> Void)
  ) {
    self.avatar = avatar
    self.state = state
    self.onClick = onClick
    self.onClose = onClose
    self.onJump = onJump
    self.onDragEnd = onDragEnd
    visibleComment = Self.comment(from: state)
  }

  deinit {
    commentHideTask?.cancel()
    localAnimationTask?.cancel()
  }

  func update(
    avatar: InlineProtocol.BotAvatar,
    state: InlineProtocol.BotPresenceState,
    onClick: (@escaping @MainActor () -> Void),
    onClose: (@escaping @MainActor () -> Void),
    onJump: (@escaping @MainActor () -> Void),
    onDragEnd: (@escaping @MainActor () -> Void)
  ) {
    let shouldJump = state.kind == .jumping && (self.state.kind != .jumping || self.state.comment != state.comment)
    self.avatar = avatar
    self.state = state
    self.onClick = onClick
    self.onClose = onClose
    self.onJump = onJump
    self.onDragEnd = onDragEnd
    updateVisibleComment(Self.comment(from: state))
    if shouldJump {
      onJump()
    }
  }

  func performClick() {
    playLocalAnimation(.jumping, duration: .milliseconds(1_100))
    onJump?()
    onClick?()
  }

  func showDebugComment() {
    showComment("Debug comment")
  }

  func dismissComment() {
    commentHideTask?.cancel()
    commentHideTask = nil
    visibleComment = nil
  }

  func close() {
    onClose?()
  }

  func updateDrag(deltaX: CGFloat) {
    guard abs(deltaX) >= 0.5 else { return }
    localAnimationTask?.cancel()
    localAnimationTask = nil
    localAnimation = deltaX < 0 ? .runningLeft : .runningRight
  }

  func finishDrag() {
    playLocalAnimation(localAnimation, duration: .milliseconds(320))
    onDragEnd?()
  }

  var renderAnimation: BotPresenceRenderAnimation {
    if let localAnimation {
      return .local(localAnimation)
    }
    return .state(state.kind)
  }

  private func updateVisibleComment(_ nextComment: String?) {
    commentHideTask?.cancel()
    commentHideTask = nil

    guard let nextComment else {
      guard visibleComment != nil else { return }
      scheduleCommentHide()
      return
    }

    showComment(nextComment)
  }

  private func showComment(_ text: String) {
    visibleComment = text
    scheduleCommentHide()
  }

  private func scheduleCommentHide() {
    commentHideTask?.cancel()
    commentHideTask = Task { @MainActor in
      try? await Task.sleep(for: BotPresenceLayout.commentVisibleDuration)
      guard !Task.isCancelled else { return }
      visibleComment = nil
      commentHideTask = nil
    }
  }

  private func playLocalAnimation(_ animation: BotPresenceLocalAnimation?, duration: Duration) {
    guard let animation else {
      localAnimation = nil
      return
    }
    localAnimationTask?.cancel()
    localAnimation = animation
    localAnimationTask = Task { @MainActor in
      try? await Task.sleep(for: duration)
      guard !Task.isCancelled else { return }
      localAnimation = nil
      localAnimationTask = nil
    }
  }

  private static func comment(from state: InlineProtocol.BotPresenceState) -> String? {
    let text = state.hasComment ? state.comment.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return text.isEmpty ? nil : text
  }
}

struct BotPresenceView: View {
  @ObservedObject var surface: BotPresenceSurfaceModel

  @StateObject private var frameModel = BotPresenceViewModel()
  @State private var isHoveringCharacter = false

  var body: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 0) {
        Spacer(minLength: 0)

        if let visibleComment = surface.visibleComment {
          BotPresenceSpeechBubble(comment: visibleComment)
            .id(visibleComment)
            .contentShape(.interaction, BotPresenceSpeechBubbleShape())
            .botPresenceInteraction(
              role: .bubble,
              onClick: surface.dismissComment,
              onDebug: surface.showDebugComment,
              onClose: surface.close,
              onDrag: surface.updateDrag(deltaX:),
              onDragEnd: surface.finishDrag
            )
            .allowsWindowActivationEvents(true)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
              surface.dismissComment()
            }
            .transition(Self.commentTransition)
        }

        Spacer()
          .frame(height: BotPresenceLayout.bubbleBottomSpacing)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

      characterLayer
    }
    .frame(width: BotPresenceLayout.windowSize.width, height: BotPresenceLayout.windowSize.height, alignment: .bottom)
    .animation(Self.commentAnimation, value: surface.visibleComment)
    .task(id: "\(avatarKey):\(surface.renderAnimation.key)") {
      await frameModel.configure(avatar: surface.avatar, animation: surface.renderAnimation)
    }
  }

  private static let commentAnimation = Animation.spring(response: 0.24, dampingFraction: 0.82, blendDuration: 0.08)

  private static let commentTransition = AnyTransition.asymmetric(
    insertion: .opacity
      .combined(with: .scale(scale: 0.88, anchor: .bottom))
      .combined(with: .offset(y: 5)),
    removal: .opacity
      .combined(with: .scale(scale: 0.94, anchor: .bottom))
      .combined(with: .offset(y: 2))
  )

  private var avatarKey: String {
    surface.avatar.hasFileUniqueID ? surface.avatar.fileUniqueID : surface.avatar.cdnURL
  }

  private var label: String {
    surface.avatar.displayName.isEmpty ? "Bot avatar" : surface.avatar.displayName
  }

  @ViewBuilder private var characterView: some View {
    if let frame = frameModel.frame {
      Image(decorative: frame, scale: 1)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: BotPresenceLayout.avatarSize.width, height: BotPresenceLayout.avatarSize.height)
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(width: BotPresenceLayout.avatarSize.width, height: BotPresenceLayout.avatarSize.height)
    }
  }

  private var characterLayer: some View {
    ZStack(alignment: .topTrailing) {
      characterView
        .contentShape(.interaction, Rectangle())
        .botPresenceInteraction(
          role: .character,
          onClick: surface.performClick,
          onDebug: surface.showDebugComment,
          onClose: surface.close,
          onDrag: surface.updateDrag(deltaX:),
          onDragEnd: surface.finishDrag
        )
        .allowsWindowActivationEvents(true)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
          surface.performClick()
        }

      BotPresenceCloseButton(action: surface.close)
        .frame(width: 18, height: 18)
        .offset(x: -2, y: 2)
        .opacity(isHoveringCharacter ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHoveringCharacter)
    }
    .frame(width: BotPresenceLayout.avatarSize.width, height: BotPresenceLayout.avatarSize.height)
    .onHover { hovering in
      isHoveringCharacter = hovering
    }
  }
}

private struct BotPresenceSpeechBubble: View {
  let comment: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      text
        .fixedSize(horizontal: true, vertical: true)

      text
        .frame(width: BotPresenceLayout.bubbleMaxWidth - 28)
        .fixedSize(horizontal: false, vertical: true)
    }
      .padding(.horizontal, 12)
      .padding(.top, 7)
      .padding(.bottom, 12)
      .background {
        BotPresenceSpeechBubbleShape()
          .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
      }
      .overlay {
        BotPresenceSpeechBubbleShape()
          .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.6)
      }
      .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
      .frame(maxWidth: BotPresenceLayout.bubbleMaxWidth)
  }

  private var text: some View {
    Text(comment)
      .font(.system(size: 14, weight: .regular))
      .foregroundStyle(Color(nsColor: .labelColor))
      .lineLimit(2)
      .multilineTextAlignment(.center)
      .minimumScaleFactor(0.9)
  }
}

private struct BotPresenceSpeechBubbleShape: Shape {
  func path(in rect: CGRect) -> Path {
    let tailHeight = min(CGFloat(8), rect.height * 0.22)
    let bubble = CGRect(
      x: rect.minX,
      y: rect.minY,
      width: rect.width,
      height: max(0, rect.height - tailHeight)
    )
    let radius = min(CGFloat(12), bubble.width / 2, bubble.height / 2)
    let tailWidth = min(CGFloat(15), max(10, bubble.width * 0.22))
    let tailTipX = min(
      bubble.maxX - 12,
      max(bubble.minX + radius + tailWidth / 2, bubble.maxX - 22)
    )
    let tailLeftX = max(bubble.minX + radius, tailTipX - tailWidth * 0.72)
    let tailRightX = min(bubble.maxX - radius * 0.4, tailTipX + tailWidth * 0.34)
    let tailTip = CGPoint(x: tailTipX, y: rect.maxY)

    var path = Path()
    path.move(to: CGPoint(x: bubble.minX + radius, y: bubble.minY))
    path.addLine(to: CGPoint(x: bubble.maxX - radius, y: bubble.minY))
    path.addQuadCurve(
      to: CGPoint(x: bubble.maxX, y: bubble.minY + radius),
      control: CGPoint(x: bubble.maxX, y: bubble.minY)
    )
    path.addLine(to: CGPoint(x: bubble.maxX, y: bubble.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: bubble.maxX - radius, y: bubble.maxY),
      control: CGPoint(x: bubble.maxX, y: bubble.maxY)
    )
    path.addLine(to: CGPoint(x: tailRightX, y: bubble.maxY))
    path.addCurve(
      to: tailTip,
      control1: CGPoint(x: tailTipX + 4, y: bubble.maxY + 0.4),
      control2: CGPoint(x: tailTipX + 3, y: rect.maxY - 1.3)
    )
    path.addCurve(
      to: CGPoint(x: tailLeftX, y: bubble.maxY),
      control1: CGPoint(x: tailTipX - 3, y: rect.maxY - 1.3),
      control2: CGPoint(x: tailLeftX + 3, y: bubble.maxY + 0.4)
    )
    path.addLine(to: CGPoint(x: bubble.minX + radius, y: bubble.maxY))
    path.addQuadCurve(
      to: CGPoint(x: bubble.minX, y: bubble.maxY - radius),
      control: CGPoint(x: bubble.minX, y: bubble.maxY)
    )
    path.addLine(to: CGPoint(x: bubble.minX, y: bubble.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: bubble.minX + radius, y: bubble.minY),
      control: CGPoint(x: bubble.minX, y: bubble.minY)
    )
    path.closeSubpath()

    return path
  }
}

private extension View {
  func botPresenceInteraction(
    role: BotPresenceInteractionRole,
    onClick: @escaping @MainActor () -> Void,
    onDebug: @escaping @MainActor () -> Void,
    onClose: @escaping @MainActor () -> Void,
    onDrag: @escaping @MainActor (CGFloat) -> Void,
    onDragEnd: @escaping @MainActor () -> Void
  ) -> some View {
    overlay {
      BotPresenceInteractionView(
        role: role,
        onClick: onClick,
        onDebug: onDebug,
        onClose: onClose,
        onDrag: onDrag,
        onDragEnd: onDragEnd
      )
    }
  }
}

private struct BotPresenceInteractionView: NSViewRepresentable {
  let role: BotPresenceInteractionRole
  let onClick: @MainActor () -> Void
  let onDebug: @MainActor () -> Void
  let onClose: @MainActor () -> Void
  let onDrag: @MainActor (CGFloat) -> Void
  let onDragEnd: @MainActor () -> Void

  func makeNSView(context: Context) -> BotPresenceInteractionNSView {
    let view = BotPresenceInteractionNSView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: BotPresenceInteractionNSView, context: Context) {
    view.role = role
    view.onClick = onClick
    view.onDebug = onDebug
    view.onClose = onClose
    view.onDrag = onDrag
    view.onDragEnd = onDragEnd
  }
}

@MainActor
final class BotPresenceInteractionNSView: NSView {
  var role: BotPresenceInteractionRole = .character
  var onClick: (@MainActor () -> Void)?
  var onDebug: (@MainActor () -> Void)?
  var onClose: (@MainActor () -> Void)?
  var onDrag: (@MainActor (CGFloat) -> Void)?
  var onDragEnd: (@MainActor () -> Void)?

  private var mouseOffset: NSPoint?
  private var didDrag = false

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let mouse = NSEvent.mouseLocation
    mouseOffset = NSPoint(
      x: mouse.x - window.frame.minX,
      y: mouse.y - window.frame.minY
    )
    didDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window, let mouseOffset else { return }

    let mouse = NSEvent.mouseLocation
    let currentOrigin = window.frame.origin
    let nextOrigin = NSPoint(
      x: mouse.x - mouseOffset.x,
      y: mouse.y - mouseOffset.y
    )
    let deltaX = nextOrigin.x - currentOrigin.x
    let deltaY = nextOrigin.y - currentOrigin.y
    guard abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5 else { return }

    window.setFrameOrigin(nextOrigin)
    didDrag = true
    onDrag?(deltaX)
  }

  override func mouseUp(with event: NSEvent) {
    mouseOffset = nil
    if didDrag {
      onDragEnd?()
      didDrag = false
      return
    }
    onClick?()
  }

  override func rightMouseDown(with event: NSEvent) {
    let menu = NSMenu()
    let debugItem = NSMenuItem(title: "Show Debug Comment", action: #selector(showDebugComment), keyEquivalent: "")
    debugItem.target = self
    menu.addItem(debugItem)
    menu.addItem(.separator())
    let closeItem = NSMenuItem(title: "Close", action: #selector(close), keyEquivalent: "")
    closeItem.target = self
    menu.addItem(closeItem)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func showDebugComment() {
    onDebug?()
  }

  @objc private func close() {
    onClose?()
  }
}

private struct BotPresenceCloseButton: NSViewRepresentable {
  let action: @MainActor () -> Void

  func makeNSView(context: Context) -> BotPresenceCloseButtonNSView {
    let button = BotPresenceCloseButtonNSView()
    updateNSView(button, context: context)
    return button
  }

  func updateNSView(_ view: BotPresenceCloseButtonNSView, context: Context) {
    view.onClose = action
  }
}

@MainActor
final class BotPresenceCloseButtonNSView: NSButton {
  var onClose: (@MainActor () -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
    imagePosition = .imageOnly
    isBordered = false
    bezelStyle = .shadowlessSquare
    setButtonType(.momentaryPushIn)
    contentTintColor = .secondaryLabelColor
    target = self
    action = #selector(close)
    toolTip = "Close"
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  @objc private func close() {
    onClose?()
  }
}

@MainActor
private final class BotPresenceViewModel: ObservableObject {
  @Published var frame: CGImage?

  private var animationTask: Task<Void, Never>?

  deinit {
    animationTask?.cancel()
  }

  func configure(
    avatar: InlineProtocol.BotAvatar,
    animation: BotPresenceRenderAnimation
  ) async {
    animationTask?.cancel()

    do {
      let frames = try await BotAvatarAtlasCache.shared.frames(for: avatar, animation: animation)
      guard !frames.isEmpty else {
        frame = nil
        return
      }

      animationTask = Task { [weak self] in
        guard let self else { return }
        var index = 0
        while !Task.isCancelled {
          let frameIndex = index
          self.frame = frames[frameIndex]
          index = (frameIndex + 1) % frames.count
          try? await Task.sleep(nanoseconds: BotAvatarAnimation.delay(for: animation, frameIndex: frameIndex))
        }
      }
    } catch {
      frame = nil
    }
  }
}

actor BotAvatarAtlasCache {
  static let shared = BotAvatarAtlasCache()

  private var cache: [String: BotAvatarAtlas] = [:]
  private var loads: [String: Task<BotAvatarAtlas?, Error>] = [:]

  nonisolated static func cacheKey(for avatar: InlineProtocol.BotAvatar) -> String {
    if avatar.hasFileUniqueID, !avatar.fileUniqueID.isEmpty {
      return avatar.fileUniqueID
    }
    return avatar.cdnURL
  }

  func prewarm(avatar: InlineProtocol.BotAvatar) async {
    _ = try? await atlas(for: avatar)
  }

  func previewFrame(for avatar: InlineProtocol.BotAvatar) async -> CGImage? {
    guard let atlas = try? await atlas(for: avatar) else { return nil }
    return atlas.previewFrame()
  }

  func frames(
    for avatar: InlineProtocol.BotAvatar,
    animation: BotPresenceRenderAnimation
  ) async throws -> [CGImage] {
    guard let atlas = try await atlas(for: avatar) else { return [] }
    return atlas.frames(for: animation)
  }

  private func atlas(for avatar: InlineProtocol.BotAvatar) async throws -> BotAvatarAtlas? {
    let key = Self.cacheKey(for: avatar)
    if let atlas = cache[key] {
      return atlas
    }

    if let load = loads[key] {
      let atlas = try await load.value
      if let atlas {
        cache[key] = atlas
      }
      return atlas
    }

    let load = Task.detached(priority: .utility) {
      try await Self.loadAtlas(for: avatar, key: key)
    }
    loads[key] = load
    defer {
      loads[key] = nil
    }

    let atlas = try await load.value
    if let atlas {
      cache[key] = atlas
    }
    return atlas
  }

  private nonisolated static func loadAtlas(
    for avatar: InlineProtocol.BotAvatar,
    key: String
  ) async throws -> BotAvatarAtlas? {
    if let data = cachedData(for: key), let atlas = makeAtlas(from: data) {
      return atlas
    }

    guard avatar.hasCdnURL, let url = URL(string: avatar.cdnURL) else {
      return nil
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .returnCacheDataElseLoad
    let (data, _) = try await URLSession.shared.data(for: request)
    guard let atlas = makeAtlas(from: data) else {
      return nil
    }

    cacheData(data, for: key)
    return atlas
  }

  private nonisolated static func makeAtlas(from data: Data) -> BotAvatarAtlas? {
    let options = [kCGImageSourceShouldCache: true] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else {
      return nil
    }

    return BotAvatarAtlas(cgImage: cgImage)
  }

  private nonisolated static func cachedData(for key: String) -> Data? {
    guard let url = cacheFileURL(for: key) else { return nil }
    return try? Data(contentsOf: url)
  }

  private nonisolated static func cacheData(_ data: Data, for key: String) {
    guard let url = cacheFileURL(for: key) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
  }

  private nonisolated static func cacheFileURL(for key: String) -> URL? {
    guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    return cachesURL
      .appendingPathComponent("BotPresenceAvatarAtlas", isDirectory: true)
      .appendingPathComponent(Self.cacheFilename(for: key))
  }

  private nonisolated static func cacheFilename(for key: String) -> String {
    let digest = SHA256.hash(data: Data(key.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(hex).image"
  }
}

struct BotAvatarAtlas: @unchecked Sendable {
  private static let columns = 8
  private static let rows = 9

  private let framesByRow: [[CGImage]]

  init(cgImage: CGImage) {
    let cellWidth = cgImage.width / Self.columns
    let cellHeight = cgImage.height / Self.rows

    framesByRow = (0..<Self.rows).map { row in
      (0..<Self.columns).compactMap { column in
        let rect = CGRect(
          x: column * cellWidth,
          y: row * cellHeight,
          width: cellWidth,
          height: cellHeight
        )
        guard let frame = cgImage.cropping(to: rect), Self.hasVisiblePixels(frame) else {
          return nil
        }
        return frame
      }
    }
  }

  func frames(for animation: BotPresenceRenderAnimation) -> [CGImage] {
    guard let row = BotAvatarAnimation.row(for: animation), framesByRow.indices.contains(row) else {
      return []
    }
    let frames = framesByRow[row]
    if !frames.isEmpty {
      return frames
    }

    if case .local = animation, framesByRow.indices.contains(7), !framesByRow[7].isEmpty {
      return framesByRow[7]
    }

    return framesByRow[0]
  }

  func previewFrame() -> CGImage? {
    for frames in framesByRow {
      if let frame = frames.first {
        return frame
      }
    }
    return nil
  }

  private static func hasVisiblePixels(_ image: CGImage) -> Bool {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return false }

    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 0, count: height * bytesPerRow)
    let rendered = data.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      ) else {
        return false
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }

    guard rendered else { return true }

    var visiblePixels = 0
    for index in stride(from: 3, to: data.count, by: 4) where data[index] > 8 {
      visiblePixels += 1
      if visiblePixels > 16 {
        return true
      }
    }
    return false
  }
}

enum BotAvatarAnimation {
  static func row(for animation: BotPresenceRenderAnimation) -> Int? {
    switch animation {
      case .local(.runningRight):
        1
      case .local(.runningLeft):
        2
      case .local(.jumping):
        4
      case let .state(kind):
        row(for: kind)
    }
  }

  private static func row(for kind: InlineProtocol.BotPresenceState.Kind) -> Int? {
    switch kind {
      case .waving:
        3
      case .jumping:
        4
      case .failed:
        5
      case .waiting:
        6
      case .running:
        7
      case .review:
        8
      case .unspecified, .hidden, .idle, .happy, .UNRECOGNIZED(_):
        0
    }
  }

  static func delay(for animation: BotPresenceRenderAnimation, frameIndex: Int) -> UInt64 {
    let row = row(for: animation) ?? 0
    let durationsMs: [UInt64] = switch row {
      case 0:
        [280, 110, 110, 140, 140, 320]
      case 1, 2:
        [120, 120, 120, 120, 120, 120, 120, 220]
      case 3:
        [140, 140, 140, 280]
      case 4:
        [140, 140, 140, 140, 280]
      case 5:
        [140, 140, 140, 140, 140, 140, 140, 240]
      case 6:
        [150, 150, 150, 150, 150, 260]
      case 7:
        [120, 120, 120, 120, 120, 220]
      case 8:
        [150, 150, 150, 150, 150, 280]
      default:
        [140]
    }
    let ms = durationsMs[min(frameIndex, durationsMs.count - 1)]
    return ms * 1_000_000
  }
}
