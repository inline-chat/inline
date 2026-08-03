import GRDBQuery
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct ExperimentalProfileToolbarLabel: View {
  @Query(CurrentUser()) private var currentUser: UserInfo?

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      avatar
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      avatar
    }
  }

  @ViewBuilder
  private var avatar: some View {
    if let currentUser {
      UserAvatar(userInfo: currentUser, size: 42)
        .frame(width: 42, height: 42)
    } else {
      Image(systemName: "person.crop.circle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
    }
  }
}

struct ExperimentalProfileView: View {
  @Query(CurrentUser()) private var currentUser: UserInfo?

  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentObject private var fileUploadViewModel: FileUploadViewModel

  @State private var pickedImage: UIImage?
  @State private var showsImagePicker = false
  @State private var showsCropper = false
  @State private var fullName = ""
  @State private var username = ""
  @State private var bio = ""
  @State private var initialFullName = ""
  @State private var initialUsername = ""
  @State private var initialBio = ""
  @State private var loadedUserID: Int64?
  @State private var usernameCheckState = ExperimentalUsernameCheckState.idle
  @State private var isSaving = false
  @State private var saveErrorMessage = ""
  @State private var showsSaveError = false

  var body: some View {
    Form {
      if let currentUser {
        Section {
          ExperimentalProfileHeaderEditor(
            currentUser: currentUser,
            isUploading: fileUploadViewModel.isUploading,
            fullName: $fullName,
            changePhoto: { showsImagePicker = true }
          )
        }
      } else {
        Section {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 72)
        }
      }

      ExperimentalProfileUsernameSection(
        username: $username,
        state: usernameCheckState,
        checkAvailability: checkUsernameAvailability
      )

      ExperimentalProfileContactSection(
        email: currentUser?.user.email,
        phoneNumber: currentUser?.user.phoneNumber
      )

      ExperimentalProfileAboutSection(bio: $bio)

      // TODO: Add editable contact details, status, links, and other
      // account fields once those product and verification flows are defined.
      // TODO: Consider macOS-style per-field edit affordances after this
      // direct-edit prototype's information architecture is verified.

      LogoutSection()
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(isSaving ? "Saving…" : "Save") {
          saveProfile()
        }
        .disabled(!canSave)
      }
    }
    .onAppear {
      loadCurrentUserIfNeeded()
    }
    .onChange(of: currentUser?.user.id) { _, _ in
      loadCurrentUserIfNeeded()
    }
    .onChange(of: username) { _, newValue in
      let candidate = cleanUsername(newValue)
      if candidate == initialUsername, !candidate.isEmpty {
        usernameCheckState = .current
      } else if !candidate.isEmpty, candidate.count < 2 {
        usernameCheckState = .invalid
      } else {
        usernameCheckState = .idle
      }
    }
    .sheet(isPresented: $showsImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        pickedImage = image
        showsCropper = true
      }
    }
    .sheet(
      isPresented: $showsCropper,
      onDismiss: { pickedImage = nil },
      content: {
        if let pickedImage {
          CircularCropView(image: pickedImage) { croppedImage in
            upload(croppedImage)
          }
        }
      }
    )
    .alert("Could Not Save Profile", isPresented: $showsSaveError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(saveErrorMessage)
    }
  }

  private var canSave: Bool {
    !isSaving && !fileUploadViewModel.isUploading && hasChanges
  }

  private var hasChanges: Bool {
    normalized(fullName) != initialFullName
      || cleanUsername(username) != initialUsername
      || normalized(bio) != initialBio
  }

  private func loadCurrentUserIfNeeded() {
    guard let user = currentUser?.user, loadedUserID != user.id else { return }

    let name = [user.firstName, user.lastName]
      .compactMap { $0 }
      .map(normalized)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let loadedUsername = cleanUsername(user.username ?? "")
    let loadedBio = normalized(user.bio ?? "")

    fullName = name
    username = loadedUsername
    bio = loadedBio
    initialFullName = name
    initialUsername = loadedUsername
    initialBio = loadedBio
    usernameCheckState = loadedUsername.isEmpty ? .idle : .current
    loadedUserID = user.id
  }

  private func checkUsernameAvailability() {
    let candidate = cleanUsername(username)
    if candidate == initialUsername, !candidate.isEmpty {
      usernameCheckState = .current
      return
    }
    guard candidate.count >= 2 else {
      usernameCheckState = candidate.isEmpty ? .idle : .invalid
      return
    }

    usernameCheckState = .checking
    Task {
      do {
        let availability = try await realtimeV2.checkUsername(candidate).availability
        guard cleanUsername(username) == candidate, !Task.isCancelled else { return }
        usernameCheckState = usernameState(for: availability)
      } catch {
        guard cleanUsername(username) == candidate, !Task.isCancelled else { return }
        Log.shared.error("Failed to check experimental profile username", error: error)
        usernameCheckState = .failed
      }
    }
  }

  private func saveProfile() {
    guard !isSaving else { return }

    let name = normalized(fullName)
    let username = cleanUsername(username)
    let bio = normalized(bio)

    guard !name.isEmpty else {
      showSaveError("Enter your name.")
      return
    }
    guard username == initialUsername || username.count >= 2 else {
      showSaveError("Usernames must be at least 2 characters.")
      return
    }

    isSaving = true

    Task {
      do {
        if username != initialUsername {
          let availability = try await realtimeV2.checkUsername(username).availability
          let state = usernameState(for: availability)
          usernameCheckState = state
          guard state == .available || state == .current else {
            showSaveError("That username is not available.")
            isSaving = false
            return
          }
        }

        if name != initialFullName || bio != initialBio {
          let nameParts = splitName(name)
          let result = try await realtimeV2.updateProfile(
            firstName: nameParts.firstName,
            lastName: nameParts.lastName,
            bio: bio
          )
          await realtimeV2.applyUpdates(result.updates)
          try await persist(result.user)
        }

        if username != initialUsername {
          let result = try await realtimeV2.changeUsername(username)
          await realtimeV2.applyUpdates(result.updates)
          try await persist(result.user)
        }

        fullName = name
        self.username = username
        self.bio = bio
        initialFullName = name
        initialUsername = username
        initialBio = bio
        usernameCheckState = .current
        isSaving = false
        ToastManager.shared.showToast(
          "Profile updated",
          type: .success,
          systemImage: "checkmark.circle.fill"
        )
      } catch {
        Log.shared.error("Failed to update experimental profile", error: error)
        showSaveError(error.localizedDescription)
        isSaving = false
      }
    }
  }

  private func splitName(_ name: String) -> (firstName: String, lastName: String) {
    let parts = name.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
    return (
      firstName: parts.first.map(String.init) ?? name,
      lastName: parts.count > 1 ? String(parts[1]) : ""
    )
  }

  private func cleanUsername(_ value: String) -> String {
    var value = normalized(value).lowercased()
    while value.hasPrefix("@") {
      value.removeFirst()
    }
    return value
  }

  private func usernameState(
    for availability: InlineProtocol.UsernameAvailability
  ) -> ExperimentalUsernameCheckState {
    switch availability {
    case .usernameAvailable:
      .available
    case .usernameCurrent:
      .current
    case .usernameTaken, .usernameReserved:
      .unavailable
    case .usernameInvalid:
      .invalid
    case .unspecified, .UNRECOGNIZED:
      .idle
    }
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func persist(_ user: InlineProtocol.User) async throws {
    _ = try await AppDatabase.shared.dbWriter.write { db in
      try User.save(db, user: user)
    }
  }

  private func showSaveError(_ message: String) {
    saveErrorMessage = message
    showsSaveError = true
  }

  private func upload(_ image: UIImage) {
    guard let data = image.jpegData(compressionQuality: 0.86) else {
      showsCropper = false
      return
    }

    Task {
      await fileUploadViewModel.uploadImage(data, fileType: .jpeg)
      pickedImage = nil
      showsCropper = false
    }
  }
}

private struct ExperimentalProfileHeaderEditor: View {
  let currentUser: UserInfo
  let isUploading: Bool
  @Binding var fullName: String
  let changePhoto: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Button(action: changePhoto) {
        ZStack(alignment: .bottomTrailing) {
          UserAvatar(userInfo: currentUser, size: 132)

          Image(systemName: isUploading ? "hourglass" : "camera.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.accentColor, in: Circle())
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
        }
      }
      .buttonStyle(.plain)
      .disabled(isUploading)
      .accessibilityLabel("Change Profile Photo")

      TextField("Name", text: $fullName)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
        .textContentType(.name)
        .textInputAutocapitalization(.words)
        .textFieldStyle(.plain)

    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 16)
  }
}

private enum ExperimentalUsernameCheckState: Equatable {
  case idle
  case checking
  case available
  case current
  case unavailable
  case invalid
  case failed
}

private struct ExperimentalProfileUsernameSection: View {
  @Binding var username: String
  let state: ExperimentalUsernameCheckState
  let checkAvailability: () -> Void

  var body: some View {
    Section {
      HStack(spacing: 10) {
        HStack(spacing: 2) {
          Text("@", comment: "Fixed prefix shown before the editable profile username.")
            .foregroundStyle(.secondary)

          TextField("Username", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        Button(action: checkAvailability) {
          if state == .checking {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Check")
          }
        }
          .disabled(state == .checking || cleanedUsername.count < 2)
      }
    } header: {
      Text("Account")
    } footer: {
      ExperimentalUsernameAvailabilityStatus(state: state)
    }
  }

  private var cleanedUsername: String {
    var value = username.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("@") {
      value.removeFirst()
    }
    return value
  }
}

private struct ExperimentalUsernameAvailabilityStatus: View {
  let state: ExperimentalUsernameCheckState

  @ViewBuilder
  var body: some View {
    switch state {
    case .idle, .checking:
      EmptyView()
    case .available:
      Label("Username is available", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .current:
      Label("This is your current username", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.secondary)
    case .unavailable:
      Label("Username is not available", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
    case .invalid:
      Label("Usernames must be at least 2 characters", systemImage: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    case .failed:
      Label("Could not check availability. Try again", systemImage: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    }
  }
}

private struct ExperimentalProfileContactSection: View {
  let email: String?
  let phoneNumber: String?

  var body: some View {
    Section("Contact") {
      LabeledContent("Email", value: nonempty(email) ?? "Not set")
      LabeledContent("Phone", value: nonempty(phoneNumber) ?? "Not set")
    }
  }

  private func nonempty(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}

private struct ExperimentalProfileAboutSection: View {
  @Binding var bio: String

  var body: some View {
    Section("About") {
      TextField("Bio", text: $bio, axis: .vertical)
        .lineLimit(3 ... 6)
    }
  }
}
