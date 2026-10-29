import AppKit
import InlineGrid
import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI

/// Floating call pill shown while this session is in a Grid room.
/// Reads `GridRoomService`; owns no call state.
@MainActor
final class GridFloatingCallController {
  static let shared = GridFloatingCallController()

  private static let originDefaultsKey = "grid.floatingCall.trailingBottom"
  private static let screenMargin: CGFloat = 16

  private enum Phase {
    case hidden
    case entering
    case shown
    case exiting
  }

  private var rooms: GridRoomService?
  private var panel: GridFloatingCallPanel?
  private var hostingView: GridFloatingCallHostingView?
  /// Window-level Liquid Glass (macOS 26+).
  private var glassView: NSView?
  private var animator: GridFloatingCallWindowAnimator?
  private let presentation = GridFloatingCallPresentation()
  private var phase = Phase.hidden
  private var transitionTask: Task<Void, Never>?
  private var lastContentSize: CGSize?
  private var notificationTasks: [Task<Void, Never>] = []

  private init() {}

  func start(rooms: GridRoomService) {
    guard self.rooms == nil else { return }
    self.rooms = rooms
    // Build the window up front so the first entrance doesn't pay for it.
    _ = makePanel(rooms: rooms)
    observeRooms()
    updateVisibility()
  }

  private func observeRooms() {
    guard let rooms else { return }
    withObservationTracking {
      _ = rooms.currentSessionRoom
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.updateVisibility()
        self?.observeRooms()
      }
    }
  }

  private func updateVisibility() {
    guard let rooms else { return }
    if let room = rooms.currentSessionRoom {
      // Kept after leaving so the pill still has content while it animates out.
      if presentation.lastRoom != room { presentation.lastRoom = room }
      let panel = panel ?? makePanel(rooms: rooms)
      if phase == .hidden || phase == .exiting { present(panel) }
    } else if let panel, phase == .shown || phase == .entering {
      dismiss(panel)
    }
  }

  private func makePanel(rooms: GridRoomService) -> GridFloatingCallPanel {
    let panel = GridFloatingCallPanel()
    let root = GridFloatingCallView(
      rooms: rooms,
      presentation: presentation,
      onOpenGrid: { spaceID in
        NSApp.activate(ignoringOtherApps: true)
        MainWindowOpenCoordinator.shared.openWindow(.grid(spaceID: spaceID))
      },
      onOpenTranscript: { chatID in
        NSApp.activate(ignoringOtherApps: true)
        MainWindowOpenCoordinator.shared.openWindow(.chat(peer: .thread(id: chatID)))
      },
      onSizeChange: { [weak self] size in
        // Resize outside SwiftUI's layout pass to avoid constraint cycles.
        DispatchQueue.main.async { self?.resize(to: size) }
      }
    )
    let hostingView = GridFloatingCallHostingView(rootView: root)
    hostingView.sizingOptions = []
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      // Regular glass: clear glass let busy or dark wallpapers wash out the controls.
      glass.style = .regular
      glass.cornerRadius = 20
      glass.contentView = hostingView
      panel.contentView = glass
      glassView = glass
    } else {
      panel.contentView = hostingView
    }
    animator = GridFloatingCallWindowAnimator(panel: panel) { [weak self] radius in
      if #available(macOS 26.0, *), let glass = self?.glassView as? NSGlassEffectView {
        glass.cornerRadius = radius
      }
    }
    notificationTasks.append(Task { @MainActor [weak self, weak panel] in
      for await _ in NotificationCenter.default.notifications(
        named: NSWindow.didMoveNotification,
        object: panel
      ) {
        guard !Task.isCancelled else { return }
        self?.saveAnchor()
      }
    })
    self.hostingView = hostingView
    self.panel = panel
    return panel
  }

  // MARK: - Transitions

  /// Entrance: a bead grows in at the pill's center and widens into the pill
  /// in one continuous motion, while the items unfold from the center outward.
  private func present(_ panel: GridFloatingCallPanel) {
    transitionTask?.cancel()
    animator?.cancel()
    let wasVisible = panel.isVisible
    phase = .entering

    let full = initialFrame(size: contentSize())
    guard let animator, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      setFolded(false, animated: false)
      animator?.apply(.init(frame: full, alpha: 1))
      panel.orderFrontRegardless()
      phase = .shown
      return
    }

    let start: GridFloatingCallWindowAnimator.State
    if wasVisible {
      // Rejoined mid-exit: continue from wherever the exit got to.
      start = animator.current
    } else {
      setFolded(true, animated: false)
      start = .init(frame: Self.scaled(Self.bead(in: full), by: 0.2), alpha: 0)
      animator.apply(start)
      hostingView?.layoutSubtreeIfNeeded()
      panel.orderFrontRegardless()
    }
    transitionTask = Task { @MainActor [weak self] in
      // The items start unfolding as the pill begins to widen.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(90))
        guard self?.phase == .entering else { return }
        self?.setFolded(false, animated: true)
      }
      await animator.animate(duration: 0.26) { Self.entrance(from: start, to: full, at: $0) }
      guard !Task.isCancelled, let self else { return }
      phase = .shown
      setFolded(false, animated: true)
      if let lastContentSize { resize(to: lastContentSize) }
    }
  }

  /// Exit: the items fold toward the center (outermost first) while the pill
  /// pinches from both sides into a bead and shrinks away, in one motion.
  private func dismiss(_ panel: GridFloatingCallPanel) {
    transitionTask?.cancel()
    animator?.cancel()
    phase = .exiting
    guard let animator, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      finishDismiss(panel)
      return
    }

    setFolded(true, animated: true)
    let start = animator.current
    transitionTask = Task { @MainActor [weak self] in
      await animator.animate(duration: 0.28) { Self.exit(from: start, at: $0) }
      guard !Task.isCancelled else { return }
      self?.finishDismiss(panel)
    }
  }

  /// Height and position lead (the bead grows in), width follows (it widens),
  /// opacity arrives early. Overlapping curves keep it one smooth motion.
  private static func entrance(
    from start: GridFloatingCallWindowAnimator.State,
    to full: NSRect,
    at t: Double
  ) -> GridFloatingCallWindowAnimator.State {
    let grow = Ease.out(min(t / 0.5, 1))
    let widen = Ease.inOut(Ease.clamp((t - 0.15) / 0.85))
    let height = Ease.mix(start.frame.height, full.height, grow)
    let width = max(height, Ease.mix(start.frame.width, full.width, widen))
    let midX = Ease.mix(start.frame.midX, full.midX, grow)
    let midY = Ease.mix(start.frame.midY, full.midY, grow)
    return .init(
      frame: NSRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height),
      alpha: Ease.mix(start.alpha, 1, Ease.out(min(t / 0.35, 1)))
    )
  }

  /// Width pinches to the height (a bead) first; the bead then shrinks to a
  /// point and fades. The two overlap so nothing stops in between.
  private static func exit(
    from start: GridFloatingCallWindowAnimator.State,
    at t: Double
  ) -> GridFloatingCallWindowAnimator.State {
    let pinch = Ease.inOut(min(t / 0.55, 1))
    let shrink = Ease.in(Ease.clamp((t - 0.4) / 0.6))
    let scale = 1 - 0.95 * shrink
    let width = Ease.mix(start.frame.width, start.frame.height, pinch) * scale
    let height = start.frame.height * scale
    return .init(
      frame: NSRect(
        x: start.frame.midX - width / 2,
        y: start.frame.midY - height / 2,
        width: width,
        height: height
      ),
      alpha: start.alpha * (1 - Ease.in(Ease.clamp((t - 0.5) / 0.5)))
    )
  }

  private func finishDismiss(_ panel: GridFloatingCallPanel) {
    panel.orderOut(nil)
    panel.alphaValue = 1
    phase = .hidden
    presentation.lastRoom = nil
  }

  private func setFolded(_ folded: Bool, animated: Bool) {
    guard presentation.isFolded != folded else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = !animated
    withTransaction(transaction) { presentation.isFolded = folded }
  }

  /// The pill pinched from both sides into a circle around its center.
  private static func bead(in frame: NSRect) -> NSRect {
    NSRect(x: frame.midX - frame.height / 2, y: frame.minY, width: frame.height, height: frame.height)
  }

  /// The bead scaled around its center.
  private static func scaled(_ bead: NSRect, by scale: CGFloat) -> NSRect {
    bead.insetBy(dx: bead.width * (1 - scale) / 2, dy: bead.height * (1 - scale) / 2)
  }

  private func contentSize() -> CGSize {
    if let size = hostingView?.fittingSize, size.width > 0, size.height > 0 { return size }
    return lastContentSize ?? CGSize(width: 200, height: 40)
  }

  // MARK: - Layout

  private func resize(to size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    lastContentSize = size
    // Transitions own the frame; the entrance settles to this size when it ends.
    guard phase == .shown, let panel else { return }
    let frame = panel.frame
    guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
    // Keep the trailing edge anchored so the buttons don't jump as people join.
    var newFrame = NSRect(
      x: frame.maxX - size.width,
      y: frame.minY,
      width: size.width,
      height: size.height
    )
    newFrame = clamped(newFrame)
    animator?.apply(.init(frame: newFrame, alpha: panel.alphaValue))
  }

  private func initialFrame(size: NSSize) -> NSRect {
    if let stored = UserDefaults.standard.array(forKey: Self.originDefaultsKey) as? [Double],
       stored.count == 2
    {
      return clamped(NSRect(
        x: stored[0] - size.width,
        y: stored[1],
        width: size.width,
        height: size.height
      ))
    }
    let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    return NSRect(
      x: visible.maxX - size.width - Self.screenMargin,
      y: visible.minY + Self.screenMargin,
      width: size.width,
      height: size.height
    )
  }

  private func clamped(_ frame: NSRect) -> NSRect {
    let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return frame }
    var frame = frame
    frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
    return frame
  }

  private func saveAnchor() {
    // Transitions move the window too; only the settled pill's position is kept.
    guard phase == .shown, let frame = panel?.frame else { return }
    UserDefaults.standard.set([Double(frame.maxX), Double(frame.minY)], forKey: Self.originDefaultsKey)
  }
}

/// Timing curves for the pill's transitions.
private enum Ease {
  static func `in`(_ t: Double) -> Double { t * t * t }
  static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
  static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
  static func clamp(_ t: Double) -> Double { min(max(t, 0), 1) }
  static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

@MainActor
@Observable
final class GridFloatingCallPresentation {
  var isFolded = false
  var lastRoom: GridRoom?
}

/// Steps the panel's frame, opacity and glass corner radius together on the
/// display link. The glass is the window itself, so the pinch and pop have to
/// move the window, and the corners must stay round at every frame.
@MainActor
private final class GridFloatingCallWindowAnimator: NSObject {
  struct State {
    var frame: NSRect
    var alpha: CGFloat
  }

  private weak var panel: NSPanel?
  private let applyCornerRadius: (CGFloat) -> Void
  private var link: CADisplayLink?
  private var continuation: CheckedContinuation<Void, Never>?
  private var startTime: CFTimeInterval = 0
  private var duration: CFTimeInterval = 0
  private var state: (Double) -> State = { _ in State(frame: .zero, alpha: 1) }

  init(panel: NSPanel, applyCornerRadius: @escaping (CGFloat) -> Void) {
    self.panel = panel
    self.applyCornerRadius = applyCornerRadius
  }

  var current: State {
    State(frame: panel?.frame ?? .zero, alpha: panel?.alphaValue ?? 1)
  }

  func apply(_ state: State) {
    guard let panel else { return }
    panel.setFrame(state.frame, display: true)
    panel.alphaValue = state.alpha
    applyCornerRadius(min(state.frame.width, state.frame.height) / 2)
  }

  /// Runs `state` from t = 0 to 1 over `duration`, one display frame at a time.
  func animate(duration: CFTimeInterval, state: @escaping (Double) -> State) async {
    cancel()
    // The screen's link, not the view's: a view link in this non-key, briefly
    // transparent panel ticks late or not at all, which stalls the entrance.
    guard let screen = panel?.screen ?? NSScreen.main else {
      apply(state(1))
      return
    }
    self.duration = duration
    self.state = state
    startTime = CACurrentMediaTime()
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      let link = screen.displayLink(target: self, selector: #selector(step(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }
  }

  /// Stops the running step; its awaiting caller resumes and checks cancellation.
  func cancel() {
    link?.invalidate()
    link = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }

  @objc private func step(_: CADisplayLink) {
    let t = duration > 0 ? min(max((CACurrentMediaTime() - startTime) / duration, 0), 1) : 1
    apply(state(t))
    if t >= 1 { cancel() }
  }
}

private final class GridFloatingCallPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    // The window shadow draws a gray ring around the glass; the glass edge is enough.
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    becomesKeyOnlyIfNeeded = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    title = "Grid Call"
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// AppKit draws Liquid Glass in inactive windows as a frosted blur, and this
  /// panel is never key (it must not take focus from the user's app). Report
  /// an active appearance so the glass renders clear, as in a focused window.
  /// Undocumented AppKit hook: if it ever stops being called, the pill falls
  /// back to the frosted inactive look; nothing else depends on it.
  @objc func _hasActiveAppearance() -> Bool { true }
}

private final class GridFloatingCallHostingView: NSHostingView<GridFloatingCallView> {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

struct GridFloatingCallView: View {
  static let maximumVisibleAvatarCount = 4

  let rooms: GridRoomService
  let presentation: GridFloatingCallPresentation
  let onOpenGrid: (Int64) -> Void
  let onOpenTranscript: (Int64) -> Void
  let onSizeChange: (CGSize) -> Void

  private static var usesWindowGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  var body: some View {
    ZStack {
      if !Self.usesWindowGlass {
        // Fills the window, so it pinches with the window during transitions.
        Capsule().fill(.regularMaterial)
      }
      Group {
        if let room = rooms.currentSessionRoom ?? presentation.lastRoom {
          pill(room: room)
        }
      }
      .fixedSize()
      .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func pill(room: GridRoom) -> some View {
    let folded = presentation.isFolded
    return HStack(spacing: 4) {
      avatars(room.avatars)
      .contentShape(Rectangle())
      // Not a Button: a button captures the press and blocks dragging the
      // window. A simultaneous tap still opens Grid while drags move the pill.
      .simultaneousGesture(TapGesture().onEnded { onOpenGrid(room.spaceID) })
      .help("Open Grid")
      .modifier(GridFloatingCallFold(isFolded: folded, depth: 0))

      // The room's disclosure while it's transcribed, for everyone in it.
      if room.transcriptionIsRunning {
        GridFloatingCallTranscriptGlyph(room: room) {
          if let chatID = room.transcriptChatID { onOpenTranscript(chatID) }
        }
        .modifier(GridFloatingCallFold(isFolded: folded, depth: 1))
        .transition(.scale(scale: 0.76).combined(with: .opacity))
      }

      GridFloatingCallButton(
        systemName: rooms.media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
        isActive: rooms.media.isMicrophoneEnabled,
        help: rooms.media.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone"
      ) {
        rooms.toggleMicrophone(spaceID: room.spaceID)
      }
      .modifier(GridFloatingCallFold(isFolded: folded, depth: 1))

      GridFloatingCallButton(
        systemName: isSharingScreen ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
        isActive: isSharingScreen,
        help: isSharingScreen ? "Stop sharing screen" : "Share screen"
      ) {
        rooms.toggleScreenShare()
      }
      .modifier(GridFloatingCallFold(isFolded: folded, depth: 1))

      GridFloatingCallButton(systemName: "door.left.hand.open", isDestructive: true, help: "Leave room") {
        rooms.leaveCurrentRoom(spaceID: room.spaceID)
      }
      .modifier(GridFloatingCallFold(isFolded: folded, depth: 0))
    }
    .animation(.smoothSnappy, value: room.transcriptionIsRunning)
    .coordinateSpace(.named(GridFloatingCallFold.space))
    .padding(.leading, 8)
    .padding(.trailing, 5)
    .padding(.vertical, 5)
    .contentShape(Capsule())
    .gesture(WindowDragGesture())
  }

  private var isSharingScreen: Bool {
    rooms.media.isScreenShareRequested || rooms.media.isScreenSharing
  }

  private func avatars(_ avatars: [GridAvatar]) -> some View {
    let visible = Array(avatars.prefix(Self.maximumVisibleAvatarCount))
    let hidden = max(avatars.count - visible.count, 0)
    return HStack(spacing: -7) {
      ForEach(visible, id: \.user.id) { avatar in
        GridFloatingCallAvatar(
          user: avatar.user,
          audioLevel: rooms.audioLevel(userID: avatar.user.id),
          isScreenSharing: rooms.isScreenSharing(avatar: avatar)
        )
        .transition(.scale(scale: 0.76).combined(with: .opacity))
      }
      if hidden > 0 {
        Text("+\(hidden)")
          .font(.system(size: 9, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 27, height: 27)
          .background(Color.primary.opacity(0.08), in: Circle())
      }
    }
    .padding(.trailing, 4)
    .animation(.smoothSnappy, value: avatars.map(\.user.id))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      avatars.map { InlineKit.User(from: $0.user).displayName }.joined(separator: ", ")
    )
  }
}

/// Slides an item toward the pill's center while shrinking and fading it.
/// Folding runs outermost first; unfolding runs innermost first.
private struct GridFloatingCallFold: ViewModifier {
  static let space = "GridFloatingCallFold"

  let isFolded: Bool
  /// 0 for the outermost items, increasing toward the center.
  let depth: Int

  private static let maxDepth = 1

  func body(content: Content) -> some View {
    let isFolded = isFolded
    let space = Self.space
    let order = isFolded ? depth : Self.maxDepth - depth
    return content
      .visualEffect { effect, proxy in
        let container = proxy.bounds(of: .named(space)) ?? .zero
        let towardCenter = container.midX - proxy.size.width / 2
        return effect
          .offset(x: isFolded ? towardCenter : 0)
          .scaleEffect(isFolded ? 0.4 : 1)
      }
      .opacity(isFolded ? 0 : 1)
      // Unfolding starts fast and settles; folding speeds up as it tucks in.
      .animation(
        (isFolded ? Animation.easeIn(duration: 0.12) : .easeOut(duration: 0.12)).delay(Double(order) * 0.02),
        value: isFolded
      )
  }
}

private struct GridFloatingCallAvatar: View {
  let user: InlineProtocol.User
  let audioLevel: Float
  let isScreenSharing: Bool

  var body: some View {
    UserAvatar(user: InlineKit.User(from: user), size: 24)
      .padding(1.5)
      .overlay(
        Circle()
          .stroke(isSpeaking ? GridFloatingCallButton.green : Color.clear, lineWidth: 1.5)
          // Speaking-level updates arrive frequently; scope the animation to the ring.
          .animation(.easeOut(duration: 0.12), value: isSpeaking)
      )
      .overlay(alignment: .bottomTrailing) {
        if isScreenSharing {
          Image(systemName: "rectangle.on.rectangle")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(GridFloatingCallButton.green, in: Circle())
            .offset(x: 2, y: 2)
        }
      }
      .help(InlineKit.User(from: user).displayName)
  }

  private var isSpeaking: Bool {
    audioLevel > 0.02
  }
}

/// A small accent glyph, not a control: starting and stopping stay in Grid's
/// media pill. A click opens the transcript.
private struct GridFloatingCallTranscriptGlyph: View {
  let room: GridRoom
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      Group {
        if room.transcription.state == .gridTranscriptionActive {
          Image(systemName: "captions.bubble.fill")
            .font(.system(size: 12, weight: .medium))
        } else {
          GridScreenShareActivityIndicator(tint: accent, size: 11)
        }
      }
      .foregroundStyle(accent)
      .frame(width: 24, height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(room.transcriptChatID == nil)
    .help("This room is being transcribed. Open transcript")
    .accessibilityLabel("This room is being transcribed. Open transcript")
  }

  private var accent: Color {
    Color(nsColor: Theme.accentColor)
  }
}

private struct GridFloatingCallButton: View {
  /// Regular glass lightens colored content, so these sit deeper than they
  /// read on screen: a clean green and a clear red once the glass is applied.
  static let green = Color(red: 0.11, green: 0.62, blue: 0.30)
  private static let red = Color(red: 0.86, green: 0.17, blue: 0.20)

  let systemName: String
  var isActive = false
  var isDestructive = false
  let help: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(foreground)
        .frame(width: 30, height: 30)
        .background(background, in: Circle())
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(help)
  }

  private var foreground: Color {
    if isActive { return .white }
    if isDestructive { return Self.red }
    return .primary
  }

  private var background: AnyShapeStyle {
    if isActive {
      return AnyShapeStyle(Self.green.gradient.opacity(isHovered ? 0.88 : 1))
    }
    if isDestructive {
      return AnyShapeStyle(Self.red.opacity(isHovered ? 0.26 : 0.18))
    }
    return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.1 : 0))
  }
}
