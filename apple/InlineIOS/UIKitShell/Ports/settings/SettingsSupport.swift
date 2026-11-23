import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import UIKit

// Shared pieces of the UIKit Settings: the page base class, a single-choice picker page, the
// profile cell, logout and version text.

/// Base for every Settings page: holds the shell, re-renders on `$` publishers and whenever the
/// page comes back on screen (UserDefaults-backed values and picker pages change underneath).
@MainActor
class SettingsFormViewController: FormViewController {
  unowned let shell: MainShellController
  var cancellables: Set<AnyCancellable> = []

  init(shell: MainShellController, title: String) {
    self.shell = shell
    super.init(style: .insetGrouped)
    self.title = title
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    setNeedsFormUpdate()
  }

  /// Re-renders the form whenever `publisher` emits (ObservableObject `$value` / `objectWillChange`).
  func reloadOnChange<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
  }

  func push(_ controller: UIViewController) {
    navigationController?.pushViewController(controller, animated: true)
  }

  /// Closes the whole Settings sheet, the same way the root's close button does.
  func closeSettings() {
    shell.router.dismissSheet()
    dismiss(animated: true)
  }

  func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    UIApplication.shared.open(url)
  }
}

extension FormIcon {
  /// Settings-style tile: white symbol on a rounded colored square (SwiftUI `SettingsItem`).
  static func tile(_ systemName: String, _ color: UIColor) -> FormIcon {
    FormIcon(systemName: systemName, tint: .white, background: color)
  }
}

// MARK: - Single choice picker page

/// One choice in a `SettingsPickerViewController`.
struct SettingsPickerOption {
  var id: String
  var title: String
  var subtitle: String?
  var icon: FormIcon?

  init(id: String, title: String, subtitle: String? = nil, icon: FormIcon? = nil) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
  }
}

/// UIKit stand-in for SwiftUI's `.pickerStyle(.menu)` rows: a pushed checkmark list.
/// Values travel as string ids so one non-generic page serves every enum.
@MainActor
final class SettingsPickerViewController: FormViewController {
  private let header: String?
  private let footer: String?
  private let options: [SettingsPickerOption]
  private let selectedID: @MainActor () -> String
  private let onSelect: @MainActor (String, SettingsPickerViewController) -> Void
  private let popsOnSelect: Bool

  /// - Parameter popsOnSelect: false when `onSelect` asks for confirmation first; call `finish()` after.
  init(
    title: String,
    header: String? = nil,
    footer: String? = nil,
    options: [SettingsPickerOption],
    selectedID: @escaping @MainActor () -> String,
    popsOnSelect: Bool = true,
    onSelect: @escaping @MainActor (String, SettingsPickerViewController) -> Void
  ) {
    self.header = header
    self.footer = footer
    self.options = options
    self.selectedID = selectedID
    self.popsOnSelect = popsOnSelect
    self.onSelect = onSelect
    super.init(style: .insetGrouped)
    self.title = title
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let selected = selectedID()
    FormSection("options", header: header, footer: footer) {
      for option in options {
        FormRow.check(
          option.id,
          option.title,
          subtitle: option.subtitle,
          icon: option.icon,
          isSelected: option.id == selected
        ) { [weak self] in
          guard let self else { return }
          guard option.id != self.selectedID() else {
            if self.popsOnSelect { self.finish() }
            return
          }
          CompatHaptics.selection()
          self.onSelect(option.id, self)
          self.setNeedsFormUpdate()
          if self.popsOnSelect { self.finish() }
        }
      }
    }
  }

  func finish() {
    setNeedsFormUpdate()
    navigationController?.popViewController(animated: true)
  }
}

// MARK: - Profile cell

/// Avatar, name and a secondary line. Root profile row and the Account header.
final class SettingsProfileCell: UITableViewCell {
  static let reuseIdentifier = "SettingsProfileCell"

  private let avatar = UserAvatarLayerView()
  private let nameLabel = UILabel()
  private let detailLabel = UILabel()
  private var avatarSize: NSLayoutConstraint!
  private var currentSize: CGFloat = 0

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    avatar.isUserInteractionEnabled = false
    nameLabel.font = .preferredFont(forTextStyle: .body).withWeight(.medium)
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.numberOfLines = 1
    detailLabel.font = .preferredFont(forTextStyle: .callout)
    detailLabel.adjustsFontForContentSizeCategory = true
    detailLabel.textColor = .secondaryLabel
    detailLabel.numberOfLines = 1

    let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
    labels.axis = .vertical
    labels.spacing = 2
    labels.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(avatar)
    contentView.addSubview(labels)
    avatarSize = avatar.widthAnchor.constraint(equalToConstant: 56)
    NSLayoutConstraint.activate([
      avatar.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      avatarSize,
      avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),
      avatar.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
      avatar.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
      labels.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
      labels.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      labels.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
      labels.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(userInfo: UserInfo?, detail: String?, size: CGFloat = 56, showsDisclosure: Bool) {
    if size != currentSize {
      avatarSize.constant = size
      currentSize = size
    }
    if let userInfo {
      avatar.isHidden = false
      avatar.configure(with: userInfo, size: size)
      nameLabel.text = userInfo.user.displayName
    } else {
      avatar.isHidden = true
      nameLabel.text = String(localized: "Account")
    }
    detailLabel.text = detail
    detailLabel.isHidden = detail?.isEmpty ?? true
    accessoryType = showsDisclosure ? .disclosureIndicator : .none
    accessibilityLabel = [nameLabel.text, detail].compactMap { $0 }.joined(separator: ", ")
    accessibilityTraits = showsDisclosure ? .button : .none
  }
}

// MARK: - Actions

@MainActor
enum SettingsActions {
  /// Asks, closes Settings and logs out (the flow the old UIKit Settings had).
  static func confirmLogout(from controller: UIViewController, shell: MainShellController) {
    Task { @MainActor [weak controller] in
      guard let controller else { return }
      let confirmed = await controller.confirm(
        title: String(localized: "Log Out"),
        message: String(localized: "Are you sure you want to log out? This will clear your local data and return you to the welcome screen."),
        confirmTitle: String(localized: "Log Out"),
        destructive: true
      )
      guard confirmed else { return }
      controller.dismiss(animated: true)
      await LogoutPerformer.perform(
        notifyServer: true,
        mainRouter: shell.mainViewRouter,
        navigation: shell.appDelegate.nav,
        onboardingNavigation: shell.mainViewRouter.onboardingNavigation,
        router: shell.router
      )
    }
  }

  static func logoutRow(from controller: UIViewController, shell: MainShellController) -> FormRow {
    FormRow.action(
      "logout",
      String(localized: "Log Out"),
      icon: .tile("arrow.right.square.fill", .systemRed),
      role: .destructive
    ) { [weak controller, unowned shell] in
      guard let controller else { return }
      confirmLogout(from: controller, shell: shell)
    }
  }
}

enum SettingsAppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  }

  static var versionText: String { "Inline \(version) (\(build))" }
}
