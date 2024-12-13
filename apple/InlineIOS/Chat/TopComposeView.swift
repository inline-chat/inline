// import GRDB
// import InlineKit
// import UIKit
//
// class TopComposeView: UIView {
//  private let contentStack: UIStackView = {
//    let stack = UIStackView()
//    stack.axis = .horizontal
//    stack.spacing = 8
//    stack.alignment = .center
//    return stack
//  }()
//
//  private let messageLabel: UILabel = {
//    let label = UILabel()
//    label.numberOfLines = 2
//    label.font = .systemFont(ofSize: 14)
//    label.textColor = .secondaryLabel
//    return label
//  }()
//
//  private let closeButton: UIButton = {
//    let button = UIButton()
//    button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
//    button.tintColor = .secondaryLabel
//    return button
//  }()
//
//  var onClose: (() -> Void)?
//  private let messageId: Int64
//
//  init(messageId: Int64, frame: CGRect = .zero) {
//    self.messageId = messageId
//    super.init(frame: frame)
//    setupView()
//    configure()
//  }
//
//  @available(*, unavailable)
//  required init?(coder: NSCoder) {
//    fatalError("init(coder:) has not been implemented")
//  }
//
//  private func setupView() {
//    backgroundColor = .secondarySystemBackground
//
//    addSubview(contentStack)
//    contentStack.translatesAutoresizingMaskIntoConstraints = false
//
//    contentStack.addArrangedSubview(messageLabel)
//    contentStack.addArrangedSubview(closeButton)
//
//    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
//
//    NSLayoutConstraint.activate([
//      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
//      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
//      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
//      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
//
//      closeButton.widthAnchor.constraint(equalToConstant: 24),
//      closeButton.heightAnchor.constraint(equalToConstant: 24)
//    ])
//  }
//
//  private func configure() {
//    Task {
//      do {
//        try await AppDatabase.shared.dbWriter.read { db in
//          if let message = try Message.fetchOne(db, id: messageId) {
//            await MainActor.run {
//              messageLabel.text = "Replying to: \(message.text)"
//            }
//          }
//        }
//      } catch {
//        await MainActor.run {
//          messageLabel.text = "Message not found"
//        }
//        print("Error fetching message: \(error)")
//      }
//    }
//  }
//
//  @objc private func closeTapped() {
//    onClose?()
//  }
// }
