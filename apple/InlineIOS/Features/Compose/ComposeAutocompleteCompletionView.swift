import InlineKit
import UIKit

@MainActor
protocol ComposeAutocompleteCompletionDelegate: AnyObject {
  func autocompleteCompletion(
    _ view: ComposeAutocompleteCompletionView,
    didSelect item: ComposeAutocompleteItem,
    activation: ComposeAutocompleteSelectionActivation
  )
}

enum ComposeAutocompleteSelectionActivation {
  case primary
  case completionOnly
}

enum ComposeAutocompletePlaceholder: Equatable {
  case loading
  case failed
}

private final class ComposeAutocompleteRowControl: UIControl {
  var isKeyboardSelected = false {
    didSet {
      updateBackground()
    }
  }

  override var isHighlighted: Bool {
    didSet {
      updateBackground()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = ComposeAutocompleteCompletionView.rowCornerRadius
    layer.cornerCurve = .continuous
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func updateBackground() {
    if isHighlighted {
      backgroundColor = UIColor.label.withAlphaComponent(0.05)
    } else if isKeyboardSelected {
      backgroundColor = UIColor.label.withAlphaComponent(0.08)
    } else {
      backgroundColor = .clear
    }
  }
}

final class ComposeAutocompleteCompletionView: UIView {
  static let maxHeight: CGFloat = 280
  static let minimumItemHeight: CGFloat = 56
  static let cornerRadius: CGFloat = 20
  static let contentInset: CGFloat = 4
  static let rowCornerRadius = cornerRadius - contentInset

  weak var delegate: ComposeAutocompleteCompletionDelegate?

  private var items: [ComposeAutocompleteItem] = []
  private var placeholder: ComposeAutocompletePlaceholder?
  private var selectedIndex = 0
  private var heightConstraint: NSLayoutConstraint?
  private var visibilityAnimator: UIViewPropertyAnimator?
  private var visibilityGeneration = 0
  private var isPresented = false
  private var showsKeyboardSelection = false
  private var isContentInteractionEnabled = true

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .clear
    scrollView.delaysContentTouches = false
    scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(
      top: Self.contentInset,
      left: 0,
      bottom: Self.contentInset,
      right: 2
    )
    return scrollView
  }()

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var backgroundView: UIVisualEffectView = {
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = true
      effect = glassEffect
    } else {
      effect = UIBlurEffect(style: .systemMaterial)
    }

    let view = UIVisualEffectView(effect: effect)
    view.layer.cornerRadius = Self.cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  var isVisible: Bool {
    isPresented
  }

  var canSelectItems: Bool {
    isPresented && isContentInteractionEnabled && placeholder == nil && !items.isEmpty
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
  }

  func update(
    items: [ComposeAutocompleteItem],
    selectedIndex: Int,
    placeholder: ComposeAutocompletePlaceholder?
  ) {
    let shouldRebuild = self.items != items || self.placeholder != placeholder
    self.items = items
    self.placeholder = placeholder
    self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
    scrollView.isScrollEnabled = placeholder == nil
    setContentInteractionEnabled(placeholder == nil)
    if shouldRebuild {
      rebuildRows()
    }
    updateHeight()
    updateSelection()
  }

  func show(animated: Bool) {
    guard !items.isEmpty || placeholder != nil else { return }
    guard !isPresented else { return }

    visibilityGeneration += 1
    visibilityAnimator?.stopAnimation(true)
    visibilityAnimator = nil
    isPresented = true
    isUserInteractionEnabled = true
    accessibilityElementsHidden = false
    isHidden = false
    alpha = 1
    updateHeight()
    guard animated, !UIAccessibility.isReduceMotionEnabled else {
      transform = .identity
      announceSuggestionsIfNeeded()
      return
    }

    transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.98, y: 0.98)
    let animator = UIViewPropertyAnimator(duration: 0.2, dampingRatio: 0.88) { [weak self] in
      self?.transform = .identity
    }
    animator.addCompletion { [weak self] _ in
      self?.visibilityAnimator = nil
      self?.announceSuggestionsIfNeeded()
    }
    visibilityAnimator = animator
    animator.startAnimation()
  }

  func hide() {
    guard isPresented else { return }

    visibilityGeneration += 1
    let generation = visibilityGeneration
    visibilityAnimator?.stopAnimation(true)
    visibilityAnimator = nil
    isPresented = false
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    guard !UIAccessibility.isReduceMotionEnabled else {
      isHidden = true
      transform = .identity
      return
    }

    let animator = UIViewPropertyAnimator(duration: 0.15, curve: .easeIn) { [weak self] in
      self?.transform = CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.98, y: 0.98)
    }
    animator.addCompletion { [weak self] position in
      guard let self,
            position == .end,
            self.visibilityGeneration == generation,
            !self.isPresented
      else {
        return
      }
      self.isHidden = true
      self.transform = .identity
      self.visibilityAnimator = nil
    }
    visibilityAnimator = animator
    animator.startAnimation()
  }

  @discardableResult
  func selectCurrentItem(activation: ComposeAutocompleteSelectionActivation = .primary) -> Bool {
    guard canSelectItems, items.indices.contains(selectedIndex) else { return false }
    delegate?.autocompleteCompletion(self, didSelect: items[selectedIndex], activation: activation)
    return true
  }

  func setContentInteractionEnabled(_ enabled: Bool) {
    guard isContentInteractionEnabled != enabled else { return }
    isContentInteractionEnabled = enabled
    scrollView.isUserInteractionEnabled = enabled
    if !enabled {
      showsKeyboardSelection = false
    }
    for case let control as ComposeAutocompleteRowControl in stackView.arrangedSubviews {
      control.isEnabled = enabled
    }
    updateSelection()
  }

  func setKeyboardSelectionVisible(_ visible: Bool) {
    guard showsKeyboardSelection != visible else { return }
    showsKeyboardSelection = visible
    updateSelection()
  }

  private func setupView() {
    backgroundColor = .clear
    clipsToBounds = false
    isHidden = true
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    alpha = 1
    translatesAutoresizingMaskIntoConstraints = false
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOffset = CGSize(width: 0, height: 8)
    layer.shadowRadius = 18
    layer.shadowOpacity = 0.12

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contentSizeCategoryDidChange),
      name: UIContentSizeCategory.didChangeNotification,
      object: nil
    )

    addSubview(backgroundView)
    backgroundView.contentView.addSubview(scrollView)
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.topAnchor.constraint(equalTo: backgroundView.contentView.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: backgroundView.contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: backgroundView.contentView.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: backgroundView.contentView.bottomAnchor),

      stackView.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor,
        constant: Self.contentInset
      ),
      stackView.leadingAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.leadingAnchor,
        constant: Self.contentInset
      ),
      stackView.trailingAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.trailingAnchor,
        constant: -Self.contentInset
      ),
      stackView.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor,
        constant: -Self.contentInset
      ),
      stackView.widthAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.widthAnchor,
        constant: -(Self.contentInset * 2)
      ),
    ])

    let initialHeight = heightAnchor.constraint(equalToConstant: 0)
    initialHeight.priority = UILayoutPriority(999)
    initialHeight.isActive = true
    heightConstraint = initialHeight
  }

  private func rebuildRows() {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    if let placeholder {
      stackView.addArrangedSubview(makePlaceholderRow(placeholder))
    } else {
      for (index, item) in items.enumerated() {
        let row = makeRow(for: item, index: index)
        stackView.addArrangedSubview(row)
      }
    }

    updateSelection()
  }

  private func makeRow(for item: ComposeAutocompleteItem, index: Int) -> UIView {
    let containerView = ComposeAutocompleteRowControl()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.tag = index
    containerView.isEnabled = isContentInteractionEnabled
    containerView.isAccessibilityElement = true
    containerView.accessibilityLabel = [item.title, item.subtitle]
      .compactMap { $0 }
      .joined(separator: ", ")
    containerView.accessibilityTraits = .button
    containerView.addAction(UIAction { [weak self, weak containerView] _ in
      guard let self, let containerView else { return }
      self.selectItem(at: containerView.tag)
    }, for: .touchUpInside)

    let iconView = makeIconView(for: item)

    let titleLabel = UILabel()
    titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: .systemFont(ofSize: 15, weight: .semibold)
    )
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.text = item.title
    titleLabel.textColor = .label
    titleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    titleLabel.lineBreakMode = .byTruncatingTail

    let subtitleLabel = UILabel()
    subtitleLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .systemFont(ofSize: 12, weight: .regular)
    )
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    subtitleLabel.text = item.subtitle
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.isHidden = item.subtitle?.isEmpty != false

    let labelsStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    labelsStack.axis = .vertical
    labelsStack.spacing = 2
    labelsStack.translatesAutoresizingMaskIntoConstraints = false

    let rowStack = UIStackView(arrangedSubviews: [iconView, labelsStack])
    rowStack.axis = .horizontal
    rowStack.alignment = .center
    rowStack.spacing = 9
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    // The row control must remain the hit-test target. Decorative descendants otherwise
    // consume the touch and prevent UIControl from beginning touch tracking.
    rowStack.isUserInteractionEnabled = false

    containerView.addSubview(rowStack)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 30),
      iconView.heightAnchor.constraint(equalToConstant: 30),

      rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      rowStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      rowStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
      containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumItemHeight),
    ])
    return containerView
  }

  private func makePlaceholderRow(_ placeholder: ComposeAutocompletePlaceholder) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isAccessibilityElement = true

    let iconView: UIView
    let message: String
    switch placeholder {
    case .loading:
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      iconView = spinner
      message = String(localized: "Loading suggestions")
      container.accessibilityTraits = .updatesFrequently
    case .failed:
      let imageView = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
      imageView.tintColor = .secondaryLabel
      imageView.contentMode = .scaleAspectFit
      iconView = imageView
      message = String(localized: "Couldn’t load suggestions. Type to retry.")
      container.accessibilityTraits = .staticText
    }

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.isUserInteractionEnabled = false

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    label.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    label.text = message

    container.accessibilityLabel = message
    container.addSubview(iconView)
    container.addSubview(label)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),
      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
      container.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumItemHeight),
    ])
    return container
  }

  private func makeIconView(for item: ComposeAutocompleteItem) -> UIView {
    if let userInfo = item.avatarUserInfo {
      let avatarView = UserAvatarView()
      avatarView.configure(with: userInfo, size: 30)
      avatarView.translatesAutoresizingMaskIntoConstraints = false
      avatarView.isUserInteractionEnabled = false
      return avatarView
    }

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.layer.cornerRadius = 15
    container.backgroundColor = ThemeManager.shared.selected.accent.withAlphaComponent(0.12)

    if let emoji = item.emoji, !emoji.isEmpty {
      let label = UILabel()
      label.text = emoji
      label.font = .systemFont(ofSize: 17)
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(label)

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      ])
    } else {
      let imageView = UIImageView()
      imageView.image = UIImage(systemName: item.symbol ?? "bubble.left")
      imageView.tintColor = ThemeManager.shared.selected.accent
      imageView.contentMode = .scaleAspectFit
      imageView.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(imageView)

      NSLayoutConstraint.activate([
        imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        imageView.widthAnchor.constraint(equalToConstant: 16),
        imageView.heightAnchor.constraint(equalToConstant: 16),
      ])
    }

    return container
  }

  private func updateSelection() {
    for (index, view) in stackView.arrangedSubviews.enumerated() {
      guard let control = view as? ComposeAutocompleteRowControl else { continue }
      let isSelected = showsKeyboardSelection && index == selectedIndex
      control.isKeyboardSelected = isSelected
      var traits: UIAccessibilityTraits = .button
      if isSelected {
        traits.insert(.selected)
      }
      if !isContentInteractionEnabled {
        traits.insert(.notEnabled)
      }
      control.accessibilityTraits = traits
    }

    guard showsKeyboardSelection,
          stackView.arrangedSubviews.indices.contains(selectedIndex)
    else {
      return
    }
    let selectedView = stackView.arrangedSubviews[selectedIndex]
    let selectedRect = selectedView.convert(selectedView.bounds, to: scrollView).insetBy(dx: 0, dy: -8)
    scrollView.scrollRectToVisible(selectedRect, animated: false)
  }

  private func updateHeight() {
    let usesExpandedAccessibilityRows = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    let titleHeight = UIFontMetrics(forTextStyle: .body)
      .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold)).lineHeight
    let subtitleHeight = UIFontMetrics(forTextStyle: .caption1)
      .scaledFont(for: .systemFont(ofSize: 12)).lineHeight
    let lineMultiplier: CGFloat = usesExpandedAccessibilityRows ? 2 : 1
    let itemHeight = max(Self.minimumItemHeight, ceil((titleHeight + subtitleHeight) * lineMultiplier + 18))
    let rowCount = placeholder == nil ? min(items.count, 4) : 1
    let contentHeight = CGFloat(rowCount) * itemHeight + Self.contentInset * 2
    let constrainedHeight = min(contentHeight, Self.maxHeight)

    if let heightConstraint {
      heightConstraint.constant = constrainedHeight
      return
    }

    let constraint = heightAnchor.constraint(equalToConstant: constrainedHeight)
    constraint.priority = UILayoutPriority(999)
    constraint.isActive = true
    heightConstraint = constraint
  }

  private func selectItem(at index: Int) {
    guard canSelectItems, items.indices.contains(index) else { return }
    selectedIndex = index
    updateSelection()
    delegate?.autocompleteCompletion(self, didSelect: items[selectedIndex], activation: .primary)
  }

  private func announceSuggestionsIfNeeded() {
    guard UIAccessibility.isVoiceOverRunning else { return }
    UIAccessibility.post(
      notification: .announcement,
      argument: String(localized: "Autocomplete suggestions available")
    )
  }

  @objc
  private func contentSizeCategoryDidChange() {
    rebuildRows()
    updateHeight()
  }
}
