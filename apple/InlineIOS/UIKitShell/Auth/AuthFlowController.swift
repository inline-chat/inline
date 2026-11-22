import Auth
import InlineIOSFoundation
import InlineKit
import Logger
import UIKit

/// UIKit onboarding: welcome → method → email/phone → code (→ invite) → profile → username.
/// Calls the same InlineKit APIs as the SwiftUI onboarding it replaces.
@MainActor
final class AuthFlowController: UINavigationController {
  private let router: MainViewRouter

  init(router: MainViewRouter) {
    self.router = router
    super.init(nibName: nil, bundle: nil)
    navigationBar.prefersLargeTitles = false
    setViewControllers(initialStack(), animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Pending profile setup (signed in, no name yet) resumes at the profile step.
  private func initialStack() -> [UIViewController] {
    if case let .profile(userId) = router.onboardingNavigation.path.last {
      return [AuthProfileViewController(flow: self, userId: userId)]
    }
    return [AuthWelcomeViewController(flow: self)]
  }

  func push(_ controller: UIViewController) {
    pushViewController(controller, animated: true)
  }

  /// Sign-in finished; decide between profile setup and the main app.
  func finishSignIn(result: VerifyCode) {
    Analytics.identify(
      userId: result.userId,
      email: result.user.email,
      name: result.user.anyName,
      username: result.user.username
    )
    if OnboardingSession.requiresSetup(pendingSetup: result.user.pendingSetup, firstName: result.user.firstName) {
      push(AuthProfileViewController(flow: self, userId: result.userId))
    } else {
      finish()
    }
  }

  func finish() {
    router.onboardingNavigation.reset()
    router.setRoute(route: .main)
  }
}

// MARK: - Welcome

final class AuthWelcomeViewController: UIViewController {
  private unowned let flow: AuthFlowController

  init(flow: AuthFlowController) {
    self.flow = flow
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.backButtonDisplayMode = .minimal

    let icon = UIImageView(image: UIImage(named: "AppIconSmall"))
    icon.contentMode = .scaleAspectFit
    icon.layer.cornerRadius = 14
    icon.layer.cornerCurve = .continuous
    icon.clipsToBounds = true
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

    let title = UILabel()
    title.text = String(localized: "Welcome to Inline")
    title.font = .preferredFont(forTextStyle: .largeTitle).withWeight(.semibold)
    title.adjustsFontForContentSizeCategory = true
    title.numberOfLines = 0

    let subtitle = UILabel()
    subtitle.text = String(localized: "The interface for multiplayer work")
    subtitle.font = .preferredFont(forTextStyle: .title2)
    subtitle.adjustsFontForContentSizeCategory = true
    subtitle.textColor = .secondaryLabel
    subtitle.numberOfLines = 0

    let header = UIStackView(arrangedSubviews: [icon, title, subtitle])
    header.axis = .vertical
    header.alignment = .leading
    header.spacing = 4
    header.setCustomSpacing(18, after: icon)

    let button = PrimaryButton(title: String(localized: "Get Started")) { [weak self] in
      guard let self else { return }
      flow.push(AuthMethodsViewController(flow: flow))
    }

    let legal = UITextView()
    legal.isEditable = false
    legal.isScrollEnabled = false
    legal.backgroundColor = .clear
    legal.textContainerInset = .zero
    legal.attributedText = Self.legalText()
    legal.linkTextAttributes = [.foregroundColor: UIColor.secondaryLabel, .underlineStyle: NSUnderlineStyle.single.rawValue]

    let footer = UIStackView(arrangedSubviews: [button, legal])
    footer.axis = .vertical
    footer.spacing = 16

    for part in [header, footer] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    let guide = view.readableContentGuide
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
      header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
      header.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -60),
      footer.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
      footer.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
      footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  private static func legalText() -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
      .font: UIFont.preferredFont(forTextStyle: .footnote),
      .foregroundColor: UIColor.tertiaryLabel,
      .paragraphStyle: paragraph,
    ]
    let text = NSMutableAttributedString(
      string: String(localized: "By continuing, you acknowledge that you understand and agree to the "),
      attributes: base
    )
    var terms = base
    terms[.link] = URL(string: "https://inline.chat/legal/terms")!
    text.append(NSAttributedString(string: String(localized: "Terms of Service"), attributes: terms))
    text.append(NSAttributedString(string: String(localized: " and "), attributes: base))
    var privacy = base
    privacy[.link] = URL(string: "https://inline.chat/legal/privacy")!
    text.append(NSAttributedString(string: String(localized: "Privacy Policy"), attributes: privacy))
    text.append(NSAttributedString(string: ".", attributes: base))
    return text
  }
}

// MARK: - Sign-in methods

final class AuthMethodsViewController: UIViewController {
  private unowned let flow: AuthFlowController

  init(flow: AuthFlowController) {
    self.flow = flow
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.backButtonDisplayMode = .minimal

    let title = UILabel()
    title.text = String(localized: "Get started")
    title.font = .preferredFont(forTextStyle: .title1).withWeight(.semibold)
    title.adjustsFontForContentSizeCategory = true
    title.textAlignment = .center
    let subtitle = UILabel()
    subtitle.text = String(localized: "Choose your sign in method")
    subtitle.font = .preferredFont(forTextStyle: .body)
    subtitle.textColor = .secondaryLabel
    subtitle.textAlignment = .center

    let email = methodButton(String(localized: "Continue with Email"), systemImage: "envelope.fill") { [weak self] in
      guard let self else { return }
      flow.push(AuthEmailViewController(flow: flow))
    }
    let phone = methodButton(String(localized: "Continue with Phone"), systemImage: "checkmark.message.fill") {
      [weak self] in
      guard let self else { return }
      flow.push(AuthPhoneViewController(flow: flow))
    }

    let stack = UIStackView(arrangedSubviews: [title, subtitle, email, phone])
    stack.axis = .vertical
    stack.spacing = 8
    stack.setCustomSpacing(4, after: title)
    stack.setCustomSpacing(24, after: subtitle)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    let guide = view.readableContentGuide
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  private func methodButton(
    _ title: String,
    systemImage: String,
    action: @escaping @MainActor () -> Void
  ) -> UIButton {
    var config = UIButton.Configuration.gray()
    config.cornerStyle = .large
    config.buttonSize = .large
    config.title = title
    config.image = UIImage(systemName: systemImage)
    config.imagePadding = 10
    config.baseForegroundColor = .label
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    return button
  }
}

// MARK: - Email

final class AuthEmailViewController: AuthFormViewController, UITextFieldDelegate {
  private unowned let flow: AuthFlowController
  private let field = AuthFormViewController.makeField(placeholder: String(localized: "Your Email"))

  init(flow: AuthFlowController, prefill: String? = nil) {
    self.flow = flow
    super.init(
      systemImage: "at",
      title: String(localized: "Sign in with email"),
      buttonTitle: String(localized: "Continue")
    )
    field.text = prefill
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
    field.keyboardType = .emailAddress
    field.textContentType = .username
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.returnKeyType = .continue
    field.delegate = self
    field.addAction(UIAction { [weak self] _ in self?.showError(nil) }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    submit()
    return false
  }

  override func submit() {
    guard !primaryButton.isLoading else { return }
    let email = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else {
      showError(String(localized: "Enter your email address."))
      return
    }
    showError(nil)
    primaryButton.isLoading = true
    primaryButton.title = String(localized: "Sending Code...")
    Task { [weak self] in
      do {
        let response = try await ApiClient.shared.sendCode(email: email)
        guard let self else { return }
        self.resetButton()
        if response.needsInviteCode == true {
          self.flow.push(AuthInviteCodeViewController(flow: self.flow, destination: .email(email, response.challengeToken)))
        } else {
          self.flow.push(AuthCodeViewController(flow: self.flow, destination: .email(email, response.challengeToken)))
        }
      } catch is CancellationError {
        self?.resetButton()
      } catch {
        self?.resetButton()
        self?.showError(for: error)
      }
    }
  }

  private func resetButton() {
    primaryButton.isLoading = false
    primaryButton.title = String(localized: "Continue")
  }
}

// MARK: - Phone

final class AuthPhoneViewController: AuthFormViewController, UITextFieldDelegate {
  private unowned let flow: AuthFlowController
  private let field = AuthFormViewController.makeField(placeholder: String(localized: "+1 555 123 4567"))

  init(flow: AuthFlowController) {
    self.flow = flow
    super.init(
      systemImage: "phone",
      title: String(localized: "Sign in with phone"),
      subtitle: String(localized: "Include your country code."),
      buttonTitle: String(localized: "Continue")
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
    field.keyboardType = .phonePad
    field.textContentType = .telephoneNumber
    field.text = "+"
    field.delegate = self
    field.addAction(UIAction { [weak self] _ in self?.showError(nil) }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  /// E.164-ish: a leading + and digits only.
  static func normalize(_ raw: String) -> String {
    let digits = raw.filter(\.isNumber)
    return digits.isEmpty ? "" : "+" + digits
  }

  override func submit() {
    guard !primaryButton.isLoading else { return }
    let phoneNumber = Self.normalize(field.text ?? "")
    guard phoneNumber.count >= 8 else {
      showError(String(localized: "Enter your phone number with its country code."))
      return
    }
    showError(nil)
    primaryButton.isLoading = true
    Task { [weak self] in
      do {
        let result = try await ApiClient.shared.sendSmsCode(phoneNumber: phoneNumber)
        guard let self else { return }
        self.primaryButton.isLoading = false
        let number = result.phoneNumber
        if result.needsInviteCode == true {
          self.flow.push(AuthInviteCodeViewController(flow: self.flow, destination: .phone(number)))
        } else {
          self.flow.push(AuthCodeViewController(flow: self.flow, destination: .phone(number)))
        }
      } catch is CancellationError {
        self?.primaryButton.isLoading = false
      } catch {
        self?.primaryButton.isLoading = false
        self?.showError(for: error)
      }
    }
  }
}

// MARK: - Code

enum AuthDestination {
  case email(String, String?)
  case phone(String)

  var displayName: String {
    switch self {
    case let .email(email, _): email
    case let .phone(phone): phone
    }
  }
}

final class AuthCodeViewController: AuthFormViewController, UITextFieldDelegate {
  private unowned let flow: AuthFlowController
  private let destination: AuthDestination
  private let inviteCode: String?
  private let field = AuthFormViewController.makeField(placeholder: "000000")
  private static let length = 6

  init(flow: AuthFlowController, destination: AuthDestination, inviteCode: String? = nil) {
    self.flow = flow
    self.destination = destination
    self.inviteCode = inviteCode
    super.init(
      systemImage: "number",
      title: String(localized: "Enter the code"),
      subtitle: String(format: NSLocalizedString("Code sent to %@", comment: "Code sent confirmation"), destination.displayName),
      buttonTitle: String(localized: "Continue")
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
    field.keyboardType = .numberPad
    field.textContentType = .oneTimeCode
    field.textAlignment = .center
    field.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
    field.defaultTextAttributes[.kern] = 6
    field.delegate = self
    field.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
    primaryButton.isEnabled = false
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  private func codeChanged() {
    let digits = String((field.text ?? "").filter(\.isNumber).prefix(Self.length))
    if field.text != digits { field.text = digits }
    showError(nil)
    primaryButton.isEnabled = digits.count == Self.length
    if digits.count == Self.length { submit() }
  }

  override func submit() {
    guard !primaryButton.isLoading else { return }
    let code = field.text ?? ""
    guard code.count == Self.length else {
      showError(String(localized: "Enter the 6-digit code."))
      return
    }
    primaryButton.isLoading = true
    primaryButton.title = String(localized: "Verifying...")
    let destination = destination
    let inviteCode = inviteCode
    Task { [weak self] in
      do {
        let result: VerifyCode
        switch destination {
        case let .email(email, challengeToken):
          result = try await ApiClient.shared.verifyCode(
            code: code, email: email, challengeToken: challengeToken, inviteCode: inviteCode
          )
        case let .phone(phone):
          result = try await ApiClient.shared.verifySmsCode(code: code, phoneNumber: phone, inviteCode: inviteCode)
        }
        guard let token = result.accountMutationToken else { throw AuthStorageError.loginSuperseded }
        try Auth.shared.handle.validateAccountMutation(token)
        guard let self else { return }
        self.resetButton()
        self.flow.finishSignIn(result: result)
      } catch InlineProtocolNativeLoginError.inviteRequired {
        guard let self else { return }
        self.resetButton()
        self.flow.push(AuthInviteCodeViewController(flow: self.flow, destination: destination))
      } catch is CancellationError {
        self?.resetButton()
      } catch {
        guard let self else { return }
        self.resetButton()
        self.primaryButton.title = String(localized: "Try Again")
        self.showError(for: error)
        self.field.becomeFirstResponder()
      }
    }
  }

  private func resetButton() {
    primaryButton.isLoading = false
    primaryButton.title = String(localized: "Continue")
  }
}

// MARK: - Invite code

final class AuthInviteCodeViewController: AuthFormViewController {
  private unowned let flow: AuthFlowController
  private let destination: AuthDestination
  private let field = AuthFormViewController.makeField(placeholder: String(localized: "Invite code"))

  init(flow: AuthFlowController, destination: AuthDestination) {
    self.flow = flow
    self.destination = destination
    super.init(
      systemImage: "ticket",
      title: String(localized: "Enter your invite code"),
      subtitle: String(localized: "Inline is invite-only for new accounts."),
      buttonTitle: String(localized: "Continue")
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
    field.autocapitalizationType = .allCharacters
    field.autocorrectionType = .no
    field.textAlignment = .center
    field.addAction(UIAction { [weak self] _ in self?.showError(nil) }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  override func submit() {
    guard !primaryButton.isLoading else { return }
    let code = (field.text ?? "").filter { $0.isLetter || $0.isNumber }.uppercased()
    guard code.count == 8 else {
      showError(String(localized: "Enter the 8-character access invite code."))
      return
    }
    primaryButton.isLoading = true
    let destination = destination
    Task { [weak self] in
      do {
        _ = try await ApiClient.shared.checkInviteCode(code)
        guard let self else { return }
        self.primaryButton.isLoading = false
        self.flow.push(AuthCodeViewController(flow: self.flow, destination: destination, inviteCode: code))
      } catch {
        self?.primaryButton.isLoading = false
        self?.showError(for: error)
      }
    }
  }
}

// MARK: - Profile

final class AuthProfileViewController: AuthFormViewController {
  private unowned let flow: AuthFlowController
  private let userId: Int64
  private let field = AuthFormViewController.makeField(placeholder: String(localized: "Your name"))

  init(flow: AuthFlowController, userId: Int64) {
    self.flow = flow
    self.userId = userId
    super.init(
      systemImage: "person.crop.circle",
      title: String(localized: "What's your name?"),
      buttonTitle: String(localized: "Continue")
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.hidesBackButton = true
    field.textContentType = .name
    field.autocapitalizationType = .words
    field.addAction(UIAction { [weak self] _ in self?.showError(nil) }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
    Task { [weak self] in
      guard let self else { return }
      let user = try? await AppDatabase.shared.dbWriter.read { [userId] db in try User.fetchOne(db, id: userId) }
      if (self.field.text ?? "").isEmpty, let name = user?.fullName, !name.isEmpty {
        self.field.text = name
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  override func submit() {
    guard !primaryButton.isLoading else { return }
    let name = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      showError(String(localized: "Please enter your name"))
      return
    }
    primaryButton.isLoading = true
    let userId = userId
    Task { [weak self] in
      do {
        let token = try Auth.shared.handle.beginAccountMutation()
        guard token.userID == userId else { throw CancellationError() }
        let (first, last) = Self.split(name)
        let realtime = Api.realtime
        let result = try await OnboardingSession.withConnection(realtime: realtime, accountToken: token) { realtime in
          try await realtime.updateProfile(firstName: first, lastName: last ?? "", bio: nil)
        }
        try Auth.shared.handle.validateAccountMutation(token)
        try await realtime.applyUpdatesAndWait(result.updates, accountToken: token)
        _ = try await AppDatabase.shared.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(token)
          return try User.save(db, user: result.user)
        }
        guard let self else { return }
        self.primaryButton.isLoading = false
        self.flow.push(AuthUsernameViewController(flow: self.flow, userId: userId))
      } catch is CancellationError {
        self?.primaryButton.isLoading = false
      } catch {
        self?.primaryButton.isLoading = false
        self?.showError(for: error)
      }
    }
  }

  static func split(_ fullName: String) -> (String, String?) {
    let formatter = PersonNameComponentsFormatter()
    if let components = formatter.personNameComponents(from: fullName), let given = components.givenName {
      return (given, components.familyName)
    }
    return (fullName, nil)
  }
}

// MARK: - Username

final class AuthUsernameViewController: AuthFormViewController {
  private unowned let flow: AuthFlowController
  private let userId: Int64
  private let field = AuthFormViewController.makeField(placeholder: String(localized: "Username"))
  private var checkTask: Task<Void, Never>?
  private var isAvailable = false

  init(flow: AuthFlowController, userId: Int64) {
    self.flow = flow
    self.userId = userId
    super.init(
      systemImage: "at",
      title: String(localized: "Pick a username"),
      subtitle: String(localized: "People can find you by it."),
      buttonTitle: String(localized: "Continue")
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.textContentType = .username
    field.addAction(UIAction { [weak self] _ in self?.usernameChanged() }, for: .editingChanged)
    fieldStack.addArrangedSubview(field)
    primaryButton.isEnabled = false
    Task { [weak self] in
      guard let self else { return }
      let user = try? await AppDatabase.shared.dbWriter.read { [userId] db in try User.fetchOne(db, id: userId) }
      if (self.field.text ?? "").isEmpty, let username = user?.username, !username.isEmpty {
        self.field.text = username
        self.usernameChanged()
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  static func clean(_ value: String) -> String {
    value
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@")))
      .lowercased()
  }

  private func usernameChanged() {
    showError(nil)
    isAvailable = false
    primaryButton.isEnabled = false
    checkTask?.cancel()
    let candidate = Self.clean(field.text ?? "")
    guard candidate.count >= 2 else { return }
    checkTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }
      do {
        let result = try await OnboardingSession.withConnection(realtime: Api.realtime) { realtime in
          try await realtime.checkUsername(candidate)
        }
        guard let self, !Task.isCancelled, Self.clean(self.field.text ?? "") == candidate else { return }
        switch result.availability {
        case .usernameAvailable, .usernameCurrent:
          self.isAvailable = true
          self.primaryButton.isEnabled = true
        case .usernameTaken, .usernameReserved, .usernameInvalid:
          self.showError(String(localized: "That username is taken."))
        case .unspecified, .UNRECOGNIZED:
          break
        }
      } catch is CancellationError {
        return
      } catch {
        self?.showError(for: error)
      }
    }
  }

  override func submit() {
    guard !primaryButton.isLoading, isAvailable else { return }
    let candidate = Self.clean(field.text ?? "")
    let userId = userId
    primaryButton.isLoading = true
    Task { [weak self] in
      do {
        let token = try Auth.shared.handle.beginAccountMutation()
        guard token.userID == userId else { throw CancellationError() }
        let realtime = Api.realtime
        let result = try await OnboardingSession.withConnection(realtime: realtime, accountToken: token) { realtime in
          try await realtime.changeUsername(candidate)
        }
        try await realtime.applyUpdatesAndWait(result.updates, accountToken: token)
        _ = try await AppDatabase.shared.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(token)
          return try User.save(db, user: result.user)
        }
        try Auth.shared.handle.validateAccountMutation(token)
        guard let self else { return }
        self.primaryButton.isLoading = false
        self.flow.finish()
      } catch is CancellationError {
        self?.primaryButton.isLoading = false
      } catch {
        self?.primaryButton.isLoading = false
        self?.showError(for: error)
      }
    }
  }
}
