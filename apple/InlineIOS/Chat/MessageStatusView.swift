import InlineKit
import UIKit

class MessageMetadata: UIView {
  private let symbolSize: CGFloat = 12

  private let dateLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 11)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let statusImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false

    // Set fixed width and height constraints
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    return imageView
  }()

  private let stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  init(date: Date, status: MessageSendingStatus?, isOutgoing: Bool) {
    super.init(frame: .zero)
    setupViews()
    configure(date: date, status: status, isOutgoing: isOutgoing)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(stackView)
    stackView.addArrangedSubview(dateLabel)
    stackView.addArrangedSubview(statusImageView)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),

      // Add fixed width and height constraints for statusImageView
      statusImageView.widthAnchor.constraint(equalToConstant: symbolSize),
      statusImageView.heightAnchor.constraint(equalToConstant: symbolSize)
    ])
  }

  func configure(date: Date, status: MessageSendingStatus?, isOutgoing: Bool) {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm"
    dateLabel.text = dateFormatter.string(from: date)
    dateLabel.textColor = isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .gray

    if isOutgoing && status != nil {
      statusImageView.isHidden = false

      let imageName: String
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize)
        .applying(UIImage.SymbolConfiguration(weight: .medium))
      switch status {
      case .sent:
        imageName = "checkmark"
      case .sending:
        imageName = "clock"
      case .failed:
        imageName = "exclamationmark"
      case .none:
        imageName = ""
      }

      statusImageView.image = UIImage(systemName: imageName)?
        .withConfiguration(symbolConfig)
        .withAlignmentRectInsets(.init(top: 0, left: -2, bottom: 0, right: -2)) // Fine-tune alignment if needed

      statusImageView.tintColor =
        status == .failed
          ? (isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .red)
          : (isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .gray)
    } else {
      statusImageView.isHidden = true
    }
  }
}

#if DEBUG
import SwiftUI

struct MessageMetadataPreview: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      // Outgoing message status previews
      HStack {
        Spacer()
        UIViewPreview {
          MessageMetadata(date: Date(), status: .sending, isOutgoing: true)
        }
      }
      HStack {
        Spacer()
        UIViewPreview {
          MessageMetadata(date: Date(), status: .sent, isOutgoing: true)
        }
      }
      HStack {
        Spacer()
        UIViewPreview {
          MessageMetadata(date: Date(), status: .failed, isOutgoing: true)
        }
      }

      // Incoming message status preview
      HStack {
        UIViewPreview {
          MessageMetadata(date: Date(), status: nil, isOutgoing: false)
        }
        Spacer()
      }
    }
    .padding()
    .background(Color(.systemBackground))
    .previewLayout(.sizeThatFits)
  }
}

// Helper struct to wrap UIView for SwiftUI previews
struct UIViewPreview<View: UIView>: UIViewRepresentable {
  let view: View

  init(_ builder: @escaping () -> View) {
    view = builder()
  }

  func makeUIView(context: Context) -> some UIView {
    return view
  }

  func updateUIView(_ uiView: UIViewType, context: Context) {
    // No updates needed
  }
}
#endif
