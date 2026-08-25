import Auth
import InlineKit
import Logger
import RealtimeV2
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
  @State private var hasHydratedProfile = false
  @FocusState private var isFocused: Bool

  @EnvironmentObject private var nav: OnboardingNavigation
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @FormState private var formState

  private let placeHolder = "Name"

  var body: some View {
    Group {
      if hasHydratedProfile {
        VStack(spacing: 20) {
          Spacer()

          VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
              .frame(width: 34, height: 34)
              .foregroundColor(.primary)

            Text(NSLocalizedString("Set up your profile", comment: "Profile setup title"))
              .font(.onboardingIOSTitle.weight(.medium))
              .foregroundStyle(.primary)
          }

          VStack(spacing: 8) {
            nameSection

            if !errorMsg.isEmpty {
              Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, OnboardingUtils.shared.hPadding)

          Spacer()
        }
        .safeAreaInset(edge: .bottom) { bottomButton }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: nav.profileName) { _, _ in errorMsg = "" }
    .task { await hydratePersistedProfile() }
  }
}

extension Profile {
  @MainActor
  private func hydratePersistedProfile() async {
    nav.prepareProfileDraft(for: userId)
    defer {
      hasHydratedProfile = true
      isFocused = true
    }

    do {
      guard let user = try await User.fetch(id: userId, from: database) else { return }
      if nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let persistedName = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        nav.profileName = persistedName
      }
    } catch {
      Log.shared.error("Failed to load persisted onboarding profile", error: error)
    }
  }

  private func submitName() {
    guard !formState.isLoading else { return }

    Task {
      do {
        formState.startLoading()
        let trimmedName = nav.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
          errorMsg = "Please enter your name"
          formState.reset()
          return
        }

        let (firstName, lastName) = parseNameComponents(from: trimmedName)
        let result = try await realtimeV2.updateProfile(
          firstName: firstName,
          lastName: lastName,
          bio: nil
        )
        await realtimeV2.applyUpdates(result.updates)
        try await database.dbWriter.write { db in
          try User(from: result.user).save(db)
        }
        formState.reset()
        nav.push(.username(userId: userId))
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
      } catch {
        Log.shared.error("Failed to save onboarding name", error: error)
        errorMsg = "Failed to save your name. Please try again."
        formState.reset()
      }
    }
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
  @ViewBuilder
  private var nameSection: some View {
    TextField(placeHolder, text: $nav.profileName)
      .focused($isFocused)
      .textContentType(.name)
      .textInputAutocapitalization(.words)
      .multilineTextAlignment(.center)
      .font(.body)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(Color.onboardingSystemGray4, lineWidth: 0.5)
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .onSubmit { submitName() }
  }

  @ViewBuilder
  private var bottomButton: some View {
    Button(formState.isLoading ? "Saving..." : "Continue") {
      submitName()
    }
    .buttonStyle(OnboardingAccentButtonStyle())
    .frame(maxWidth: .infinity)
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    .disabled(formState.isLoading)
    .opacity(formState.isLoading ? 0.5 : 1)
  }
}

struct OnboardingUsername: View {
  let userId: Int64

  @State private var errorMsg = ""
  @State private var usernameStatus: UsernameStatus = .idle
  @State private var hasHydratedProfile = false
  @FocusState private var isFocused: Bool

  @EnvironmentObject private var nav: OnboardingNavigation
  @EnvironmentObject private var appNavigation: Navigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @FormState private var formState

  var body: some View {
    Group {
      if hasHydratedProfile {
        VStack(spacing: 20) {
          Spacer()

          VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
              .frame(width: 34, height: 34)
              .foregroundColor(.primary)

            Text("Choose a username")
              .font(.onboardingIOSTitle.weight(.medium))
              .foregroundStyle(.primary)
          }

          VStack(spacing: 8) {
            usernameSection

            if !errorMsg.isEmpty {
              Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, OnboardingUtils.shared.hPadding)

          Spacer()
        }
        .safeAreaInset(edge: .bottom) { bottomButton }
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
    nav.prepareProfileDraft(for: userId)
    defer {
      hasHydratedProfile = true
      isFocused = true
    }

    do {
      guard let user = try await User.fetch(id: userId, from: database) else { return }
      guard nav.profileUsername.isEmpty else { return }
      nav.profileUsername = cleanUsername(user.username ?? "")
    } catch {
      Log.shared.error("Failed to load persisted onboarding username", error: error)
    }
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
  }

  private func submitUsername() {
    guard !formState.isLoading, usernameStatus == .available else { return }

    let candidate = cleanUsername(nav.profileUsername)
    Task {
      do {
        formState.startLoading()
        let result = try await realtimeV2.changeUsername(candidate)
        await realtimeV2.applyUpdates(result.updates)
        try await database.dbWriter.write { db in
          try User(from: result.user).save(db)
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
      .font(.body)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(Color.onboardingSystemGray4, lineWidth: 0.5)
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
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
    .buttonStyle(OnboardingAccentButtonStyle())
    .frame(maxWidth: .infinity)
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    .disabled(formState.isLoading || usernameStatus != .available)
    .opacity((formState.isLoading || usernameStatus != .available) ? 0.5 : 1)
  }
}

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
