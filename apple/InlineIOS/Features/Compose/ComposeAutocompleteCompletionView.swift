import InlineIOSUI
import InlineKit
import UIKit

@MainActor
protocol ComposeAutocompleteCompletionDelegate: AnyObject {
  func autocompleteCompletion(_ view: ComposeAutocompleteCompletionView, didSelect item: ComposeAutocompleteItem)
  func autocompleteCompletionDidRequestClose(_ view: ComposeAutocompleteCompletionView)
}

final class ComposeAutocompleteCompletionView: UIView {
  static let maxHeight: CGFloat = 216
  static let itemHeight: CGFloat = 56

  weak var delegate: ComposeAutocompleteCompletionDelegate?

  private var items: [ComposeAutocompleteItem] = []
  private var selectedIndex = 0

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .clear
    return scrollView
  }()

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var backgroundView: UIView = {
    let view = UIView()
    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    blurView.layer.cornerRadius = 12
    blurView.clipsToBounds = true
    view.addSubview(blurView)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: view.topAnchor),
      blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    view.layer.cornerRadius = 12
    view.layer.borderWidth = 1
    view.layer.borderColor = UIColor.lightGray.withAlphaComponent(0.2).cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  var isVisible: Bool {
    !isHidden && alpha > 0
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(items: [ComposeAutocompleteItem], selectedIndex: Int) {
    self.items = items
    self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
    rebuildRows()
    updateHeight()
  }

  func setSelectedIndex(_ selectedIndex: Int) {
    guard items.indices.contains(selectedIndex) else { return }
    self.selectedIndex = selectedIndex
    updateSelection()
  }

  func show() {
    guard !items.isEmpty else { return }

    isHidden = false
    updateHeight()
    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
      self.alpha = 1.0
      self.transform = .identity
    }
  }

  func hide() {
    UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn]) {
      self.alpha = 0.0
      self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    } completion: { _ in
      self.isHidden = true
    }
  }

  @discardableResult
  func selectCurrentItem() -> Bool {
    guard items.indices.contains(selectedIndex) else { return false }
    delegate?.autocompleteCompletion(self, didSelect: items[selectedIndex])
    return true
  }

  private func setupView() {
    backgroundColor = .clear
    clipsToBounds = false
    isHidden = true
    alpha = 0
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundView)
    addSubview(scrollView)
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])
  }

  private func rebuildRows() {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for (index, item) in items.enumerated() {
      let row = makeRow(for: item, index: index)
      stackView.addArrangedSubview(row)
    }

    updateSelection()
  }

  private func makeRow(for item: ComposeAutocompleteItem, index: Int) -> UIView {
    let containerView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.tag = index

    let iconView = makeIconView(for: item)

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.text = item.title
    titleLabel.textColor = .label
    titleLabel.lineBreakMode = .byTruncatingTail

    let subtitleLabel = UILabel()
    subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 1
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

    containerView.addSubview(rowStack)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 30),
      iconView.heightAnchor.constraint(equalToConstant: 30),

      rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      rowStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      rowStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
      containerView.heightAnchor.constraint(equalToConstant: Self.itemHeight),
    ])

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleRowTap(_:)))
    containerView.addGestureRecognizer(tapGesture)
    return containerView
  }

  private func makeIconView(for item: ComposeAutocompleteItem) -> UIView {
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
      view.backgroundColor = index == selectedIndex
        ? UIColor.tertiarySystemFill
        : .clear
      view.layer.cornerRadius = 10
      view.clipsToBounds = true
    }

    guard stackView.arrangedSubviews.indices.contains(selectedIndex) else { return }
    let selectedView = stackView.arrangedSubviews[selectedIndex]
    scrollView.scrollRectToVisible(selectedView.frame.insetBy(dx: 0, dy: -8), animated: false)
  }

  private func updateHeight() {
    let constrainedHeight = suggestionListHeight(
      itemCount: items.count,
      itemHeight: Self.itemHeight,
      maxVisibleItems: 4,
      maxHeight: Self.maxHeight
    )

    if let heightConstraint = constraints.first(where: { $0.firstAttribute == .height }) {
      heightConstraint.constant = constrainedHeight
    } else {
      heightAnchor.constraint(equalToConstant: constrainedHeight).isActive = true
    }
  }

  @objc
  private func handleRowTap(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view, items.indices.contains(view.tag) else { return }
    selectedIndex = view.tag
    updateSelection()
    delegate?.autocompleteCompletion(self, didSelect: items[selectedIndex])
  }
}
