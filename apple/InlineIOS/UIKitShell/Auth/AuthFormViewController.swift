import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import Logger
import UIKit

/// Base screen for one onboarding step: symbol, title, subtitle, a field area and a primary
/// button that rides above the keyboard (keyboardLayoutGuide, iOS 15).
class AuthFormViewController: UIViewController {
  let iconView = UIImageView()
  let titleLabel = UILabel()
  let subtitleLabel = UILabel()
  let fieldStack = UIStackView()
  let errorLabel = UILabel()
  let primaryButton: PrimaryButton
  let footerStack = UIStackView()

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()

  init(systemImage: String?, title: String, subtitle: String? = nil, buttonTitle: String) {
    primaryButton = PrimaryButton(title: buttonTitle)
    super.init(nibName: nil, bundle: nil)
    iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
    titleLabel.text = title
    subtitleLabel.text = subtitle
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    iconView.preferredSymbolConfiguration = .init(pointSize: 30, weight: .medium)
    iconView.tintColor = .label
    iconView.contentMode = .scaleAspectFit
    iconView.isHidden = iconView.image == nil

    titleLabel.font = .preferredFont(forTextStyle: .title1).withWeight(.semibold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 0
    titleLabel.textAlignment = .center

    subtitleLabel.font = .preferredFont(forTextStyle: .body)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 0
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = subtitleLabel.text?.isEmpty ?? true

    errorLabel.font = .preferredFont(forTextStyle: .callout)
    errorLabel.adjustsFontForContentSizeCategory = true
    errorLabel.textColor = .systemRed
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true

    fieldStack.axis = .vertical
    fieldStack.spacing = 8

    contentStack.axis = .vertical
    contentStack.alignment = .fill
    contentStack.spacing = 12
    contentStack.addArrangedSubview(iconView)
    contentStack.addArrangedSubview(titleLabel)
    contentStack.addArrangedSubview(subtitleLabel)
    contentStack.setCustomSpacing(28, after: subtitleLabel)
    contentStack.setCustomSpacing(28, after: titleLabel)
    contentStack.addArrangedSubview(fieldStack)
    contentStack.addArrangedSubview(errorLabel)
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .interactive
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentStack)
    view.addSubview(scrollView)

    footerStack.axis = .vertical
    footerStack.spacing = 12
    footerStack.addArrangedSubview(primaryButton)
    footerStack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(footerStack)

    let readable = view.readableContentGuide
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 48),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
      contentStack.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 8),
      contentStack.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -8),
      contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),

      footerStack.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 8),
      footerStack.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -8),
      footerStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
    ])

    primaryButton.setAction { [weak self] in self?.submit() }
  }

  /// Override: the primary button action.
  func submit() {}

  func showError(_ message: String?) {
    errorLabel.text = message
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
      self.errorLabel.isHidden = message?.isEmpty ?? true
    }
    if let message, !message.isEmpty {
      UIAccessibility.post(notification: .announcement, argument: message)
      CompatHaptics.notify(.error)
    }
  }

  func showError(for error: Error) {
    showError(AuthErrorText.message(for: error))
  }

  /// Text field styled like the onboarding fields.
  static func makeField(placeholder: String) -> UITextField {
    let field = AuthTextField()
    field.placeholder = placeholder
    field.font = .preferredFont(forTextStyle: .title3)
    field.adjustsFontForContentSizeCategory = true
    field.backgroundColor = .secondarySystemBackground
    field.layer.cornerRadius = 14
    field.layer.cornerCurve = .continuous
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
    field.clearButtonMode = .whileEditing
    return field
  }
}

/// Padded text field.
final class AuthTextField: UITextField {
  private let inset = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 12)
  override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
  override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
  override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
}

/// Same wording as the SwiftUI onboarding (`OnboardingUtils.showError`).
enum AuthErrorText {
  static func message(for error: Error) -> String {
    let fallback = String(localized: "Something went wrong. Please try again.")
    let message: String?
    if let apiError = error as? APIError {
      message = switch apiError {
      case .networkError:
        String(localized: "Check your connection and try again.")
      case .rateLimited, .httpError(statusCode: 420), .httpError(statusCode: 429):
        String(localized: "Too many tries. Please try again after a few minutes.")
      case .httpError(statusCode: 408):
        String(localized: "The request took too long. Please try again.")
      case let .error(_, _, description):
        description
      case .invalidURL, .invalidResponse, .httpError, .decodingError:
        fallback
      }
    } else if let urlError = error as? URLError {
      message = urlError.code == .timedOut
        ? String(localized: "The request took too long. Please try again.")
        : String(localized: "Check your connection and try again.")
    } else {
      message = (error as? any LocalizedError)?.errorDescription
    }
    Log.shared.error("Onboarding request failed", error: error)
    if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return message
    }
    return fallback
  }
}
