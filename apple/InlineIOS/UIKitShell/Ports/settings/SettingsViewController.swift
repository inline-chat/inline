import Auth
import Combine
import GRDB
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import UIKit

/// UIKit Settings root, mirroring the SwiftUI `SettingsView` (Settings.swift): profile, the
/// General…Active Sessions pages, Bots, Experimental/Debug and Help, with the version in the
/// footer. Pages that only exist in SwiftUI (Connectors, Bots, Debug) show on iOS 18+ through
/// the SwiftUI bridge and are hidden before that.
@MainActor
final class SettingsViewController: SettingsFormViewController {
  private var user: UserInfo?

  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Settings"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func registerCells(in tableView: UITableView) {
    tableView.register(SettingsProfileCell.self, forCellReuseIdentifier: SettingsProfileCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { [weak self] _ in self?.closeSettings() }
    )
    ValueObservation
      .tracking { db in try CurrentUser().fetch(db) }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] user in
        self?.user = user
        self?.setNeedsFormUpdate()
      })
      .store(in: &cancellables)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let user = self.user
    let bridged = SettingsBridgedPages.isAvailable

    FormSection("profile") {
      FormRow.custom(
        "profile",
        reuseIdentifier: SettingsProfileCell.reuseIdentifier,
        contentKey: user.map { AnyHashable($0) } ?? AnyHashable("signed-out"),
        onSelect: { [weak self] in
          guard let self else { return }
          push(AccountProfileSettingsViewController(shell: shell))
        },
        configure: { cell in
          (cell as? SettingsProfileCell)?.configure(
            userInfo: user,
            detail: user?.user.email ?? user?.user.username.map { "@\($0)" },
            size: 48,
            showsDisclosure: true
          )
        }
      )
    }

    FormSection("pages") {
      FormRow.navigation("general", String(localized: "General"), icon: .tile("gear", .systemGray)) { [weak self] in
        guard let self else { return }
        push(GeneralSettingsViewController(shell: shell))
      }
      FormRow.navigation("appearance", String(localized: "Appearance"), icon: .tile("paintbrush.fill", .systemBlue)) { [weak self] in
        guard let self else { return }
        push(AppearanceSettingsViewController(shell: shell))
      }
      FormRow.navigation("notifications", String(localized: "Notifications"), icon: .tile("bell.fill", .systemRed)) { [weak self] in
        guard let self else { return }
        push(NotificationsSettingsViewController(shell: shell))
      }
      FormRow.navigation("privacy", String(localized: "Privacy"), icon: .tile("hand.raised.fill", .systemBlue)) { [weak self] in
        guard let self else { return }
        push(PrivacySettingsViewController(shell: shell))
      }
      FormRow.navigation("storage", String(localized: "Data & Storage"), icon: .tile("externaldrive.fill", .systemIndigo)) { [weak self] in
        guard let self else { return }
        push(DataStorageSettingsViewController(shell: shell))
      }
      if bridged {
        FormRow.navigation(
          "connectors",
          String(localized: "Connectors"),
          icon: .tile("app.connected.to.app.below.fill", .systemPurple)
        ) { [weak self] in
          guard let self else { return }
          if #available(iOS 18.0, *) { push(SettingsBridgedPages.connectors(shell: shell)) }
        }
      }
      FormRow.navigation(
        "sessions",
        String(localized: "Active Sessions"),
        icon: .tile("laptopcomputer.and.iphone", .systemBlue)
      ) { [weak self] in
        guard let self else { return }
        push(AccountSessionsSettingsViewController(shell: shell))
      }
    }

    if bridged {
      FormSection("bots") {
        FormRow.navigation("bots", String(localized: "Bots"), icon: .tile("cpu", .systemPurple)) { [weak self] in
          guard let self else { return }
          if #available(iOS 18.0, *) { push(SettingsBridgedPages.bots(shell: shell)) }
        }
      }
    }

    FormSection("labs") {
      FormRow.navigation("experimental", String(localized: "Experimental"), icon: .tile("testtube.2", .systemOrange)) { [weak self] in
        guard let self else { return }
        push(ExperimentalSettingsViewController(shell: shell))
      }
      if bridged, DeveloperMode.isEnabled {
        FormRow.navigation("debug", String(localized: "Debug"), icon: .tile("ladybug.fill", .systemGreen)) { [weak self] in
          guard let self else { return }
          if #available(iOS 18.0, *) { push(SettingsBridgedPages.debug(shell: shell)) }
        }
      }
    }

    FormSection("help", footer: SettingsAppInfo.versionText) {
      FormRow.navigation("help", String(localized: "Help"), icon: .tile("questionmark.circle.fill", .systemBlue)) { [weak self] in
        guard let self else { return }
        push(HelpSettingsViewController(shell: shell))
      }
    }
  }
}
