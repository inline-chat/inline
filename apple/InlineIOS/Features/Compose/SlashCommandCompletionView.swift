import InlineKit
import UIKit

protocol SlashCommandCompletionDelegate: AnyObject {
  func slashCommandCompletion(_ view: SlashCommandCompletionView, didSelect suggestion: PeerBotCommandSuggestion)
  func slashCommandCompletionDidRequestClose(_ view: SlashCommandCompletionView)
}

final class SlashCommandCompletionView: UIView {
  static let maxHeight: CGFloat = 216
  static let itemHeight: CGFloat = 64

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
  }

  func show() {
    guard !suggestions.isEmpty else { return }

    isHidden = false
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

    let commandLabel = UILabel()
    commandLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
    commandLabel.text = "/\(suggestion.command)"
    commandLabel.textColor = .label

    let botLabel = UILabel()
    botLabel.font = .systemFont(ofSize: 13, weight: .medium)
    botLabel.textColor = .secondaryLabel
    botLabel.textAlignment = .right
    botLabel.text = suggestion.isAmbiguous ? (suggestion.botLabel ?? suggestion.botDisplayName) : nil
    botLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let descriptionLabel = UILabel()
    descriptionLabel.font = .systemFont(ofSize: 14)
    descriptionLabel.textColor = .secondaryLabel
    descriptionLabel.numberOfLines = 1
    descriptionLabel.text = suggestion.description

    let topRow = UIStackView(arrangedSubviews: [commandLabel, botLabel])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 8

    let stack = UIStackView(arrangedSubviews: [topRow, descriptionLabel])
    stack.axis = .vertical
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
      containerView.heightAnchor.constraint(equalToConstant: Self.itemHeight),
    ])

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

  @objc
  private func handleRowTap(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view, suggestions.indices.contains(view.tag) else { return }
    selectedIndex = view.tag
    updateSelection()
    delegate?.slashCommandCompletion(self, didSelect: suggestions[selectedIndex])
  }
}
