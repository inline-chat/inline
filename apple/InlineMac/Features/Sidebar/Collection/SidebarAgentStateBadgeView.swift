import AppKit
import Auth
import Combine
import InlineKit

/// A small corner badge on a sidebar chat icon for agent work in that chat:
/// working, waiting (orange when it waits for the viewer), paused or active
/// elsewhere. Reads the cached state synchronously, so it is right on the
/// row's first frame, then follows the store.
final class SidebarAgentStateBadgeView: NSView {
  private let ring = CALayer()
  private let glyph = NSImageView()
  private var peer: Peer?
  private var cancellable: AnyCancellable?
  private var displayed: AgentWorkPresentation?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(ring)
    glyph.imageScaling = .scaleProportionallyDown
    glyph.symbolConfiguration = .init(pointSize: 7, weight: .bold)
    addSubview(glyph)
    isHidden = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor
  func configure(peer: Peer) {
    guard self.peer != peer else { return }
    self.peer = peer
    apply(AgentWorkStateStore.shared.badgeState(peer: peer, viewerUserID: Auth.shared.getCurrentUserId()))
    cancellable = AgentWorkStateStore.shared.$states
      .dropFirst()
      .sink { [weak self] states in
        // The publisher fires before the store's property changes; read the
        // delivered value instead of the store.
        guard let self, let peer = self.peer else { return }
        let viewer = Auth.shared.getCurrentUserId()
        let candidates = states.values.filter { $0.key.peer == peer && $0.runState != .idle }
        let urgent = candidates.max { lhs, rhs in
          Self.rank(lhs, viewer: viewer) < Self.rank(rhs, viewer: viewer)
        }
        self.apply(urgent.flatMap { Self.rank($0, viewer: viewer) > 0 ? $0 : nil })
      }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cancellable = nil
    peer = nil
    apply(nil)
  }

  /// The label assistive tech reads with the row, if any.
  var accessibilityDescription: String? { displayed?.title }

  private static func rank(_ state: AgentWorkState, viewer: Int64?) -> Int {
    switch state.runState {
    case .waiting: state.isWaiting(for: viewer) ? 4 : 2
    case .working, .stopping: 3
    case .heldElsewhere: 1
    case .paused, .offline, .idle, .unknown: 0
    }
  }

  private func apply(_ state: AgentWorkState?) {
    guard let state else {
      displayed = nil
      isHidden = true
      return
    }
    let presentation = AgentWorkPresentation(state, viewerUserID: Auth.shared.getCurrentUserId())
    displayed = presentation
    isHidden = false
    let tint: NSColor = switch presentation.tone {
    case .active: .controlAccentColor
    case .attention: .systemOrange
    case .problem: .systemRed
    case .quiet: .secondaryLabelColor
    }
    glyph.image = NSImage(
      systemSymbolName: presentation.isAnimated ? "ellipsis" : presentation.symbolName,
      accessibilityDescription: nil
    )
    glyph.contentTintColor = .white
    effectiveAppearance.performAsCurrentDrawingAppearance {
      ring.backgroundColor = tint.cgColor
      ring.borderColor = NSColor.windowBackgroundColor.cgColor
    }
    toolTip = presentation.title
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.frame = bounds
    ring.cornerRadius = bounds.width / 2
    ring.borderWidth = 1.5
    CATransaction.commit()
    glyph.frame = bounds.insetBy(dx: 2, dy: 2)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      ring.borderColor = NSColor.windowBackgroundColor.cgColor
    }
  }
}
