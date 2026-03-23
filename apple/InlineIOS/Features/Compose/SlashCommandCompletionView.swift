import InlineKit
import InlineIOSUI
import UIKit

protocol SlashCommandCompletionDelegate: AnyObject {
  func slashCommandCompletion(_ view: SlashCommandCompletionView, didSelect suggestion: PeerBotCommandSuggestion)
  func slashCommandCompletionDidRequestClose(_ view: SlashCommandCompletionView)
}

final class SlashCommandCompletionView: UIView {
  static let maxHeight: CGFloat = 216
  static let itemHeight: CGFloat = 56

  weak var delegate: SlashCommandCompletionDelegate?

  private var suggestions: [PeerBotCommandSuggestion] = []
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

  func updateSuggestions(_ suggestions: [PeerBotCommandSuggestion]) {
    self.suggestions = suggestions
    selectedIndex = suggestions.isEmpty ? 0 : min(selectedIndex, suggestions.count - 1)
    rebuildRows()
    updateHeight()
  }

  func show() {
    guard !suggestions.isEmpty else { return }

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

  func selectNext() {
    guard !suggestions.isEmpty else { return }
    selectedIndex = (selectedIndex + 1) % suggestions.count
    updateSelection()
  }

  func selectPrevious() {
    guard !suggestions.isEmpty else { return }
    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : suggestions.count - 1
    updateSelection()
  }

  @discardableResult
  func selectCurrentItem() -> Bool {
    guard suggestions.indices.contains(selectedIndex) else { return false }
    delegate?.slashCommandCompletion(self, didSelect: suggestions[selectedIndex])
    return true
  }

  private func rebuildRows() {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for (index, suggestion) in suggestions.enumerated() {
      let row = makeRow(for: suggestion, index: index)
      stackView.addArrangedSubview(row)
    }

    updateSelection()
  }

  private func makeRow(for suggestion: PeerBotCommandSuggestion, index: Int) -> UIView {
    let containerView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.tag = index

    let avatarView = UserAvatarView()
    avatarView.configure(with: suggestion.botUserInfo, size: 30)
    avatarView.translatesAutoresizingMaskIntoConstraints = false

    let commandLabel = UILabel()
    commandLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    commandLabel.text = "/\(suggestion.command)"
    commandLabel.textColor = .label
    commandLabel.lineBreakMode = .byTruncatingTail

    let botLabel = UILabel()
    botLabel.font = .systemFont(ofSize: 12, weight: .medium)
    botLabel.textColor = .secondaryLabel
    botLabel.textAlignment = .right
    botLabel.text = suggestion.isAmbiguous ? (suggestion.botLabel ?? suggestion.botDisplayName) : nil
    botLabel.lineBreakMode = .byTruncatingTail

    let descriptionLabel = UILabel()
    descriptionLabel.font = .systemFont(ofSize: 12, weight: .regular)
    descriptionLabel.textColor = .secondaryLabel
    descriptionLabel.numberOfLines = 1
    descriptionLabel.text = suggestion.description
    descriptionLabel.lineBreakMode = .byTruncatingTail

    let topRow = UIStackView(arrangedSubviews: [commandLabel, botLabel])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 6

    let labelsStack = UIStackView(arrangedSubviews: [topRow, descriptionLabel])
    labelsStack.axis = .vertical
    labelsStack.spacing = 2
    labelsStack.translatesAutoresizingMaskIntoConstraints = false

    let rowStack = UIStackView(arrangedSubviews: [avatarView, labelsStack])
    rowStack.axis = .horizontal
    rowStack.alignment = .center
    rowStack.spacing = 8
    rowStack.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(rowStack)

    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: 30),
      avatarView.heightAnchor.constraint(equalToConstant: 30),

      rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      rowStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      rowStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
      containerView.heightAnchor.constraint(equalToConstant: Self.itemHeight),
    ])

    commandLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    botLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleRowTap(_:)))
    containerView.addGestureRecognizer(tapGesture)
    return containerView
  }

  private func updateSelection() {
    for (index, view) in stackView.arrangedSubviews.enumerated() {
      view.backgroundColor = index == selectedIndex
        ? ThemeManager.shared.selected.backgroundColor.withAlphaComponent(0.16)
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
      itemCount: suggestions.count,
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
    guard let view = gesture.view, suggestions.indices.contains(view.tag) else { return }
    selectedIndex = view.tag
    updateSelection()
    delegate?.slashCommandCompletion(self, didSelect: suggestions[selectedIndex])
  }
}
