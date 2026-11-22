import Auth
import Combine
import GRDB
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineTheme
import UIKit

/// UIKit Settings. Today it serves iOS 15–16 (iOS 17+ keeps the bridged SwiftUI Settings until
/// this reaches parity): profile, notification mode, theme, help and logout.
@MainActor
final class SettingsViewController: FormViewController {
  private unowned let shell: MainShellController
  private var user: UserInfo?
  private var cancellables: Set<AnyCancellable> = []

  init(shell: MainShellController) {
    self.shell = shell
    super.init(style: .insetGrouped)
    title = String(localized: "Settings")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { [weak self] _ in self?.close() }
    )
    ValueObservation
      .tracking { db in try CurrentUser().fetch(db) }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] user in
        self?.user = user
        self?.setNeedsFormUpdate()
      })
      .store(in: &cancellables)
    INUserSettings.current.notification.$mode
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
    ThemeManager.shared.$selectedPreset
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
  }

  private func close() {
    shell.router.dismissSheet()
    dismiss(animated: true)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let notification = INUserSettings.current.notification
    let preset = ThemeManager.shared.selectedPreset

    FormSection("profile") {
      if let user {
        FormRow.value(
          "name",
          user.user.displayName,
          value: nil,
          subtitle: user.user.username.map { "@\($0)" } ?? user.user.email,
          icon: FormIcon(systemName: "person.crop.circle.fill", tint: .systemBlue)
        )
      } else {
        FormRow.value("name", String(localized: "Account"), value: nil, icon: FormIcon(systemName: "person.crop.circle"))
      }
    }

    FormSection("notifications", header: String(localized: "Notifications")) {
      for mode in NotificationMode.pickerModes {
        FormRow.check(
          "mode-\(mode.rawValue)",
          mode.title,
          icon: FormIcon(systemName: mode.systemImage),
          isSelected: mode.isSelected(in: notification.mode)
        ) {
          notification.mode = mode
        }
      }
    }

    FormSection("theme", header: String(localized: "Theme")) {
      for theme in ThemeManager.themes {
        FormRow.check("theme-\(theme.id)", theme.name, isSelected: theme.id == preset.rawValue) {
          ThemeManager.shared.switchToTheme(withID: theme.id)
        }
      }
    }

    FormSection("help", header: String(localized: "Help")) {
      FormRow.action("website", String(localized: "Website"), icon: FormIcon(systemName: "safari"), role: .normal) {
        UIApplication.shared.open(URL(string: "https://inline.chat")!)
      }
      FormRow.action("privacy", String(localized: "Privacy Policy"), icon: FormIcon(systemName: "hand.raised"), role: .normal) {
        UIApplication.shared.open(URL(string: "https://inline.chat/legal/privacy")!)
      }
      FormRow.action("terms", String(localized: "Terms of Service"), icon: FormIcon(systemName: "doc.text"), role: .normal) {
        UIApplication.shared.open(URL(string: "https://inline.chat/legal/terms")!)
      }
    }

    FormSection("account", footer: Self.versionText) {
      FormRow.button("logout", String(localized: "Log Out"), role: .destructive) { [weak self] in
        self?.confirmLogout()
      }
    }
  }

  private static var versionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "Inline \(version) (\(build))"
  }

  private func confirmLogout() {
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Log Out"),
        message: String(localized: "Are you sure you want to log out? This will clear your local data and return you to the welcome screen."),
        confirmTitle: String(localized: "Log Out"),
        destructive: true
      )
      guard confirmed else { return }
      let shell = shell
      dismiss(animated: true)
      await LogoutPerformer.perform(
        notifyServer: true,
        mainRouter: shell.mainViewRouter,
        navigation: shell.appDelegate.nav,
        onboardingNavigation: shell.mainViewRouter.onboardingNavigation,
        router: shell.router
      )
    }
  }
}
