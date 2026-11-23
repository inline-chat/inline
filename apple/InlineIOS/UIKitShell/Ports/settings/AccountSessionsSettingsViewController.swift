import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import UIKit

/// Active Sessions page (SwiftUI `AccountSessionsSettingsView`): signed-in devices, sign out of
/// one by tapping it or swiping, pull to refresh, and Log Out for this device.
@MainActor
final class AccountSessionsSettingsViewController: SettingsFormViewController {
  private var sessions: [InlineProtocol.AccountSession] = []
  private var isLoading = false
  private var loadError: String?
  private var revokingSessionID: Int64?
  private var loadTask: Task<Void, Never>?

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter
  }()

  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Active Sessions"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    loadTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let refreshItem = UIBarButtonItem(
      primaryAction: UIAction(image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        self?.refresh()
      }
    )
    refreshItem.accessibilityLabel = String(localized: "Refresh Sessions")
    navigationItem.rightBarButtonItem = refreshItem

    let control = UIRefreshControl()
    control.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
    tableView.refreshControl = control
    refresh()
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    FormSection(
      "sessions",
      header: String(localized: "Signed-In Devices"),
      footer: String(localized: "Sign out any device or client you do not recognize. Use Log Out below to sign out this device.")
    ) {
      if isLoading, sessions.isEmpty {
        FormRow("loading", title: String(localized: "Loading sessions…"), accessory: .activity)
      } else if let loadError, sessions.isEmpty {
        FormRow.value(
          "error",
          String(localized: "Could Not Load Sessions"),
          value: nil,
          subtitle: loadError,
          icon: FormIcon(systemName: "exclamationmark.triangle", tint: .systemOrange)
        )
        FormRow.action("retry", String(localized: "Try Again")) { [weak self] in
          self?.refresh()
        }
      } else if sessions.isEmpty {
        FormRow.note("empty", String(localized: "No signed-in devices or clients were returned."))
      } else {
        for session in sessions {
          row(for: session)
        }
      }
    }

    FormSection("logout", header: String(localized: "Actions")) {
      SettingsActions.logoutRow(from: self, shell: shell)
    }
  }

  private func row(for session: InlineProtocol.AccountSession) -> FormRow {
    let isRevoking = revokingSessionID == session.id
    var subtitleLines = [Self.detail(session)]
    if session.lastActiveAt > 0 {
      let date = Date(timeIntervalSince1970: TimeInterval(session.lastActiveAt))
      let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
      subtitleLines.append(String(localized: "Last active \(relative)"))
    }
    var row = FormRow(
      "session-\(session.id)",
      title: Self.title(session),
      subtitle: subtitleLines.filter { !$0.isEmpty }.joined(separator: "\n"),
      value: session.current ? String(localized: "Current") : nil,
      icon: FormIcon(systemName: Self.iconName(session), tint: .secondaryLabel),
      accessory: isRevoking ? .activity : .none,
      isEnabled: !isRevoking
    )
    guard !session.current else { return row }
    row.onSelect = { [weak self] in self?.confirmRevoke(session) }
    return row.deletable(String(localized: "Sign Out")) { [weak self] in
      self?.confirmRevoke(session)
    }
  }

  // MARK: Loading

  private func refresh() {
    guard !isLoading else {
      tableView.refreshControl?.endRefreshing()
      return
    }
    isLoading = true
    loadError = nil
    setNeedsFormUpdate()
    loadTask = Task { [weak self] in
      do {
        let result = try await Api.realtime.getSessions()
        guard let self else { return }
        sessions = result.sessions.sorted { lhs, rhs in
          if lhs.current != rhs.current { return lhs.current }
          return lhs.lastActiveAt > rhs.lastActiveAt
        }
      } catch {
        guard let self else { return }
        Log.scoped("IOSSettings.Sessions").error("Failed to load sessions", error: error)
        loadError = error.localizedDescription
        if !sessions.isEmpty {
          ToastManager.shared.showToast(
            String(localized: "Could not refresh sessions"),
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
        }
      }
      guard let self else { return }
      isLoading = false
      tableView.refreshControl?.endRefreshing()
      setNeedsFormUpdate()
    }
  }

  private func confirmRevoke(_ session: InlineProtocol.AccountSession) {
    guard !session.current, revokingSessionID == nil else { return }
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Sign Out Session?"),
        message: String(localized: "This signs that device or client out of your account."),
        confirmTitle: String(localized: "Sign Out"),
        destructive: true,
        style: .actionSheet
      )
      guard confirmed else { return }
      revoke(session)
    }
  }

  private func revoke(_ session: InlineProtocol.AccountSession) {
    guard !session.current, revokingSessionID == nil else { return }
    revokingSessionID = session.id
    setNeedsFormUpdate()
    Task { [weak self] in
      do {
        _ = try await Api.realtime.revokeSession(session.id)
        self?.sessions.removeAll { $0.id == session.id }
      } catch {
        Log.scoped("IOSSettings.Sessions").error("Failed to revoke session", error: error)
        ToastManager.shared.showToast(
          String(localized: "Could not sign out session"),
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
      self?.revokingSessionID = nil
      self?.setNeedsFormUpdate()
    }
  }

  // MARK: Text

  private static func title(_ session: InlineProtocol.AccountSession) -> String {
    optional(session.hasDeviceName, session.deviceName) ?? clientTitle(session)
  }

  private static func detail(_ session: InlineProtocol.AccountSession) -> String {
    let location = [
      optional(session.hasCity, session.city),
      optional(session.hasCountry, session.country),
    ].compactMap { $0 }
    return [
      clientTitle(session),
      optional(session.hasClientVersion, session.clientVersion),
      optional(session.hasOsVersion, session.osVersion),
      location.isEmpty ? nil : location.joined(separator: ", "),
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private static func clientTitle(_ session: InlineProtocol.AccountSession) -> String {
    switch session.clientType {
    case "macos": String(localized: "Inline for Mac")
    case "ios": String(localized: "Inline for iOS")
    case "web": String(localized: "Inline Web")
    case "cli": String(localized: "Inline CLI")
    case "api": String(localized: "API")
    default: String(localized: "Unknown Client")
    }
  }

  private static func iconName(_ session: InlineProtocol.AccountSession) -> String {
    switch session.clientType {
    case "macos": "desktopcomputer"
    case "ios": "iphone"
    case "web": "globe"
    case "cli": "terminal"
    default: "person.crop.circle.badge.questionmark"
    }
  }

  private static func optional(_ hasValue: Bool, _ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return hasValue && !trimmed.isEmpty ? trimmed : nil
  }
}
