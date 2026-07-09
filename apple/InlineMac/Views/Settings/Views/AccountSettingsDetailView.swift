import InlineKit
import InlineProtocol
import InlineUI
import Logger
import MultipartFormDataKit
import RealtimeV2
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Upload File Error Handling

enum UploadFileError: LocalizedError {
  case permissionDenied(String)
  case invalidFile(String)
  case unknown(Error)

  var errorDescription: String? {
    switch self {
    case let .permissionDenied(filename):
      "Cannot access '\(filename)'. Make sure you have permission to view this file."
    case let .invalidFile(filename):
      "'\(filename)' could not be opened. The file might be corrupted or in an unsupported format."
    case let .unknown(error):
      error.localizedDescription
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .permissionDenied:
      "Try selecting a different file or check the file permissions in Finder."
    case .invalidFile:
      "Please select a valid image file."
    case .unknown:
      "Please try again or select a different file."
    }
  }
}

// MARK: - Account Settings Photo View Model

@MainActor
final class AccountSettingsPhotoViewModel: ObservableObject {
  @Published private(set) var isUploading = false
  @Published var errorState: ErrorState?
  @Published var showUploadSheet = false

  private let maxFileSize = 10 * 1_024 * 1_024 // 10MB
  private let supportedImageTypes: Set<UTType> = [.jpeg, .png, .heic]

  struct ErrorState {
    let title: String
    let message: String
    let suggestion: String?
  }

  func uploadImage(from url: URL) async {
    guard !isUploading else { return }

    isUploading = true
    showUploadSheet = true

    do {
      guard url.startAccessingSecurityScopedResource() else {
        throw UploadFileError.permissionDenied(url.lastPathComponent)
      }

      defer {
        url.stopAccessingSecurityScopedResource()
      }

      // Verify file type
      guard let fileType = UTType(filenameExtension: url.pathExtension),
            supportedImageTypes.contains(fileType)
      else {
        throw UploadFileError.invalidFile(url.lastPathComponent)
      }

      // Verify file exists and get attributes
      let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
      guard let fileSize = resourceValues.fileSize,
            fileSize <= maxFileSize
      else {
        throw UploadFileError.invalidFile("\(url.lastPathComponent) exceeds maximum size of 10MB")
      }

      // Read file data
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw UploadFileError.permissionDenied(url.lastPathComponent)
      }

      try await uploadImageToServer(data, fileType: fileType)

      // Close sheet on success
      showUploadSheet = false
    } catch let error as UploadFileError {
      Log.shared.error("Failed to upload image", error: error)
      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)
      showError(UploadFileError.unknown(error))
    }

    isUploading = false
  }

  private func uploadImageToServer(_ data: Data, fileType: UTType) async throws {
    let mimeType = switch fileType {
    case .jpeg:
      MIMEType.imageJpeg
    case .png:
      MIMEType.imagePng
    default:
      MIMEType.imageJpeg
    }

    let fileName = "profile_photo.\(fileType.preferredFilenameExtension ?? "jpg")"

    let result = try await ApiClient.shared
      .uploadFile(
        type: .photo,
        data: data,
        filename: fileName,
        mimeType: mimeType,
        progress: { _ in }
      )

    // call update profile photo method
    let result2 = try await ApiClient.shared.updateProfilePhoto(fileUniqueId: result.fileUniqueId)

    _ = try await AppDatabase.shared.dbWriter.write { db in
      try result2.user.saveFull(db)
    }
  }

  private func showError(_ error: UploadFileError) {
    showUploadSheet = false
    errorState = ErrorState(
      title: "Upload Error",
      message: error.errorDescription ?? "An unknown error occurred",
      suggestion: error.recoverySuggestion
    )
  }
}

// MARK: - Account Settings Detail View

struct AccountSettingsDetailView: View {
  @EnvironmentObject private var root: RootData
  @Environment(\.logOut) private var logOut
  @Environment(\.realtimeV2) private var realtimeV2
  @StateObject private var photoViewModel = AccountSettingsPhotoViewModel()
  @StateObject private var viewModel = AccountSettingsViewModel()
  @State private var showImagePicker = false
  @State private var showLogoutConfirmation = false
  @State private var editingProfileUser: InlineKit.User?
  @State private var editingUsernameUser: InlineKit.User?

  var body: some View {
    Form {
      if let user = root.currentUser {
        AccountProfileSection(
          user: user,
          isUploadingPhoto: photoViewModel.isUploading,
          onChangePhoto: { showImagePicker = true },
          onEditProfile: { editingProfileUser = user }
        )

        AccountIdentitySection(
          username: user.username,
          email: user.email,
          phoneNumber: user.phoneNumber,
          accountID: user.id,
          onChangeUsername: { editingUsernameUser = user }
        )
      } else {
        Section {
          SettingsLoadingRow(
            "Loading Account",
            description: "Fetching your profile details."
          )
        } header: {
          SettingsSectionHeader("Profile")
        }
      }

      AccountSignOutSection(onSignOut: { showLogoutConfirmation = true })
    }
    .settingsFormStyle()
    .environmentObject(root)
    .fileImporter(
      isPresented: $showImagePicker,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      Task {
        await handleImageSelection(result)
      }
    }
    .sheet(isPresented: $photoViewModel.showUploadSheet) {
      UploadProgressSheet()
        .environmentObject(photoViewModel)
    }
    .sheet(item: $editingProfileUser) { user in
      ProfileEditSheet(user: user, isSaving: viewModel.isSavingProfile) { firstName, lastName, bio in
        let saved = await viewModel.saveProfile(
          firstName: firstName,
          lastName: lastName,
          bio: bio,
          realtimeV2: realtimeV2
        )
        if saved {
          editingProfileUser = nil
        }
      }
    }
    .sheet(item: $editingUsernameUser, onDismiss: viewModel.resetUsernameState) { user in
      UsernameEditSheet(
        user: user,
        usernameState: viewModel.usernameState,
        isChecking: viewModel.isCheckingUsername,
        isSaving: viewModel.isSavingUsername,
        onChange: { username in
          viewModel.usernameChanged(username, currentUsername: user.username)
        },
        onCheck: { username in
          await viewModel.checkUsername(username, currentUsername: user.username, realtimeV2: realtimeV2)
        },
        onSave: { username in
          let saved = await viewModel.saveUsername(username, currentUsername: user.username, realtimeV2: realtimeV2)
          if saved {
            editingUsernameUser = nil
          }
        }
      )
    }
    .alert(
      photoViewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { photoViewModel.errorState != nil },
        set: { if !$0 { photoViewModel.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = photoViewModel.errorState {
        VStack(alignment: .leading, spacing: 8) {
          Text(errorState.message)
          if let suggestion = errorState.suggestion {
            Text(suggestion)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .alert(
      viewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { viewModel.errorState != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = viewModel.errorState {
        Text(errorState.message)
      }
    }
    .confirmationDialog(
      "Sign Out?",
      isPresented: $showLogoutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) {
        Task {
          await logOut()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Are you sure you want to log out?")
    }
  }

  private func handleImageSelection(_ result: Result<[URL], Error>) async {
    do {
      let urls = try result.get()
      guard let url = urls.first else { return }
      await photoViewModel.uploadImage(from: url)
    } catch {
      // Handle file selection error
      photoViewModel.errorState = AccountSettingsPhotoViewModel.ErrorState(
        title: "Selection Error",
        message: "Could not select the image file.",
        suggestion: "Please try selecting a different image."
      )
    }
  }
}

private struct AccountProfileSection: View {
  let user: InlineKit.User
  let isUploadingPhoto: Bool
  let onChangePhoto: () -> Void
  let onEditProfile: () -> Void

  var body: some View {
    Section {
      HStack(alignment: .center, spacing: 16) {
        Button(action: onChangePhoto) {
          UserAvatar(user: user, size: 64)
            .overlay {
              Circle()
                .stroke(.primary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingPhoto)
        .help("Change Profile Photo")

        VStack(alignment: .leading, spacing: 4) {
          Text(displayName)
            .font(.headline)
            .lineLimit(1)

          if let bio = nonEmpty(user.bio) {
            Text(bio)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .trailing, spacing: 8) {
          Button("Edit Profile...") {
            onEditProfile()
          }

          if isUploadingPhoto {
            ProgressView()
              .controlSize(.small)
          } else {
            Button("Change Photo...") {
              onChangePhoto()
            }
          }
        }
      }
      .padding(.vertical, 4)
    } header: {
      SettingsSectionHeader(
        "Profile",
        subtitle: "Your profile is visible to people you chat with."
      )
    }
  }

  private var displayName: String {
    user.fullName.settingsTrimmed.isEmpty ? "Unnamed Account" : user.fullName
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.settingsTrimmed.isEmpty else { return nil }
    return value
  }
}

private struct AccountIdentitySection: View {
  let username: String?
  let email: String?
  let phoneNumber: String?
  let accountID: Int64
  let onChangeUsername: () -> Void

  var body: some View {
    Section {
      LabeledContent {
        HStack(spacing: 12) {
          Text(username.map { "@\($0)" } ?? "Not set")
            .foregroundStyle(username == nil ? .secondary : .primary)
            .textSelection(.enabled)

          Button("Change...") {
            onChangeUsername()
          }
        }
      } label: {
        SettingsRowLabel(
          "Username",
          description: "The public name people can use to find your account."
        )
      }

      if let email = nonEmpty(email) {
        LabeledContent {
          Text(email)
            .textSelection(.enabled)
        } label: {
          SettingsRowLabel("Email")
        }
      }

      if let phoneNumber = nonEmpty(phoneNumber) {
        LabeledContent {
          Text(phoneNumber)
            .textSelection(.enabled)
        } label: {
          SettingsRowLabel("Phone")
        }
      }

      DisclosureGroup {
        LabeledContent("Account ID") {
          Text(verbatim: "\(accountID)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
        }
      } label: {
        SettingsRowLabel("Technical Details")
      }
    } header: {
      SettingsSectionHeader("Account")
    }
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.settingsTrimmed.isEmpty else { return nil }
    return value
  }
}

private struct AccountSignOutSection: View {
  let onSignOut: () -> Void

  var body: some View {
    Section {
      LabeledContent {
        Button("Sign Out...", role: .destructive) {
          onSignOut()
        }
      } label: {
        SettingsRowLabel("This Mac")
      }
    } header: {
      SettingsSectionHeader("Session")
    }
  }
}

struct AccountSessionsSettingsDetailView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @StateObject private var viewModel = AccountSettingsViewModel()
  @State private var sessionToRevoke: InlineProtocol.AccountSession?

  var body: some View {
    Form {
      Section {
        if let errorState = viewModel.errorState {
          if viewModel.sessions.isEmpty {
            SettingsErrorRow(
              dynamicTitle: errorState.title,
              message: errorState.message,
              actionTitle: "Try Again",
              action: {
                Task {
                  await viewModel.loadSessions(realtimeV2: realtimeV2)
                }
              }
            )
          } else {
            SettingsErrorRow(
              dynamicTitle: errorState.title,
              message: errorState.message,
              actionTitle: "Dismiss",
              action: viewModel.clearError
            )
          }
        }

        if viewModel.isLoadingSessions, viewModel.sessions.isEmpty {
          SettingsLoadingRow(
            "Loading Sessions",
            description: "Fetching devices and clients signed into your account."
          )
        } else if viewModel.sessions.isEmpty, viewModel.errorState == nil {
          SettingsEmptyRow(
            "No Active Sessions",
            description: "No signed-in devices or clients were returned.",
            systemImage: "laptopcomputer.and.iphone"
          )
        } else {
          ForEach(viewModel.sessions, id: \.id) { session in
            AccountSessionRow(
              session: session,
              isRevoking: viewModel.revokingSessionID == session.id,
              onRevoke: { sessionToRevoke = session }
            )
          }
        }
      } header: {
        SettingsSectionHeader(
          "Signed-In Devices",
          subtitle: "Revoke anything you do not recognize. Sign out this Mac from the Account page."
        )
      }
    }
    .settingsFormStyle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task {
            await viewModel.loadSessions(realtimeV2: realtimeV2)
          }
        } label: {
          Label("Refresh Sessions", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .disabled(viewModel.isLoadingSessions)
        .help("Refresh Sessions")
      }
    }
    .confirmationDialog(
      "Revoke Session?",
      isPresented: .init(
        get: { sessionToRevoke != nil },
        set: { if !$0 { sessionToRevoke = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Revoke", role: .destructive) {
        guard let session = sessionToRevoke else { return }
        Task {
          await viewModel.revoke(session, realtimeV2: realtimeV2)
          sessionToRevoke = nil
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This signs that device or client out of your account.")
    }
    .task {
      await viewModel.loadSessions(realtimeV2: realtimeV2)
    }
  }
}

// MARK: - Profile Edit Sheet

private struct ProfileEditSheet: View {
  @Environment(\.dismiss) private var dismiss

  let user: InlineKit.User
  let isSaving: Bool
  let onSave: (String, String, String) async -> Void

  @State private var firstName: String
  @State private var lastName: String
  @State private var bio: String

  init(
    user: InlineKit.User,
    isSaving: Bool,
    onSave: @escaping (String, String, String) async -> Void
  ) {
    self.user = user
    self.isSaving = isSaving
    self.onSave = onSave
    _firstName = State(initialValue: user.firstName ?? "")
    _lastName = State(initialValue: user.lastName ?? "")
    _bio = State(initialValue: user.bio ?? "")
  }

  var body: some View {
    SettingsEditSheet(
      title: "Edit Profile",
      detail: "Update the name and bio people see when they chat with you.",
      isSaving: isSaving,
      canSave: !firstName.settingsTrimmed.isEmpty,
      onCancel: { dismiss() },
      onSave: {
        Task {
          await onSave(firstName, lastName, bio)
        }
      },
      content: {
        Form {
          Section {
            LabeledContent("First Name") {
              TextField("First Name", text: $firstName)
                .textContentType(.givenName)
                .frame(minWidth: 220, idealWidth: 280)
            }

            LabeledContent("Last Name") {
              TextField("Last Name", text: $lastName)
                .textContentType(.familyName)
                .frame(minWidth: 220, idealWidth: 280)
            }

            LabeledContent("Bio") {
              TextEditor(text: $bio)
                .frame(minWidth: 220, idealWidth: 280, minHeight: 72, idealHeight: 96)
            }
          } footer: {
            Text("Your profile is visible to people you chat with.")
          }
        }
      }
    )
    .frame(width: 500, height: 380)
  }
}

// MARK: - Username Edit Sheet

private struct UsernameEditSheet: View {
  @Environment(\.dismiss) private var dismiss

  let user: InlineKit.User
  let usernameState: AccountSettingsViewModel.UsernameState
  let isChecking: Bool
  let isSaving: Bool
  let onChange: (String) -> Void
  let onCheck: (String) async -> Void
  let onSave: (String) async -> Void

  @State private var username: String
  @State private var availabilityTask: Task<Void, Never>?

  init(
    user: InlineKit.User,
    usernameState: AccountSettingsViewModel.UsernameState,
    isChecking: Bool,
    isSaving: Bool,
    onChange: @escaping (String) -> Void,
    onCheck: @escaping (String) async -> Void,
    onSave: @escaping (String) async -> Void
  ) {
    self.user = user
    self.usernameState = usernameState
    self.isChecking = isChecking
    self.isSaving = isSaving
    self.onChange = onChange
    self.onCheck = onCheck
    self.onSave = onSave
    _username = State(initialValue: user.username ?? "")
  }

  var body: some View {
    SettingsEditSheet(
      title: "Change Username",
      detail: "Choose the public username people can use to find your account.",
      isSaving: isSaving,
      canSave: !isChecking && usernameState.canSave,
      onCancel: { dismiss() },
      onSave: {
        Task {
          await onSave(username)
        }
      },
      content: {
        Form {
          Section {
            LabeledContent("Username") {
              HStack(spacing: 6) {
                Text("@")
                  .foregroundStyle(.secondary)

                TextField("username", text: $username)
                  .textContentType(.username)
                  .disabled(isChecking || isSaving)

                if isChecking {
                  ProgressView()
                    .controlSize(.small)
                }
              }
              .frame(minWidth: 220, idealWidth: 280)
            }

            if let message = usernameState.message {
              Label {
                Text(message)
              } icon: {
                Image(systemName: messageIconName)
              }
              .font(.caption)
              .foregroundStyle(messageColor)
            }
          } footer: {
            Text("Availability is checked automatically as you type. Clear the field to remove your username.")
          }
        }
      }
    )
    .frame(width: 500, height: 300)
    .onChange(of: username) { _, newValue in
      usernameDidChange(newValue)
    }
    .onDisappear {
      availabilityTask?.cancel()
    }
  }

  private var messageColor: Color {
    switch usernameState {
    case .available, .unchanged, .willClear:
      .green
    case .unavailable, .reserved, .invalid:
      .red
    case .idle, .checking:
      .secondary
    }
  }

  private var messageIconName: String {
    switch usernameState {
    case .available, .unchanged, .willClear:
      "checkmark.circle.fill"
    case .unavailable, .reserved, .invalid:
      "exclamationmark.circle.fill"
    case .idle, .checking:
      "circle"
    }
  }

  private func usernameDidChange(_ candidate: String) {
    onChange(candidate)
    availabilityTask?.cancel()

    let cleaned = candidate.settingsTrimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    guard !cleaned.isEmpty else { return }

    availabilityTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await onCheck(candidate)
    }
  }
}

// MARK: - Session Row

private struct AccountSessionRow: View {
  let session: InlineProtocol.AccountSession
  let isRevoking: Bool
  let onRevoke: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: iconName)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
            .font(.body)

          if session.current {
            Text("Current")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        Text("Last active \(lastActiveText)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      if session.current {
        EmptyView()
      } else if isRevoking {
        ProgressView()
          .controlSize(.small)
      } else {
        Button("Revoke", role: .destructive) {
          onRevoke()
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var title: String {
    if session.hasDeviceName, !session.deviceName.isEmpty {
      return session.deviceName
    }
    return clientTitle
  }

  private var detail: String {
    [
      clientTitle,
      optional(session.hasClientVersion, session.clientVersion),
      optional(session.hasOsVersion, session.osVersion),
      location,
    ]
    .compactMap { $0 }
    .joined(separator: " - ")
  }

  private var location: String? {
    let parts = [
      optional(session.hasCity, session.city),
      optional(session.hasCountry, session.country),
    ].compactMap { $0 }

    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  private var clientTitle: String {
    switch session.clientType {
    case "macos":
      "Inline for Mac"
    case "ios":
      "Inline for iOS"
    case "web":
      "Inline Web"
    case "cli":
      "Inline CLI"
    case "api":
      "API"
    default:
      "Unknown Client"
    }
  }

  private var iconName: String {
    switch session.clientType {
    case "macos":
      "desktopcomputer"
    case "ios":
      "iphone"
    case "web":
      "globe"
    case "cli":
      "terminal"
    default:
      "person.crop.circle.badge.questionmark"
    }
  }

  private var lastActiveText: String {
    guard session.lastActiveAt > 0 else {
      return "unknown"
    }
    let date = Date(timeIntervalSince1970: TimeInterval(session.lastActiveAt))
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private func optional(_ hasValue: Bool, _ value: String) -> String? {
    let trimmed = value.settingsTrimmed
    return hasValue && !trimmed.isEmpty ? trimmed : nil
  }
}

private extension String {
  var settingsTrimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Upload Progress Sheet

struct UploadProgressSheet: View {
  @EnvironmentObject var photoViewModel: AccountSettingsPhotoViewModel

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        VStack(spacing: 16) {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(1.2)

          Text("Uploading Profile Photo...")
            .font(.headline)
        }

        Text("Please wait while your photo is being uploaded.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Spacer()
      }
      .padding()
      .frame(minWidth: 320, minHeight: 200)
      .navigationTitle("Upload Photo")
    }
    .presentationDetents([.height(280)])
    .interactiveDismissDisabled()
  }
}

#Preview {
  AccountSettingsDetailView()
    .previewsEnvironment(.populated)
}
