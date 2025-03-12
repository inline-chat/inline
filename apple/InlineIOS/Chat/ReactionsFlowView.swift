import Auth
import InlineKit
import UIKit

class ReactionsFlowView: UIView {
  // MARK: - Properties

  var horizontalSpacing: CGFloat = 4
  var verticalSpacing: CGFloat = 4
  private var outgoing: Bool = false

  private var containerStackView: UIStackView!

  var onReactionTap: ((String) -> Void)?

  // MARK: - Initialization

  init(outgoing: Bool) {
    self.outgoing = outgoing
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    containerStackView = UIStackView()
    containerStackView.axis = .vertical
    containerStackView.spacing = verticalSpacing
    containerStackView.alignment = .leading
    containerStackView.distribution = .fill
    containerStackView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(containerStackView)

    NSLayoutConstraint.activate([
      containerStackView.topAnchor.constraint(equalTo: topAnchor),
      containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Public Methods

  func configure(with reactions: [(emoji: String, count: Int, userIds: [Int64])]) {
    // Clear existing content
    containerStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

    // Create reaction views
    let reactionViews = reactions.map { reaction -> MessageReactionView in
      let byCurrentUser = reaction.userIds.contains(Auth.shared.getCurrentUserId() ?? 0)
      let view = MessageReactionView(
        emoji: reaction.emoji,
        count: reaction.count,
        byCurrentUser: byCurrentUser,
        outgoing: outgoing
      )

      view.onTap = { [weak self] emoji in
        self?.onReactionTap?(emoji)
      }

      return view
    }
    print("REACTION VIEWS COUNT \(reactionViews.count)")

    // Calculate sizes
    let sizes = reactionViews.map { $0.sizeThatFits(CGSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )) }

    // Organize into rows
    var currentRow = UIStackView()
    currentRow.axis = .horizontal
    currentRow.spacing = horizontalSpacing
    currentRow.alignment = .center

    var currentRowWidth: CGFloat = 0
    let maxWidth = UIScreen.main.bounds.width * 0.7 // Adjust as needed

    for (index, view) in reactionViews.enumerated() {
      let viewWidth = sizes[index].width

      if currentRowWidth + viewWidth > maxWidth, currentRowWidth > 0 {
        // Add the current row and start a new one
        containerStackView.addArrangedSubview(currentRow)

        currentRow = UIStackView()
        currentRow.axis = .horizontal
        currentRow.spacing = horizontalSpacing
        currentRow.alignment = .center
        currentRowWidth = 0
      }

      currentRow.addArrangedSubview(view)
      currentRowWidth += viewWidth + horizontalSpacing
    }

    // Add the last row if it has any views
    if currentRow.arrangedSubviews.count > 0 {
      containerStackView.addArrangedSubview(currentRow)
    }
  }
}
