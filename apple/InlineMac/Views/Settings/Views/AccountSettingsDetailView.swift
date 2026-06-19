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

    let _ = try await AppDatabase.shared.dbWriter.write { db in
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
  @State private var sessionToRevoke: InlineProtocol.AccountSession?

  init() {}

  var body: some View {
    Form {
      Section {
        if let user = root.currentUser {
          profileRows(user)
        } else {
          Text("Account details are loading.")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Profile")
      } footer: {
        Text("Your name, username, and profile photo are visible to people you chat with.")
      }

      Section {
        if viewModel.isLoadingSessions, viewModel.sessions.isEmpty {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading sessions...")
              .foregroundStyle(.secondary)
          }
        } else if viewModel.sessions.isEmpty {
          Text("No active sessions.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.sessions, id: \.id) { session in
            AccountSessionRow(
              session: session,
              isRevoking: viewModel.revokingSessionID == session.id,
              onRevoke: {
                sessionToRevoke = session
              }
            )
          }
        }

        Button("Refresh") {
          Task {
            await viewModel.loadSessions(realtimeV2: realtimeV2)
          }
        }
        .disabled(viewModel.isLoadingSessions)
      } header: {
        Text("Active Sessions")
      } footer: {
        Text("Sessions are devices and clients signed into your account. Revoke anything you do not recognize.")
      }

      Section {
        LabeledContent("This Mac") {
          Button("Sign Out...", role: .destructive) {
            showLogoutConfirmation = true
          }
        }
      } header: {
        Text("Session")
      } footer: {
        Text("Signing out removes this device's local session. Your account and messages remain available on other devices.")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .alert(
      viewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { viewModel.errorState != nil },
        set: { if !$0 { viewModel.errorState = nil } }
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

  @ViewBuilder
  private func profileRows(_ user: InlineKit.User) -> some View {
    LabeledContent("Photo") {
      HStack(spacing: 12) {
        Button {
          showImagePicker = true
        } label: {
          UserAvatar(user: user, size: 48)
            .overlay(
              Circle()
                .stroke(.primary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(photoViewModel.isUploading)

        Button("Change...") {
          showImagePicker = true
        }
        .disabled(photoViewModel.isUploading)

        if photoViewModel.isUploading {
          ProgressView()
            .controlSize(.small)
        }
      }
    }

    LabeledContent("Name") {
      HStack(spacing: 12) {
        Text(nonEmpty(user.fullName, fallback: "Not set"))
          .foregroundStyle(user.fullName.isEmpty ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .frame(maxWidth: 280, alignment: .trailing)

        Button("Edit...") {
          editingProfileUser = user
        }
      }
    }

    LabeledContent("Bio") {
      HStack(spacing: 12) {
        Text(nonEmpty(user.bio, fallback: "Not set"))
          .foregroundStyle(user.bio == nil ? .secondary : .primary)
          .lineLimit(2)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .frame(maxWidth: 280, alignment: .trailing)

        Button("Edit...") {
          editingProfileUser = user
        }
      }
    }

    LabeledContent("Username") {
      HStack(spacing: 12) {
        Text(user.username.map { "@\($0)" } ?? "Not set")
          .foregroundStyle(user.username == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .frame(maxWidth: 280, alignment: .trailing)

        Button("Change...") {
          editingUsernameUser = user
        }
      }
    }

    LabeledContent("Email") {
      Text(nonEmpty(user.email, fallback: "Not linked"))
        .foregroundStyle(user.email == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }

    LabeledContent("Phone") {
      Text(nonEmpty(user.phoneNumber, fallback: "Not linked"))
        .foregroundStyle(user.phoneNumber == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }

    LabeledContent("Account ID") {
      Text(verbatim: "\(user.id)")
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .textSelection(.enabled)
    }
  }

  private func nonEmpty(_ value: String?, fallback: String) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return fallback
    }
    return value
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
    NavigationStack {
      Form {
        Section {
          LabeledContent("First Name") {
            TextField("First Name", text: $firstName)
              .textContentType(.givenName)
              .frame(width: 260)
          }

          LabeledContent("Last Name") {
            TextField("Last Name", text: $lastName)
              .textContentType(.familyName)
              .frame(width: 260)
          }

          LabeledContent("Bio") {
            TextEditor(text: $bio)
              .frame(width: 260, height: 96)
          }
        } footer: {
          Text("Your profile is visible to people you chat with.")
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .navigationTitle("Edit Profile")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            dismiss()
          }
          .disabled(isSaving)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving..." : "Save") {
            Task {
              await onSave(firstName, lastName, bio)
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || firstName.settingsTrimmed.isEmpty)
        }
      }
    }
    .frame(minWidth: 460, minHeight: 340)
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
    NavigationStack {
      Form {
        Section {
          LabeledContent("Username") {
            HStack(spacing: 4) {
              Text("@")
                .foregroundStyle(.secondary)
              TextField("username", text: $username)
                .textContentType(.username)
                .disabled(isChecking || isSaving)
            }
            .frame(width: 240)
          }

          HStack(spacing: 8) {
            Button(isChecking ? "Checking..." : "Check Availability") {
              Task {
                await onCheck(username)
              }
            }
            .disabled(isChecking || isSaving || username.settingsTrimmed.isEmpty)

            if isChecking {
              ProgressView()
                .controlSize(.small)
            }
          }

          if let message = usernameState.message {
            Text(message)
              .font(.caption)
              .foregroundStyle(messageColor)
          }
        } footer: {
          Text("Usernames are public and help people find your account.")
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .navigationTitle("Change Username")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            dismiss()
          }
          .disabled(isSaving)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving..." : "Save") {
            Task {
              await onSave(username)
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || isChecking || !usernameState.canSave)
        }
      }
      .onChange(of: username) {
        onChange(username)
      }
    }
    .frame(minWidth: 460, minHeight: 280)
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
