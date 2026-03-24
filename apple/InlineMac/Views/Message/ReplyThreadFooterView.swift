import AppKit
import Combine
import InlineKit
import QuartzCore

final class ReplyThreadFooterView: NSView {
  struct LayoutMetrics {
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 10
    static let contentSpacing: CGFloat = 7
    static let trailingAccessoryWidth: CGFloat = 30
    static let unreadDotSize: CGFloat = 6
    static let avatarSize: CGFloat = 20
    static let avatarOverlap: CGFloat = 6
    static let maxAvatars = 3
    static let cornerRadius: CGFloat = 8
    static let labelFont: NSFont = .systemFont(ofSize: 12, weight: .medium)
  }

  static func title(for replyCount: Int) -> String {
    replyCount == 1 ? "1 reply" : "\(replyCount) replies"
  }

  static func width(replyCount: Int, hasUnread: Bool, avatarCount: Int) -> CGFloat {
    let boundedAvatarCount = min(max(avatarCount, 0), LayoutMetrics.maxAvatars)
    let titleWidth = ceil((title(for: replyCount) as NSString).size(withAttributes: [
      .font: LayoutMetrics.labelFont,
    ]).width)

    var width = LayoutMetrics.horizontalPadding

    if hasUnread {
      width += LayoutMetrics.unreadDotSize
      width += LayoutMetrics.contentSpacing
    }

    if boundedAvatarCount > 0 {
      width += LayoutMetrics.avatarSize
      if boundedAvatarCount > 1 {
        let extraAvatars = CGFloat(boundedAvatarCount - 1)
        width += extraAvatars * (LayoutMetrics.avatarSize - LayoutMetrics.avatarOverlap)
      }
      width += LayoutMetrics.contentSpacing
    }

    width += titleWidth
    width += LayoutMetrics.trailingAccessoryWidth
    return ceil(width)
  }

  var onClick: (() -> Void)?

  private let backgroundView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private let unreadDotView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private let avatarsContainerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let label: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = LayoutMetrics.labelFont
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private let spinnerView: NSProgressIndicator = {
    let spinner = NSProgressIndicator()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.alphaValue = 0
    return spinner
  }()

  private var avatarViews: [Int64: UserAvatarView] = [:]
  private var userSubscriptions: Set<AnyCancellable> = []
  private var userFetchTasks: [Task<Void, Never>] = []
  private var avatarConstraints: [NSLayoutConstraint] = []
  private var currentUserIds: [Int64] = []
  private var currentHasUnread = false
  private var isHovered = false
  private var isLoading = false
  private var trackingAreaRef: NSTrackingArea?
  private var unreadDotWidthConstraint: NSLayoutConstraint?
  private var unreadDotLeadingConstraint: NSLayoutConstraint?
  private var avatarsLeadingConstraint: NSLayoutConstraint?
  private var labelLeadingConstraint: NSLayoutConstraint?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    addSubview(backgroundView)
    backgroundView.addSubview(unreadDotView)
    backgroundView.addSubview(avatarsContainerView)
    backgroundView.addSubview(label)
    backgroundView.addSubview(spinnerView)

    unreadDotWidthConstraint = unreadDotView.widthAnchor.constraint(equalToConstant: LayoutMetrics.unreadDotSize)
    unreadDotLeadingConstraint = unreadDotView.leadingAnchor.constraint(
      equalTo: backgroundView.leadingAnchor,
      constant: LayoutMetrics.horizontalPadding
    )
    avatarsLeadingConstraint = avatarsContainerView.leadingAnchor.constraint(
      equalTo: unreadDotView.trailingAnchor,
      constant: LayoutMetrics.contentSpacing
    )
    labelLeadingConstraint = label.leadingAnchor.constraint(
      equalTo: avatarsContainerView.trailingAnchor,
      constant: LayoutMetrics.contentSpacing
    )

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: LayoutMetrics.height),

      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      unreadDotLeadingConstraint!,
      unreadDotView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
      unreadDotWidthConstraint!,
      unreadDotView.heightAnchor.constraint(equalToConstant: LayoutMetrics.unreadDotSize),

      avatarsLeadingConstraint!,
      avatarsContainerView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
      avatarsContainerView.heightAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),

      labelLeadingConstraint!,
      label.trailingAnchor.constraint(equalTo: spinnerView.leadingAnchor, constant: -LayoutMetrics.contentSpacing),
      label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),

      spinnerView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -LayoutMetrics.horizontalPadding),
      spinnerView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
      spinnerView.widthAnchor.constraint(equalToConstant: LayoutMetrics.trailingAccessoryWidth - LayoutMetrics.horizontalPadding),
      spinnerView.heightAnchor.constraint(equalToConstant: LayoutMetrics.trailingAccessoryWidth - LayoutMetrics.horizontalPadding),
    ])

    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(clickGesture)
  }

  func configure(replyCount: Int, hasUnread: Bool, recentReplierUserIds: [Int64]) {
    currentHasUnread = hasUnread
    label.stringValue = Self.title(for: replyCount)
    label.textColor = hasUnread ? .labelColor : .secondaryLabelColor

    unreadDotView.layer?.cornerRadius = LayoutMetrics.unreadDotSize / 2
    unreadDotView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    unreadDotView.isHidden = !hasUnread
    unreadDotWidthConstraint?.constant = hasUnread ? LayoutMetrics.unreadDotSize : 0
    avatarsLeadingConstraint?.constant = hasUnread ? LayoutMetrics.contentSpacing : 0

    let avatarUserIds = Array(recentReplierUserIds.prefix(LayoutMetrics.maxAvatars))
    labelLeadingConstraint?.constant = avatarUserIds.isEmpty ? 0 : LayoutMetrics.contentSpacing
    updateAvatars(userIds: avatarUserIds)
    updateAppearance()
  }

  func reset() {
    userSubscriptions.removeAll()
    userFetchTasks.forEach { $0.cancel() }
    userFetchTasks.removeAll()
    currentUserIds = []
    setLoading(false)
    clearAvatarViews()
  }

  func setLoading(_ loading: Bool) {
    guard isLoading != loading else { return }
    isLoading = loading
    if loading {
      spinnerView.startAnimation(nil)
    } else {
      spinnerView.stopAnimation(nil)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      spinnerView.animator().alphaValue = loading ? 1 : 0
    }
  }

  @objc private func handleClick() {
    guard !isLoading else { return }
    onClick?()
  }

  private func updateAvatars(userIds: [Int64]) {
    guard userIds != currentUserIds else { return }

    userSubscriptions.removeAll()
    userFetchTasks.forEach { $0.cancel() }
    userFetchTasks.removeAll()
    currentUserIds = userIds

    clearAvatarViews()

    guard !userIds.isEmpty else {
      avatarsContainerView.isHidden = true
      return
    }

    avatarsContainerView.isHidden = false

    var previousView: UserAvatarView?
    for (index, userId) in userIds.enumerated() {
      let avatarView = UserAvatarView(userInfo: ObjectCache.shared.getUser(id: userId) ?? .deleted, size: LayoutMetrics.avatarSize)
      avatarView.translatesAutoresizingMaskIntoConstraints = false
      avatarView.wantsLayer = true
      avatarView.layer?.cornerRadius = LayoutMetrics.avatarSize / 2
      avatarView.layer?.masksToBounds = true
      avatarView.layer?.borderWidth = 1
      avatarView.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
      avatarsContainerView.addSubview(avatarView)
      avatarViews[userId] = avatarView

      var constraints: [NSLayoutConstraint] = [
        avatarView.topAnchor.constraint(equalTo: avatarsContainerView.topAnchor),
        avatarView.widthAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),
        avatarView.heightAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),
      ]

      if let previousView {
        constraints.append(
          avatarView.leadingAnchor.constraint(
            equalTo: previousView.leadingAnchor,
            constant: LayoutMetrics.avatarSize - LayoutMetrics.avatarOverlap
          )
        )
      } else {
        constraints.append(avatarView.leadingAnchor.constraint(equalTo: avatarsContainerView.leadingAnchor))
      }

      if index == userIds.count - 1 {
        constraints.append(avatarView.trailingAnchor.constraint(equalTo: avatarsContainerView.trailingAnchor))
      }

      NSLayoutConstraint.activate(constraints)
      avatarConstraints.append(contentsOf: constraints)
      previousView = avatarView

      ObjectCache.shared
        .getUserPublisher(id: userId)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] userInfo in
          guard let self else { return }
          guard self.currentUserIds.contains(userId) else { return }
          guard let avatarView = self.avatarViews[userId], let userInfo else { return }
          avatarView.update(userInfo: userInfo)
        }
        .store(in: &userSubscriptions)

      if ObjectCache.shared.getUser(id: userId) == nil {
        userFetchTasks.append(Task { @MainActor in
          try? await DataManager.shared.getUser(id: userId)
        })
      }
    }
  }

  private func clearAvatarViews() {
    NSLayoutConstraint.deactivate(avatarConstraints)
    avatarConstraints.removeAll()
    avatarViews.values.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }

    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    trackingAreaRef = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard isHovered == false else { return }
    isHovered = true
    updateAppearance(animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard isHovered == true else { return }
    isHovered = false
    updateAppearance(animated: true)
  }

  private func updateAppearance(animated: Bool = false) {
    backgroundView.layer?.cornerRadius = LayoutMetrics.cornerRadius
    let baseAlpha: CGFloat = currentHasUnread ? 0.12 : 0.06
    let hoverAlpha: CGFloat = currentHasUnread ? 0.17 : 0.1
    let backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isHovered ? hoverAlpha : baseAlpha).cgColor

    CATransaction.begin()
    CATransaction.setAnimationDuration(animated ? 0.12 : 0)
    backgroundView.layer?.backgroundColor = backgroundColor
    CATransaction.commit()
  }
}
