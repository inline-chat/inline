import Combine
import GRDB
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import UIKit

/// Account page (SwiftUI `ExperimentalProfileView`): first/last name, username with an
/// availability check, bio, read-only contact details and Log Out. Profile photo is not ported.
@MainActor
final class AccountProfileSettingsViewController: SettingsFormViewController {
  private enum UsernameState: Equatable {
    case idle, checking, available, current, unavailable, invalid, failed

    var footer: String? {
      switch self {
      case .idle, .checking: nil
      case .available: String(localized: "Username is available")
      case .current: String(localized: "This is your current username")
      case .unavailable: String(localized: "Username is not available")
      case .invalid: String(localized: "Usernames must be at least 2 characters")
      case .failed: String(localized: "Could not check availability. Try again")
      }
    }
  }

  private var user: UserInfo?
  private var loadedUserID: Int64?

  private var firstName = ""
  private var lastName = ""
  private var username = ""
  private var bio = ""
  private var initialFirstName = ""
  private var initialLastName = ""
  private var initialUsername = ""
  private var initialBio = ""

  private var usernameState = UsernameState.idle
  private var isSaving = false
  private var checkTask: Task<Void, Never>?

  private lazy var saveItem = UIBarButtonItem(
    primaryAction: UIAction(title: String(localized: "Save")) { [weak self] _ in self?.save() }
  )

  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Account"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func registerCells(in tableView: UITableView) {
    tableView.register(SettingsProfileCell.self, forCellReuseIdentifier: SettingsProfileCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    saveItem.style = .done
    navigationItem.rightBarButtonItem = saveItem
    updateNavigationItems()
    ValueObservation
      .tracking { db in try CurrentUser().fetch(db) }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] user in
        guard let self else { return }
        self.user = user
        loadIfNeeded()
        setNeedsFormUpdate()
      })
      .store(in: &cancellables)
  }

  deinit {
    checkTask?.cancel()
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let user = self.user
    let isBusy = isSaving

    FormSection("header") {
      FormRow.custom(
        "header",
        reuseIdentifier: SettingsProfileCell.reuseIdentifier,
        contentKey: user.map { AnyHashable($0) } ?? AnyHashable("loading"),
        configure: { cell in
          (cell as? SettingsProfileCell)?.configure(
            userInfo: user,
            detail: user?.user.username.map { "@\($0)" },
            size: 64,
            showsDisclosure: false
          )
        }
      )
    }

    FormSection("name", header: String(localized: "Name")) {
      FormRow.textField("first", placeholder: String(localized: "First Name"), text: firstName) { [weak self] text in
        self?.firstName = text
        self?.updateNavigationItems()
      }
      .keyboard(.default, contentType: .givenName)
      FormRow.textField("last", placeholder: String(localized: "Last Name"), text: lastName) { [weak self] text in
        self?.lastName = text
        self?.updateNavigationItems()
      }
      .keyboard(.default, contentType: .familyName)
    }

    FormSection("username", header: String(localized: "Username"), footer: usernameState.footer) {
      FormRow.textField("username", placeholder: String(localized: "@username"), text: username) { [weak self] text in
        self?.usernameChanged(text)
      }
      .keyboard(.asciiCapable, contentType: .username)
      FormRow.action(
        "check",
        String(localized: "Check Availability"),
        isEnabled: !isBusy && Self.clean(username).count >= 2 && Self.clean(username) != initialUsername,
        isLoading: usernameState == .checking
      ) { [weak self] in
        self?.checkAvailability()
      }
    }

    FormSection("contact", header: String(localized: "Contact")) {
      FormRow.value("email", String(localized: "Email"), value: Self.nonEmpty(user?.user.email) ?? String(localized: "Not set"))
      FormRow.value("phone", String(localized: "Phone"), value: Self.nonEmpty(user?.user.phoneNumber) ?? String(localized: "Not set"))
    }

    FormSection("about", header: String(localized: "About")) {
      FormRow.textField("bio", placeholder: String(localized: "Bio"), text: bio) { [weak self] text in
        self?.bio = text
        self?.updateNavigationItems()
      }
    }

    FormSection("actions") {
      SettingsActions.logoutRow(from: self, shell: shell)
    }
  }

  // MARK: State

  private var hasChanges: Bool {
    Self.normalized(firstName) != initialFirstName
      || Self.normalized(lastName) != initialLastName
      || Self.clean(username) != initialUsername
      || Self.normalized(bio) != initialBio
  }

  private func loadIfNeeded() {
    guard let user = user?.user, loadedUserID != user.id else { return }
    firstName = Self.normalized(user.firstName ?? "")
    lastName = Self.normalized(user.lastName ?? "")
    username = Self.clean(user.username ?? "")
    bio = Self.normalized(user.bio ?? "")
    initialFirstName = firstName
    initialLastName = lastName
    initialUsername = username
    initialBio = bio
    usernameState = username.isEmpty ? .idle : .current
    loadedUserID = user.id
    updateNavigationItems()
  }

  private func updateNavigationItems() {
    saveItem.isEnabled = hasChanges && !isSaving
    saveItem.title = isSaving ? String(localized: "Saving…") : String(localized: "Save")
    let guarded = hasChanges || isSaving
    isModalInPresentation = guarded
    navigationController?.isModalInPresentation = guarded
    navigationItem.hidesBackButton = guarded
    if guarded {
      if navigationItem.leftBarButtonItem == nil {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
          primaryAction: UIAction(image: UIImage(systemName: "chevron.backward")) { [weak self] _ in
            self?.confirmDiscard()
          }
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Back")
      }
      navigationItem.leftBarButtonItem?.isEnabled = !isSaving
    } else {
      navigationItem.leftBarButtonItem = nil
    }
  }

  private func usernameChanged(_ text: String) {
    username = text
    let candidate = Self.clean(text)
    let next: UsernameState = if candidate == initialUsername, !candidate.isEmpty {
      .current
    } else if !candidate.isEmpty, candidate.count < 2 {
      .invalid
    } else {
      .idle
    }
    checkTask?.cancel()
    setUsernameState(next)
    updateNavigationItems()
    setNeedsFormUpdate()
  }

  private func setUsernameState(_ state: UsernameState) {
    guard usernameState != state else { return }
    usernameState = state
    setNeedsFormUpdate()
  }

  private func confirmDiscard() {
    Task { [weak self] in
      guard let self else { return }
      let discard = await confirm(
        title: String(localized: "Discard Changes?"),
        message: String(localized: "Your unsaved account changes will be lost."),
        confirmTitle: String(localized: "Discard Changes"),
        destructive: true,
        cancelTitle: String(localized: "Keep Editing"),
        style: .actionSheet,
        sourceView: nil
      )
      guard discard else { return }
      isModalInPresentation = false
      navigationController?.isModalInPresentation = false
      navigationController?.popViewController(animated: true)
    }
  }

  // MARK: Username

  private func checkAvailability() {
    let candidate = Self.clean(username)
    if candidate == initialUsername, !candidate.isEmpty {
      setUsernameState(.current)
      return
    }
    guard candidate.count >= 2 else {
      setUsernameState(candidate.isEmpty ? .idle : .invalid)
      return
    }
    setUsernameState(.checking)
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      do {
        let availability = try await Api.realtime.checkUsername(candidate).availability
        guard let self, !Task.isCancelled, Self.clean(self.username) == candidate else { return }
        setUsernameState(Self.state(for: availability))
      } catch {
        guard let self, !Task.isCancelled, Self.clean(self.username) == candidate else { return }
        Log.shared.error("Failed to check profile username", error: error)
        setUsernameState(.failed)
      }
    }
  }

  private static func state(for availability: InlineProtocol.UsernameAvailability) -> UsernameState {
    switch availability {
    case .usernameAvailable: .available
    case .usernameCurrent: .current
    case .usernameTaken, .usernameReserved: .unavailable
    case .usernameInvalid: .invalid
    case .unspecified, .UNRECOGNIZED: .idle
    }
  }

  // MARK: Save

  private func save() {
    guard !isSaving else { return }
    view.endEditing(true)

    let first = Self.normalized(firstName)
    let last = Self.normalized(lastName)
    let username = Self.clean(self.username)
    let bio = Self.normalized(self.bio)

    guard !first.isEmpty else {
      presentAlert(title: String(localized: "Could Not Save Profile"), message: String(localized: "Enter your name."))
      return
    }
    guard username == initialUsername || username.count >= 2 else {
      presentAlert(
        title: String(localized: "Could Not Save Profile"),
        message: String(localized: "Usernames must be at least 2 characters.")
      )
      return
    }

    isSaving = true
    updateNavigationItems()
    setNeedsFormUpdate()

    Task { [weak self] in
      guard let self else { return }
      let realtime = Api.realtime
      do {
        if username != initialUsername {
          let availability = try await realtime.checkUsername(username).availability
          let state = Self.state(for: availability)
          setUsernameState(state)
          guard state == .available || state == .current else {
            finishSaving()
            presentAlert(
              title: String(localized: "Could Not Save Profile"),
              message: String(localized: "That username is not available.")
            )
            return
          }
        }

        if first != initialFirstName || last != initialLastName || bio != initialBio {
          let result = try await realtime.updateProfile(firstName: first, lastName: last, bio: bio)
          await realtime.applyUpdates(result.updates)
          try await Self.persist(result.user)
          initialFirstName = first
          initialLastName = last
          initialBio = bio
        }

        if username != initialUsername {
          let result = try await realtime.changeUsername(username)
          await realtime.applyUpdates(result.updates)
          try await Self.persist(result.user)
          initialUsername = username
        }

        firstName = first
        lastName = last
        self.username = username
        self.bio = bio
        usernameState = username.isEmpty ? .idle : .current
        finishSaving()
        ToastManager.shared.showToast(
          String(localized: "Profile updated"),
          type: .success,
          systemImage: "checkmark.circle.fill"
        )
      } catch {
        Log.shared.error("Failed to update profile", error: error)
        finishSaving()
        presentAlert(title: String(localized: "Could Not Save Profile"), message: error.localizedDescription)
      }
    }
  }

  private func finishSaving() {
    isSaving = false
    updateNavigationItems()
    setNeedsFormUpdate()
  }

  private static func persist(_ user: InlineProtocol.User) async throws {
    try await AppDatabase.shared.dbWriter.write { db in
      _ = try User.save(db, user: user)
    }
  }

  // MARK: Text

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func clean(_ value: String) -> String {
    var value = normalized(value).lowercased()
    while value.hasPrefix("@") {
      value.removeFirst()
    }
    return value
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}
