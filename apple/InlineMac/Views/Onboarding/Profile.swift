import AppKit
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import MemojiKit
import MultipartFormDataKit
import Observation
import RealtimeV2
import SwiftUI

@MainActor
@Observable
final class OnboardingProfileSetupModel {
  enum UsernameState: Equatable {
    case idle
    case checking
    case available
    case unavailable
    case current
    case invalid

    var message: LocalizedStringResource? {
      switch self {
      case .idle: nil
      case .checking: "Checking availability..."
      case .available: "Available"
      case .unavailable: "Not available"
      case .current: "Your current username"
      case .invalid: "Use at least 2 characters"
      }
    }

    var canContinue: Bool {
      switch self {
      case .available, .current: true
      case .idle, .checking, .unavailable, .invalid: false
      }
    }
  }

  var name = ""
  var username = ""
  private(set) var previewImage: NSImage?
  private(set) var hasPhoto = false
  private(set) var isSavingName = false
  private(set) var isSavingUsername = false
  private(set) var isUploadingPhoto = false
  private(set) var usernameState: UsernameState = .idle
  var errorMessage: String?
  private(set) var currentUsername: String?
  private(set) var savedUserInfo: UserInfo?

  private var hydrated = false

  func hydrate(user: InlineKit.User?) {
    guard !hydrated else { return }

    if let user {
      hydrated = true
      savedUserInfo = UserInfo(user: user)
      let fullName = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
      name = fullName.isEmpty ? Self.systemFullName : fullName
      username = user.username ?? ""
      currentUsername = user.username
      hasPhoto = user.profileFileUniqueId != nil || user.profileCdnUrl != nil || user.profileLocalPath != nil
    } else if name.isEmpty {
      name = Self.systemFullName
    }
  }

  func saveName(realtimeV2: RealtimeV2) async -> Bool {
    guard !isSavingName else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      errorMessage = "Enter your name to continue."
      return false
    }

    isSavingName = true
    errorMessage = nil
    defer { isSavingName = false }

    do {
      let components = Self.nameComponents(trimmed)
      let result = try await realtimeV2.updateProfile(
        firstName: components.firstName,
        lastName: components.lastName ?? "",
        bio: nil
      )
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func usernameDidChange(currentUsername: String?) {
    let value = cleanUsername(username)
    errorMessage = nil
    usernameState = value == currentUsername && !value.isEmpty ? .current : .idle
  }

  func checkUsername(currentUsername: String?, realtimeV2: RealtimeV2) async {
    let candidate = cleanUsername(username)
    if candidate == currentUsername, !candidate.isEmpty {
      errorMessage = nil
      usernameState = .current
      return
    }
    guard candidate.count >= 2 else {
      usernameState = candidate.isEmpty ? .idle : .invalid
      return
    }

    errorMessage = nil
    usernameState = .checking
    do {
      let result = try await realtimeV2.checkUsername(candidate)
      guard cleanUsername(username) == candidate, !Task.isCancelled else { return }
      usernameState = switch result.availability {
      case .usernameAvailable: .available
      case .usernameCurrent: .current
      case .usernameTaken, .usernameReserved: .unavailable
      case .usernameInvalid: .invalid
      case .unspecified, .UNRECOGNIZED: .idle
      }
    } catch {
      guard !Task.isCancelled else { return }
      usernameState = .idle
      errorMessage = error.localizedDescription
    }
  }

  func saveUsername(currentUsername: String?, realtimeV2: RealtimeV2) async -> Bool {
    guard !isSavingUsername, usernameState.canContinue else { return false }
    let candidate = cleanUsername(username)

    isSavingUsername = true
    errorMessage = nil
    defer { isSavingUsername = false }

    do {
      let result = try await realtimeV2.changeUsername(candidate)
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func uploadPhoto(data: Data, realtimeV2: RealtimeV2) async -> Bool {
    guard !isUploadingPhoto else { return false }
    isUploadingPhoto = true
    errorMessage = nil
    defer { isUploadingPhoto = false }

    do {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try ProfilePhotoProcessor.prepare(data)
      }.value
      let upload = try await ApiClient.shared.uploadFile(
        type: .photo,
        data: prepared,
        filename: "profile-photo.png",
        mimeType: .imagePng,
        progress: { _ in }
      )
      let result = try await realtimeV2.setProfilePhoto(fileUniqueID: upload.fileUniqueId)
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user, preservesProfilePhoto: false)
      await cacheSelectedPhoto(prepared, userID: result.user.id)
      previewImage = NSImage(data: prepared)
      hasPhoto = true
      return true
    } catch {
      Log.shared.error("Failed to set onboarding profile photo", error: error)
      errorMessage = error.localizedDescription
      return false
    }
  }

  func removePhoto(realtimeV2: RealtimeV2) async {
    guard hasPhoto, !isUploadingPhoto else { return }
    isUploadingPhoto = true
    errorMessage = nil
    defer { isUploadingPhoto = false }

    do {
      let result = try await realtimeV2.setProfilePhoto(fileUniqueID: nil)
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user, preservesProfilePhoto: false)
      previewImage = nil
      hasPhoto = false
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func save(
    _ user: InlineProtocol.User,
    preservesProfilePhoto: Bool = true
  ) async throws {
    let previousUserInfo = savedUserInfo
    let savedUser = try await AppDatabase.shared.dbWriter.write { db in
      try User.save(db, user: user)
    }

    var previewUser = savedUser
    if preservesProfilePhoto, hasPhoto, let previousUser = previousUserInfo?.user {
      previewUser.profileFileId = previewUser.profileFileId ?? previousUser.profileFileId
      previewUser.profileFileUniqueId = previewUser.profileFileUniqueId ?? previousUser.profileFileUniqueId
      previewUser.profileCdnUrl = previewUser.profileCdnUrl ?? previousUser.profileCdnUrl
      previewUser.profileLocalPath = previewUser.profileLocalPath ?? previousUser.profileLocalPath
    }
    savedUserInfo = UserInfo(
      user: previewUser,
      profilePhotos: preservesProfilePhoto ? previousUserInfo?.profilePhoto : nil
    )
  }

  private func cacheSelectedPhoto(_ data: Data, userID: Int64) async {
    do {
      try await User.cacheImageData(userId: userID, data: data)
      if let cachedUser = try await AppDatabase.shared.dbWriter.read({ db in
        try User.fetchOne(db, id: userID)
      }) {
        savedUserInfo = UserInfo(user: cachedUser)
      }
    } catch {
      Log.shared.error("Failed to cache onboarding profile photo", error: error)
    }
  }

  var messagePreviewIdentity: OnboardingPreviewIdentity {
    let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let savedName = savedUserInfo?.user.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let displayName = if !enteredName.isEmpty {
      enteredName
    } else if !savedName.isEmpty {
      savedName
    } else {
      String(localized: "You")
    }
    return OnboardingPreviewIdentity(displayName: displayName, avatarImage: previewImage)
  }

  private func cleanUsername(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@")))
  }

  private static var systemFullName: String {
    NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func nameComponents(_ fullName: String) -> (firstName: String, lastName: String?) {
    let formatter = PersonNameComponentsFormatter()
    if let components = formatter.personNameComponents(from: fullName),
       let givenName = components.givenName,
       !givenName.isEmpty {
      return (givenName, components.familyName)
    }

    let parts = fullName.split(separator: " ", maxSplits: 1).map(String.init)
    return (parts.first ?? fullName, parts.count > 1 ? parts[1] : nil)
  }
}

struct OnboardingProfile: View {
  @Environment(\.dependencies) private var dependencies
  @EnvironmentStateObject private var root: RootData
  @EnvironmentObject private var onboarding: OnboardingViewModel
  @Environment(OnboardingProfileSetupModel.self) private var model
  @Environment(\.realtimeV2) private var realtimeV2
  @FocusState private var isNameFocused: Bool
  private let memojiLog = Log.scoped("OnboardingProfile.Memoji")

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  var body: some View {
    @Bindable var model = model

    OnboardingStepLayout(
      title: "Set up your profile"
    ) {
      VStack(spacing: 18) {
        EditableProfileAvatar(
          size: 64,
          hasPhoto: model.hasPhoto,
          showsMemoji: showsMemojiPickerOption,
          isBusy: model.isUploadingPhoto,
          onPickFile: { url in
            Task { await uploadFile(url) }
          },
          onFilePickerFailure: { _ in
            model.errorMessage = "That image could not be opened."
          },
          onUsePhotoData: { data in
            await model.uploadPhoto(data: data, realtimeV2: realtimeV2)
          },
          onMemojiFailure: handleMemojiFailure,
          onRemove: removePhoto,
          avatar: { size in
            OnboardingAvatarContent(
              size: size,
              userInfo: root.currentUserInfo,
              fallbackName: model.name,
              previewImage: model.previewImage,
              hasPhoto: model.hasPhoto
            )
          }
        )
        .help("Choose or drop a profile photo")

        GrayTextField("Your name", text: $model.name)
          .textContentType(.name)
          .focused($isNameFocused)
          .frame(width: 280)
          .disabled(model.isSavingName)
          .onSubmit(continueToUsername)

        OnboardingInlineError(message: model.errorMessage)

        InlineButton {
          continueToUsername()
        } label: {
          OnboardingLoadingLabel(title: "Continue", isLoading: model.isSavingName)
        }
        .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .task(id: root.currentUser?.id) {
      model.hydrate(user: root.currentUser)
      isNameFocused = true
    }
  }

  private func continueToUsername() {
    Task {
      if await model.saveName(realtimeV2: realtimeV2) {
        model.usernameDidChange(currentUsername: model.currentUsername)
        onboarding.navigate(to: .username)
      }
    }
  }

  private func uploadFile(_ url: URL) async {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? 0) <= 10 * 1_024 * 1_024 else {
        model.errorMessage = "Choose an image smaller than 10 MB."
        return
      }
      await model.uploadPhoto(data: try Data(contentsOf: url), realtimeV2: realtimeV2)
    } catch {
      model.errorMessage = "That image could not be opened."
    }
  }

  private func removePhoto() {
    Task { await model.removePhoto(realtimeV2: realtimeV2) }
  }

  private var showsMemojiPickerOption: Bool {
    MemojiBetaRollout.isEnabled(dependencies: dependencies)
  }

  private func handleMemojiFailure(_ error: MemojiError) {
    let message = "Memoji beta failure [\(error.diagnosticCode.rawValue)]: \(error.diagnosticSummary)"
    if error.diagnosticCode == .noSavedMemoji {
      memojiLog.info(message)
    } else {
      memojiLog.error(
        message,
        error: MemojiBetaDiagnosticError(
          code: error.diagnosticCode,
          summary: error.diagnosticSummary
        )
      )
    }
  }
}

struct OnboardingUsername: View {
  @EnvironmentObject private var onboarding: OnboardingViewModel
  @Environment(OnboardingProfileSetupModel.self) private var model
  @Environment(\.realtimeV2) private var realtimeV2
  @FocusState private var isFocused: Bool

  var body: some View {
    @Bindable var model = model

    VStack {
      Image(systemName: "person.crop.circle.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundColor(.primary)
        .padding(.bottom, 4)

      Text("Choose a username")
        .font(.system(size: 21.0, weight: .semibold))
        .foregroundStyle(.primary)

      GrayTextField(
        "username",
        text: $model.username,
        prefix: "@",
        centersPlaceholder: true
      )
        .textContentType(.username)
        .focused($isFocused)
        .frame(width: 280)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onSubmit(continueToAppearance)

      if let message = model.usernameState.message {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(width: 260)
          .padding(.bottom, 8)
          .contentTransition(.opacity)
      }

      if let error = model.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(width: 300)
          .padding(.bottom, 8)
      }

      InlineButton {
        continueToAppearance()
      } label: {
        OnboardingLoadingLabel(title: "Continue", isLoading: model.isSavingUsername)
      }
      .disabled(!model.usernameState.canContinue || model.isSavingUsername)
    }
    .padding()
    .animation(.easeOut(duration: 0.15), value: model.usernameState)
    .task {
      isFocused = true
    }
    .task(id: model.username) {
      model.usernameDidChange(currentUsername: model.currentUsername)
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await model.checkUsername(currentUsername: model.currentUsername, realtimeV2: realtimeV2)
    }
  }

  private func continueToAppearance() {
    Task {
      if await model.saveUsername(currentUsername: model.currentUsername, realtimeV2: realtimeV2) {
        onboarding.navigate(to: .appearance)
      }
    }
  }
}

struct OnboardingStepLayout<Content: View>: View {
  let title: LocalizedStringKey
  let content: Content

  init(
    title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      Text(title)
        .font(.title2.weight(.semibold))
      content
        .padding(.top, 22)
      Spacer()
    }
    .padding(32)
    .frame(minHeight: 430)
  }
}

private struct OnboardingAvatarContent: View {
  let size: CGFloat
  let userInfo: UserInfo?
  let fallbackName: String
  let previewImage: NSImage?
  let hasPhoto: Bool

  @ViewBuilder
  var body: some View {
    if let previewImage {
      Image(nsImage: previewImage)
        .resizable()
        .scaledToFill()
    } else if let userInfo, hasPhoto {
      UserAvatar(userInfo: userInfo, size: size)
    } else if fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      InitialsCircle(name: fallbackName, size: size)
    } else {
      Circle()
        .fill(.primary.opacity(0.07))
    }
  }
}

private struct OnboardingInlineError: View {
  let message: String?

  var body: some View {
    if let message {
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
        .frame(width: 300)
    }
  }
}

private struct OnboardingLoadingLabel: View {
  let title: LocalizedStringKey
  let isLoading: Bool

  var body: some View {
    if isLoading {
      ProgressView().controlSize(.small).frame(width: 70)
    } else {
      Text(title).padding(.horizontal)
    }
  }
}

#Preview {
  OnboardingProfile()
    .appDatabase(AppDatabase.empty())
    .environmentObject(OnboardingViewModel())
    .environment(OnboardingProfileSetupModel())
    .frame(width: 900, height: 600)
}
