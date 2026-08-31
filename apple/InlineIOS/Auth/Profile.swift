#if !IOS_ONBOARDING_GALLERY_APP
import Auth
import InlineKit
import InlineUI
import Logger
import MultipartFormDataKit
import RealtimeV2
#endif
import SwiftUI

enum UsernameStatus: Equatable {
  case idle
  case checking
  case available
  case taken
}

struct Profile: View {
  let userId: Int64

  @State private var errorMsg = ""
  @State private var isLoadingPhoto = false
  @State private var saveTask: Task<Void, Never>?
  #if IOS_ONBOARDING_GALLERY_APP
  @State private var hasHydratedProfile = true
  #else
  @State private var hasHydratedProfile = false
  @State private var persistedUser: User?
  @State private var avatarLocalURL: URL?
  #endif
  @FocusState private var isFocused: Bool

  @EnvironmentObject private var nav: OnboardingNavigation
  #if !IOS_ONBOARDING_GALLERY_APP
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  #endif
  @FormState private var formState

  private let placeHolder = "Name"

  var body: some View {
    Group {
      if hasHydratedProfile {
        OnboardingFormPage(
          focus: $isFocused,
          autofocus: nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
          Text(NSLocalizedString("Set up your profile", comment: "Profile setup title"))
            .font(.onboardingIOSTitle.bold())
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

          OnboardingProfilePhotoPicker(
            photo: $nav.profilePhoto,
            isLoading: $isLoadingPhoto,
            errorMessage: $errorMsg,
            hasExistingPhoto: hasExistingPhoto,
            isSaving: formState.isLoading,
            lookupPhoto: lookupXPhoto,
            savePhoto: saveXPhoto
          ) {
            profileAvatar
          }

          VStack(spacing: 8) {
            nameSection

            if !errorMsg.isEmpty {
              Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
          }
        } actions: {
          bottomButton
        }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: nav.profileName) { _, _ in errorMsg = "" }
    .task { await hydratePersistedProfile() }
    .navigationBarBackButtonHidden(formState.isLoading)
    .onDisappear { saveTask?.cancel() }
  }
}

extension Profile {
  @MainActor
  private func hydratePersistedProfile() async {
    #if !IOS_ONBOARDING_GALLERY_APP
    nav.prepareProfileDraft(for: userId)
    defer { hasHydratedProfile = true }

    do {
      guard let user = try await User.fetch(id: userId, from: database) else { return }
      let localURL = await Task.detached { () -> URL? in
        guard let url = user.getLocalURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
      }.value
      guard !Task.isCancelled else { return }
      persistedUser = user
      avatarLocalURL = localURL
      if nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let persistedName = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        nav.profileName = persistedName
      }
    } catch {
      Log.shared.error("Failed to load persisted onboarding profile", error: error)
    }
    #endif
  }

  private func submitName() {
    guard !formState.isLoading, !isLoadingPhoto else { return }
    let trimmedName = nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      errorMsg = "Please enter your name"
      return
    }

    #if IOS_ONBOARDING_GALLERY_APP
    nav.push(.username(userId: userId))
    #else
    let photo = nav.profilePhoto
    errorMsg = ""
    isFocused = false
    formState.startLoading()
    saveTask = Task {
      defer { formState.reset() }
      do {
        let mutationToken = try Auth.shared.handle.beginAccountMutation()
        guard mutationToken.userID == userId else { throw CancellationError() }

        let (firstName, lastName) = parseNameComponents(from: trimmedName)
        let result = try await realtimeV2.updateProfile(
          firstName: firstName,
          lastName: lastName ?? "",
          bio: nil
        )
        try Auth.shared.handle.validateAccountMutation(mutationToken)
        try Task.checkCancellation()
        await realtimeV2.applyUpdatesAndWait(result.updates)
        persistedUser = try await database.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          return try User.save(db, user: result.user)
        }

        if let photo, !photo.isUploaded {
          nav.profilePhoto = try await saveProfilePhoto(photo, mutationToken: mutationToken)
        }

        try Auth.shared.handle.validateAccountMutation(mutationToken)
        try Task.checkCancellation()
        nav.push(.username(userId: userId))
      } catch is CancellationError {
        return
      } catch let error as APIError {
        guard !Task.isCancelled else { return }
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
      } catch {
        guard !Task.isCancelled else { return }
        Log.shared.error("Failed to save onboarding profile", error: error)
        errorMsg = error.localizedDescription
      }
    }
    #endif
  }

  private func saveXPhoto(_ photo: OnboardingProfilePhoto) async throws -> OnboardingProfilePhoto {
    #if IOS_ONBOARDING_GALLERY_APP
    throw OnboardingProfilePhotoError.previewUnavailable
    #else
    let mutationToken = try Auth.shared.handle.beginAccountMutation()
    return try await saveProfilePhoto(photo, mutationToken: mutationToken)
    #endif
  }

  #if !IOS_ONBOARDING_GALLERY_APP
  private func saveProfilePhoto(
    _ photo: OnboardingProfilePhoto,
    mutationToken: AuthAccountMutationToken
  ) async throws -> OnboardingProfilePhoto {
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    guard mutationToken.userID == userId else { throw CancellationError() }
    try Task.checkCancellation()
    guard !photo.isUploaded else { return photo }

    let upload = try await ApiClient.shared.uploadFile(
      type: .photo,
      data: photo.data,
      filename: "profile-photo.png",
      mimeType: .imagePng,
      progress: { _ in }
    )
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    try Task.checkCancellation()
    let result = try await realtimeV2.setProfilePhoto(fileUniqueID: upload.fileUniqueId)
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    try Task.checkCancellation()
    await realtimeV2.applyUpdatesAndWait(result.updates)
    let savedUser = try await database.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      return try User.save(db, user: result.user)
    }
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    try Task.checkCancellation()
    persistedUser = savedUser
    avatarLocalURL = nil
    do {
      try await User.cacheImageData(userId: userId, data: photo.data)
      if let cachedUser = try await User.fetch(id: userId, from: database) {
        try Auth.shared.handle.validateAccountMutation(mutationToken)
        try Task.checkCancellation()
        persistedUser = cachedUser
        avatarLocalURL = cachedUser.getLocalURL()
      }
    } catch {
      Log.shared.error("Failed to cache onboarding profile photo", error: error)
    }
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    try Task.checkCancellation()
    var savedPhoto = photo
    savedPhoto.isUploaded = true
    return savedPhoto
  }
  #endif

  private func lookupXPhoto(_ username: String) async throws -> Data {
    #if IOS_ONBOARDING_GALLERY_APP
    throw OnboardingProfilePhotoError.previewUnavailable
    #else
    let result = try await realtimeV2.getExternalProfilePhoto(provider: .x, username: username)
    switch result.status {
    case .externalProfilePhotoFound where !result.photo.isEmpty:
      return result.photo
    case .externalProfilePhotoNotFound:
      throw OnboardingProfilePhotoError.notFound
    case .externalProfilePhotoUnavailable:
      throw OnboardingProfilePhotoError.unavailable
    case .unspecified, .externalProfilePhotoFound, .UNRECOGNIZED:
      throw OnboardingProfilePhotoError.invalidImage
    }
    #endif
  }

  private func parseNameComponents(from fullName: String) -> (firstName: String, lastName: String?) {
    let formatter = PersonNameComponentsFormatter()
    if let components = formatter.personNameComponents(from: fullName) {
      if components.givenName == nil {
        return (fullName, nil)
      }
      return (components.givenName ?? fullName, components.familyName)
    }
    return (fullName, nil)
  }
}

// MARK: - Views

extension Profile {
  private var hasExistingPhoto: Bool {
    #if IOS_ONBOARDING_GALLERY_APP
    false
    #else
    persistedUser?.stableAvatarIdentity != nil
      || persistedUser?.profileCdnUrl != nil
      || avatarLocalURL != nil
    #endif
  }

  @ViewBuilder
  private var profileAvatar: some View {
    #if IOS_ONBOARDING_GALLERY_APP
    Circle()
      .fill(Color.accentColor.gradient)
      .overlay {
        let name = nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initial = name.first {
          Text(String(initial).uppercased())
            .font(.system(size: 42, weight: .medium))
            .foregroundStyle(.white)
        } else {
          Image(systemName: "person.fill")
            .font(.system(size: 42))
            .foregroundStyle(.white)
        }
      }
    #else
    if let user = persistedUser {
      UserAvatar(
        userID: userId,
        firstName: nav.profileName,
        lastName: nil,
        email: user.email,
        username: user.username,
        stableAvatarIdentity: user.stableAvatarIdentity,
        remoteURL: user.getRemoteURL(),
        localURL: avatarLocalURL,
        size: 104
      )
    } else {
      Circle().fill(Color(uiColor: .secondarySystemBackground))
    }
    #endif
  }

  @ViewBuilder
  private var nameSection: some View {
    TextField(placeHolder, text: $nav.profileName)
      .focused($isFocused)
      .textContentType(.name)
      .textInputAutocapitalization(.words)
      .multilineTextAlignment(.center)
      .onboardingFormField()
      .submitLabel(.continue)
      .disabled(formState.isLoading)
      .onSubmit { submitName() }
  }

  @ViewBuilder
  private var bottomButton: some View {
    Button(formState.isLoading ? "Saving..." : "Continue") {
      submitName()
    }
    .buttonStyle(OnboardingFormButtonStyle())
    .disabled(formState.isLoading || isLoadingPhoto)
  }
}

struct OnboardingUsername: View {
  let userId: Int64

  @State private var errorMsg = ""
  @State private var usernameStatus: UsernameStatus = .idle
  #if IOS_ONBOARDING_GALLERY_APP
  @State private var hasHydratedProfile = true
  #else
  @State private var hasHydratedProfile = false
  #endif
  @FocusState private var isFocused: Bool

  @EnvironmentObject private var nav: OnboardingNavigation
  #if IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject private var gallery: OnboardingGallerySession
  #else
  @EnvironmentObject private var appNavigation: Navigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  #endif
  @FormState private var formState

  var body: some View {
    Group {
      if hasHydratedProfile {
        OnboardingFormPage(focus: $isFocused) {
          OnboardingFormHeader(title: Text("Choose a username"), systemImage: "at")

          VStack(spacing: 8) {
            usernameSection

            if !errorMsg.isEmpty {
              Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
          }
        } actions: {
          bottomButton
        }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { await hydratePersistedProfile() }
    .task(id: hasHydratedProfile ? nav.profileUsername : nil) { await checkUsername() }
  }
}

extension OnboardingUsername {
  @MainActor
  private func hydratePersistedProfile() async {
    #if !IOS_ONBOARDING_GALLERY_APP
    nav.prepareProfileDraft(for: userId)
    defer { hasHydratedProfile = true }

    do {
      guard let user = try await User.fetch(id: userId, from: database) else { return }
      guard nav.profileUsername.isEmpty else { return }
      nav.profileUsername = cleanUsername(user.username ?? "")
    } catch {
      Log.shared.error("Failed to load persisted onboarding username", error: error)
    }
    #endif
  }

  @MainActor
  private func checkUsername() async {
    guard hasHydratedProfile else { return }

    let candidate = cleanUsername(nav.profileUsername)
    errorMsg = ""
    guard candidate.count >= 2 else {
      usernameStatus = .idle
      return
    }

    #if IOS_ONBOARDING_GALLERY_APP
    usernameStatus = candidate == "taken" ? .taken : .available
    #else
    usernameStatus = .checking
    do {
      try await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, cleanUsername(nav.profileUsername) == candidate else { return }
      let result = try await realtimeV2.checkUsername(candidate)
      guard !Task.isCancelled, cleanUsername(nav.profileUsername) == candidate else { return }

      withAnimation(.smooth(duration: 0.15)) {
        usernameStatus = switch result.availability {
        case .usernameAvailable, .usernameCurrent: .available
        case .usernameTaken, .usernameReserved, .usernameInvalid: .taken
        case .unspecified, .UNRECOGNIZED: .idle
        }
      }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      Log.shared.error("Failed to check onboarding username", error: error)
      usernameStatus = .idle
      errorMsg = error.localizedDescription
    }
    #endif
  }

  private func submitUsername() {
    guard !formState.isLoading, usernameStatus == .available else { return }

    #if IOS_ONBOARDING_GALLERY_APP
    gallery.didFinish = true
    #else
    let candidate = cleanUsername(nav.profileUsername)
    Task {
      do {
        formState.startLoading()
        let result = try await realtimeV2.changeUsername(candidate)
        await realtimeV2.applyUpdatesAndWait(result.updates)
        _ = try await database.dbWriter.write { db in
          try User.save(db, user: result.user)
        }
        appNavigation.reset()
        nav.reset()
        mainViewRouter.setRoute(route: .main)
        formState.reset()
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
        usernameStatus = .idle
      } catch {
        Log.shared.error("Failed to save onboarding username", error: error)
        errorMsg = error.localizedDescription
        formState.reset()
        usernameStatus = .idle
      }
    }
    #endif
  }

  private func cleanUsername(_ value: String) -> String {
    value
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@")))
      .lowercased()
  }
}

extension OnboardingUsername {
  @ViewBuilder
  private var usernameSection: some View {
    TextField("Username", text: $nav.profileUsername)
      .focused($isFocused)
      .textContentType(.username)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled(true)
      .multilineTextAlignment(.center)
      .onboardingFormField(horizontalPadding: 48)
      .overlay(alignment: .trailing) {
        usernameStatusIndicator
          .padding(.trailing, 20)
      }
      .onSubmit { submitUsername() }
  }

  @ViewBuilder
  private var usernameStatusIndicator: some View {
    if cleanUsername(nav.profileUsername).count >= 2 {
      switch usernameStatus {
      case .idle:
        EmptyView()
      case .checking:
        Image(systemName: "hourglass")
          .font(.callout)
          .foregroundColor(.secondary)
      case .available:
        Image(systemName: "checkmark.circle")
          .font(.callout)
          .foregroundColor(.green)
      case .taken:
        Image(systemName: "xmark.circle")
          .font(.callout)
          .foregroundColor(.red)
      }
    }
  }

  @ViewBuilder
  private var bottomButton: some View {
    Button(formState.isLoading ? "Creating Account..." : "Continue") {
      submitUsername()
    }
    .buttonStyle(OnboardingFormButtonStyle())
    .disabled(formState.isLoading || usernameStatus != .available)
  }
}

#if !IOS_ONBOARDING_GALLERY_APP
#Preview("Profile - Light Mode") {
  Profile(userId: 1)
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("Profile - Dark Mode") {
  Profile(userId: 1)
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("Profile - Compact") {
  Profile(userId: 1)
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environment(\.appDatabase, AppDatabase.empty())
    .previewDevice("iPhone SE (3rd generation)")
}

#Preview("Profile - Large Text") {
  Profile(userId: 1)
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environment(\.appDatabase, AppDatabase.empty())
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Username") {
  OnboardingUsername(userId: 1)
    .environmentObject(OnboardingNavigation())
    .environmentObject(Navigation())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}
#endif
