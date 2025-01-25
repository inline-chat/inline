import InlineKit
import UIKit

class ComposeEmbedView: UIView {
  var peerId: Peer?

  init(peerId: Peer?) {
    super.init(frame: .zero)
    self.peerId = peerId
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static var height: CGFloat = 60.0

  private lazy var line: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false

    view.backgroundColor = ColorManager.shared.selectedColor
    view.layer.cornerRadius = 2

    return view
  }()

  private lazy var heading: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Replying to Dena"
    label.textColor = ColorManager.shared.selectedColor
    label.font = .systemFont(ofSize: 14, weight: .semibold)

    return label
  }()

  private lazy var text: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Sample message"
    label.textColor = .black
    label.numberOfLines = 1
    label.font = .systemFont(ofSize: 14, weight: .regular)
    return label
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "xmark")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .secondaryLabel

    button.configuration = config
    button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    button.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)

    return button
  }()

  private func setupViews() {
    backgroundColor = .clear

    addSubview(text)
    addSubview(heading)
    addSubview(line)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),

      line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      line.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      line.heightAnchor.constraint(equalToConstant: Self.height),
      line.widthAnchor.constraint(equalToConstant: 4),

      heading.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8),
      heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      heading.topAnchor.constraint(equalTo: topAnchor, constant: 8),

      text.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 8),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      text.topAnchor.constraint(equalTo: heading.bottomAnchor),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      closeButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 28),
      closeButton.heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  @objc func closeTapped() {
    guard let peerId else { return }

    ChatState.shared.clearReplyingMessageId(peer: peerId)
  }
}
